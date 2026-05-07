// Mixer.swift
//
// Free-running ring-buffer mixer: pairs mono mic samples with mono
// system-audio samples into an interleaved stereo s16 stream and writes
// to the supplied WavWriter.
//
// Strategy: each producer pushes mono Float32 samples into its own
// thread-safe ring buffer. A periodic `DispatchSourceTimer` (default 20 ms)
// drains whichever channel has fewer samples available, zero-pads the
// other to match, applies tanh soft-clip, interleaves, and emits one
// `[Int16]` chunk to the writer.
//
// This mirrors in spirit the Linux ffmpeg path's `-use_wallclock_as_timestamps 1`
// trick (meet_record/capture.py:316), which avoids amerge blocking on a
// late-starting source by aligning by wall-clock instead of by sample
// availability. We achieve the same property here by zero-padding the
// channel that hasn't produced enough samples yet.
//
// Trade-offs:
//   - Simple and robust. No host-time math, no per-frame timestamping.
//   - Sub-buffer alignment is "good enough for diarization" (tens of ms),
//     not sample-accurate. M4.x can swap to host-time alignment later if
//     needed without changing the mixer's external API.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A simple FIFO buffer of `Float` samples with thread-safe push/pop.
final class FloatRingBuffer {
    private var buffer: [Float] = []
    private let lock = NSLock()

    /// Append samples to the tail.
    func push(_ src: UnsafePointer<Float>, count: Int) {
        if count <= 0 { return }
        lock.lock()
        defer { lock.unlock() }
        // Reserve in chunks to amortize allocation cost.
        if buffer.capacity - buffer.count < count {
            buffer.reserveCapacity(buffer.count + max(count, 4096))
        }
        for i in 0..<count {
            buffer.append(src[i])
        }
    }

    /// Pop up to `maxCount` samples from the head. Returns the actually
    /// popped slice (may be shorter than `maxCount`).
    func pop(maxCount: Int) -> [Float] {
        if maxCount <= 0 { return [] }
        lock.lock()
        defer { lock.unlock() }
        let n = min(maxCount, buffer.count)
        if n == 0 { return [] }
        let slice = Array(buffer.prefix(n))
        buffer.removeFirst(n)
        return slice
    }

    /// Current count without taking samples.
    var available: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    /// Drain everything. Returns whatever was buffered.
    func drainAll() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let out = buffer
        buffer.removeAll(keepingCapacity: false)
        return out
    }
}

/// Pairs mono mic + mono system frames into an interleaved stereo s16
/// stream and writes them to a WavWriter.
///
/// Channel ordering: **L = mic, R = system**. Load-bearing — see
/// `meet_record/audio.py:read_stereo_channels` and
/// `compute_speaker_channel_energy()` at `audio.py:191`.
final class Mixer {
    private let writer: WavWriter
    private let writeQueue = DispatchQueue(label: "tools.pretyflaco.meetrecordmac.mixer.write")
    private let drainQueue = DispatchQueue(label: "tools.pretyflaco.meetrecordmac.mixer.drain", qos: .userInitiated)
    private var timer: DispatchSourceTimer?

    private let micBuffer = FloatRingBuffer()
    private let sysBuffer = FloatRingBuffer()

    /// Drain interval. 20 ms ≈ 320 frames at 16 kHz, small enough to keep
    /// memory bounded but large enough to amortize lock + write overhead.
    let drainIntervalMs: Int

    // Diagnostic counters. Reads/writes are protected by `countersLock`.
    // Used by main.swift to print push/emit totals at end of run, so a
    // duration drift surfaces from logs alone instead of requiring an
    // external `ffprobe` round-trip.
    private let countersLock = NSLock()
    private var _micPushed: Int = 0
    private var _sysPushed: Int = 0
    private var _framesEmitted: Int = 0

    var micPushed: Int {
        countersLock.lock(); defer { countersLock.unlock() }
        return _micPushed
    }
    var sysPushed: Int {
        countersLock.lock(); defer { countersLock.unlock() }
        return _sysPushed
    }
    var framesEmitted: Int {
        countersLock.lock(); defer { countersLock.unlock() }
        return _framesEmitted
    }

