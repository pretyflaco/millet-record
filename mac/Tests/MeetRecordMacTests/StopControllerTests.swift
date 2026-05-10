// StopControllerTests.swift
//
// Unit tests that exercise the single-shot semantics + wait/timeout
// without involving real POSIX signals or stdin reads (those require a
// TTY/pipe and aren't reliable in CI). The signal/stdin wiring lives in
// `start()` which we don't invoke here; we test `requestStop` and `wait`
// directly. The behavior we care about — "first reason wins, subsequent
// requests are ignored, wait blocks until reason set" — is identical
// whether the producer is a signal handler, the stdin reader, or a
// synthetic `requestStop(...)` call from a test.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import MeetRecordMac

final class StopControllerTests: XCTestCase {

    func testStopRequestedFalseInitially() {
        let s = StopController()
        XCTAssertFalse(s.stopRequested)
        XCTAssertNil(s.reason)
    }

    func testRequestStopSetsReasonAndStopRequested() {
        let s = StopController()
        s.requestStop(.qByte)
        XCTAssertTrue(s.stopRequested)
        XCTAssertEqual(s.reason, .qByte)
    }

    func testFirstReasonWins() {
        let s = StopController()
        s.requestStop(.qByte)
        s.requestStop(.sigint)
        s.requestStop(.sigterm)
        XCTAssertEqual(s.reason, .qByte, "subsequent requests must be ignored")
    }

    func testWaitReturnsImmediatelyIfAlreadyStopped() {
        let s = StopController()
        s.requestStop(.stdinEOF)
        let start = Date()
        let r = s.wait(timeout: 5.0)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(r, .stdinEOF)
        XCTAssertLessThan(elapsed, 0.5, "wait must not block when stopped already")
    }

    func testWaitFiresOnAsyncRequestStop() {
        let s = StopController()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
            s.requestStop(.sigint)
        }
        let start = Date()
        let r = s.wait(timeout: 5.0)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(r, .sigint)
        XCTAssertGreaterThanOrEqual(elapsed, 0.08, "should have actually waited")
        XCTAssertLessThan(elapsed, 1.0, "should have woken on the request, not the timeout")
    }

    func testWaitTimesOutWithGivenReason() {
        let s = StopController()
        let start = Date()
        let r = s.wait(timeout: 0.2, timeoutReason: .maxSeconds)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(r, .maxSeconds)
        XCTAssertGreaterThanOrEqual(elapsed, 0.18)
        XCTAssertLessThan(elapsed, 1.0)
    }

    func testWaitTimeoutReasonStaysIfRequestComesLater() {
        let s = StopController()
        // Wait short, time out, then call requestStop after — the
        // recorded reason should remain the timeout (first-wins).
        _ = s.wait(timeout: 0.1)
        XCTAssertEqual(s.reason, .maxSeconds)
        s.requestStop(.qByte)
        XCTAssertEqual(s.reason, .maxSeconds, "post-timeout requests must be ignored")
    }
}
