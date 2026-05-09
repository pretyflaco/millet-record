// MicCapture.swift
//
// Microphone capture via AVAudioEngine input node tap. Resamples the
// device-native input format to 16 kHz mono Float32 and emits buffers
// to a caller-supplied closure.
//
// Adapted in spirit from RecapAI/Recap (MIT):
//   Recap/Audio/Capture/MicrophoneCapture+AudioEngine.swift
// Original copyright (c) 2025 Rawand Ahmed Shaswar. See NOTICE.
//
// SPDX-License-Identifier: GPL-3.0-or-later (this adaptation)
// Original Recap source: MIT

import Foundation
import AVFoundation
import OSLog

@available(macOS 14.4, *)
final class MicCapture {
    /// Caller receives a buffer of mono Float32 samples at the configured
    /// `targetSampleRate`. The buffer is owned by AVAudioEngine; copy out if
    /// you need the data beyond the closure scope. Called on a high-priority
    /// background thread; do not block.
    typealias FrameHandler = (UnsafePointer<Float>, Int) -> Void

    private let logger = Logger(subsystem: "tools.pretyflaco.meetrecordmac", category: "MicCapture")

    private let engine = AVAudioEngine()
    private let targetSampleRate: Double

    /// Diagnostic gain multiplier applied to each Float sample before the
    /// caller's frame handler sees them. Default 1.0 (no-op). Set via
    /// `MEET_RECORD_MAC_MIC_GAIN` env var in main.swift. Tracked under
    /// M4.5: the input level gap @patternn observed (mic ~22 dB below sys)
    /// is being investigated; this is the knob the investigation uses to
    /// localize the gap, not a baked-in fix.
    let gain: Float

    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?
    private var handler: FrameHandler?

    /// Native rate of the AVAudioEngine input node (set on `start`).
    /// Exposed so main.swift can include it in the `done:` summary.
    private(set) var nativeSampleRate: Double = 0
    /// Native channel count of the AVAudioEngine input node.
    private(set) var nativeChannelCount: UInt32 = 0
    /// `engine.inputNode.volume` snapshot at start. Useful for telling
    /// "macOS input slider is low" apart from "mic gain is intrinsically
    /// low at unity volume."
    private(set) var inputNodeVolume: Float = 0

    init(targetSampleRate: Double = 16_000, gain: Float = 1.0) {
        self.targetSampleRate = targetSampleRate
        self.gain = gain
    }

    /// Start capture. Must be called on the main thread (AVAudioEngine
    /// requires it for input setup).
    @MainActor
    func start(handler: @escaping FrameHandler) throws {
        self.handler = handler

        let input = engine.inputNode
        let nativeFormat = input.outputFormat(forBus: 0)
        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            throw MicCaptureError.engine("Input node returned invalid format: \(nativeFormat)")
        }
        self.sourceFormat = nativeFormat
        self.nativeSampleRate = nativeFormat.sampleRate
        self.nativeChannelCount = nativeFormat.channelCount
        self.inputNodeVolume = input.volume

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw MicCaptureError.engine("Failed to construct target AVAudioFormat")
        }
        self.targetFormat = target

        guard let conv = AVAudioConverter(from: nativeFormat, to: target) else {
            throw MicCaptureError.engine("AVAudioConverter init failed (mic → 16 kHz mono)")
        }
        self.converter = conv

        // Install a tap with a frame size that's small enough for low latency
        // but large enough to amortize per-callback overhead. 1024 frames at
        // the device rate is typically ~21 ms at 48 kHz, which pairs well
        // with the Mixer's 20 ms drain timer.
        input.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        self.handler = nil
    }

    deinit { stop() }

    // MARK: - Private

    private func handle(buffer: AVAudioPCMBuffer) {
        guard let converter = converter, let target = targetFormat, let handler = handler else { return }
        let inFrames = Int(buffer.frameLength)
        if inFrames == 0 { return }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let outFrameCapacity = AVAudioFrameCount(Double(inFrames) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outFrameCapacity) else { return }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error || error != nil {
            logger.warning("convert error: \(error?.localizedDescription ?? "unknown")")
            return
        }

        let outFrames = Int(out.frameLength)
        if outFrames == 0 { return }
        guard let monoPtr = out.floatChannelData?[0] else { return }

        // Diagnostic mic-gain stage (M4.5). Default 1.0 → no-op. Applied
        // pre-handler so the Mixer's tanh soft-clip catches any hot
        // outputs gracefully, rather than producing harsh saturation.
        MicGain.applyInPlace(monoPtr, count: outFrames, gain: gain)

        handler(monoPtr, outFrames)
    }
}

enum MicCaptureError: Error, CustomStringConvertible {
    case engine(String)
    var description: String {
        switch self {
        case .engine(let s): return "MicCapture engine error: \(s)"
        }
    }
}
