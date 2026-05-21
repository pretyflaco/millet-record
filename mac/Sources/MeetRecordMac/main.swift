// main.swift — meet-record-mac M5
//
// CLI dispatch + the long-running `record` loop. Subcommand surface is
// defined in CLI.swift; this file decides what to do based on the
// parsed invocation.
//
// Subcommands:
//   record [...]            — capture mic + system to a WAV
//   devices [--json]        — enumerate input devices
//   probe-permissions       — report TCC status (exit 0 ok / 1 blocked)
//   --version               — print version
//   --help                  — print usage
//
// Stop protocol (record only):
//   * `q` byte on stdin  → graceful flush + exit 0 (mirrors ffmpeg)
//   * EOF on stdin       → graceful flush + exit 0 (parent closed pipe)
//   * SIGINT             → graceful flush + exit 0
//   * SIGTERM            → graceful flush + exit 0
//   * SIGKILL            → no chance to flush; partial WAV with stale
//                          RIFF size header
//   * --max-seconds n    → cap; defaults to 0 (unlimited)
//
// Output contract is unchanged from M4: stereo s16le 16 kHz WAV with
// L = mic, R = system, 44-byte standard header.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AVFoundation
import AudioToolbox

// macOS 14.4 is enforced by Package.swift's .macOS("14.4") platform pin.

// MARK: - Subcommand dispatch

