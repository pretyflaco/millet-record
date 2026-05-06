// main.swift — meet-record-mac M3 prototype
//
// Captures 5 seconds of system audio via Core Audio Process Tap, downmixes
// to 16 kHz mono, and writes a stereo s16le 16 kHz WAV with that audio on
// the right channel and zeros on the left.
//
// This is a minimal stepping stone. M4 adds the mic on the left channel;
// M5 adds CLI parsing, signal handling, status-fd, and the q-byte stop
// protocol that meet_record/capture.py expects.
//
// Usage (M3):
//   meet-record-mac <output.wav>
//
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AVFoundation
import AudioToolbox

// MARK: - Argument parsing (intentionally trivial in M3)

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: meet-record-mac <output.wav>\n".utf8))
    exit(2)
}
let outputURL = URL(fileURLWithPath: args[1])

// macOS 14.4 is enforced by Package.swift's .macOS("14.4") platform pin.

// MARK: - Constants

let outputSampleRate: Double = 16_000
let outputChannels: UInt16 = 2  // L=mic (zeros in M3), R=system

// MARK: - WAV writer

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

// MARK: - Process tap + AVAudioConverter pipeline

// We receive system audio in the tap's native format (typically 44.1 or 48 kHz
// float32 stereo). For M3 we mix down to mono and resample to 16 kHz using
// AVAudioConverter, then interleave with a left-channel zero buffer.

let tap = ProcessTap()
var converter: AVAudioConverter?
var sourceFormat: AVAudioFormat?

let targetMonoFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: outputSampleRate,
    channels: 1,
    interleaved: false
)!

let writeQueue = DispatchQueue(label: "tools.pretyflaco.meetrecordmac.write")
var totalRightSamplesWritten: Int = 0

func handleTapBuffer(_ bufferList: AudioBufferList, _ asbd: AudioStreamBasicDescription) {
    // Lazily build the AVAudioFormat + converter once we know the tap's format.
    if sourceFormat == nil {
        var asbdLocal = asbd
        guard let fmt = AVAudioFormat(streamDescription: &asbdLocal) else {
            FileHandle.standardError.write(Data("error: cannot construct AVAudioFormat from tap ASBD\n".utf8))
            return
        }
        sourceFormat = fmt
        converter = AVAudioConverter(from: fmt, to: targetMonoFormat)
        if converter == nil {
            FileHandle.standardError.write(Data("error: AVAudioConverter init failed\n".utf8))
            return
        }
    }

    guard let sourceFormat = sourceFormat,
          let converter = converter else { return }

    // Wrap the incoming AudioBufferList in an AVAudioPCMBuffer (no copy).
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

    // Compute output capacity proportional to sample-rate ratio, with slack.
    let ratio = targetMonoFormat.sampleRate / sourceFormat.sampleRate
    let outFrameCapacity = AVAudioFrameCount(Double(frameCapacity) * ratio + 64)

    guard let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: targetMonoFormat,
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

    // Convert mono float32 → interleaved stereo s16 with zeros on left.
    guard let monoPtr = outputBuffer.floatChannelData?[0] else { return }
    var stereoSamples = [Int16](repeating: 0, count: outFrames * 2)
    for i in 0..<outFrames {
        let s = monoPtr[i]
        let clipped = max(-1.0, min(1.0, s))
        let int16Sample = Int16(clipped * 32767.0)
        stereoSamples[2 * i] = 0                  // L = mic placeholder (M4 fills this)
        stereoSamples[2 * i + 1] = int16Sample    // R = system audio
    }

    writeQueue.sync {
        do {
            try stereoSamples.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                try writer.writeSamples(base, count: stereoSamples.count)
            }
            totalRightSamplesWritten += outFrames
        } catch {
            FileHandle.standardError.write(Data("warn: WAV write failed: \(error)\n".utf8))
        }
    }
}

// MARK: - Run

do {
    try tap.start(handler: handleTapBuffer)
} catch {
    FileHandle.standardError.write(Data("error: failed to start tap: \(error)\n".utf8))
    try? writer.close()
    exit(1)
}

let captureSeconds: TimeInterval = 5.0
FileHandle.standardError.write(Data("meet-record-mac M3: capturing \(Int(captureSeconds))s of system audio → \(outputURL.path)\n".utf8))

Thread.sleep(forTimeInterval: captureSeconds)

tap.stop()

writeQueue.sync {
    do {
        try writer.close()
    } catch {
        FileHandle.standardError.write(Data("error: failed to close WAV: \(error)\n".utf8))
        exit(1)
    }
}

let durationSec = Double(totalRightSamplesWritten) / outputSampleRate
FileHandle.standardError.write(Data(
    "done: wrote \(totalRightSamplesWritten) frames (~\(String(format: "%.2f", durationSec))s) to \(outputURL.path)\n".utf8
))
exit(0)
