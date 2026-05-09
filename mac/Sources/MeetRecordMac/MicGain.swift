// MicGain.swift
//
// Pure helper for the diagnostic mic-gain stage. Multiplies each Float
// sample in-place by a fixed gain factor. Lives in its own file so the
// gain math is unit-testable without instantiating AVAudioEngine —
// XCTest on `macos-14` runners can't always set up live audio sessions.
//
// **This is diagnostic instrumentation, not a fix.** Default gain is 1.0
// (no-op, M4.2 behavior preserved). The `MEET_RECORD_MAC_MIC_GAIN` env
// var lets us experiment with software gain values to localize the M4.5
// mic-vs-system level gap. The eventual fix may or may not bake a
// non-unity default into MicCapture; that decision waits on data.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum MicGain {
    /// Multiply `count` Float samples at `samples` in place by `gain`.
    ///
    /// Applied **before** the tanh soft-clip in the Mixer. Hot inputs
    /// resulting from high gain are caught by the soft-clip stage rather
    /// than producing the harsh saturation pattern naive multiply +
    /// hard-clip would yield. With gain=1.0 this is a deliberate no-op
    /// (early-return) so M4.2 behavior is bit-identical when the env
    /// var is unset.
    static func applyInPlace(
        _ samples: UnsafeMutablePointer<Float>,
        count: Int,
        gain: Float
    ) {
        if gain == 1.0 || count <= 0 { return }
        for i in 0..<count {
            samples[i] *= gain
        }
    }

    /// Parse the `MEET_RECORD_MAC_MIC_GAIN` env var. Defaults to 1.0
    /// (no-op) on any parse failure, keeping the unset-env-var path
    /// safe even with malformed user input.
    static func gainFromEnvironment(_ env: [String: String]) -> Float {
        guard let raw = env["MEET_RECORD_MAC_MIC_GAIN"],
              let parsed = Float(raw),
              parsed.isFinite,
              parsed > 0 else {
            return 1.0
        }
        return parsed
    }
}
