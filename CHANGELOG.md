# Changelog

Notable changes per release of `millet-record` (formerly
`meetscribe-record`), the capture-only companion of
[`millet-pipeline`](https://github.com/pretyflaco/millet).
Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## v0.6.0 — 2026-09-28 — crash resilience: recording lock, recorder marker, interrupted-session recovery

Incident 2026-09-28: a scribe's TUI died mid-recording.  The recorder —
deliberately `start_new_session=True`-detached so the meeting survives a
UI crash — kept writing as an orphan for 12 more minutes, capturing two
*subsequent* meetings into the dead session's file.  Meanwhile the
recording appeared lost: nothing on disk said "interrupted,
recoverable", and nothing stopped a second recording from starting while
the orphan held the mic.  The audio itself was fully intact (chunk WAVs
+ header repair already worked); what was missing was the bookkeeping.

This release adds the bookkeeping.  Test suite grows 81 → 104 (23 new).

### Added

* **Recording lock** (`recording.lock` in the output root).
  `create_session` + `start()` now take a PID-checked lock; a second
  `start()` in the same root raises **`RecordingInProgressError`**
  (carrying the holder's pid/start time/session dir).  Locks left by
  dead processes are reclaimed automatically, with a
  (pid, /proc start-ticks) pair guarding against pid reuse on Linux.
  Set `MEET_RECORD_LOCK=0` to bypass (diagnostic kill switch, matching
  the `MEET_RECORD_MAC=0` convention).  The `record` CLI exits cleanly
  with the holder info instead of a traceback.  Direct
  `RecordingSession(...)` construction (no `create_session`) skips
  locking, for embedders that manage their own lifecycle.
* **`<stem>.recorder.json` marker**, written on every recorder spawn
  (start/restart/resume), removed on clean stop/pause: recorder pid +
  owner pid + start ticks + backend + chunk name.  Because the recorder
  outlives its parent by design, this marker is what lets a later
  process distinguish *recording right now* from *orphaned recorder
  still writing*.
* **`<stem>.session.json` is written at recording start** with
  `status: "recording"` + `owner_pid`, rewritten at stop with
  `status: "stopped"` (and on failed start with `status: "failed"`).
  An interrupted session dir is now self-describing.
* **`find_interrupted_sessions(root) -> list[InterruptedSession]`** —
  scans a recordings dir for sessions that never finished (chunk files,
  no final WAV), newest first, and classifies each via the marker:
  in-progress (leave it alone), `orphaned` (owner dead, recorder alive —
  SIGINT the recorder, then recover), or plain interrupted.
* **`recover_session(session_dir) -> Path`** — repairs chunk WAV headers
  (a SIGKILLed recorder never patched its RIFF/data sizes), stitches
  chunks in order (ffmpeg concat, largest-chunk fallback), cleans up
  chunks, and marks the metadata `status: "recovered"`.  Refuses
  (RuntimeError) while a recorder is still writing into the dir.

### Removed (announced in 0.4.0, two-minor-version window)

* **`meet` console script** and its deprecation shim.  Use `millet`.
* **`meet_record` import alias** (MetaPathFinder).  Use `millet_record`.
  Verified safe across the ecosystem: vezir and millet-pipeline import
  the canonical names; only docstrings mentioned the legacy one.
* **`meet.subcommands` entry-point group scan** in the CLI plugin
  loader (millet-pipeline dual-publishes `millet.subcommands` since
  0.9.x, so nothing is lost).

## v0.5.1 — 2026-08-26 — system-channel silence detection

Adds live detection of a silent system (remote) channel during recording.
The system-audio monitor is resolved once at session start; if the meeting
app's output is later routed to a different sink (e.g. switching apps
mid-call, plugging in headphones), the recorded monitor goes silent while the
mic keeps the stereo file growing — so remote participants are lost with no
process failure and no warning.  Test suite grows 69 → 81 (12 new).

### Added

* **`audio.sample_channel_rms(path, *, tail_seconds=8.0)`** — cheaply measures
  per-channel active RMS from the tail of a growing recording chunk (ffmpeg
  `-sseof` end-relative seek).  Returns `(mic_rms, system_rms)` over active
  samples, or `None` (treated as "unknown", never "silent") on any failure.
* **Watchdog system-silence check.**  `RecordingSession._check_system_channel`
  samples the current chunk every `_CHANNEL_CHECK_INTERVAL` (5 s) and flags
  `system_silent` once the mic has been active but the system channel silent
  for `_SYSTEM_SILENCE_TIMEOUT` (42 s).  Gated on the system channel having
  been active at least once, so genuine in-room meetings (no system audio at
  all) never warn.  The RMS ratio (`_SYSTEM_SILENT_RATIO = 0.10`) matches the
  pipeline's `system_inactive_rms_ratio`, so a recording that warns here is
  exactly one that trips single-source fallback downstream.
* **`RecordingStatus.system_silent` / `system_ever_active`** — surfaced so the
  `record` CLI prints a persistent, non-interrupting warning
  (`⚠ System audio silent — remote participants may not be recorded`) and a
  `✔ System audio restored` line on recovery (re-arms per episode).
* **`session.json` records `system_ever_active` and `system_silent_detected`**
  so a recording where remotes were likely not captured is auditable without
  re-analyzing the audio.

## v0.5.0 — 2026-07-06 — orphan-recorder race fixes, leak-proof lifecycle, crash-safe WAV headers

Reliability release.  Fixes the stop/pause-vs-watchdog races that could
leave a detached recorder process recording forever, plus a set of
resource-leak and crash-resilience fixes found in the 2026-07 ecosystem
review.  Test suite grows 53 → 69 (16 new race/lifecycle tests).

### Fixed

* **`stop()`/`pause()` vs watchdog races (orphaned recorder).**  Session
  state was mutated outside `_lock` while the watchdog thread read it
  under the lock.  Because recorders run `start_new_session=True`-
  detached, a watchdog restart racing a `stop()` or `pause()` could
  spawn a fresh recorder *after* the old one was killed — a process
  that records until the disk fills, with nobody left to stop it.
  `stop()` now joins the watchdog **before** killing the recorder (and
  closes the shared log last); `pause()` holds `_lock` across the
  stop + flag pair; `_attempt_restart` re-checks stop/pause/failed
  state under the lock and abandons a lost race.
* **`record` CLI leaked the recorder on any non-Ctrl+C exit.**  Only
  `KeyboardInterrupt` triggered `session.stop()`.  Unexpected
  exceptions and SIGTERM (systemd stop, `kill`, session logout) exited
  the parent while the detached recorder kept running.  Now: a
  `finally` guard stops the session on every exit path, and SIGTERM is
  translated into the same graceful drain + stop as Ctrl+C.
* **`start()` failure leaked audio plumbing.**  A startup failure left
  the log handle open, the PulseAudio null-sink/loopback modules loaded
  (breaking the user's audio routing until a manual
  `pactl unload-module`), and an empty chunk file on disk.  All torn
  down on failure now.
* **`stop()` could hang forever on a wedged concat.**  The chunk-stitch
  `ffmpeg` call had no timeout.  Now budgeted proportionally to total
  chunk size (floor 120 s) with the existing largest-chunk fallback.
* **SIGKILLed chunks silently truncated.**  A recorder killed with
  SIGKILL (or lost to a host crash) never patched its WAV header, so
  the chunk carried a 0-length `data` size while holding real audio —
  and `ffmpeg -f concat -c copy` trusts the header.  Two-layer fix:
  the macOS sidecar's `WavWriter` now re-patches header sizes in place
  every ~10 s of audio, and the Python side repairs every chunk's
  header from the on-disk file size before stitching
  (`_repair_wav_header`).
* **`status()`/`pause()` froze up to 10 s during a watchdog restart.**
  The blocking recorder-startup poll no longer runs under `_lock`.

## v0.4.4 — 2026-06-16 — cap requires-python at <3.14 (coincurve build fail)

Packaging guard.  No code change.

### Fixed

* **`requires-python` now `>=3.10,<3.14`.**  On a fresh Mac, `brew install
  python3` gives Python 3.14, and `coincurve` (pulled transitively in the
  vezir thin-client via `vezir[nostr]`) has no cp314 wheel — so the install
  fell back to a source build that fails (`Expected exactly one LICENSE file
  in cffi distribution`).  Capping the floor/ceiling makes pip/pipx select
  3.13 (which has a prebuilt wheel) or refuse with a clear message, instead
  of a cryptic build crash.  Relax once coincurve ships cp314 wheels.

## v0.4.3 — 2026-06-16 — publish the macOS arm64 wheel to PyPI

Packaging fix.  No code or runtime-behavior change.

### Fixed

* **macOS arm64 wheel is now published to PyPI.**  Releases 0.4.0–0.4.2
  shipped only the binary-less `py3-none-any` wheel to PyPI; the
  `…-macosx_14_0_arm64` wheel that bundles the `meet-record-mac` Swift
  sidecar (built on a GitHub `macos-14` runner) existed *only* as a
  workflow artifact and was never uploaded.  Result: `pip install
  millet-record` on Apple Silicon got an empty `millet_record/_bin/`, and
  `vezir scribe` failed with `meet-record-mac not found`.
* **`release.yml` now publishes on a `record-v*` tag push** via PyPI
  Trusted Publishing (OIDC — no stored token): both wheels + the sdist
  are uploaded after the macOS wheel passes its install/record smoke
  test.  Manual `workflow_dispatch` runs still build + verify only.

### Upgrade

* macOS (Apple Silicon): `pip install --upgrade millet-record` (or
  `vezir[tui]`) now resolves the wheel with the bundled sidecar.

## v0.4.2 — 2026-05-29 — CI fix, ruff, Linux capture tests

Code-health release.  No runtime behavior change.

### Fixed

* **CI never triggered on code changes**: `python-ci.yml` `paths:`
  filters referenced the pre-rename `meet_record/**`; the package is
  `millet_record/**`.  Pushes/PRs touching the package were silently
  skipping CI.  Filters corrected; a `ruff check` step added.

### Added

* **`[tool.ruff]` config** (mirrors the vezir ruleset
  `E,F,W,I,B,UP,RUF`); existing lint cleaned up.
* **`tests/test_capture_linux.py`** (10 tests) covering the Linux
  PulseAudio/PipeWire + ffmpeg path that real Linux users hit:
  `list_sources` parsing, `get_default_sink/source`,
  `get_monitor_source`, and the Linux branch of `check_prerequisites`
  (missing ffmpeg / pactl).  Previously only the macOS sidecar path was
  tested.

## v0.4.1 — 2026-05-24 — fix `--version` mislabel when only legacy pipeline installed

### Fixed

* **`--version` output mislabeled legacy `meetscribe-offline` as
  `millet-pipeline`.**  When the new `millet-pipeline 0.9.0` was not
  installed but the pre-rename `meetscribe-offline` was, the
  fallback found the legacy version number but the output string
  still claimed `millet-pipeline X.Y.Z`.  A user on the 2026-05-24
  laptop smoke read `millet, version 0.7.1 (millet-pipeline 0.7.1;
  millet-record 0.4.0)` and assumed they had the new package
  installed when they only had the old one.

  Now the output explicitly names the legacy package and prompts
  for the upgrade:

      millet, version 0.7.1 (meetscribe-offline 0.7.1 [legacy —
        `pip install millet-pipeline` to upgrade]; millet-record 0.4.1)

  Also reworded the "not installed" branch from "millet-pipeline not
  installed" to "pipeline not installed" so it doesn't visually
  conflict with the line above when both branches appear in
  documentation side-by-side.

No other changes.  Pure cosmetic.

---

## v0.4.0 — 2026-05-24 — rename to `millet-record`

The package formerly known as `meetscribe-record` is now
**`millet-record`**.  Capture-only sibling of `millet-pipeline`
(formerly `meetscribe-offline`).  Named after the Ottoman *millet
system*.  Part of the [vezir](https://github.com/pretyflaco/vezir)
ecosystem.

This release is **all rename, no feature change.**  Functional
behavior is identical to 0.3.0.

### Changed

* **Distribution name**: `meetscribe-record` → `millet-record`.
* **Import name**: `meet_record` → `millet_record`.  The old name is
  preserved as a sys.modules alias + a meta-path finder so existing
  `from meet_record.X import …` keeps working unchanged.  Removed in
  `0.6.0`.
* **CLI console script**: `meet` → `millet`.  The legacy `meet` is
  retained as a separate entry point that emits a `DeprecationWarning`
  + a stderr notice, then forwards to the same group.  Removed in
  `0.6.0`.  Set `MILLET_SUPPRESS_DEPRECATION=1` to silence.
* **Entry-point group consulted**: `millet.subcommands` (primary) and
  `meet.subcommands` (legacy fallback for one deprecation cycle).
* **`--version` output**: `meet 0.5.0 (meetscribe-offline 0.5.0;
  meetscribe-record 0.1.0)` → `millet 0.9.0 (millet-pipeline 0.9.0;
  millet-record 0.4.0)`.

### What did NOT change

* The bundled macOS Swift sidecar binary name (`meet-record-mac`).
  Renaming it would require macOS code-signing bundle-path changes
  that aren't worth doing as part of the rename.  Tracked as a
  follow-up.
* Internal class names, function signatures, capture behavior.
* Linux ffmpeg + PulseAudio path, macOS sidecar path.

### Migration

```bash
pip uninstall meetscribe-record
pip install millet-record   # or `pip install millet-pipeline` to get both
millet --version            # was: meet --version
```

Existing scripts that import `from meet_record.capture import …`
continue to work for two minor versions before removal.

---

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
