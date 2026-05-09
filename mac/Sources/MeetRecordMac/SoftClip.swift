// SoftClip.swift
//
// Tanh-based soft clipper for converting float audio in roughly [-1, +1]
// to s16 PCM with graceful saturation behavior near full scale. This
// avoids the harsh quantization artifacts of naive saturation
// (`Int16(max(-1, min(1, x)) * 32767)`).
//
// Property targets (verified by SoftClipTests):
//   1. Output is always within Int16 range, regardless of input magnitude.
//   2. Output is monotonic increasing in input (no fold-back).
//   3. For inputs in roughly [-0.5, +0.5] the mapping is near-linear so
//      transcription / diarization downstream see undistorted speech.
//   4. Headroom: input = ±1.0 maps to roughly ±0.762 of full scale
//      (tanh(1.0) ≈ 0.762), leaving meaningful headroom before clipping.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum SoftClip {
    /// Convert a single float sample to s16 with tanh soft clipping.
    @inlinable
    static func toInt16(_ x: Float) -> Int16 {
        // Foundation's tanhf for Float; portable and fast on Apple Silicon.
        let y = tanhf(x)
        // tanhf is bounded by ±1.0 by definition, so this multiplication
        // and round-to-nearest cannot overflow Int16.
        let scaled = y * 32767.0
        let rounded = scaled.rounded(.toNearestOrEven)
        return Int16(rounded)
    }

    /// Convert a buffer of mono floats to s16 with tanh clipping.
    static func toInt16Buffer(_ src: UnsafePointer<Float>, count: Int) -> [Int16] {
        var out = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            out[i] = toInt16(src[i])
        }
        return out
    }
}
