// MixerTests.swift
//
// Mixer / FloatRingBuffer unit tests. CI-runnable; no audio HW.
//
// We avoid relying on the live DispatchSourceTimer in tests — instead we
// exercise the pieces individually:
//   - FloatRingBuffer push/pop semantics
//   - WavWriter integration through the Mixer's start/stopAndFlush flow,
//     verifying channel ordering and lengths after a controlled push.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import MeetRecordMac

final class FloatRingBufferTests: XCTestCase {
    func testPushPopRoundTrip() {
        let rb = FloatRingBuffer()
        let input: [Float] = [1, 2, 3, 4, 5]
        input.withUnsafeBufferPointer { ptr in
            rb.push(ptr.baseAddress!, count: input.count)
        }
        XCTAssertEqual(rb.available, 5)

        let head = rb.pop(maxCount: 3)
        XCTAssertEqual(head, [1, 2, 3])
        XCTAssertEqual(rb.available, 2)

        let tail = rb.pop(maxCount: 100)
        XCTAssertEqual(tail, [4, 5])
        XCTAssertEqual(rb.available, 0)
    }

    func testDrainAllEmptiesBuffer() {
        let rb = FloatRingBuffer()
        let input: [Float] = [10, 20, 30]
        input.withUnsafeBufferPointer { ptr in
            rb.push(ptr.baseAddress!, count: input.count)
        }
        let all = rb.drainAll()
        XCTAssertEqual(all, [10, 20, 30])
        XCTAssertEqual(rb.available, 0)
    }

    func testPopMoreThanAvailable() {
        let rb = FloatRingBuffer()
        let input: [Float] = [7, 8]
        input.withUnsafeBufferPointer { ptr in
            rb.push(ptr.baseAddress!, count: input.count)
        }
        let popped = rb.pop(maxCount: 100)
        XCTAssertEqual(popped, [7, 8])
    }

    func testPopFromEmptyReturnsEmpty() {
        let rb = FloatRingBuffer()
        XCTAssertEqual(rb.pop(maxCount: 10), [])
    }

    /// Push and pop from concurrent threads without crashing or losing
    /// data. We don't assert ordering across producers (that's not what
    /// the buffer guarantees), only that total sample count is preserved.
    func testConcurrentPushIsSafe() {
        let rb = FloatRingBuffer()
        let totalPerProducer = 1000
        let producers = 4
        let group = DispatchGroup()
        for p in 0..<producers {
            group.enter()
            DispatchQueue.global().async {
                let chunk = [Float](repeating: Float(p), count: totalPerProducer)
                chunk.withUnsafeBufferPointer { ptr in
                    rb.push(ptr.baseAddress!, count: chunk.count)
                }
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(rb.available, totalPerProducer * producers)
    }
}

final class MixerTests: XCTestCase {
    func tmpURL(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixer-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    /// Push N mic + N system samples (different known amplitudes), call
    /// `stopAndFlush`, and verify the resulting WAV has L=mic-amplitude,
    /// R=system-amplitude in every frame. This exercises the full path
    /// without depending on the live drain timer.
    func testStopAndFlushProducesPairedFrames() throws {
        let url = tmpURL("paired.wav")
        let writer = try WavWriter(url: url, sampleRate: 16_000, channels: 2)
        let mixer = Mixer(writer: writer)

        // Don't start the timer — we want deterministic flushing.
        let n = 100
        let micVal: Float = 0.1
        let sysVal: Float = 0.2
        let mic = [Float](repeating: micVal, count: n)
        let sys = [Float](repeating: sysVal, count: n)

        mic.withUnsafeBufferPointer { ptr in mixer.pushMic(ptr.baseAddress!, count: n) }
        sys.withUnsafeBufferPointer { ptr in mixer.pushSystem(ptr.baseAddress!, count: n) }

        mixer.stopAndFlush()
        mixer.waitForWritesToDrain()
        try writer.close()

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + n * 4, "Expected 44-byte header + n frames * 4 bytes (stereo s16)")

        let expectedMic = SoftClip.toInt16(micVal)
        let expectedSys = SoftClip.toInt16(sysVal)

        for i in 0..<n {
            let off = 44 + i * 4
            let l = Int16(littleEndian: data.subdata(in: off..<(off + 2)).withUnsafeBytes { $0.load(as: Int16.self) })
            let r = Int16(littleEndian: data.subdata(in: (off + 2)..<(off + 4)).withUnsafeBytes { $0.load(as: Int16.self) })
            XCTAssertEqual(l, expectedMic, "Frame \(i) L (mic) wrong")
            XCTAssertEqual(r, expectedSys, "Frame \(i) R (system) wrong")
        }

        XCTAssertEqual(mixer.micPushed, n)
        XCTAssertEqual(mixer.sysPushed, n)
        XCTAssertEqual(mixer.framesEmitted, n)
    }

    /// If one channel is shorter at flush time, we **truncate to min** so we
    /// don't write a chunk of zero-padded silence at the boundary. Drops at
    /// most one drain-interval (~20 ms) of the over-running channel. This
    /// addresses the end-of-stream "deformation" @patternn flagged in M4
    /// review.
    ///
    /// Push 50 mic + 200 sys samples; expect 50 paired frames in the WAV
    /// (the over-running 150 sys samples are dropped).
    func testStopAndFlushTruncatesToShorterChannel() throws {
        let url = tmpURL("truncated.wav")
        let writer = try WavWriter(url: url, sampleRate: 16_000, channels: 2)
        let mixer = Mixer(writer: writer)

        let micVal: Float = 0.1
        let sysVal: Float = 0.2
        let mic = [Float](repeating: micVal, count: 50)
        let sys = [Float](repeating: sysVal, count: 200)

        mic.withUnsafeBufferPointer { ptr in mixer.pushMic(ptr.baseAddress!, count: mic.count) }
        sys.withUnsafeBufferPointer { ptr in mixer.pushSystem(ptr.baseAddress!, count: sys.count) }

        mixer.stopAndFlush()
        mixer.waitForWritesToDrain()
        try writer.close()

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + 50 * 4,
                       "Flush should write min(mic.count, sys.count) = 50 paired frames, not max")

        let expectedMic = SoftClip.toInt16(micVal)
        let expectedSys = SoftClip.toInt16(sysVal)

        for i in 0..<50 {
            let off = 44 + i * 4
            let l = Int16(littleEndian: data.subdata(in: off..<(off + 2)).withUnsafeBytes { $0.load(as: Int16.self) })
            let r = Int16(littleEndian: data.subdata(in: (off + 2)..<(off + 4)).withUnsafeBytes { $0.load(as: Int16.self) })
            XCTAssertEqual(l, expectedMic, "Frame \(i) L (mic) should hold the real mic value")
            XCTAssertEqual(r, expectedSys, "Frame \(i) R (sys) should hold the real sys value")
        }

        XCTAssertEqual(mixer.framesEmitted, 50, "framesEmitted counter should match what was written")
    }

    /// Stopping with both buffers empty produces an empty (header-only)
    /// WAV without crashing or writing garbage.
    func testStopAndFlushOnEmptyBuffersIsSafe() throws {
        let url = tmpURL("empty.wav")
        let writer = try WavWriter(url: url, sampleRate: 16_000, channels: 2)
        let mixer = Mixer(writer: writer)
        mixer.stopAndFlush()
        mixer.waitForWritesToDrain()
        try writer.close()

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44, "Empty WAV must remain exactly 44 bytes")
    }

