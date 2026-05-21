// CLI.swift
//
// Argument parsing for meet-record-mac (M5).
//
// Surface:
//
//   meet-record-mac record \
//       --output <chunk.wav>
//       [--mic <"default" | "none" | <device-uid>>]
//       [--system <"system" | "none" | "app:<bundle-id>">]
//       [--sample-rate 16000]
//       [--max-seconds 0]
//
//   meet-record-mac devices [--json]
//   meet-record-mac probe-permissions
//   meet-record-mac --version
//   meet-record-mac --help
//
// Pure parser: no AVFoundation, no AudioToolbox, no IO. Returns a typed
// `CLIInvocation` value or throws a `CLIError`. Unit-testable on any
// platform.
//
// Why subcommand-style rather than the M4-era bare-positional shape:
// `meet record` (and therefore the Python parent in M6) needs to invoke
// the binary in three distinct modes — record / enumerate devices /
// probe TCC — and conflating those into the same flag namespace produces
// the kind of ambiguity that bites a year later. M4's positional usage
// (`meet-record-mac <output.wav>`) is intentionally removed; the
// equivalent is now `meet-record-mac record --output <output.wav>`.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Top-level subcommand dispatch.
enum CLIInvocation: Equatable {
    case record(RecordOptions)
    case devices(DevicesOptions)
    case probePermissions
    case requestPermissions
    case version
    case help
}

/// Options for `meet-record-mac record`.
struct RecordOptions: Equatable {
    /// Output WAV path (required). Parent directory must exist; the
    /// recorder will create / truncate the file.
    var outputPath: String

    /// Microphone selection (default `.default`).
    var mic: MicSelection

    /// System-audio selection (default `.system`).
    var system: SystemSelection

    /// Output sample rate in Hz (default 16000). The downstream Python
    /// pipeline assumes 16000; changing this is for non-production use.
    var sampleRate: Int

    /// Hard cap on capture duration in seconds. `0` means unlimited
    /// (the recorder runs until `q` is read on stdin / SIGINT / SIGTERM).
    /// Production use is `0`; the cap is for CI / standalone smoke tests.
    var maxSeconds: Double

    static func defaults(outputPath: String) -> RecordOptions {
        RecordOptions(
            outputPath: outputPath,
            mic: .default,
            system: .system,
            sampleRate: 16_000,
            maxSeconds: 0
        )
    }
}

/// Microphone source selection.
enum MicSelection: Equatable {
    /// Use AVAudioEngine's default input device. Matches M4 behavior.
    case `default`
    /// Capture without a mic. Output WAV's left channel will be silent.
    case none
    /// Use the device whose `kAudioDevicePropertyDeviceUID` matches.
    /// Lookup happens at start time; an unknown UID fails the run.
    case deviceUID(String)
}

/// System-audio source selection.
enum SystemSelection: Equatable {
    /// System-wide tap: every output process. Matches M4 behavior.
    case system
    /// Capture without system audio. Right channel will be silent.
    case none
    /// Per-app tap. Bundle ID looked up via
    /// `kAudioHardwarePropertyProcessObjectList` at start time; an
    /// unknown bundle ID fails the run.
    case appBundleID(String)
}

/// Options for `meet-record-mac devices`.
struct DevicesOptions: Equatable {
    /// Emit JSON (machine-readable) instead of human-readable text.
    var json: Bool
}

/// Top-level parse failures. All carry a human-readable message that the
/// caller is expected to print on stderr verbatim. Exit code 2 is the
/// conventional "usage error" shell convention.
enum CLIError: Error, Equatable, CustomStringConvertible {
    case missingSubcommand
    case unknownSubcommand(String)
    case missingRequiredFlag(subcommand: String, flag: String)
    case missingValueForFlag(String)
    case unknownFlag(subcommand: String, flag: String)
    case invalidValue(flag: String, value: String, hint: String)

