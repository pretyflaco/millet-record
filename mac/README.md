# meet-record-mac

Native macOS Apple Silicon recording sidecar for meetscribe-record.

Replaces the Linux `ffmpeg -f pulse` pipeline on macOS with a Swift binary
built on Core Audio Process Tap + AVAudioEngine, modeled on
[`RecapAI/Recap`](https://github.com/RecapAI/Recap) (MIT — see `NOTICE` at
the repo root).

## Status

**M4.5 investigation build** (M4 merged). Captures 5 seconds of dual-channel audio:

- Microphone via `AVAudioEngine` input tap → **left** channel
- System audio via Core Audio Process Tap → **right** channel

Both streams are downmixed to 16 kHz mono Float32, paired by a
free-running ring-buffer mixer (`Mixer.swift`) using `min(micAvail, sysAvail)`
semantics so neither channel zero-pads mid-stream, soft-clipped via `tanh`
(`SoftClip.swift`) to avoid full-scale saturation, and written as a stereo
s16le 16 kHz WAV. On first mic delivery the mixer's `markMicReady()`
discards any pre-mic system audio that accumulated during AVAudioEngine
cold-start (~1–2 s on Apple Silicon), so paired emits begin from a
common "now" instead of carrying a constant sys-leads-mic offset.

CLI parsing, signal handling, the q-byte stop protocol, and per-app
capture selection all land in M5.

The current build adds **M4.5 diagnostic instrumentation** for an
investigation into the mic-vs-system level gap @patternn observed (mic
~22 dB below system on Apple M1 internal mic). See "Diagnostic env vars"
below.

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

## Diagnostic env vars

These are **investigation knobs**, not user-facing settings. Default
behavior with both unset is the M4.2 baseline (no software gain, no
extra logging).

- **`MEET_RECORD_MAC_DEBUG=1`** — emit per-callback frame counts to
  stderr. Lets you trace the mic and system push streams sample-by-
  sample. Off by default; the unconditional `done:` summary at end of
  run is usually enough.

- **`MEET_RECORD_MAC_MIC_GAIN=<float>`** — multiply each mic sample by
  this factor before the tanh soft-clip stage. Default `1.0` (no-op,
  M4.2 behavior preserved). Used by the M4.5 mic-level investigation
  to localize the +22 dB gap @patternn measured between the mic and
  system channels on Apple Silicon. Examples:
  - `=4` ≈ +12 dB
  - `=8` ≈ +18 dB
  - `=16` ≈ +24 dB

  Hot inputs (gain × sample > 1.0) pass through to the existing tanh
  soft-clip in `Mixer.swift`, so cranking gain produces graceful
  saturation rather than harsh hard-clipping. The eventual fix may
  bake a non-unity default into `MicCapture` if data dictates; that
  decision waits on @patternn's gain-matrix run.

  The recommended user-facing fix for a quiet mic is to raise the
  macOS input level slider (System Settings → Sound → Input → Input
  volume), not to use this env var.

The `done:` summary line at end of run reports `mic_input: rate=… Hz
channels=… inputVolume=… gain=…` so the AVAudioEngine's reported
native format and `inputNode.volume` are visible without extra flags.

## Distribution status

Phase 1 (current): unsigned binary built in CI on `macos-14` runners.
Download from GitHub Actions artifacts; macOS Gatekeeper will block first
run. Bypass with:

```sh
xattr -d com.apple.quarantine ./meet-record-mac
```

Phase 2 (post-validation): Apple Developer ID signed + notarized binary,
shipped inside the macOS-arm64 wheel of `meetscribe-record` on PyPI.
