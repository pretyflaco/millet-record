# Changelog

Notable changes per release of `meetscribe-record`, the capture-only
companion of [`meetscribe-offline`](https://github.com/pretyflaco/meetscribe).
Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## v0.3.0 — 2026-05-21

### macOS Sequoia TCC permission fix (M7)

New `request-permissions` subcommand for `meet-record-mac` that calls
`AVCaptureDevice.requestAccess(for: .audio)` to trigger the macOS
permission dialog on first use.

**Problem**: on macOS Sequoia 15+, Apple removed the `+` button from
System Settings > Privacy > Microphone.  The old `probe-permissions`
subcommand only *read* the TCC status without triggering the
permission dialog.  When status was `not_determined` (fresh install),
`meet record` would refuse to start because permissions were
"blocked", but the dialog never appeared — a deadlock with no escape.

**Fix**: `check_prerequisites()` now calls `request-permissions`
instead of `probe-permissions`.  On first run, this triggers the
macOS permission dialog so the user can grant mic access
interactively.  If already granted or denied, it returns immediately
without showing any UI.  Idempotent and backward-compatible.

### Changes

- `Permissions.swift`: `requestMic()` calls
  `AVCaptureDevice.requestAccess(for: .audio)` with `DispatchSemaphore`
  blocking; `requestAndProbe()` wraps both mic request + system audio
  probe.
- `CLI.swift`: new `request-permissions` subcommand (no flags, same
  output format as `probe-permissions`).
- `main.swift`: `runRequestPermissions()` with Sequoia-specific
  troubleshooting guidance on stderr when denied.
- `capture.py`: `check_prerequisites()` calls `request-permissions`;
  timeout raised 10s → 30s; error messages include `tccutil reset`
  guidance for Sequoia.
- `cli.py`: `meet check` shows macOS-specific output (mic permission /
  system audio perm) instead of PulseAudio / PipeWire on darwin.

### Versions

- Python package: 0.3.0
- Sidecar binary: 0.6.0 (M7)

---

## v0.2.1 — 2026-05-18

### Fixed

- **`session.json` now carries `stop_reason`.**  Regression vs
  0.2.0a1, caught by @patternn in M8 macOS-local validation.

---

## v0.2.0 — 2026-05-14

### Default macOS sidecar ON

`pip install meetscribe-record` on macOS 14.4+ Apple Silicon now uses
the bundled `meet-record-mac` Swift sidecar (Core Audio Process Tap +
AVAudioEngine) without any opt-in env var.  Linux behavior is
unchanged.

This release closes the M6 arc on epic [#1](https://github.com/pretyflaco/meetscribe-record/issues/1).

### Highlights

- **macOS Apple Silicon recording works out of the box.**  First run
  prompts for Microphone and System Audio Recording permissions via
  standard macOS TCC dialogs; both are required for full
  dual-channel capture (mic on left, system on right).
- **Process-group isolation** ([#13](https://github.com/pretyflaco/meetscribe-record/pull/13)):
  `start_new_session=True` on the recorder subprocess.  Terminal
  Ctrl+C now reaches only the Python parent, which drives the
  documented `q`-byte stop ladder cleanly.  Fixes spurious watchdog
  restarts that produced two-chunk recordings on Ctrl+C in 0.2.0a1.
  Applies to both Linux ffmpeg and macOS sidecar backends.
- **Default-flip for the macOS backend** ([#14](https://github.com/pretyflaco/meetscribe-record/pull/14)):
  set `MEET_RECORD_MAC=0` to fall back to the legacy ffmpeg +
  PulseAudio path (diagnostic kill switch only — that path doesn't
  work on a stock macOS install).  Fail-open semantics: any value
  other than literal `"0"` keeps the sidecar enabled.

### Validation

The macOS recording pipeline was validated end-to-end on an Apple M1
(macOS 26.4.1, ffmpeg 8.0.1) across patternn rounds:

- **M6c.ii** (2026-05-10): audio-path validation.  Left channel mean
  −23.9 dB on controlled speech; `you_ratio = 0.242`, 1.61× past the
  `_label_speakers_from_channels` 0.15 floor; chunk stitching
  seamless; WAV format `pcm_s16le 16 kHz 2 ch` correct.
- **M6c.ii.b** (2026-05-14): post-fix re-validation.  `restart_count: 0`,
  `chunk_count: 1`, `stop_reason: stdin-q` on a single ~43 s
  recording.  The race in [#12](https://github.com/pretyflaco/meetscribe-record/issues/12)
  (`alreadyClosed` warning on SIGINT) is no longer reachable on the
  normal stop path.

### Distribution

- macOS-arm64 wheel ships with the notarized-pending sidecar binary
  inside (`meet_record/_bin/meet-record-mac`).
- Linux/universal wheel keeps the empty `_bin/` directory and
  `capture.py` shells out to system `ffmpeg` + `pactl` as before.
- PyPI publish for 0.2.0 was not automated; the artifacts are on the
  [GitHub release](https://github.com/pretyflaco/meetscribe-record/releases/tag/record-v0.2.0).
  v0.2.1 was the first real PyPI push after this; 0.2.0 itself never
  reached PyPI (see notes in vezir's 2026-05-18 update on [blink-wip#639](https://github.com/blinkbitcoin/blink-wip/issues/639)).

### Requirements

- **macOS recording**: macOS 14.4+ Apple Silicon.  Intel Macs and
  macOS < 14.4 are unsupported (Process Tap APIs require Sonoma 14.4).
- **Linux recording**: ffmpeg + PulseAudio (or PipeWire with the
  PulseAudio compatibility layer).

---

## v0.1.0 — 2026-04-25

### Initial release

Capture-only subset of [meetscribe](https://github.com/pretyflaco/meetscribe).
Records dual-channel meeting audio (microphone on the left channel,
system/remote audio on the right) into a single stereo WAV via
PipeWire or PulseAudio + ffmpeg.  Ships none of meetscribe's
transcription, diarization, summarization, or PDF dependencies;
install footprint is ~30 MB instead of ~3 GB.

### When to use which

| Need | Install |
|---|---|
| Record audio only (e.g. for [vezir](https://github.com/pretyflaco/vezir) thin clients, or local archival) | `pip install meetscribe-record` |
| Record + transcribe + diarize + summarize + PDF | `pip install meetscribe-offline` (depends on this) |

### Subcommands shipped

- `meet record` — dual-channel meeting capture
- `meet devices` — list audio sources
- `meet check` — verify prerequisites
- `meet archive` — compress past WAV recordings to OGG/Opus

When `meetscribe-offline` is also installed, the same `meet` console
script transparently exposes all 12 subcommands via Click entry-point
plugin discovery (`meet.subcommands`).