    init(writer: WavWriter, drainIntervalMs: Int = 20) {
        self.writer = writer
        self.drainIntervalMs = drainIntervalMs
    }

    func pushMic(_ src: UnsafePointer<Float>, count: Int) {
        micBuffer.push(src, count: count)
        countersLock.lock()
        _micPushed += count
        countersLock.unlock()
    }

    func pushSystem(_ src: UnsafePointer<Float>, count: Int) {
        sysBuffer.push(src, count: count)
        countersLock.lock()
        _sysPushed += count
        countersLock.unlock()
    }

    /// Start the periodic drain timer.
    func start() {
        let t = DispatchSource.makeTimerSource(queue: drainQueue)
        t.schedule(
            deadline: .now() + .milliseconds(drainIntervalMs),
            repeating: .milliseconds(drainIntervalMs)
        )
        t.setEventHandler { [weak self] in
            self?.drainOnce()
        }
        t.resume()
        self.timer = t
    }

    /// Stop the timer and flush whatever's buffered, **truncating to the
    /// shorter channel** so we never write a chunk of zero-padded silence
    /// at the boundary. Cost: drops at most one drain-interval worth of
    /// the over-running channel (~20 ms by default). Without this, the
    /// final emit could pair real audio against zeros, producing the
    /// audible end-of-stream artifact that @patternn flagged in M4
    /// (PR #3 review).
    func stopAndFlush() {
        timer?.cancel()
        timer = nil
        let mic = micBuffer.drainAll()
        let sys = sysBuffer.drainAll()
        let n = min(mic.count, sys.count)
        if n == 0 { return }
        emit(micFrames: Array(mic.prefix(n)), sysFrames: Array(sys.prefix(n)))
    }

    // MARK: - Internal (also exposed for unit tests)

    /// One pass of the drain timer: pair whatever's available now,
    /// zero-padding the channel that hasn't produced enough yet only when
    /// at least one side has data. While both sides are still empty we
    /// emit nothing, avoiding silent zero-pollution at startup.
    ///
    /// Internal (not private) so MixerTests can invoke it deterministically
    /// without spinning up the live DispatchSourceTimer.
    func drainOnce() {
        let micAvail = micBuffer.available
        let sysAvail = sysBuffer.available
        if micAvail == 0 && sysAvail == 0 { return }

        let n = max(micAvail, sysAvail)
        let mic = micBuffer.pop(maxCount: n)
        let sys = sysBuffer.pop(maxCount: n)
        emit(micFrames: padded(mic, to: n), sysFrames: padded(sys, to: n))
    }

    private func padded(_ src: [Float], to n: Int) -> [Float] {
        if src.count == n { return src }
        var out = src
        out.reserveCapacity(n)
        for _ in src.count..<n { out.append(0) }
        return out
    }

    /// Convert the two mono streams to interleaved s16 with tanh soft-clip
    /// and post to the writer queue.
    private func emit(micFrames: [Float], sysFrames: [Float]) {
        precondition(micFrames.count == sysFrames.count, "Mixer: channel lengths must match before emit")
        let n = micFrames.count
        if n == 0 { return }

        var interleaved = [Int16](repeating: 0, count: n * 2)
        for i in 0..<n {
            interleaved[2 * i]     = SoftClip.toInt16(micFrames[i])  // L = mic
            interleaved[2 * i + 1] = SoftClip.toInt16(sysFrames[i])  // R = system
        }

        countersLock.lock()
        _framesEmitted += n
        countersLock.unlock()

        writeQueue.async { [writer] in
            do {
                try interleaved.withUnsafeBufferPointer { ptr in
                    guard let base = ptr.baseAddress else { return }
                    try writer.writeSamples(base, count: interleaved.count)
                }
            } catch {
                FileHandle.standardError.write(Data("warn: WAV write failed: \(error)\n".utf8))
            }
        }
    }

    /// Synchronization barrier on the write queue. Tests use this to
    /// guarantee all `emit`-triggered writes have flushed to disk before
    /// they read back the WAV file.
    func waitForWritesToDrain() {
        writeQueue.sync { }
    }
}
