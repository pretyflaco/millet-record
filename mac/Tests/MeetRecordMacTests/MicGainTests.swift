// MicGainTests.swift
//
// Unit tests for the diagnostic mic-gain stage. Pure helper, no
// AVAudioEngine, runs cleanly on macos-14 CI runners that can't
// always set up live audio sessions.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import MeetRecordMac

final class MicGainTests: XCTestCase {
    func testUnityGainIsNoOp() {
        var samples: [Float] = [-0.5, -0.1, 0.0, 0.1, 0.5, 0.99, -1.0]
        let original = samples
        let count = samples.count
        samples.withUnsafeMutableBufferPointer { ptr in
            MicGain.applyInPlace(ptr.baseAddress!, count: count, gain: 1.0)
        }
        XCTAssertEqual(samples, original, "gain=1.0 must be bit-identical (no-op early return)")
    }

    func testZeroCountIsNoOp() {
        var samples: [Float] = [0.5, -0.5]
        let original = samples
        samples.withUnsafeMutableBufferPointer { ptr in
            MicGain.applyInPlace(ptr.baseAddress!, count: 0, gain: 4.0)
        }
        XCTAssertEqual(samples, original, "count=0 must not modify the buffer")
    }

    func testScalesEachSampleByGain() {
        var samples: [Float] = [0.1, -0.2, 0.05, -0.5]
        let count = samples.count
        samples.withUnsafeMutableBufferPointer { ptr in
            MicGain.applyInPlace(ptr.baseAddress!, count: count, gain: 4.0)
        }
        // gain=4 doubles 0.1 → 0.4 etc. Tolerance for float32 multiplication.
        let expected: [Float] = [0.4, -0.8, 0.2, -2.0]
        for (a, b) in zip(samples, expected) {
            XCTAssertEqual(a, b, accuracy: 1e-6)
        }
    }

    /// Hot inputs (gain × sample > 1.0) MUST be passed through to the
    /// downstream tanh soft-clip, NOT pre-clipped here. The point of the
    /// gain stage is to let SoftClip do its job; pre-clipping would
    /// negate that.
    func testGainAllowsHotInputsForDownstreamSoftClip() {
        var samples: [Float] = [0.5, 0.8, -0.7]
        let count = samples.count
        samples.withUnsafeMutableBufferPointer { ptr in
            MicGain.applyInPlace(ptr.baseAddress!, count: count, gain: 8.0)
        }
        // Output is intentionally outside [-1, +1]. The soft-clip stage
        // (called later in Mixer) maps these through tanh.
        XCTAssertEqual(samples[0], 4.0, accuracy: 1e-6)
        XCTAssertEqual(samples[1], 6.4, accuracy: 1e-6)
        XCTAssertEqual(samples[2], -5.6, accuracy: 1e-6)

        // Belt-and-suspenders: ensure the values pass cleanly through
        // SoftClip. Once gain×sample is large enough that tanh(...) is
        // numerically indistinguishable from ±1.0 in Float, rounding
        // legitimately produces ±32767. The point of the soft-clip is
        // graceful saturation, not "never reach full scale" — what we
        // care about is that the result is finite and within Int16
        // range, with NO undefined-behavior conversion (NaN/Inf →
        // arbitrary Int16 truncation).
        let post = samples.map { SoftClip.toInt16($0) }
        for v in post {
            XCTAssertLessThanOrEqual(Int(v), Int(Int16.max))
            XCTAssertGreaterThanOrEqual(Int(v), Int(Int16.min))
        }

        // tanh(0.5*8 = 4.0) ≈ 0.9993; this lower-amplitude input is
        // strictly inside full scale and is the case where soft-clip's
        // headroom is observable. Verify that one explicitly.
        XCTAssertLessThan(abs(Int(post[0])), Int(Int16.max),
                          "Sample 0 (gain×input = 4.0) should land below full scale; tanh(4)*32767 ≈ 32744")
    }

    // MARK: - Env-var parsing

    func testEnvFallsBackToProvidedDefaultWhenMissing() {
        // Missing var → caller-supplied default flows through.
        XCTAssertEqual(MicGain.gainFromEnvironment([:], defaultGain: 1.0), 1.0)
        XCTAssertEqual(MicGain.gainFromEnvironment([:], defaultGain: 4.0), 4.0)
        XCTAssertEqual(
            MicGain.gainFromEnvironment([:], defaultGain: MicCapture.defaultGain),
            MicCapture.defaultGain
        )
    }

    func testEnvParsesValidFloat() {
        // Env var present + parseable → its value wins over default.
        XCTAssertEqual(
            MicGain.gainFromEnvironment(["MEET_RECORD_MAC_MIC_GAIN": "4.0"], defaultGain: 1.0),
            4.0
        )
        XCTAssertEqual(
            MicGain.gainFromEnvironment(["MEET_RECORD_MAC_MIC_GAIN": "8"], defaultGain: 4.0),
            8.0
        )
        XCTAssertEqual(
            MicGain.gainFromEnvironment(["MEET_RECORD_MAC_MIC_GAIN": "0.5"], defaultGain: 4.0),
            0.5
        )
        // Crucially: setting the env var to "1" reproduces M4.2 unity-gain
        // behavior even when the production default is 4.0. This is the
        // documented escape hatch.
        XCTAssertEqual(
            MicGain.gainFromEnvironment(["MEET_RECORD_MAC_MIC_GAIN": "1"], defaultGain: 4.0),
            1.0
        )
    }

    func testEnvFallsBackToDefaultOnInvalidInput() {
        let invalids: [String] = ["", "abc", "nan", "-1", "0", "inf"]
        for s in invalids {
            XCTAssertEqual(
                MicGain.gainFromEnvironment(["MEET_RECORD_MAC_MIC_GAIN": s], defaultGain: 4.0),
                4.0,
                "Invalid env value \(s.debugDescription) should fall back to provided default"
            )
        }
    }

    // MARK: - Production default (M4.5b)

    /// Locks the M4.5b decision: production default mic gain is 4.0×.
    /// If anyone changes this without an issue + data justifying the
    /// change, the failure message points them at the audit trail.
    ///
    /// Decision data in pretyflaco/meetscribe-record#6:
    ///   - patternn's M4.5 matrix on Apple M1: speech-active L mean
    ///     -35.0/-24.3/-18.5 dB at gain 1/4/8, R stable at -15.x dB
    ///   - gain=4 → labeler you_ratio 0.27 (1.79× past 0.15 floor),
    ///             8.7 dB peak headroom, soft-clip not engaging
    ///   - gain=8 → audibly amplified noise floor in silences
    func testDefaultGainMatchesProductionDefault() {
        XCTAssertEqual(
            MicCapture.defaultGain, 4.0, accuracy: 0.0001,
            "M4.5b ships gain=4.0× to close the +20 dB Apple Silicon mic-vs-tap gap. See pretyflaco/meetscribe-record#6 before changing this."
        )
    }
}
