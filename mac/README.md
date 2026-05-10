# meet-record-mac

Native macOS Apple Silicon recording sidecar for meetscribe-record.

Replaces the Linux `ffmpeg -f pulse` pipeline on macOS with a Swift binary
built on Core Audio Process Tap + AVAudioEngine, modeled on
[`RecapAI/Recap`](https://github.com/RecapAI/Recap) (MIT — see `NOTICE` at
the repo root).

## Status

**M4.5b** (M4, M4.5b merged). Captures 5 seconds of dual-channel audio:

- Microphone via `AVAudioEngine` input tap → **left** channel
- System audio via Core Audio Process Tap → **right** channel

Both streams are downmixed to 16 kHz mono Float32, paired by a
free-running ring-buffer mixer (`Mixer.swift`) using `min(micAvail, sysAvail)`
semantics so neither channel zero-pads mid-stream, soft-clipped via `tanh`
(`SoftClip.swift`) to avoid full-scale saturation, and written as a stereo
s16le 16 kHz WAV. On first mic delivery the mixer's `markMicReady()`
discards any pre-mic system audio that accumulated during AVAudioEngine
cold-start (~0.2 s on Apple M1, measured), so paired emits begin from a
common "now" instead of carrying a constant sys-leads-mic offset.

The mic path applies a static **+12 dB** software gain (4.0×) by default
(M4.5b) to compensate for the Apple Silicon level mismatch between
AVAudioEngine input and Process Tap output. Without it, mic samples land
~20 dB below system samples, which causes downstream channel-energy
labelers (`meet/transcribe.py:_label_speakers_from_channels`) to
mis-classify a Mac scribe as REMOTE. Override via
`MEET_RECORD_MAC_MIC_GAIN=<float>` (see below).

CLI parsing, signal handling, the q-byte stop protocol, and per-app
capture selection all land in M5.

Epic: <https://github.com/pretyflaco/meetscribe-record/issues/1>

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

Expected M4.5b result: both channels carry meaningful audio. Reference
measurements from patternn's M1 with the production default (gain=4.0):
left mean ≈ −24 dB, right mean ≈ −15 dB, gap ≈ 9 dB; left peak ≈ −9 dB
leaves >8 dB of headroom and the tanh soft-clip stays inactive on
normal speech. Concrete absolute levels depend on your hardware and
input slider setting.

## Environment variables

- **`MEET_RECORD_MAC_DEBUG=1`** — emit per-callback frame counts to
  stderr. Useful for tracing the mic and system push streams sample-
  by-sample when investigating an issue. Off by default; the
  unconditional `done:` summary at end of run is usually enough.

- **`MEET_RECORD_MAC_MIC_GAIN=<float>`** — override the default mic
  gain (`4.0`, baked into `MicCapture.defaultGain`). Multiplies each
  mic sample before the tanh soft-clip stage. Examples:
  - `=1` reproduces M4.2 behavior (no gain). Useful for debugging the
    raw input level on hardware that may differ from M1.
  - `=4` matches the production default (no-op vs unset).
  - `=8` ≈ +18 dB. patternn's M4.5 testing showed this engages the
    soft-clip on speech peaks and audibly amplifies the mic noise
    floor in silences. Not recommended.

  The default of 4.0× was picked from patternn's M4.5 matrix data on
  M1; see `MicCapture.defaultGain` doc and pretyflaco/meetscribe-record#6
  for the full audit. If you observe the default is wrong for your
  hardware, file an issue with a `done:` summary at gain=1 plus L/R
  mean RMS — we'll widen the data set before changing the default.

The `done:` summary line at end of run reports `mic_input: rate=… Hz
channels=… inputVolume=… gain=…` so the AVAudioEngine's native input
format and `inputNode.volume` snapshot are always visible.

## Distribution status

Phase 1 (current): unsigned binary built in CI on `macos-14` runners.
Download from GitHub Actions artifacts; macOS Gatekeeper will block first
run. Bypass with:

```sh
xattr -d com.apple.quarantine ./meet-record-mac
```

Phase 2 (post-validation): Apple Developer ID signed + notarized binary,
shipped inside the macOS-arm64 wheel of `meetscribe-record` on PyPI.
