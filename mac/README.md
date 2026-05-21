# meet-record-mac

Native macOS Apple Silicon recording sidecar for meetscribe-record.

Replaces the Linux `ffmpeg -f pulse` pipeline on macOS with a Swift binary
built on Core Audio Process Tap + AVAudioEngine, modeled on
[`RecapAI/Recap`](https://github.com/RecapAI/Recap) (MIT — see `NOTICE` at
the repo root).

## Status

**Default macOS recording backend** as of `meetscribe-record` 0.2.0
(M6c.ii.c, post-patternn M6c.ii.b sign-off). `meet record` shells out
to this binary on darwin without any opt-in env var; set
`MEET_RECORD_MAC=0` from `meetscribe-record`'s parent process to force
the legacy ffmpeg+PulseAudio path (which fails on a stock macOS
install — the var is a diagnostic kill switch, not a recommended
config).

Captures dual-channel audio for an unbounded duration; stop is driven
by the parent process via a `q` byte on stdin (matching ffmpeg's stop
convention) or by SIGINT/SIGTERM.

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

## CLI surface (M5)

```
meet-record-mac record \
    --output <chunk.wav>
    [--mic <"default" | "none" | <device-uid>>]
    [--system <"system" | "none" | "app:<bundle-id>">]
    [--sample-rate 16000]
    [--max-seconds 0]

meet-record-mac devices [--json]
meet-record-mac probe-permissions
meet-record-mac request-permissions
meet-record-mac --version
meet-record-mac --help
```

### Stop protocol (record mode)

The recorder runs **open-ended** by default and stops on any of:

- A single `q` (0x71) byte on stdin → `stop_reason: stdin-q`
- EOF on stdin (parent closed the pipe) → `stop_reason: stdin-eof`
- `SIGINT` (Ctrl-C / parent escalation) → `stop_reason: SIGINT`
- `SIGTERM` (parent escalation) → `stop_reason: SIGTERM`
- `--max-seconds N` cap if `N > 0` → `stop_reason: max-seconds`
- `SIGKILL` — leaves a partial WAV with a stale RIFF size header

Mirrors ffmpeg's "press q to quit" convention so the existing Python
parent (`meet_record/capture.py:_stop_ffmpeg`) is a drop-in.

### Run a quick smoke test

```sh
# 5-second recording, default mic, system-wide tap. The shell is the
# parent here, so we just send the q byte after a sleep:
( sleep 5 && printf 'q' ) | ./.build/release/meet-record-mac \
    record --output /tmp/sample.wav

ffprobe -hide_banner /tmp/sample.wav
```

Expected: stereo 16 kHz s16le WAV, both channels carrying audio (left =
mic, right = system). The `done:` summary line on stderr reports
`stop_reason: stdin-q`, frame counts, and the mic input format.

Per-app capture:

```sh
# Tap only what Zoom is playing (other apps' audio not captured)
./.build/release/meet-record-mac record \
    --output /tmp/zoom.wav \
    --system app:us.zoom.xos
```

Note: per-app tap requires the target app to have already touched the
audio HAL since boot; newly-launched apps that haven't played any audio
yet may not appear in the Process Tap process list.

Mic-only or system-only:

```sh
# Mic only — right channel will be silence
./.build/release/meet-record-mac record --output /tmp/mic.wav --system none

# System only — left channel will be silence
./.build/release/meet-record-mac record --output /tmp/sys.wav --mic none
```

### Enumerate devices

```sh
./.build/release/meet-record-mac devices --json
```

```json
[
  {
    "uid": "BuiltInMicrophoneDevice",
    "name": "MacBook Pro Microphone",
    "is_default": true
  },
  ...
]
```

The `uid` field is exactly what `--mic <uid>` accepts.

### Probe TCC permissions

```sh
./.build/release/meet-record-mac probe-permissions
# mic: granted
# system_audio: granted
# overall: ok
```

Exit code is `0` when both are granted, `1` otherwise. Read-only: does
not trigger any permission dialogs. The system_audio probe attempts to
create + immediately destroy a Process Tap.

### Request TCC permissions (M7)

```sh
./.build/release/meet-record-mac request-permissions
# mic: granted
# system_audio: granted
# overall: ok
```

Same output format and exit codes as `probe-permissions`, but
**triggers the macOS permission dialog** for Microphone when the TCC
status is `notDetermined` (first use). Idempotent: if already granted
or denied, returns immediately without showing any UI. The system_audio
probe still triggers its dialog as a side effect of the tap creation.

This is the subcommand that `meet check` and `meet record`'s
prerequisite check call since meetscribe-record 0.3.0.

## Permissions

macOS requires **two separate permissions** for dual-channel capture.
Both must be granted for the terminal app hosting the recording:

| Permission | Channel | What happens if missing |
|---|---|---|
| **Microphone** | Left (your voice) | `AVAudioEngine.start()` fails or captures silence |
| **System Audio Recording** | Right (remote participants) | Process Tap creation fails; right channel is silent |

On first run, macOS should prompt for both. If only Microphone is
granted, your recording will capture your voice but remote participants
will be silent — the transcript will show only you, with Whisper
hallucinating single-word entries ("Hi.", "Thanks.", "Bye.") for others.

Verify both are granted:

```sh
./.build/release/meet-record-mac request-permissions
# or: meet check
```

If you accidentally clicked Deny, or a permission is missing, re-grant
via:

```
System Settings → Privacy & Security → Microphone
                                     → System Audio Recording
```

Enable your terminal app in **both** lists. Microphone and System Audio
Recording are independent TCC buckets — granting one does not grant the
other.

## Per-channel level analysis (modern ffmpeg syntax)

`-map_channel` was removed in ffmpeg 8.x; use `-af "pan=…"` instead.

```sh
xattr -d com.apple.quarantine ./meet-record-mac
( sleep 5 && printf 'q' ) | ./meet-record-mac record --output /tmp/sample.wav

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

These variables are read by `meet_record.capture` (the Python parent),
not by the sidecar binary itself, except `MEET_RECORD_MAC_DEBUG` and
`MEET_RECORD_MAC_MIC_GAIN` which the sidecar reads directly.

- **`MEET_RECORD_MAC=0`** — opt out of the sidecar and force
  `meet_record.capture` back to the legacy ffmpeg+PulseAudio path.
  Diagnostic kill switch: that path fails on a stock macOS install
  (no PulseAudio device), so this is for narrowing down a sidecar
  bug or cross-checking against pre-0.2.0 behavior with a manually
  installed PulseAudio. Any other value (unset, "1", "yes", typos)
  keeps the sidecar enabled — fail-open into the working backend.

- **`MEET_RECORD_MAC_PATH=<path>`** — override the resolved path to
  the `meet-record-mac` binary. Resolution order is
  `MEET_RECORD_MAC_PATH` → `meet_record/_bin/meet-record-mac` (the
  pip-installed bundle location) → `meet-record-mac` on `PATH`.
  Useful for running a `swift build` artefact against a pip-installed
  package, or for pointing the test suite at a mock recorder.

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
