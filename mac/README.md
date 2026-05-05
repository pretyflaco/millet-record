# meet-record-mac

Native macOS Apple Silicon recording sidecar for meetscribe-record.

Replaces the Linux `ffmpeg -f pulse` pipeline on macOS with a Swift binary
built on Core Audio Process Tap + AVAudioEngine, modeled on
[`RecapAI/Recap`](https://github.com/RecapAI/Recap) (MIT — see `NOTICE` at
the repo root).

## Status

**M3 prototype.** Captures 5 seconds of system audio, downmixes to 16 kHz
mono, and writes a stereo s16le 16 kHz WAV with that audio on the right
channel and silence on the left. No CLI parsing, no mic capture, no signal
handling, no q-byte stop protocol yet — those land in M4 / M5.

Tracking issue: <https://github.com/pretyflaco/meetscribe-record/issues/1>

## Requirements

- macOS 14.4+ (Process Tap APIs require Sonoma 14.4)
- Apple Silicon (M1 / M2 / M3 / …)
- Xcode 15.4+ / Swift 5.9+

## Build

```sh
cd mac
swift build -c release
```

The binary lands at:

```
.build/release/meet-record-mac
```

## Test

```sh
cd mac
swift test
```

Header-byte-level tests for the WAV writer don't touch Core Audio and pass
on any macOS host (CI included).

## Run the M3 prototype

```sh
./.build/release/meet-record-mac /tmp/sample.wav
ffprobe -hide_banner /tmp/sample.wav
```

Expected output: a stereo 16 kHz s16le WAV of ~5 seconds. The right channel
contains whatever was playing through your default output during capture
(open YouTube, Spotify, anything); the left channel is silence in M3.

## Permissions

On first run, macOS prompts for:

- **Microphone** — required even though M3 doesn't tap the mic, because the
  AVAudioEngine path is wired up in advance for M4. Grant it.
- **System Audio Recording** — new TCC bucket introduced for Process Tap on
  macOS 14.4. Grant it.

If you accidentally clicked Deny, re-grant via:

```
System Settings → Privacy & Security → Microphone
                                     → System Audio Recording
```

## Distribution status

Phase 1 (current): unsigned binary built in CI on `macos-14` runners.
Download from GitHub Actions artifacts; macOS Gatekeeper will block first
run. Bypass with:

```sh
xattr -d com.apple.quarantine ./meet-record-mac
```

Phase 2 (post-validation): Apple Developer ID signed + notarized binary,
shipped inside the macOS-arm64 wheel of `meetscribe-record` on PyPI.
