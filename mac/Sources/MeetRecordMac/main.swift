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

// MARK: - Constants

let outputSampleRate: Double = 16_000
let outputChannels: UInt16 = 2  // L=mic, R=system

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

let mic = MicCapture(targetSampleRate: outputSampleRate)
do {
    // MicCapture.start is @MainActor because AVAudioEngine input setup
    // must happen on the main thread. Top-level main.swift code already
    // runs on the main thread, so MainActor.assumeIsolated's runtime
    // check (Thread.isMainThread) succeeds without dispatching.
    try MainActor.assumeIsolated {
        try mic.start { samples, count in
            mixer.pushMic(samples, count: count)
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
    "meet-record-mac M4: capturing \(Int(captureSeconds))s of mic+system audio → \(outputURL.path)\n".utf8
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

FileHandle.standardError.write(Data("done: wrote \(outputURL.path)\n".utf8))
exit(0)
