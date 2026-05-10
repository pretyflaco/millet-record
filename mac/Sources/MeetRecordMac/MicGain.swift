// MicGain.swift
//
// Pure helper for the mic-gain stage. Multiplies each Float sample
// in-place by a fixed gain factor. Lives in its own file so the gain
// math is unit-testable without instantiating AVAudioEngine — XCTest
// on `macos-14` runners can't always set up live audio sessions.
//
// History: shipped in M4.5 as diagnostic-only with default 1.0 (no-op,
// M4.2 behavior preserved). Promoted to the production gain stage in
// M4.5b after patternn's matrix data showed gain=4.0 cleanly closes
// the Apple Silicon mic-vs-tap level gap; see MicCapture.defaultGain
// for the full decision audit. The `MEET_RECORD_MAC_MIC_GAIN` env var
// remains as the user-side override.
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
    /// (early-return) so the unity path is bit-identical to no gain
    /// stage at all.
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

    /// Parse the `MEET_RECORD_MAC_MIC_GAIN` env var, falling back to
    /// `defaultGain` when unset, malformed, non-finite, or non-positive.
    /// Pass `MicCapture.defaultGain` from the call site so the production
    /// default flows through one source of truth rather than being
    /// duplicated in this helper.
    ///
    /// - Parameters:
    ///   - env: process environment dictionary (typically
    ///     `ProcessInfo.processInfo.environment`).
    ///   - defaultGain: the value to use when the env var is absent or
    ///     unparseable. Production callers should pass
    ///     `MicCapture.defaultGain`.
    static func gainFromEnvironment(
        _ env: [String: String],
        defaultGain: Float
    ) -> Float {
        guard let raw = env["MEET_RECORD_MAC_MIC_GAIN"],
              let parsed = Float(raw),
              parsed.isFinite,
              parsed > 0 else {
            return defaultGain
        }
        return parsed
    }
}
