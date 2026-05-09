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

    /// `drainOnce` mid-stream MUST emit exactly `min(micAvail, sysAvail)`
    /// paired frames per call. The faster producer's surplus stays
    /// buffered for the next drain; we never zero-pad mid-stream.
    ///
    /// **History note:** an earlier version of this test asserted the
    /// `max(...)` semantics that produced @patternn's M4 9 s vs 5 s drift —
    /// the assertion encoded the bug as expected behavior, so CI passed
    /// while the real recording was broken. Lesson: a passing test is
    /// only as good as the invariant it encodes.
    ///
    /// Pushes 1000 sys + 100 mic; calls `drainOnce()` once. Expected:
    /// 100 paired frames emitted (mic was the slower side); 900 sys
    /// remain buffered. Mic buffer is empty.
    func testDrainOnceProducesMinAvailableFrames() throws {
        let url = tmpURL("drain-once-min.wav")
        let writer = try WavWriter(url: url, sampleRate: 16_000, channels: 2)
        let mixer = Mixer(writer: writer)
        // Don't call mixer.start() — drive drainOnce() manually for
        // deterministic timing.

        let micVal: Float = 0.3
        let sysVal: Float = 0.4
        let mic = [Float](repeating: micVal, count: 100)
        let sys = [Float](repeating: sysVal, count: 1000)

        mic.withUnsafeBufferPointer { ptr in mixer.pushMic(ptr.baseAddress!, count: mic.count) }
        sys.withUnsafeBufferPointer { ptr in mixer.pushSystem(ptr.baseAddress!, count: sys.count) }

        mixer.drainOnce()
        mixer.waitForWritesToDrain()

        XCTAssertEqual(mixer.micPushed, 100, "micPushed counter")
        XCTAssertEqual(mixer.sysPushed, 1000, "sysPushed counter")
        XCTAssertEqual(
            mixer.framesEmitted, 100,
            "framesEmitted should equal min(micAvail, sysAvail) = 100, NOT 1000 (max-bug) or 1100 (double-count)"
        )

        // A second drainOnce: mic is empty, so nothing should emit.
        mixer.drainOnce()
        mixer.waitForWritesToDrain()
        XCTAssertEqual(mixer.framesEmitted, 100, "drainOnce with empty mic must emit nothing")

        try writer.close()

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + 100 * 4, "WAV body must be exactly 100 paired frames")

        let expectedMic = SoftClip.toInt16(micVal)
        let expectedSys = SoftClip.toInt16(sysVal)

        for i in 0..<100 {
            let off = 44 + i * 4
            let l = Int16(littleEndian: data.subdata(in: off..<(off + 2)).withUnsafeBytes { $0.load(as: Int16.self) })
            let r = Int16(littleEndian: data.subdata(in: (off + 2)..<(off + 4)).withUnsafeBytes { $0.load(as: Int16.self) })
            XCTAssertEqual(l, expectedMic, "Frame \(i) L should be real mic")
            XCTAssertEqual(r, expectedSys, "Frame \(i) R should be real sys")
        }
    }

    /// `drainOnce` with one buffer empty must emit nothing — the populated
    /// channel waits in its buffer for the other side to catch up.
    func testDrainOnceWaitsForBothProducers() throws {
        let url = tmpURL("wait.wav")
        let writer = try WavWriter(url: url, sampleRate: 16_000, channels: 2)
        let mixer = Mixer(writer: writer)

        let mic = [Float](repeating: 0.1, count: 100)
        mic.withUnsafeBufferPointer { ptr in mixer.pushMic(ptr.baseAddress!, count: mic.count) }
        mixer.drainOnce()
        mixer.waitForWritesToDrain()
        XCTAssertEqual(mixer.framesEmitted, 0, "drainOnce with empty sys buffer must emit nothing")

        let sys = [Float](repeating: 0.2, count: 100)
        sys.withUnsafeBufferPointer { ptr in mixer.pushSystem(ptr.baseAddress!, count: sys.count) }
        mixer.drainOnce()
        mixer.waitForWritesToDrain()
        XCTAssertEqual(mixer.framesEmitted, 100, "Now both sides have data; emit min = 100 frames")

        try writer.close()
    }

    /// **Regression gate for the M4 bursty-producer bug.** Simulates
    /// @patternn's actual M4.1 delivery pattern: the system tap delivers
    /// in fine slices (~170 frames every ~10 ms) while the mic delivers
    /// in larger bursts (~1664 frames every ~100 ms). Under the old
    /// `max(...)` + zero-pad semantics, a single drain that saw a fresh
    /// mic burst would zero-pad the system channel up to 1664 frames,
    /// inflating output ~10× faster than real time. Under `min(...)`,
    /// total emit count tracks the slower producer and never exceeds it.
    ///
    /// Total pushed: mic=1664, sys=1700. Expected emit ≤ 1664 across all
    /// drains. Old buggy code would have emitted ~5000+ frames here.
    func testBurstyProducerDoesNotInflateOutput() throws {
        let url = tmpURL("bursty.wav")
        let writer = try WavWriter(url: url, sampleRate: 16_000, channels: 2)
        let mixer = Mixer(writer: writer)

        let sysChunk = [Float](repeating: 0.4, count: 170)
        let micBurst = [Float](repeating: 0.3, count: 1664)

        // Simulate 10 sys-tap callbacks with a drain after each. No mic
        // data yet, so no frames should emit during this phase.
        for _ in 0..<10 {
            sysChunk.withUnsafeBufferPointer { ptr in
                mixer.pushSystem(ptr.baseAddress!, count: sysChunk.count)
            }
            mixer.drainOnce()
        }
        mixer.waitForWritesToDrain()
        XCTAssertEqual(
            mixer.framesEmitted, 0,
            "Mic empty → drainOnce must emit nothing during sys-only phase"
        )
        XCTAssertEqual(mixer.sysPushed, 1700)

        // Now mic burst arrives. drain.
        micBurst.withUnsafeBufferPointer { ptr in
            mixer.pushMic(ptr.baseAddress!, count: micBurst.count)
        }
        mixer.drainOnce()
        mixer.waitForWritesToDrain()

        // After this drain: min(micAvail=1664, sysAvail=1700) = 1664
        // paired frames emitted. Old buggy max(...) would have emitted
        // 1700 frames (with 36 zero-padded mic samples at the tail) —
        // the multiplicative inflation only shows up when this pattern
        // repeats over many cycles in a real recording.
        XCTAssertEqual(
            mixer.framesEmitted, 1664,
            "After mic burst arrives, emit min(1664, 1700) = 1664 frames"
        )
        XCTAssertEqual(
            mixer.framesEmitted, mixer.micPushed,
            "Slower producer (mic) caps the emit count"
        )
        XCTAssertLessThanOrEqual(
            mixer.framesEmitted, mixer.sysPushed,
            "emit must never exceed faster producer's push count"
        )

        try writer.close()
    }

    /// `markMicReady()` discards everything currently buffered on the
    /// system side so subsequent paired emits start from "now," not from
    /// pre-mic system audio. Idempotent: a second call is a no-op.
    func testMarkMicReadyDiscardsBufferedSysSamples() throws {
        let url = tmpURL("mark-ready.wav")
        let writer = try WavWriter(url: url, sampleRate: 16_000, channels: 2)
        let mixer = Mixer(writer: writer)

        // Sys produces for "2 seconds" of cold-start time before mic
        // is ready: 5000 samples accumulate.
        let preMicSys = [Float](repeating: 0.5, count: 5000)
        preMicSys.withUnsafeBufferPointer { ptr in
            mixer.pushSystem(ptr.baseAddress!, count: preMicSys.count)
        }
        XCTAssertEqual(mixer.sysPushed, 5000)

        // Mic warms up. main.swift calls markMicReady on the first
        // non-empty mic callback. The 5000 buffered sys samples vanish.
        mixer.markMicReady()
        XCTAssertEqual(mixer.sysDiscardedAtMicReady, 5000,
                       "markMicReady should report exactly the pre-mic sys count it dropped")

        // Idempotent: second call must NOT discard anything new.
        let preMic2 = [Float](repeating: 0.6, count: 200)
        preMic2.withUnsafeBufferPointer { ptr in
            mixer.pushSystem(ptr.baseAddress!, count: preMic2.count)
        }
        mixer.markMicReady()
        XCTAssertEqual(
            mixer.sysDiscardedAtMicReady, 5000,
            "Second markMicReady() must be a no-op; counter must NOT include the new 200 sys samples"
        )

        // Now push fresh mic + sys post-warmup, drain, verify only the
        // post-warmup samples emit.
        let mic = [Float](repeating: 0.1, count: 100)
        let sys = [Float](repeating: 0.2, count: 100)
        mic.withUnsafeBufferPointer { ptr in mixer.pushMic(ptr.baseAddress!, count: mic.count) }
        sys.withUnsafeBufferPointer { ptr in mixer.pushSystem(ptr.baseAddress!, count: sys.count) }
        mixer.drainOnce()
        mixer.waitForWritesToDrain()

        // micAvail=100, sysAvail = 200 (the post-second-markReady pushes)
        // + 100 (the fresh push) = 300. Emit = min(100, 300) = 100.
        XCTAssertEqual(
            mixer.framesEmitted, 100,
            "Should emit exactly the post-warmup mic count, with leftover sys remaining buffered"
        )

        try writer.close()
    }
}
