// swift-tools-version:5.9
//
// meet-record-mac — macOS Apple Silicon dual-channel recorder for meetscribe.
//
// M3 scope (this commit): bare-minimum prototype that captures 5 seconds of
// system audio via Core Audio Process Tap + Aggregate Device, downmixes to a
// 16 kHz mono stream, and writes a stereo s16le WAV file with that audio on
// the right channel and silence on the left. No CLI parsing, no mic, no
// signal handling, no per-app selection. Subsequent milestones add those.
//
// Output contract (must match what the existing Linux ffmpeg path produces,
// because meet_record/audio.py:read_stereo_channels and
// meet_record/capture.py:_BYTES_PER_SECOND assume it):
//   - RIFF WAV, pcm_s16le
//   - 16000 Hz
//   - 2 channels, interleaved, L = mic, R = system audio
//   - 44-byte standard header
//
// Reference (MIT): https://github.com/RecapAI/Recap
//
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "MeetRecordMac",
    platforms: [
        // Process Tap APIs require macOS 14.4. Pin precisely so the compiler
        // doesn't demand `if #available` guards at every call site.
        .macOS("14.4"),
    ],
    products: [
        .executable(name: "meet-record-mac", targets: ["MeetRecordMac"]),
    ],
    targets: [
        .executableTarget(
            name: "MeetRecordMac",
            path: "Sources/MeetRecordMac"
        ),
        .testTarget(
            name: "MeetRecordMacTests",
            dependencies: ["MeetRecordMac"],
            path: "Tests/MeetRecordMacTests"
        ),
    ]
)
