# meet-record-mac

Native macOS Apple Silicon recording sidecar for meetscribe-record.

Replaces the Linux `ffmpeg -f pulse` pipeline on macOS with a Swift binary
built on Core Audio Process Tap + AVAudioEngine, modeled on
[`RecapAI/Recap`](https://github.com/RecapAI/Recap) (MIT — see `NOTICE` at
the repo root).

## Status

**M4 prototype.** Captures 5 seconds of dual-channel audio:

- Microphone via `AVAudioEngine` input tap → **left** channel
- System audio via Core Audio Process Tap → **right** channel

Both streams are downmixed to 16 kHz mono Float32, paired by a
free-running ring-buffer mixer (`Mixer.swift`) with ~20 ms drain interval,
soft-clipped via `tanh` (`SoftClip.swift`) to avoid full-scale saturation,
and written as a stereo s16le 16 kHz WAV.

CLI parsing, signal handling, the q-byte stop protocol, and per-app
capture selection all land in M5.

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

## Run the M4 prototype

```sh
./.build/release/meet-record-mac /tmp/sample.wav
ffprobe -hide_banner /tmp/sample.wav
```

Expected output: a stereo 16 kHz s16le WAV of ~5 seconds. **Both** channels
should now contain audio: left = microphone, right = system audio. Speak
into your mic while music plays through your default output; both channels
should have non-trivial RMS.

## Permissions

On first run, macOS prompts for:

- **Microphone** — required (M4 actually taps the mic).
- **System Audio Recording** — new TCC bucket introduced for Process Tap on
  macOS 14.4. Grant it.

If you accidentally clicked Deny, re-grant via:

```
System Settings → Privacy & Security → Microphone
                                     → System Audio Recording
```

## Smoke test (modern ffmpeg syntax)

`-map_channel` was removed in ffmpeg 8.x; use `-af "pan=…"` instead.

```sh
xattr -d com.apple.quarantine ./meet-record-mac
./meet-record-mac /tmp/sample.wav

ffprobe -hide_banner /tmp/sample.wav
# expect: pcm_s16le, 16000 Hz, 2 channels, s16, ~5 s

# Per-channel split
ffmpeg -hide_banner -i /tmp/sample.wav -af "pan=mono|c0=c0" /tmp/left.wav   # mic
ffmpeg -hide_banner -i /tmp/sample.wav -af "pan=mono|c0=c1" /tmp/right.wav  # system

# Levels per channel
ffmpeg -hide_banner -i /tmp/left.wav  -af volumedetect -f null - 2>&1 | grep volume
ffmpeg -hide_banner -i /tmp/right.wav -af volumedetect -f null - 2>&1 | grep volume
```

Expected M4 result: both channels have RMS ≥ −40 dBFS, neither saturates
at −0.0 dBFS (tanh soft-clip leaves headroom — `tanh(1.0) ≈ 0.762` of full
scale).

## Distribution status

Phase 1 (current): unsigned binary built in CI on `macos-14` runners.
Download from GitHub Actions artifacts; macOS Gatekeeper will block first
run. Bypass with:

```sh
xattr -d com.apple.quarantine ./meet-record-mac
```

Phase 2 (post-validation): Apple Developer ID signed + notarized binary,
shipped inside the macOS-arm64 wheel of `meetscribe-record` on PyPI.
