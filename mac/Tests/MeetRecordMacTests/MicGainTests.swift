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
        samples.withUnsafeMutableBufferPointer { ptr in
            MicGain.applyInPlace(ptr.baseAddress!, count: samples.count, gain: 1.0)
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
        samples.withUnsafeMutableBufferPointer { ptr in
            MicGain.applyInPlace(ptr.baseAddress!, count: samples.count, gain: 4.0)
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
        samples.withUnsafeMutableBufferPointer { ptr in
            MicGain.applyInPlace(ptr.baseAddress!, count: samples.count, gain: 8.0)
        }
        // Output is intentionally outside [-1, +1]. The soft-clip stage
        // (called later in Mixer) maps these through tanh.
        XCTAssertEqual(samples[0], 4.0, accuracy: 1e-6)
        XCTAssertEqual(samples[1], 6.4, accuracy: 1e-6)
        XCTAssertEqual(samples[2], -5.6, accuracy: 1e-6)

        // Belt-and-suspenders: ensure the values produce sensible
        // (non-saturated mid-scale) output through SoftClip.
        let post = samples.map { SoftClip.toInt16($0) }
        for v in post {
            // tanh(4) ≈ 0.9993, * 32767 ≈ 32744 — close to but not
            // exactly +32767, leaving the limiter's headroom intact.
            XCTAssertLessThan(abs(Int(v)), Int(Int16.max),
                              "Soft-clip must not produce exactly ±32767 saturation even on extreme gain output")
        }
    }

    // MARK: - Env-var parsing

    func testEnvDefaultsToUnityWhenMissing() {
        XCTAssertEqual(MicGain.gainFromEnvironment([:]), 1.0)
    }

    func testEnvParsesValidFloat() {
        XCTAssertEqual(MicGain.gainFromEnvironment(["MEET_RECORD_MAC_MIC_GAIN": "4.0"]), 4.0)
        XCTAssertEqual(MicGain.gainFromEnvironment(["MEET_RECORD_MAC_MIC_GAIN": "8"]), 8.0)
        XCTAssertEqual(MicGain.gainFromEnvironment(["MEET_RECORD_MAC_MIC_GAIN": "0.5"]), 0.5)
    }

    func testEnvFallsBackToUnityOnInvalidInput() {
        let invalids: [String] = ["", "abc", "nan", "-1", "0", "inf"]
        for s in invalids {
            XCTAssertEqual(
                MicGain.gainFromEnvironment(["MEET_RECORD_MAC_MIC_GAIN": s]),
                1.0,
                "Invalid env value \(s.debugDescription) should fall back to gain=1.0"
            )
        }
    }
}
