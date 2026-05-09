// SoftClipTests.swift
//
// Property tests for the tanh soft-clipper. CI-runnable on any macOS host;
// no Core Audio or AVAudioEngine state involved.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import MeetRecordMac

final class SoftClipTests: XCTestCase {
    /// Output is always inside Int16 range, regardless of input magnitude.
    func testBoundedForExtremeInputs() {
        let extremes: [Float] = [-1000, -100, -10, -1, 0, 1, 10, 100, 1000]
        for x in extremes {
            let y = SoftClip.toInt16(x)
            XCTAssertTrue(y >= Int16.min && y <= Int16.max,
                          "SoftClip.toInt16(\(x)) = \(y) out of Int16 range")
        }
    }

    /// Output is monotonically non-decreasing in input. Tanh-based mapping
    /// must never fold back, otherwise diarization energy comparisons break.
    func testMonotonic() {
        let xs: [Float] = stride(from: -3.0, through: 3.0, by: 0.05).map { Float($0) }
        var prev = SoftClip.toInt16(xs.first!)
        for x in xs.dropFirst() {
            let y = SoftClip.toInt16(x)
            XCTAssertGreaterThanOrEqual(y, prev, "Non-monotonic at x=\(x): prev=\(prev) y=\(y)")
            prev = y
        }
    }

    /// Zero maps to zero exactly; tanh(0) = 0.
    func testZeroIsZero() {
        XCTAssertEqual(SoftClip.toInt16(0), 0)
    }

    /// Sign symmetry: tanh is odd, so toInt16(-x) ≈ -toInt16(x) (off by ≤ 1
    /// because of round-half-to-even at the boundary).
    func testSignSymmetry() {
        let xs: [Float] = [0.1, 0.25, 0.5, 0.7, 1.0, 1.5, 2.5]
        for x in xs {
            let pos = SoftClip.toInt16(x)
            let neg = SoftClip.toInt16(-x)
            XCTAssertLessThanOrEqual(abs(Int(pos) + Int(neg)), 1,
                                     "Asymmetric at x=\(x): pos=\(pos) neg=\(neg)")
        }
    }

    /// Headroom: input = ±1.0 maps to roughly ±25000 (i.e. tanh(1) ≈ 0.7616
    /// → 0.7616 * 32767 ≈ 24960). This is the entire point of using tanh
    /// over naive saturation — peaks at amplitude 1.0 must NOT hit full
    /// scale, leaving room for transients without clipping artifacts.
    func testHeadroomAtUnity() {
        let y = SoftClip.toInt16(1.0)
        // Allow ±200 LSB tolerance for floating-point + rounding variance.
        XCTAssertEqual(Int(y), 24960, accuracy: 200,
                       "tanh(1.0) * 32767 should be ~24960; got \(y)")
        XCTAssertLessThan(abs(Int(y)), 32000,
                          "Input ±1.0 must NOT saturate to full scale (that's the bug we're fixing)")
    }

    /// Near-linear region: small inputs (|x| ≤ 0.3) preserve their amplitude
    /// faithfully (within a few percent). Speech content lives mostly in
    /// this range so transcription must see it undistorted.
    func testNearLinearForSmallInputs() {
        let xs: [Float] = [0.05, 0.1, 0.2, 0.3]
        for x in xs {
            let actual = Float(SoftClip.toInt16(x)) / 32767.0
            let linear = x  // ideal naive linear mapping
            let relErr = abs(actual - linear) / linear
            XCTAssertLessThan(relErr, 0.05,
                              "x=\(x): tanh-based output \(actual) should be within 5% of \(linear), got rel err \(relErr)")
        }
    }

    /// Buffer variant matches scalar variant for every sample.
    func testBufferVariantMatchesScalar() {
        let inputs: [Float] = [-2, -1, -0.5, -0.1, 0, 0.1, 0.5, 1, 2]
        let bufOut = inputs.withUnsafeBufferPointer { ptr -> [Int16] in
            SoftClip.toInt16Buffer(ptr.baseAddress!, count: inputs.count)
        }
        for (i, x) in inputs.enumerated() {
            XCTAssertEqual(bufOut[i], SoftClip.toInt16(x),
                           "Buffer variant disagrees with scalar at i=\(i), x=\(x)")
        }
    }
}
