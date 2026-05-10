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

    /// Default mic gain multiplier (M4.5b).
    ///
    /// **Why 4.0**: On Apple Silicon, AVAudioEngine input levels run ~20 dB
    /// below Process Tap output for the same source material. Without
    /// compensation, downstream channel-energy-based labelers
    /// (`meet/transcribe.py:_label_speakers_from_channels`) fail to
    /// recognize the local scribe (you_ratio ~0.09 < 0.15 threshold).
    ///
    /// 4.0× (≈ +12 dB) was chosen over 8.0× (≈ +18 dB) on patternn's M4.5
    /// matrix data:
    ///   - 4.0× yields you_ratio ≈ 0.27, comfortably past the 0.15 floor
    ///   - 4.0× preserves 8.7 dB of peak headroom (vs 2.6 dB at 8.0×)
    ///   - 4.0× does not engage the tanh soft-clip on normal speech (8.0×
    ///     was observed engaging, costing ~1.5 dB on peaks)
    ///   - 4.0× amplifies the mic's noise floor by 12 dB rather than 18 dB,
    ///     reducing the chance of triggering Whisper's quiet-noise
    ///     hallucinations during silences.
    ///
    /// See pretyflaco/meetscribe-record#6 for the full decision audit.
    /// Override via `MEET_RECORD_MAC_MIC_GAIN=<float>` env var; set to 1.0
    /// to reproduce M4.2 behavior (no gain).
    static let defaultGain: Float = 4.0

    private let logger = Logger(subsystem: "tools.pretyflaco.meetrecordmac", category: "MicCapture")

    private let engine = AVAudioEngine()
    private let targetSampleRate: Double

    /// Static gain multiplier applied to each Float sample before the
    /// caller's frame handler sees them. Default `defaultGain` (= 4.0,
    /// see static doc). Override via `MEET_RECORD_MAC_MIC_GAIN` env var
    /// in main.swift. Set to 1.0 to disable; values > 8.0 will engage
    /// the Mixer's tanh soft-limiter on normal speech peaks.
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

    init(targetSampleRate: Double = 16_000, gain: Float = MicCapture.defaultGain) {
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