    var description: String {
        switch self {
        case .missingSubcommand:
            return "missing subcommand. See `meet-record-mac --help`."
        case .unknownSubcommand(let s):
            return "unknown subcommand: \(s). See `meet-record-mac --help`."
        case .missingRequiredFlag(let sub, let flag):
            return "`\(sub)` requires \(flag)."
        case .missingValueForFlag(let flag):
            return "flag \(flag) requires a value."
        case .unknownFlag(let sub, let flag):
            return "unknown flag for `\(sub)`: \(flag)."
        case .invalidValue(let flag, let value, let hint):
            return "invalid value for \(flag): \(value.debugDescription). \(hint)"
        }
    }
}

/// Pure parser entry point. Pass `CommandLine.arguments` minus the
/// program name (i.e. `Array(CommandLine.arguments.dropFirst())`) so
/// tests can pass synthetic argv lists.
enum CLI {
    static let usageText: String = """
    meet-record-mac — macOS Apple Silicon dual-channel recorder

    USAGE:
        meet-record-mac <SUBCOMMAND> [OPTIONS]

    SUBCOMMANDS:
        record                  Capture mic + system audio to a WAV file.
        devices                 List available audio input devices.
        probe-permissions       Report mic + system-audio TCC status (exit 0
                                if both granted, 1 otherwise).
        request-permissions     Request mic + system-audio TCC access. Triggers
                                the macOS permission dialog on first use; then
                                reports status. Idempotent.

    GLOBAL FLAGS:
        --version               Print version and exit.
        --help, -h              Print this message and exit.

    `record` OPTIONS:
        --output <path>         Output WAV path. REQUIRED.
        --mic <selector>        Microphone source. One of:
                                  default     — AVAudioEngine default input (default)
                                  none        — no mic; left channel silent
                                  <uid>       — device with this kAudioDevicePropertyDeviceUID
        --system <selector>     System audio source. One of:
                                  system           — system-wide tap (default)
                                  none             — no system audio; right channel silent
                                  app:<bundle-id>  — per-app tap (e.g. app:us.zoom.xos)
        --sample-rate <hz>      Output sample rate (default 16000).
        --max-seconds <n>       Cap capture duration in seconds. 0 = unlimited
                                (default; stop via `q` on stdin, SIGINT, or SIGTERM).

    `devices` OPTIONS:
        --json                  Emit JSON instead of human-readable text.

    STOP PROTOCOL (record mode):
        Send a single `q` byte on stdin for graceful shutdown (mirrors
        ffmpeg's stop convention). EOF on stdin is treated identically.
        SIGINT / SIGTERM also trigger graceful shutdown. SIGKILL leaves a
        partial WAV with a stale RIFF size header.

    EXIT CODES:
        0   success / clean shutdown
        1   runtime error (Core Audio, file I/O, permission denial)
        2   usage error
    """

    /// Build version string. Surface-stable so the Python parent can
    /// version-check its known-good binary.
    static let versionString = "meet-record-mac 0.6.0 (M7)"

    static func parse(_ args: [String]) throws -> CLIInvocation {
        // Top-level "global-only" flags first.
        if args.isEmpty {
            throw CLIError.missingSubcommand
        }
        switch args[0] {
        case "--version":
            return .version
        case "--help", "-h":
            return .help
        default:
            break
        }

        let sub = args[0]
        let rest = Array(args.dropFirst())

        switch sub {
        case "record":
            return try .record(parseRecord(rest))
        case "devices":
            return try .devices(parseDevices(rest))
        case "probe-permissions":
            // No flags; reject any.
            for a in rest {
                throw CLIError.unknownFlag(subcommand: "probe-permissions", flag: a)
            }
            return .probePermissions
        case "request-permissions":
            // No flags; reject any.
            for a in rest {
                throw CLIError.unknownFlag(subcommand: "request-permissions", flag: a)
            }
            return .requestPermissions
        case "--help", "-h":
            return .help
        case "--version":
            return .version
        default:
            throw CLIError.unknownSubcommand(sub)
        }
    }

    // MARK: - record

