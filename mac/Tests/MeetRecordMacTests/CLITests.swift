// CLITests.swift
//
// Unit tests for the CLI parser. Pure (no AVFoundation, no AudioToolbox,
// no IO), runs on any macOS host including the macos-14 CI runner.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import MeetRecordMac

final class CLITests: XCTestCase {

    // MARK: - top-level dispatch

    func testEmptyArgvIsMissingSubcommand() {
        XCTAssertThrowsError(try CLI.parse([])) { err in
            XCTAssertEqual(err as? CLIError, .missingSubcommand)
        }
    }

    func testHelpFlagAtTop() throws {
        XCTAssertEqual(try CLI.parse(["--help"]), .help)
        XCTAssertEqual(try CLI.parse(["-h"]), .help)
    }

    func testVersionFlagAtTop() throws {
        XCTAssertEqual(try CLI.parse(["--version"]), .version)
    }

    func testUnknownSubcommand() {
        XCTAssertThrowsError(try CLI.parse(["nope"])) { err in
            XCTAssertEqual(err as? CLIError, .unknownSubcommand("nope"))
        }
    }

    // MARK: - record subcommand

    func testRecordRequiresOutput() {
        XCTAssertThrowsError(try CLI.parse(["record"])) { err in
            XCTAssertEqual(
                err as? CLIError,
                .missingRequiredFlag(subcommand: "record", flag: "--output")
            )
        }
    }

    func testRecordRequiresValueAfterOutput() {
        XCTAssertThrowsError(try CLI.parse(["record", "--output"])) { err in
            XCTAssertEqual(err as? CLIError, .missingValueForFlag("--output"))
        }
    }

    func testRecordMinimalDefaults() throws {
        let inv = try CLI.parse(["record", "--output", "/tmp/out.wav"])
        guard case .record(let opts) = inv else {
            return XCTFail("expected .record, got \(inv)")
        }
        XCTAssertEqual(opts.outputPath, "/tmp/out.wav")
        XCTAssertEqual(opts.mic, .default)
        XCTAssertEqual(opts.system, .system)
        XCTAssertEqual(opts.sampleRate, 16_000)
        XCTAssertEqual(opts.maxSeconds, 0)
    }

    func testRecordAllFlags() throws {
        let inv = try CLI.parse([
            "record",
            "--output", "/tmp/x.wav",
            "--mic", "default",
            "--system", "system",
            "--sample-rate", "48000",
            "--max-seconds", "30",
        ])
        guard case .record(let opts) = inv else {
            return XCTFail("expected .record, got \(inv)")
        }
        XCTAssertEqual(opts.outputPath, "/tmp/x.wav")
        XCTAssertEqual(opts.mic, .default)
        XCTAssertEqual(opts.system, .system)
        XCTAssertEqual(opts.sampleRate, 48_000)
        XCTAssertEqual(opts.maxSeconds, 30)
    }

    func testRecordRejectsUnknownFlag() {
        XCTAssertThrowsError(try CLI.parse(["record", "--output", "/tmp/x.wav", "--bogus"])) { err in
            XCTAssertEqual(err as? CLIError, .unknownFlag(subcommand: "record", flag: "--bogus"))
        }
    }

    func testRecordRejectsNonPositiveSampleRate() {
        for v in ["0", "-1", "abc"] {
            XCTAssertThrowsError(try CLI.parse(["record", "--output", "/tmp/x.wav", "--sample-rate", v])) { err in
                if case .invalidValue(let flag, let value, _) = err as? CLIError {
                    XCTAssertEqual(flag, "--sample-rate")
                    XCTAssertEqual(value, v)
                } else {
                    XCTFail("expected .invalidValue for sample-rate=\(v), got \(err)")
                }
            }
        }
    }

    func testRecordAcceptsZeroMaxSecondsAsUnlimited() throws {
        let inv = try CLI.parse(["record", "--output", "/tmp/x.wav", "--max-seconds", "0"])
        guard case .record(let opts) = inv else {
            return XCTFail("expected .record")
        }
        XCTAssertEqual(opts.maxSeconds, 0)
    }

    func testRecordRejectsNegativeMaxSeconds() {
        XCTAssertThrowsError(try CLI.parse(["record", "--output", "/tmp/x.wav", "--max-seconds", "-5"])) { err in
            if case .invalidValue(let flag, _, _) = err as? CLIError {
                XCTAssertEqual(flag, "--max-seconds")
            } else {
                XCTFail("expected .invalidValue, got \(err)")
            }
        }
    }

    // MARK: - --mic value parsing

    func testMicSelectionDefault() throws {
        XCTAssertEqual(try CLI.parseMicSelection("default"), .default)
    }