    /// `drainOnce` mid-stream MUST emit exactly `max(micAvail, sysAvail)`
    /// paired frames per call — never more, never less. If the mixer ever
    /// over-counts (the kind of bug we're chasing in M4.1's duration drift),
    /// this test will catch it directly.
    ///
    /// Pushes 1000 sys + 100 mic; calls `drainOnce()` once. Expected: 1000
    /// paired frames in the WAV with the first 100 L holding the real mic
    /// value and the last 900 L being zero-padded (mid-stream behavior is
    /// pad-not-truncate; only flush truncates). All 1000 R hold sys value.
    /// Total emit counter = 1000, push counters = mic=100, sys=1000.
    func testDrainOnceProducesExactlyMaxAvailableFrames() throws {
        let url = tmpURL("drain-once.wav")
        let writer = try WavWriter(url: url, sampleRate: 16_000, channels: 2)
        let mixer = Mixer(writer: writer)
        // Don't call mixer.start() — we drive drainOnce() manually so the
        // test is deterministic without timer races.

        let micVal: Float = 0.3
        let sysVal: Float = 0.4
        let mic = [Float](repeating: micVal, count: 100)
        let sys = [Float](repeating: sysVal, count: 1000)

        mic.withUnsafeBufferPointer { ptr in mixer.pushMic(ptr.baseAddress!, count: mic.count) }
        sys.withUnsafeBufferPointer { ptr in mixer.pushSystem(ptr.baseAddress!, count: sys.count) }

        mixer.drainOnce()
        mixer.waitForWritesToDrain()

        // A second drainOnce on now-empty buffers must emit nothing.
        mixer.drainOnce()
        mixer.waitForWritesToDrain()
        try writer.close()

        XCTAssertEqual(mixer.micPushed, 100, "micPushed counter")
        XCTAssertEqual(mixer.sysPushed, 1000, "sysPushed counter")
        XCTAssertEqual(mixer.framesEmitted, 1000,
                       "framesEmitted should equal max(micAvail, sysAvail) from the single non-empty drainOnce, NOT 1100 or any other multiple")

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + 1000 * 4, "WAV body must be exactly 1000 paired frames")

        let expectedMic = SoftClip.toInt16(micVal)
        let expectedSys = SoftClip.toInt16(sysVal)

        for i in 0..<100 {
            let off = 44 + i * 4
            let l = Int16(littleEndian: data.subdata(in: off..<(off + 2)).withUnsafeBytes { $0.load(as: Int16.self) })
            XCTAssertEqual(l, expectedMic, "Frame \(i) L should be real mic")
        }
        for i in 100..<1000 {
            let off = 44 + i * 4
            let l = Int16(littleEndian: data.subdata(in: off..<(off + 2)).withUnsafeBytes { $0.load(as: Int16.self) })
            XCTAssertEqual(l, 0, "Frame \(i) L should be zero-padded (mid-stream pad behavior)")
        }
        for i in 0..<1000 {
            let off = 44 + i * 4
            let r = Int16(littleEndian: data.subdata(in: (off + 2)..<(off + 4)).withUnsafeBytes { $0.load(as: Int16.self) })
            XCTAssertEqual(r, expectedSys, "Frame \(i) R should be real sys")
        }
    }
}
