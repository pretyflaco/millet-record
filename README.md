# meetscribe-record

Lightweight capture-only subset of [meetscribe](https://github.com/pretyflaco/meetscribe).

Records dual-channel meeting audio — your microphone on the left channel,
system/remote audio on the right — into a single stereo WAV via PipeWire
or PulseAudio + ffmpeg. Ships none of meetscribe's transcription,
diarization, summarization, or PDF dependencies; install footprint is
~30 MB instead of ~3 GB.

## When to use which

| Need | Install |
|---|---|
| Just record audio (e.g., for [vezir](https://github.com/pretyflaco/vezir) thin clients, or local archival) | `pip install meetscribe-record` |
| Record + transcribe + diarize + summarize + PDF (full meetscribe) | `pip install meetscribe-offline` (depends on meetscribe-record) |

## Install

```bash
pip install meetscribe-record
```

System deps (apt example):

```bash
sudo apt install ffmpeg pulseaudio-utils
```

## CLI

```bash
meet check          # verify prerequisites
meet devices        # list audio sources
meet record         # record dual-channel WAV; Ctrl+C to stop
meet archive        # compress past WAV recordings to OGG/Opus
```

`meet record` writes to `~/meet-recordings/meeting-YYYYMMDD-HHMMSS/...wav`
unless `-o` is passed. See `meet record --help` for options.

When `meetscribe-offline` is also installed, additional subcommands
(`transcribe`, `run`, `label`, `sync`, `gui`, ...) become available
under the same `meet` command via Click entry-points.

## Architecture

`meetscribe-record` exposes a stable package `meet_record` containing:

- `meet_record.capture` — ffmpeg-backed dual-channel capture (RecordingSession,
  watchdog, drain buffer)
- `meet_record.audio`   — stereo channel reading + ffmpeg-based audio
  compression
- `meet_record.utils`   — formatting helpers (HH:MM:SS, file sizes)
- `meet_record.languages` — language constants used by capture flow
- `meet_record.cli`     — `meet` console-script entry point

`meetscribe-offline` depends on this package and re-uses these modules,
plus its own heavy modules (transcribe, label, voiceprint, summarize,
sync, pdf, gui).

## macOS (Apple Silicon)

`pip install meetscribe-record` on macOS 14.4+ Apple Silicon ships a
bundled `meet-record-mac` Swift sidecar that captures via Core Audio
Process Tap + AVAudioEngine — no PulseAudio, no BlackHole, no extra
install. `meet record` uses it by default as of 0.2.0.

First run prompts for Microphone and System Audio Recording permissions
via the standard macOS TCC dialogs; both are required for full dual-
channel capture (mic on left, system on right). See
[`mac/README.md`](mac/README.md) for the sidecar's CLI surface, level
analysis recipes, and environment variables.

Set `MEET_RECORD_MAC=0` to force the legacy ffmpeg+PulseAudio path
(diagnostic kill switch only — that path will fail on a stock macOS
install because there is no PulseAudio device). Intel Macs and
macOS < 14.4 are unsupported.

## License

GPL-3.0-or-later, same as parent meetscribe.