    func testMicSelectionNone() throws {
        XCTAssertEqual(try CLI.parseMicSelection("none"), .none)
    }

    func testMicSelectionDeviceUID() throws {
        XCTAssertEqual(
            try CLI.parseMicSelection("BuiltInMicrophoneDevice"),
            .deviceUID("BuiltInMicrophoneDevice")
        )
        // UIDs can contain colons, hyphens, dots — anything not the
        // reserved keywords.
        XCTAssertEqual(
            try CLI.parseMicSelection("AppleUSBAudioEngine:Apple:USB Audio:14110000:1"),
            .deviceUID("AppleUSBAudioEngine:Apple:USB Audio:14110000:1")
        )
    }

    func testMicSelectionEmptyStringRejected() {
        XCTAssertThrowsError(try CLI.parseMicSelection("")) { err in
            if case .invalidValue(let flag, _, _) = err as? CLIError {
                XCTAssertEqual(flag, "--mic")
            } else {
                XCTFail("expected .invalidValue, got \(err)")
            }
        }
    }

    // MARK: - --system value parsing

    func testSystemSelectionSystem() throws {
        XCTAssertEqual(try CLI.parseSystemSelection("system"), .system)
    }

    func testSystemSelectionNone() throws {
        XCTAssertEqual(try CLI.parseSystemSelection("none"), .none)
    }

    func testSystemSelectionApp() throws {
        XCTAssertEqual(
            try CLI.parseSystemSelection("app:us.zoom.xos"),
            .appBundleID("us.zoom.xos")
        )
    }

    func testSystemSelectionAppRequiresBundleID() {
        XCTAssertThrowsError(try CLI.parseSystemSelection("app:")) { err in
            if case .invalidValue(let flag, _, _) = err as? CLIError {
                XCTAssertEqual(flag, "--system")
            } else {
                XCTFail("expected .invalidValue, got \(err)")
            }
        }
    }

    func testSystemSelectionRejectsBareWord() {
        XCTAssertThrowsError(try CLI.parseSystemSelection("zoom")) { err in
            if case .invalidValue(let flag, _, _) = err as? CLIError {
                XCTAssertEqual(flag, "--system")
            } else {
                XCTFail("expected .invalidValue, got \(err)")
            }
        }
    }

    // MARK: - devices subcommand

    func testDevicesDefault() throws {
        let inv = try CLI.parse(["devices"])
        XCTAssertEqual(inv, .devices(DevicesOptions(json: false)))
    }

    func testDevicesJson() throws {
        let inv = try CLI.parse(["devices", "--json"])
        XCTAssertEqual(inv, .devices(DevicesOptions(json: true)))
    }

    func testDevicesRejectsUnknownFlag() {
        XCTAssertThrowsError(try CLI.parse(["devices", "--bogus"])) { err in
            XCTAssertEqual(err as? CLIError, .unknownFlag(subcommand: "devices", flag: "--bogus"))
        }
    }

    // MARK: - probe-permissions subcommand

    func testProbePermissionsParsesCleanly() throws {
        XCTAssertEqual(try CLI.parse(["probe-permissions"]), .probePermissions)
    }

    func testProbePermissionsRejectsAnyFlag() {
        XCTAssertThrowsError(try CLI.parse(["probe-permissions", "--json"])) { err in
            XCTAssertEqual(err as? CLIError, .unknownFlag(subcommand: "probe-permissions", flag: "--json"))
        }
    }

    // MARK: - Devices.jsonString helper

    func testJsonStringEscapesQuotes() {
        XCTAssertEqual(Devices.jsonString("hello"), "\"hello\"")
        XCTAssertEqual(Devices.jsonString("a\"b"), "\"a\\\"b\"")
        XCTAssertEqual(Devices.jsonString("a\\b"), "\"a\\\\b\"")
        XCTAssertEqual(Devices.jsonString("a\nb"), "\"a\\nb\"")
    }

    func testJsonStringRoundTripsViaJSONSerialization() throws {
        // Belt-and-suspenders: feed our output through Foundation's JSON
        // parser and verify we get back the original string. Catches
        // any escaping mistakes.
        let inputs = [
            "BuiltInMicrophoneDevice",
            "MacBook Pro Microphone",
            "AppleUSBAudioEngine:Apple:USB Audio:14110000:1",
            "with\"quote",
            "with\\backslash",
            "with\nnewline",
            "tab\there",
        ]
        for s in inputs {
            let json = "[\(Devices.jsonString(s))]"
            let parsed = try JSONSerialization.jsonObject(
                with: Data(json.utf8), options: []
            ) as? [String]
            XCTAssertEqual(parsed?.first, s, "round-trip failed for \(s.debugDescription)")
        }
    }
}
