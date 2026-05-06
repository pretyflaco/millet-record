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
        // Allow async write queue to drain.
        Thread.sleep(forTimeInterval: 0.1)
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
    }

    /// If one channel is shorter, `stopAndFlush` zero-pads it so we don't
    /// drop real audio from the longer side. We push 50 mic samples and
    /// 200 system samples; expect 200 paired frames where the first 50 L
    /// have the mic value and the last 150 L are zero-padded.
    func testStopAndFlushZeroPadsShorterChannel() throws {
        let url = tmpURL("padded.wav")
        let writer = try WavWriter(url: url, sampleRate: 16_000, channels: 2)
        let mixer = Mixer(writer: writer)

        let micVal: Float = 0.1
        let sysVal: Float = 0.2
        let mic = [Float](repeating: micVal, count: 50)
        let sys = [Float](repeating: sysVal, count: 200)

        mic.withUnsafeBufferPointer { ptr in mixer.pushMic(ptr.baseAddress!, count: mic.count) }
        sys.withUnsafeBufferPointer { ptr in mixer.pushSystem(ptr.baseAddress!, count: sys.count) }

        mixer.stopAndFlush()
        Thread.sleep(forTimeInterval: 0.1)
        try writer.close()

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + 200 * 4)

        let expectedMic = SoftClip.toInt16(micVal)
        let expectedSys = SoftClip.toInt16(sysVal)

        // FloatRingBuffer is a single-producer FIFO from each side; pop
        // returns head-first, so the first 50 frames have the real mic
        // value and the last 150 are zero-padded.
        for i in 0..<50 {
            let off = 44 + i * 4
            let l = Int16(littleEndian: data.subdata(in: off..<(off + 2)).withUnsafeBytes { $0.load(as: Int16.self) })
            XCTAssertEqual(l, expectedMic, "First 50 mic frames should preserve mic value (frame \(i))")
        }
        for i in 50..<200 {
            let off = 44 + i * 4
            let l = Int16(littleEndian: data.subdata(in: off..<(off + 2)).withUnsafeBytes { $0.load(as: Int16.self) })
            XCTAssertEqual(l, 0, "Mic frames beyond the 50 supplied should be zero-padded (frame \(i))")
        }
        for i in 0..<200 {
            let off = 44 + i * 4
            let r = Int16(littleEndian: data.subdata(in: (off + 2)..<(off + 4)).withUnsafeBytes { $0.load(as: Int16.self) })
            XCTAssertEqual(r, expectedSys, "All 200 system frames should preserve system value (frame \(i))")
        }
    }

    /// Stopping with both buffers empty produces an empty (header-only)
    /// WAV without crashing or writing garbage.
    func testStopAndFlushOnEmptyBuffersIsSafe() throws {
        let url = tmpURL("empty.wav")
        let writer = try WavWriter(url: url, sampleRate: 16_000, channels: 2)
        let mixer = Mixer(writer: writer)
        mixer.stopAndFlush()
        Thread.sleep(forTimeInterval: 0.05)
        try writer.close()

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44, "Empty WAV must remain exactly 44 bytes")
    }
}
