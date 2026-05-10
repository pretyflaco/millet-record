// SyntheticSilence.swift
//
// When `--mic none` or `--system none` is requested, the corresponding
// real producer (MicCapture / ProcessTap) is never started. The Mixer's
// drainOnce uses `min(micAvail, sysAvail)` semantics, which means it
// emits zero frames if either side never produces. To keep the surviving
// side flowing into the WAV, we drive the absent side with a small
// background timer that pushes zeros at the output sample rate.
//
// This deliberately re-uses the Mixer's existing pair-emit semantics
// rather than adding a `--system none` / `--mic none` branch inside
// Mixer itself. Net cost: 1 file, 1 small dispatch-timer object, and a
// fixed `[Float]` zero buffer reused across ticks.
//
// Sample-rate matching: both Mic and ProcessTap downsample to 16 kHz
// mono before pushing into the Mixer (see main.swift's converter
// pipelines). So the synthetic feed pushes 16 kHz × interval frames.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Dispatch

/// Pumps a steady stream of zero samples into one of the Mixer's input
/// channels. Used when `--mic none` or `--system none` is selected.
final class SyntheticSilence {
    enum Channel: Equatable {
        case mic
        case system
    }

    private weak var mixer: Mixer?
    private let channel: Channel
    private let sampleRate: Int
    private let intervalMs: Int
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var zeros: [Float] = []

    init(mixer: Mixer, channel: Channel, sampleRate: Int = 16_000, intervalMs: Int = 20) {
        self.mixer = mixer
        self.channel = channel
        self.sampleRate = sampleRate
        self.intervalMs = intervalMs
        self.queue = DispatchQueue(
            label: "tools.pretyflaco.meetrecordmac.synthetic-\(channel == .mic ? "mic" : "sys")",
            qos: .userInitiated
        )
        // Pre-allocate one tick's worth of zeros. Reused across calls.
        let frames = sampleRate * intervalMs / 1000
        self.zeros = [Float](repeating: 0.0, count: frames)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(
            deadline: .now() + .milliseconds(intervalMs),
            repeating: .milliseconds(intervalMs)
        )
        t.setEventHandler { [weak self] in
            self?.tick()
        }
        t.resume()
        self.timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    deinit { stop() }

    private func tick() {
        guard let mixer = mixer else { return }
        zeros.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            switch channel {
            case .mic:
                mixer.pushMic(base, count: zeros.count)
            case .system:
                mixer.pushSystem(base, count: zeros.count)
            }
        }
    }
}
