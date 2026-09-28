# millet-record

[![CI](https://github.com/pretyflaco/millet-record/actions/workflows/python-ci.yml/badge.svg)](https://github.com/pretyflaco/millet-record/actions/workflows/python-ci.yml)
[![PyPI](https://img.shields.io/pypi/v/millet-record.svg)](https://pypi.org/project/millet-record/)
[![PyPI Downloads](https://static.pepy.tech/personalized-badge/millet-record?period=total&units=INTERNATIONAL_SYSTEM&left_color=BLACK&right_color=GREEN&left_text=downloads)](https://pepy.tech/projects/millet-record)

Lightweight capture-only subset of [millet](https://github.com/pretyflaco/millet)
(formerly meetscribe-record).

Records dual-channel meeting audio — your microphone on the left
channel, system/remote audio on the right — into a single stereo WAV
via PipeWire or PulseAudio + ffmpeg. Ships none of millet's
transcription, diarization, summarization, or PDF dependencies;
install footprint is ~30 MB instead of ~3 GB.

Full release history in [`CHANGELOG.md`](CHANGELOG.md).  Named after
the Ottoman *millet system*.  Part of the
[vezir](https://github.com/pretyflaco/vezir) ecosystem.

## When to use which

| Need | Install |
|---|---|
| Just record audio (e.g., for [vezir](https://github.com/pretyflaco/vezir) thin clients, or local archival) | `pip install millet-record` |
| Record + transcribe + diarize + summarize + PDF | `pip install millet-pipeline` (depends on millet-record) |

## Install

```bash
pip install millet-record
```

System deps (apt example):

```bash
sudo apt install ffmpeg pulseaudio-utils
```

## CLI

```bash
millet check                   # verify prerequisites
millet devices                 # list audio sources
millet record                  # record dual-channel WAV; Ctrl+C to stop
millet archive                 # compress past WAV recordings to OGG/Opus
```

`millet record` writes to `~/meet-recordings/meeting-YYYYMMDD-HHMMSS/...wav`
unless `-o` is passed. See `millet record --help` for options.

When `millet-pipeline` is also installed, additional subcommands
(`transcribe`, `run`, `label`, `sync`, `gui`, ...) become available
under the same `millet` command via Click entry-points.

### System-audio silence warning (0.5.1)

The system-audio monitor is resolved once, at session start.  If the
meeting app's output is later routed elsewhere — switching apps mid-call,
plugging in headphones — that monitor goes silent while your mic keeps the
stereo file growing.  The remote side is lost with no process failure and
nothing in the output to suggest it.

`millet record` now samples per-channel RMS while recording and warns
inline the first time the system channel goes quiet:

```
⚠ System audio silent — remote participants may not be recorded
✔ System audio restored
```

`session.json` records `system_ever_active` and `system_silent_detected`,
so a downstream tool can flag a recording that captured only one side.  An
unreadable sample counts as *unknown*, never as silent, so a transient
ffmpeg hiccup cannot produce a false alarm.

### Crash resilience (0.6.0)

Recorders run `start_new_session=True`-detached **on purpose**: if the
controlling app (TUI, CLI) crashes, the recording survives — the meeting
is still happening.  0.6.0 adds the bookkeeping to make that survivable
in practice:

* `recording.lock` in the recordings root blocks a second concurrent
  recording (`RecordingInProgressError`, PID-checked, stale locks
  auto-reclaimed; `MEET_RECORD_LOCK=0` disables).
* `<stem>.recorder.json` identifies the live recorder process
  (pid + owner pid + start ticks); removed on clean stop/pause.
* `<stem>.session.json` is now written at recording *start*
  (`status: "recording"`) and rewritten at stop (`status: "stopped"`).
* `millet_record.capture.find_interrupted_sessions(root)` scans a
  recordings dir for sessions that never finished, distinguishing
  *in progress* / *orphaned recorder* / *interrupted*; and
  `millet_record.capture.recover_session(dir)` stitches leftover chunks
  into the final WAV (repairing SIGKILL-damaged headers).

### Legacy `meet` command (removed in 0.6.0)

The pre-rename `meet` console script and the `meet_record` import alias
were removed in `millet-record 0.6.0`, after the announced two-minor-version
deprecation window.  Use `millet` / `millet_record`.

## Architecture

`millet-record` exposes a stable package `millet_record` containing:

- `millet_record.capture` — ffmpeg-backed dual-channel capture
  (RecordingSession, watchdog, drain buffer)
- `millet_record.audio` — stereo channel reading, per-channel RMS
  sampling (system-silence detection), ffmpeg-based audio compression
- `millet_record.utils` — formatting helpers (HH:MM:SS, file sizes)
- `millet_record.languages` — language constants used by capture flow
- `millet_record.cli` — `millet` console-script entry point

`millet-pipeline` depends on this package and re-uses these modules,
plus its own heavy modules (transcribe, label, voiceprint, summarize,
sync, pdf, gui).

## macOS (Apple Silicon)

`pip install millet-record` on macOS 14.4+ Apple Silicon ships a
bundled `meet-record-mac` Swift sidecar that captures via Core Audio
Process Tap + AVAudioEngine — no PulseAudio, no BlackHole, no extra
install.  `millet record` uses it by default.

> **Note:** the Swift binary itself is still named `meet-record-mac`
> for now — renaming would require macOS code-signing bundle-path
> changes that aren't worth doing as part of the package rename.
> Tracked as a follow-up; doesn't affect end users.

First run prompts for Microphone and System Audio Recording permissions
via the standard macOS TCC dialogs; both are required for full dual-
channel capture (mic on left, system on right). See
[`mac/README.md`](mac/README.md) for the sidecar's CLI surface, level
analysis recipes, and environment variables.

On **macOS Sequoia 15+**, Apple removed the manual `+` button from
System Settings → Privacy → Microphone, so users can no longer add
permissions before running the app.  Instead, run `millet check`: it
invokes the sidecar's `request-permissions` routine, which calls
`AVCaptureDevice.requestAccess(for: .audio)` to trigger the TCC dialog,
and reports which permission is still missing.  (`request-permissions`
is a subcommand of the bundled `meet-record-mac` binary, not of the
`millet` CLI — `millet check` is the user-facing entry point.)

Set `MEET_RECORD_MAC=0` to force the legacy ffmpeg+PulseAudio path
(diagnostic kill switch only — that path will fail on a stock macOS
install because there is no PulseAudio device).  Intel Macs and
macOS < 14.4 are unsupported.

## License

GPL-3.0-or-later, same as parent millet.