    static func parseRecord(_ args: [String]) throws -> RecordOptions {
        var output: String?
        var mic: MicSelection = .default
        var system: SystemSelection = .system
        var sampleRate = 16_000
        var maxSeconds: Double = 0

        var i = 0
        while i < args.count {
            let flag = args[i]
            switch flag {
            case "--output":
                output = try requireValue(flag, args: args, index: &i)
            case "--mic":
                let v = try requireValue(flag, args: args, index: &i)
                mic = try parseMicSelection(v)
            case "--system":
                let v = try requireValue(flag, args: args, index: &i)
                system = try parseSystemSelection(v)
            case "--sample-rate":
                let v = try requireValue(flag, args: args, index: &i)
                guard let hz = Int(v), hz > 0 else {
                    throw CLIError.invalidValue(
                        flag: flag, value: v, hint: "expected a positive integer (Hz)."
                    )
                }
                sampleRate = hz
            case "--max-seconds":
                let v = try requireValue(flag, args: args, index: &i)
                guard let secs = Double(v), secs >= 0, secs.isFinite else {
                    throw CLIError.invalidValue(
                        flag: flag, value: v,
                        hint: "expected a non-negative finite number; 0 = unlimited."
                    )
                }
                maxSeconds = secs
            default:
                throw CLIError.unknownFlag(subcommand: "record", flag: flag)
            }
            i += 1
        }

        guard let outputPath = output, !outputPath.isEmpty else {
            throw CLIError.missingRequiredFlag(subcommand: "record", flag: "--output")
        }

        return RecordOptions(
            outputPath: outputPath,
            mic: mic,
            system: system,
            sampleRate: sampleRate,
            maxSeconds: maxSeconds
        )
    }

    // MARK: - devices

    static func parseDevices(_ args: [String]) throws -> DevicesOptions {
        var json = false
        for a in args {
            switch a {
            case "--json":
                json = true
            default:
                throw CLIError.unknownFlag(subcommand: "devices", flag: a)
            }
        }
        return DevicesOptions(json: json)
    }

    // MARK: - selectors

    /// Parse `--mic` value. The syntax overlaps device UIDs (free-form
    /// strings) so we treat the well-known keywords as reserved and
    /// pass anything else through as a `deviceUID`. UIDs are validated
    /// at start time, not parse time, since they require AudioToolbox.
    static func parseMicSelection(_ raw: String) throws -> MicSelection {
        switch raw {
        case "default": return .default
        case "none": return .none
        case "":
            throw CLIError.invalidValue(
                flag: "--mic", value: raw,
                hint: "expected `default`, `none`, or a device UID."
            )
        default:
            return .deviceUID(raw)
        }
    }

    /// Parse `--system` value. `app:<bundle-id>` is the per-app form;
    /// `<bundle-id>` is everything after the colon and must be non-empty.
    static func parseSystemSelection(_ raw: String) throws -> SystemSelection {
        switch raw {
        case "system": return .system
        case "none": return .none
        case "":
            throw CLIError.invalidValue(
                flag: "--system", value: raw,
                hint: "expected `system`, `none`, or `app:<bundle-id>`."
            )
        default:
            if raw.hasPrefix("app:") {
                let id = String(raw.dropFirst("app:".count))
                guard !id.isEmpty else {
                    throw CLIError.invalidValue(
                        flag: "--system", value: raw,
                        hint: "bundle ID must follow `app:` (e.g. `app:us.zoom.xos`)."
                    )
                }
                return .appBundleID(id)
            }
            throw CLIError.invalidValue(
                flag: "--system", value: raw,
                hint: "expected `system`, `none`, or `app:<bundle-id>`."
            )
        }
    }

    // MARK: - helpers

    private static func requireValue(
        _ flag: String, args: [String], index: inout Int
    ) throws -> String {
        let next = index + 1
        guard next < args.count else {
            throw CLIError.missingValueForFlag(flag)
        }
        index = next
        return args[next]
    }
}
