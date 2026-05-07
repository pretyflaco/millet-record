// main.swift — meet-record-mac M4
//
// Captures 5 seconds of dual-channel audio:
//   - Microphone via AVAudioEngine input tap   → left channel (L)
//   - System audio via Core Audio Process Tap  → right channel (R)
// Both streams are downmixed to 16 kHz mono Float32, paired by a
// free-running ring-buffer Mixer with ~20 ms drain, soft-clipped via
// tanh, and written as a stereo s16le 16 kHz WAV.
//
// Output contract is unchanged from M3 (stereo s16le 16 kHz WAV with
// 44-byte standard header), only what's *in* the left channel changes:
// M3 wrote zeros, M4 writes mic samples.
//
// Usage (M4):
//   meet-record-mac <output.wav>
//
// CLI parsing, signal handling, q-byte stop protocol, status-fd, and
// per-app capture selection all land in M5.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AVFoundation
import AudioToolbox

// macOS 14.4 is enforced by Package.swift's .macOS("14.4") platform pin.

// MARK: - Argument parsing (intentionally trivial in M4)

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: meet-record-mac <output.wav>\n".utf8))
    exit(2)
}
let outputURL = URL(fileURLWithPath: args[1])

// MARK: - Constants + debug helper

let outputSampleRate: Double = 16_000
let outputChannels: UInt16 = 2  // L=mic, R=system

// MEET_RECORD_MAC_DEBUG=1 enables per-callback frame-count logging.
// Used to localize duration drift bugs without an external ffprobe round-trip.
let DEBUG_LOGGING = ProcessInfo.processInfo.environment["MEET_RECORD_MAC_DEBUG"] != nil

@inline(__always)
func debugLog(_ msg: @autoclosure () -> String) {
    if DEBUG_LOGGING {
        FileHandle.standardError.write(Data(msg().utf8))
    }
}

// MARK: - WAV writer + Mixer

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

// MARK: - Process tap (system audio → right channel)

// Reuse the M3 conversion path: tap delivers in its native format
// (typically 44.1 / 48 kHz stereo float32); we downmix to 16 kHz mono and
// push to mixer.pushSystem(...).

let tap = ProcessTap()
var sysConverter: AVAudioConverter?
var sysSourceFormat: AVAudioFormat?

let monoTargetFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: outputSampleRate,
    channels: 1,
    interleaved: false
)!

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

do {
    try tap.start(handler: handleTapBuffer)
} catch {
    FileHandle.standardError.write(Data("error: failed to start tap: \(error)\n".utf8))
    mixer.stopAndFlush()
    try? writer.close()
    exit(1)
}

// MARK: - Mic capture (mic → left channel)

// Track when the first mic callback fires (relative to tap-start) so the
// "done:" summary line can report mic warmup latency. AVAudioEngine input
// has a known cold-start delay (~1-2 s on Apple Silicon); the value lets
// us confirm Mixer.markMicReady() is being called at a sensible time.
let recordingStartedAt = Date()
let micFirstSeenLock = NSLock()
var micFirstSeenAt: TimeInterval? = nil

let mic = MicCapture(targetSampleRate: outputSampleRate)
do {
    // MicCapture.start is @MainActor because AVAudioEngine input setup
    // must happen on the main thread. Top-level main.swift code already
    // runs on the main thread, so MainActor.assumeIsolated's runtime
    // check (Thread.isMainThread) succeeds without dispatching.
    try MainActor.assumeIsolated {
        try mic.start { samples, count in
            // First non-empty mic delivery: discard any pre-mic system
            // audio that accumulated during AVAudioEngine cold start.
            // markMicReady() is idempotent and lock-checked, so calling
            // it on every callback is cheap after the first.
            if count > 0 {
                micFirstSeenLock.lock()
                if micFirstSeenAt == nil {
                    micFirstSeenAt = Date().timeIntervalSince(recordingStartedAt)
                }
                micFirstSeenLock.unlock()
                mixer.markMicReady()
            }
            mixer.pushMic(samples, count: count)
            debugLog("mic: outFrames=\(count) cum=\(mixer.micPushed)\n")
        }
    }
} catch {
    FileHandle.standardError.write(Data("error: failed to start mic capture: \(error)\n".utf8))
    tap.stop()
    mixer.stopAndFlush()
    try? writer.close()
    exit(1)
}

// MARK: - Run

let captureSeconds: TimeInterval = 5.0
FileHandle.standardError.write(Data(
    "meet-record-mac M4.2: capturing \(Int(captureSeconds))s of mic+system audio → \(outputURL.path)\n".utf8
))

Thread.sleep(forTimeInterval: captureSeconds)

mic.stop()
tap.stop()
mixer.stopAndFlush()

do {
    try writer.close()
} catch {
    FileHandle.standardError.write(Data("error: failed to close WAV: \(error)\n".utf8))
    exit(1)
}

// Restore the M3-style "done:" line and extend it with push/emit counters
// so duration drift is visible from the run output alone (no ffprobe needed).
//
// Interpretation guide for future debugging:
//   paired ≈ wall_clock * 16000          → recording is correctly real-time
//   paired ≈ min(mic_push, sys_push)     → drainOnce is using min-semantics correctly
//   paired ≫ min(mic_push, sys_push)     → mixer is over-emitting (was the M4 bug:
//                                          old max(...) + zero-pad inflated by ~2×)
//   sys_discarded > 0                    → markMicReady() ran; pre-mic system audio
//                                          was dropped (expected: AVAudioEngine has
//                                          ~1-2 s cold-start latency on Apple Silicon)
let pairedFrames = mixer.framesEmitted
let durationSec = Double(pairedFrames) / outputSampleRate
micFirstSeenLock.lock()
let micWarmupSec = micFirstSeenAt
micFirstSeenLock.unlock()
let micWarmupStr = micWarmupSec.map { String(format: "%.3fs", $0) } ?? "never"
let summary = String(
    format: """
    done: wrote %d paired frames (~%.2fs) to %@
      push counters:    mic=%d sys=%d
      emit counter:     paired=%d
      mic_first_seen:   %@
      sys_discarded:    %d  (pre-mic system audio dropped by markMicReady)

    """,
    pairedFrames, durationSec, outputURL.path,
    mixer.micPushed, mixer.sysPushed,
    pairedFrames,
    micWarmupStr,
    mixer.sysDiscardedAtMicReady
)
FileHandle.standardError.write(Data(summary.utf8))
exit(0)