let invocation: CLIInvocation
do {
    invocation = try CLI.parse(Array(CommandLine.arguments.dropFirst()))
} catch let err as CLIError {
    FileHandle.standardError.write(Data("error: \(err.description)\n".utf8))
    FileHandle.standardError.write(Data("run `meet-record-mac --help` for usage.\n".utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(2)
}

switch invocation {
case .help:
    print(CLI.usageText)
    exit(0)
case .version:
    print(CLI.versionString)
    exit(0)
case .devices(let opts):
    runDevices(opts)
case .probePermissions:
    runProbePermissions()
case .requestPermissions:
    runRequestPermissions()
case .record(let opts):
    runRecord(opts)
}

// MARK: - `devices`

func runDevices(_ opts: DevicesOptions) -> Never {
    do {
        let rows = try Devices.listInputs()
        FileHandle.standardOutput.write(Data(Devices.render(rows, json: opts.json).utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: devices enumeration failed: \(error)\n".utf8))
        exit(1)
    }
}

// MARK: - `probe-permissions`

func runProbePermissions() -> Never {
    let report = Permissions.probe()
    FileHandle.standardOutput.write(Data(Permissions.render(report).utf8))
    exit(report.allGranted ? 0 : 1)
}

// MARK: - `request-permissions`

func runRequestPermissions() -> Never {
    let report = Permissions.requestAndProbe()
    FileHandle.standardOutput.write(Data(Permissions.render(report).utf8))
    if !report.allGranted {
        FileHandle.standardError.write(Data(
            """
            Tip: grant permissions in System Settings → Privacy & Security:
              • Microphone → enable for your terminal app
              • System Audio Recording → enable for your terminal app
            On macOS Sequoia+, apps only appear in these lists after they
            first request access. If your terminal is missing, try:
              tccutil reset Microphone
              tccutil reset SystemAudioRecording
            then re-run this command.\n
            """.utf8
        ))
    }
    exit(report.allGranted ? 0 : 1)
}

// MARK: - `record` (the long-running data path)

func runRecord(_ opts: RecordOptions) -> Never {
    let outputURL = URL(fileURLWithPath: opts.outputPath)
    let outputSampleRate = Double(opts.sampleRate)
    let outputChannels: UInt16 = 2  // L=mic, R=system

    // MEET_RECORD_MAC_DEBUG=1 enables per-callback frame-count logging.
    let DEBUG_LOGGING = ProcessInfo.processInfo.environment["MEET_RECORD_MAC_DEBUG"] != nil
    @inline(__always)
    func debugLog(_ msg: @autoclosure () -> String) {
        if DEBUG_LOGGING {
            FileHandle.standardError.write(Data(msg().utf8))
        }
    }

    // MEET_RECORD_MAC_MIC_GAIN=<float> overrides the default mic gain
    // (`MicCapture.defaultGain` = 4.0× as of M4.5b). See MicCapture.swift
    // and pretyflaco/meetscribe-record#6 for the decision audit.
    let micGain = MicGain.gainFromEnvironment(
        ProcessInfo.processInfo.environment,
        defaultGain: MicCapture.defaultGain
    )

    // ─── WAV writer + Mixer ────────────────────────────────────────────────
    let writer: WavWriter
    do {
        writer = try WavWriter(
            url: outputURL,
            sampleRate: UInt32(outputSampleRate),
            channels: outputChannels
        )
    } catch {
        FileHandle.standardError.write(Data("error: failed to open output WAV: \(error)\n".utf8))
        exit(1)
    }
    let mixer = Mixer(writer: writer)
    mixer.start()

    // ─── Stop coordination ────────────────────────────────────────────────
    let stopController = StopController()
    stopController.start()

    // ─── Banner ───────────────────────────────────────────────────────────
    let micLabel: String
    switch opts.mic {
    case .default: micLabel = "default"
    case .none: micLabel = "none"
    case .deviceUID(let s): micLabel = "uid=\(s)"
    }
    let sysLabel: String
    switch opts.system {
    case .system: sysLabel = "system-wide"
    case .none: sysLabel = "none"
    case .appBundleID(let b): sysLabel = "app:\(b)"
    }
    let maxLabel = opts.maxSeconds > 0 ? "max=\(opts.maxSeconds)s" : "max=∞"
    FileHandle.standardError.write(Data(
        "meet-record-mac M5 [mic=\(micLabel) system=\(sysLabel) gain=\(micGain)x \(maxLabel)] → \(outputURL.path)\n".utf8
    ))

    // ─── System audio (right channel) ──────────────────────────────────────
    let monoTargetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: outputSampleRate,
        channels: 1,
        interleaved: false
    )!

    var tap: ProcessTap?
    var sysSilence: SyntheticSilence?
    var sysConverter: AVAudioConverter?
    var sysSourceFormat: AVAudioFormat?

    func handleTapBuffer(_ bufferList: AudioBufferList, _ asbd: AudioStreamBasicDescription) {
        if sysSourceFormat == nil {
            var asbdLocal = asbd
            guard let fmt = AVAudioFormat(streamDescription: &asbdLocal) else {
                FileHandle.standardError.write(Data("error: cannot construct AVAudioFormat from tap ASBD\n".utf8))
                return
            }
            sysSourceFormat = fmt
            sysConverter = AVAudioConverter(from: fmt, to: monoTargetFormat)
            if sysConverter == nil {
                FileHandle.standardError.write(Data("error: AVAudioConverter init failed (system → 16 kHz mono)\n".utf8))
                return
            }
        }
        guard let sourceFormat = sysSourceFormat,
              let converter = sysConverter else { return }

        var mutableList = bufferList
        let frameCapacity = AVAudioFrameCount(
            Int(mutableList.mBuffers.mDataByteSize) / Int(sourceFormat.streamDescription.pointee.mBytesPerFrame)
        )
        guard frameCapacity > 0 else { return }

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            bufferListNoCopy: &mutableList,
            deallocator: nil
        ) else { return }
        inputBuffer.frameLength = frameCapacity

        let ratio = monoTargetFormat.sampleRate / sourceFormat.sampleRate
        let outFrameCapacity = AVAudioFrameCount(Double(frameCapacity) * ratio + 64)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: monoTargetFormat,
            frameCapacity: outFrameCapacity
        ) else { return }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        if status == .error || error != nil {
            FileHandle.standardError.write(Data("warn: convert error: \(error?.localizedDescription ?? "unknown")\n".utf8))
            return
        }
        let outFrames = Int(outputBuffer.frameLength)
        if outFrames == 0 { return }
        guard let monoPtr = outputBuffer.floatChannelData?[0] else { return }
        mixer.pushSystem(monoPtr, count: outFrames)
        debugLog("tap: outFrames=\(outFrames) cum=\(mixer.sysPushed) inFrames=\(frameCapacity) inFmt=\(sourceFormat.sampleRate)Hz/\(sourceFormat.channelCount)ch\n")
    }

    switch opts.system {
    case .system:
        let t = ProcessTap()
        do {
            try t.start(target: .systemWide, handler: handleTapBuffer)
        } catch {
            FileHandle.standardError.write(Data("error: failed to start system tap: \(error)\n".utf8))
            mixer.stopAndFlush()
            try? writer.close()
            exit(1)
        }
        tap = t
    case .appBundleID(let bid):
        let t = ProcessTap()
        do {
            try t.start(target: .bundleID(bid), handler: handleTapBuffer)
        } catch {
            FileHandle.standardError.write(Data("error: failed to start per-app tap (\(bid)): \(error)\n".utf8))
            mixer.stopAndFlush()
            try? writer.close()
            exit(1)
        }
        tap = t
    case .none:
        // Synthetic 16 kHz silence on the system channel so paired emits
        // continue while mic produces real audio.
        let s = SyntheticSilence(mixer: mixer, channel: .system, sampleRate: Int(outputSampleRate))
        s.start()
        sysSilence = s
    }

    // ─── Mic capture (left channel) ────────────────────────────────────────
    let recordingStartedAt = Date()
    let micFirstSeenLock = NSLock()
    var micFirstSeenAt: TimeInterval? = nil

    var mic: MicCapture?
    var micSilence: SyntheticSilence?

    switch opts.mic {
    case .default, .deviceUID:
        let uid: String?
        if case .deviceUID(let u) = opts.mic { uid = u } else { uid = nil }
        let m = MicCapture(targetSampleRate: outputSampleRate, gain: micGain, inputDeviceUID: uid)
        do {
            try MainActor.assumeIsolated {
                try m.start { samples, count in
                    if count > 0 {
                        micFirstSeenLock.lock()
                        let isFirst = micFirstSeenAt == nil
                        if isFirst {
                            micFirstSeenAt = Date().timeIntervalSince(recordingStartedAt)
                        }
                        micFirstSeenLock.unlock()
                        if isFirst {
                            debugLog("mic_input: rate=\(m.nativeSampleRate)Hz channels=\(m.nativeChannelCount) inputVolume=\(m.inputNodeVolume) gain=\(m.gain)\n")
                        }
                        mixer.markMicReady()
                    }
                    mixer.pushMic(samples, count: count)
                    debugLog("mic: outFrames=\(count) cum=\(mixer.micPushed)\n")
                }
            }
        } catch {
            FileHandle.standardError.write(Data("error: failed to start mic capture: \(error)\n".utf8))
            tap?.stop()
            sysSilence?.stop()
            mixer.stopAndFlush()
            try? writer.close()
            exit(1)
        }
        mic = m
    case .none:
        // Synthetic silence on the mic side. Mark mic ready immediately
        // so the mixer doesn't sit waiting for a "real" mic warmup —
        // there's no warmup to wait for in `--mic none` mode.
        let s = SyntheticSilence(mixer: mixer, channel: .mic, sampleRate: Int(outputSampleRate))
        s.start()
        mixer.markMicReady()
        micSilence = s
    }

    // ─── Block on stop signal ─────────────────────────────────────────────
    let stopReason = stopController.wait(
        timeout: opts.maxSeconds > 0 ? opts.maxSeconds : nil
    )
    FileHandle.standardError.write(Data(
        "stopping: reason=\(stopReason.rawValue)\n".utf8
    ))

    // ─── Tear down ────────────────────────────────────────────────────────
    mic?.stop()
    micSilence?.stop()
    tap?.stop()
    sysSilence?.stop()
    mixer.stopAndFlush()

    do {
        try writer.close()
    } catch {
        FileHandle.standardError.write(Data("error: failed to close WAV: \(error)\n".utf8))
        exit(1)
    }

    // ─── done: summary ────────────────────────────────────────────────────
    let pairedFrames = mixer.framesEmitted
    let durationSec = Double(pairedFrames) / outputSampleRate
    micFirstSeenLock.lock()
    let micWarmupSec = micFirstSeenAt
    micFirstSeenLock.unlock()
    let micWarmupStr = micWarmupSec.map { String(format: "%.3fs", $0) } ?? "n/a"
    let micRateStr: String
    let micChannelsStr: String
    let micVolumeStr: String
    let micGainStr: String
    if let m = mic {
        micRateStr = String(format: "%.1f", m.nativeSampleRate)
        micChannelsStr = String(m.nativeChannelCount)
        micVolumeStr = String(format: "%.3f", m.inputNodeVolume)
        micGainStr = String(format: "%.3f", m.gain)
    } else {
        micRateStr = "0.0"
        micChannelsStr = "0"
        micVolumeStr = "0.000"
        micGainStr = "0.000"
    }
    let summary = """
    done: wrote \(pairedFrames) paired frames (~\(String(format: "%.2f", durationSec))s) to \(outputURL.path)
      stop_reason:      \(stopReason.rawValue)
      push counters:    mic=\(mixer.micPushed) sys=\(mixer.sysPushed)
      emit counter:     paired=\(pairedFrames)
      mic_first_seen:   \(micWarmupStr)
      sys_discarded:    \(mixer.sysDiscardedAtMicReady)  (pre-mic system audio dropped by markMicReady)
      mic_input:        rate=\(micRateStr)Hz channels=\(micChannelsStr) inputVolume=\(micVolumeStr) gain=\(micGainStr)

    """
    FileHandle.standardError.write(Data(summary.utf8))
    exit(0)
}
