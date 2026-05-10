// StopController.swift
//
// Single-shot stop coordination for `meet-record-mac record`. Three
// independent producers can each signal "please stop":
//
//   1. POSIX signal SIGINT  (Ctrl-C, parent escalation)
//   2. POSIX signal SIGTERM (parent escalation)
//   3. A `q` byte (0x71) read from stdin, OR EOF on stdin.
//      Mirrors ffmpeg's documented "press q to quit" stop convention,
//      which is the protocol meet_record/capture.py:_stop_ffmpeg uses
//      (write b"q", close stdin, wait, escalate to SIGINT, then SIGTERM,
//      then SIGKILL). Treating EOF identically to `q` makes "parent
//      closes the pipe" indistinguishable from "parent sent the byte
//      and then closed."
//
// All three converge on a single `requestStop(reason:)` that fires
// exactly once; subsequent calls are no-ops. The main thread waits on
// `wait(timeout:)`, runs cleanup, then exits. The reason is logged in
// the `done:` summary so a Mac validator can tell `q-byte` from
// `SIGINT` from `EOF` after the fact.
//
// Implementation notes:
//
//   - The stdin reader runs on a detached pthread doing a blocking
//     `read(2)` for a single byte. DispatchSource.read on STDIN_FILENO
//     has subtle differences across pipe vs TTY; the pthread approach
//     works uniformly. The thread exits as soon as the read returns
//     (one byte, EOF, or error).
//
//   - Signals are caught via DispatchSourceSignal. The default Unix
//     handler must be ignored first (signal(SIGINT, SIG_IGN)) so the
//     dispatch source receives the event instead of the process being
//     summarily terminated.
//
//   - Both producers convert their "I saw a stop" into a single
//     monitor-protected setOnce. The main thread waits on a NSCondition;
//     no busy-loop, bounded wakeup latency.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Dispatch

/// What caused the stop. Surfaces in the `done:` summary line.
enum StopReason: String, Equatable {
    case qByte = "stdin-q"
    case stdinEOF = "stdin-eof"
    case sigint = "SIGINT"
    case sigterm = "SIGTERM"
    case maxSeconds = "max-seconds"
}

/// Thread-safe single-shot stop coordinator. Construct, call `start()`
/// to wire signal handlers and the stdin reader, then block on
/// `wait(timeout:)` from the main thread. Subsequent stop signals are
/// recorded but the first one wins.
final class StopController {
    private let condition = NSCondition()
    private var _reason: StopReason?
    private var sigintSource: DispatchSourceSignal?
    private var sigtermSource: DispatchSourceSignal?
    private var stdinThread: Thread?

    /// True once any stop producer has fired. Cheap (lock-protected
    /// read of a single optional). Useful from the audio callbacks.
    var stopRequested: Bool {
        condition.lock()
        defer { condition.unlock() }
        return _reason != nil
    }

    /// The reason `stopRequested` is true. Nil if `wait(...)` hasn't
    /// returned yet.
    var reason: StopReason? {
        condition.lock()
        defer { condition.unlock() }
        return _reason
    }

    /// Wire signal handlers and start the stdin reader. Idempotent;
    /// calling twice is a programmer error and asserts in debug.
    func start(handlerQueue: DispatchQueue = DispatchQueue.global(qos: .userInitiated)) {
        // Replace the default signal disposition with SIG_IGN so the
        // process doesn't terminate before our dispatch source sees the
        // signal. Without this, SIGINT kills the process outright.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let sint = DispatchSource.makeSignalSource(signal: SIGINT, queue: handlerQueue)
        sint.setEventHandler { [weak self] in
            self?.requestStop(.sigint)
        }
        sint.resume()
        self.sigintSource = sint

        let sterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: handlerQueue)
        sterm.setEventHandler { [weak self] in
            self?.requestStop(.sigterm)
        }
        sterm.resume()
        self.sigtermSource = sterm

        // stdin reader thread. Blocking read of one byte from STDIN_FILENO.
        let t = Thread { [weak self] in
            self?.stdinReadLoop()
        }
        t.name = "meet-record-mac-stdin-reader"
        t.qualityOfService = .userInteractive
        t.start()
        self.stdinThread = t
    }

    /// Single-shot stop request. Idempotent; the first reason wins.
    /// May be called from any thread / signal context / audio callback.
    func requestStop(_ r: StopReason) {
        condition.lock()
        defer { condition.unlock() }
        if _reason == nil {
            _reason = r
            condition.broadcast()
        }
    }

    /// Block until a stop is requested or `timeout` elapses. Returns
    /// the actual reason (which is `.maxSeconds` only if the caller
    /// passed that as `timeoutReason` and the timeout fired).
    /// `timeout` of `nil` waits indefinitely.
    @discardableResult
    func wait(timeout: TimeInterval?, timeoutReason: StopReason = .maxSeconds) -> StopReason {
        condition.lock()
        defer { condition.unlock() }

        if let timeout = timeout, timeout > 0 {
            let deadline = Date().addingTimeInterval(timeout)
            while _reason == nil {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    _reason = timeoutReason
                    break
                }
                _ = condition.wait(until: Date().addingTimeInterval(remaining))
            }
        } else {
            while _reason == nil {
                condition.wait()
            }
        }
        return _reason!
    }

    // MARK: - private

    /// Blocking read of one byte. The thread exits on:
    ///   - one byte read: if it's `q` (0x71) → .qByte; else discarded.
    ///   - EOF (read returns 0): → .stdinEOF.
    ///   - error (read returns -1): logged, treated as EOF.
    /// Any other byte is silently consumed and the read is repeated.
    private func stdinReadLoop() {
        var buf: UInt8 = 0
        while true {
            let n = read(STDIN_FILENO, &buf, 1)
            if n == 0 {
                // EOF — parent closed our stdin.
                requestStop(.stdinEOF)
                return
            }
            if n < 0 {
                // EINTR can happen if a signal interrupts us; we already
                // have signal handlers so just retry. Other errors are
                // treated as EOF (no more useful input).
                let e = errno
                if e == EINTR { continue }
                FileHandle.standardError.write(Data(
                    "warn: stdin read error (errno=\(e)); treating as EOF\n".utf8
                ))
                requestStop(.stdinEOF)
                return
            }
            // Got one byte.
            if buf == 0x71 /* 'q' */ {
                requestStop(.qByte)
                return
            }
            // Other bytes (newlines, padding, etc.) are ignored. Keep
            // reading until we get a `q` or EOF.
        }
    }
}
