"""Audio capture module for recording meeting audio.

Captures dual-channel audio: microphone (your voice) on one channel,
system audio (remote participants) on the other.

Backends:
- Linux: ffmpeg with PulseAudio/PipeWire monitor sources (default).
- macOS 14.4+ Apple Silicon: meet-record-mac (Swift sidecar) using
  Core Audio Process Tap + AVAudioEngine. Default backend on darwin
  as of 0.2.0 (post-M6c.ii.b sign-off). Set MEET_RECORD_MAC=0 to
  force the legacy ffmpeg+PulseAudio path (which fails on macOS
  because there is no PulseAudio device — the var is primarily a
  diagnostic kill switch).

Reliability features (apply to either backend):
- subprocess stderr goes to a log file (prevents pipe buffer deadlock)
- Watchdog thread monitors process health and file growth
- Auto-restart on subprocess failure with chunk-based recording
- Chunk stitching on stop via ffmpeg concat (post-process; ffmpeg
  remains a runtime dep on macOS for stitching even when the recorder
  is the Swift sidecar)

Crash/interrupt resilience (0.6.0):
- ``recording.lock`` in the output root (PID-checked, stale-auto-reclaimed)
  blocks a second recording while one is active — see
  ``RecordingInProgressError``.  Set ``MEET_RECORD_LOCK=0`` to bypass.
- ``<stem>.recorder.json`` marker written per spawned recorder (pid +
  owner pid + start ticks), removed on clean stop/pause: lets any later
  process tell "recording now" from "orphaned recorder" from "crashed".
- ``<stem>.session.json`` is written at start (``status: recording``),
  not only at stop, so an interrupted dir is self-describing.
- ``find_interrupted_sessions()`` + ``recover_session()`` scan and
  stitch dirs the parent never came back for.

Stop protocol (both backends):
- Write `b"q"` to stdin → graceful flush + exit 0 within 5 s
- Escalate via SIGINT (5 s) → SIGTERM (3 s) → SIGKILL
- The Swift sidecar speaks this protocol natively (see
  pretyflaco/meetscribe-record:mac/Sources/MeetRecordMac/StopController.swift),
  so the ladder in `_stop_ffmpeg` is unchanged across backends.
"""

from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import IO

from .audio import sample_channel_rms

# ─── Constants ───────────────────────────────────────────────────────────────

_WATCHDOG_INTERVAL = 3.0  # seconds between health checks
_STARTUP_POLL_INTERVAL = 0.1  # seconds between startup file-size checks
_STARTUP_TIMEOUT = 10.0  # max seconds to wait for ffmpeg to produce data
_MAX_RESTART_ATTEMPTS = 5  # max consecutive restart attempts
_STALL_TIMEOUT = 15.0  # seconds of no file growth before declaring stall
DRAIN_SECONDS = 10  # seconds to keep recording after user requests stop,
# allowing ffmpeg's ~0.9x realtime pipeline to flush

# ── System-channel silence detection ──
# The system-audio channel (remote participants) can go silent mid-recording
# without any process/file-growth failure — e.g. the meeting app's output is
# switched to a different sink, so the recorded monitor carries nothing while
# the mic keeps the stereo file growing normally.  The watchdog samples the
# tail of the current chunk and flags this so the UI can warn the scribe.
_CHANNEL_CHECK_INTERVAL = 5.0  # seconds between per-channel activity samples
_SYSTEM_SILENCE_TIMEOUT = 42.0  # seconds of mic-active-but-system-silent before flagging
# System RMS at or below this fraction of the mic's active RMS counts as
# silent.  Matches the pipeline's system_inactive_rms_ratio so a recording
# that warns here is exactly one that trips single-source fallback downstream.
_SYSTEM_SILENT_RATIO = 0.10
# Active-RMS floor (int16 amplitude) below which a channel is treated as
# carrying no speech.  Matches audio._SILENCE_THRESHOLD.
_SILENCE_FLOOR = 50.0

# WAV format constants (must match recorder output settings)
_WAV_HEADER_BYTES = 44  # standard WAV header size
_SAMPLE_RATE = 16000  # Hz
_CHANNELS = 2  # stereo (left=mic, right=system)
_BYTES_PER_SAMPLE = 2  # pcm_s16le = 16-bit = 2 bytes
_BYTES_PER_SECOND = _SAMPLE_RATE * _CHANNELS * _BYTES_PER_SAMPLE  # 64000

# ─── macOS sidecar (M6a) ─────────────────────────────────────────────────────

# Env var that controls whether the macOS sidecar backend is used.
#
# As of 0.2.0 (post-M6c.ii.b sign-off, 2026-05-14) the sidecar is ON by
# default on darwin. Set MEET_RECORD_MAC=0 to force the legacy
# ffmpeg+PulseAudio path. That path will fail on a stock macOS install
# (no PulseAudio device); the env var primarily exists as a diagnostic
# kill switch — for cross-checking against pre-0.2.0 behavior with a
# manually-installed PulseAudio, or for narrowing down a sidecar bug
# during investigation.
#
# The constant name is kept as `_DARWIN_OPT_IN_ENV` for git-blame
# continuity through the M6c.ii arc; the semantics flipped to opt-OUT
# in M6c.ii.c. Internal symbol; no public API surface depends on it.
_DARWIN_OPT_IN_ENV = "MEET_RECORD_MAC"

# Env var that overrides the path to the Swift sidecar binary. Primarily
# used by the test suite to point at a mock recorder; can also be used in
# manual smoke testing to validate a locally-built binary against a
# pip-installed package.
_DARWIN_RECORDER_PATH_ENV = "MEET_RECORD_MAC_PATH"


def _resolve_darwin_recorder() -> Path:
    """Locate the meet-record-mac binary.

    Resolution order:
      1. ``MEET_RECORD_MAC_PATH`` env var (test/manual override).
      2. ``millet_record/_bin/meet-record-mac`` next to this module
         (the path the macOS arm64 wheel installs to).
      3. ``meet-record-mac`` on ``PATH`` (development convenience for
         running against a `swift build` artefact in a checkout).

    Raises FileNotFoundError if none of the above resolve.
    """
    override = os.environ.get(_DARWIN_RECORDER_PATH_ENV)
    if override:
        candidate = Path(override).expanduser()
        if not candidate.is_file():
            raise FileNotFoundError(
                f"{_DARWIN_RECORDER_PATH_ENV}={override} does not point to a file"
            )
        return candidate

    bundled = Path(__file__).parent / "_bin" / "meet-record-mac"
    if bundled.is_file():
        return bundled

    # Fallback to PATH for development.
    import shutil

    on_path = shutil.which("meet-record-mac")
    if on_path:
        return Path(on_path)

    raise FileNotFoundError(
        "meet-record-mac not found. Install the macOS arm64 wheel of "
        "meetscribe-record (which bundles it at millet_record/_bin/), set "
        f"{_DARWIN_RECORDER_PATH_ENV} to a built binary, or add it to PATH."
    )


def _darwin_backend_enabled() -> bool:
    """True iff the macOS sidecar backend should be used.

    Default-ON on darwin as of 0.2.0 (M6c.ii.c, post-patternn M6c.ii.b
    sign-off). Set ``MEET_RECORD_MAC=0`` to force the legacy ffmpeg+
    PulseAudio path; any other value (unset, "1", "yes", empty string,
    typos) keeps the sidecar enabled so an accidentally-misset value
    fails open into the working backend on macOS.

    Linux / other platforms always return False — no behavior change
    on those platforms; the legacy ffmpeg+PulseAudio path is the only
    backend they have.
    """
    if sys.platform != "darwin":
        return False
    return os.environ.get(_DARWIN_OPT_IN_ENV, "").strip() != "0"


# ─── Log parsers ─────────────────────────────────────────────────────────────


_STOP_REASON_RE = re.compile(r"^\s*stop_reason:\s*(\S+)", re.MULTILINE)


def _extract_last_stop_reason(log_path: Path) -> str:
    """Return the final ``stop_reason: <value>`` recorded in *log_path*.

    Both the macOS sidecar (meet-record-mac) and the Linux ffmpeg
    wrapper emit a ``stop_reason: <value>`` line per chunk into the
    shared ``.ffmpeg.log``. A multi-chunk session ends with the *last*
    such line (the reason the final chunk terminated, i.e. the reason
    the session as a whole ended).

    Returns ``"unknown"`` if the log is missing or contains no
    ``stop_reason:`` line (e.g. hard crash before the recorder
    flushed its summary, or a non-darwin-non-ffmpeg backend that
    doesn't emit the line).
    """
    try:
        text = log_path.read_text(errors="replace")
    except OSError:
        return "unknown"

    matches = _STOP_REASON_RE.findall(text)
    if not matches:
        return "unknown"
    return matches[-1]


# ─── WAV header repair ───────────────────────────────────────────────────────


def _repair_wav_header(path: Path) -> bool:
    """Patch RIFF/data chunk sizes to match the actual file size.

    A recorder killed with SIGKILL (or lost to a host crash) never runs
    its close() path, so the WAV header keeps placeholder sizes (0, or
    a stale periodic snapshot) while the file holds real audio bytes.
    ``ffmpeg -f concat -c copy`` trusts the header, so an unrepaired
    chunk would silently truncate the stitched output.

    Walks the RIFF chunk list to find the ``data`` chunk (robust to
    extra chunks like ``LIST``), then rewrites the data size and the
    top-level RIFF size from the on-disk file length.  Sizes are
    clamped to the 32-bit WAV format limit.

    Returns True if the header was modified, False if the file was
    already consistent or isn't a parseable WAV.  Raises OSError on
    I/O failure (caller decides how loud to be).
    """
    size = path.stat().st_size
    if size <= _WAV_HEADER_BYTES:
        return False

    _U32_MAX = 0xFFFFFFFF
    with open(path, "r+b") as f:
        head = f.read(12)
        if len(head) < 12 or head[0:4] != b"RIFF" or head[8:12] != b"WAVE":
            return False
        stored_riff = int.from_bytes(head[4:8], "little")

        # Walk chunks to find 'data'
        offset = 12
        data_offset: int | None = None
        stored_data = 0
        while offset + 8 <= size:
            f.seek(offset)
            chunk_hdr = f.read(8)
            if len(chunk_hdr) < 8:
                break
            if chunk_hdr[0:4] == b"data":
                data_offset = offset
                stored_data = int.from_bytes(chunk_hdr[4:8], "little")
                break
            csize = int.from_bytes(chunk_hdr[4:8], "little")
            offset += 8 + csize + (csize & 1)  # chunks are word-aligned
        if data_offset is None:
            return False

        actual_data = min(size - (data_offset + 8), _U32_MAX)
        actual_riff = min(size - 8, _U32_MAX)

        changed = False
        if stored_data != actual_data:
            f.seek(data_offset + 4)
            f.write(actual_data.to_bytes(4, "little"))
            changed = True
        if stored_riff != actual_riff:
            f.seek(4)
            f.write(actual_riff.to_bytes(4, "little"))
            changed = True
    return changed


# ─── Process liveness, recording lock, recorder marker (0.6.0) ───────────────

# Lock filename in the recording output root.  JSON content: pid,
# pid_start_ticks, started_at, session_dir, output_file.
_LOCK_FILENAME = "recording.lock"

# Per-session marker written while a recorder process is alive.  Sits next
# to ``<stem>.session.json`` / ``<stem>.ffmpeg.log``.
_RECORDER_MARKER_SUFFIX = ".recorder.json"

# Kill switch: MEET_RECORD_LOCK=0 disables the recording lock (matches the
# MEET_RECORD_MAC=0 diagnostic-kill-switch convention).
_LOCK_ENV = "MEET_RECORD_LOCK"


class RecordingInProgressError(RuntimeError):
    """Raised by ``start()`` when another live recording holds the lock.

    ``holder`` is the parsed lock content (pid / started_at / session_dir
    of the incumbent); ``lock_path`` points at the lock file for manual
    inspection or removal.
    """

    def __init__(self, holder: dict, lock_path: Path):
        self.holder = holder
        self.lock_path = lock_path
        super().__init__(
            "Another recording is already active "
            f"(pid {holder.get('pid', '?')}, started {holder.get('started_at', '?')}, "
            f"session {holder.get('session_dir', '?')}). Stop that recording first. "
            f"If the process is gone, delete the stale lock: {lock_path}"
        )


def _proc_start_ticks(pid: int) -> int | None:
    """Process start time in clock ticks since boot, from /proc (Linux only).

    Paired with the pid this survives pid reuse: a recycled pid with a
    different start time is a different process.  Returns None on
    non-Linux or on any read/parse failure — callers treat None as
    "cannot verify" and fall back to bare pid liveness.
    """
    if sys.platform != "linux":
        return None
    try:
        text = Path(f"/proc/{pid}/stat").read_text()
        # comm (field 2) is parenthesised and may itself contain spaces or
        # parens — fields resume after the LAST ')'.
        rest = text[text.rindex(")") + 2:]
        return int(rest.split()[19])  # field 22 overall = starttime
    except (OSError, ValueError, IndexError):
        return None


def _process_alive(pid: int | None, start_ticks: int | None = None) -> bool:
    """Best-effort liveness check for a recorded pid.

    start_ticks (from ``_proc_start_ticks`` at record time) guards against
    pid reuse: a live pid whose current start time differs is a different
    process.  When start_ticks is unknown or /proc is unavailable (macOS),
    falls back to bare liveness.
    """
    if not pid or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # exists, owned by another user
    except OSError:
        return False
    if start_ticks is not None:
        current = _proc_start_ticks(pid)
        if current is not None and current != start_ticks:
            return False  # pid was reused by a different process
    return True


# ─── Data classes ────────────────────────────────────────────────────────────


@dataclass
class AudioDevice:
    """Represents a PulseAudio/PipeWire audio device."""

    index: int
    name: str
    driver: str
    sample_spec: str
    state: str

    @property
    def is_monitor(self) -> bool:
        return self.name.endswith(".monitor")


@dataclass
class RecordingStatus:
    """Snapshot of current recording state."""

    is_alive: bool
    elapsed_seconds: float
    file_size_bytes: int
    restart_count: int
    failed: bool
    fail_reason: str | None = None
    paused: bool = False
    system_silent: bool = False
    system_ever_active: bool = False


@dataclass
class RecordingSession:
    """Manages a single recording session with auto-restart on failure.

    Recording is chunk-based: each ffmpeg invocation writes to a separate
    chunk file. On stop(), chunks are concatenated into the final output.
    """

    output_dir: Path
    output_file: Path
    mic_source: str
    monitor_source: str
    use_virtual_sink: bool = False

    # ── Internal state (not part of repr) ──
    _ffmpeg_proc: subprocess.Popen | None = field(default=None, repr=False)
    _ffmpeg_log: IO | None = field(default=None, repr=False)
    _virtual_sink_module: int | None = field(default=None, repr=False)
    _loopback_module: int | None = field(default=None, repr=False)
    _metadata: dict = field(default_factory=dict, repr=False)

    # Chunk tracking
    _chunks: list[Path] = field(default_factory=list, repr=False)
    _current_chunk: Path | None = field(default=None, repr=False)

    # Pause state
    _paused: bool = field(default=False, repr=False)

    # Watchdog state
    _watchdog_thread: threading.Thread | None = field(default=None, repr=False)
    _stop_event: threading.Event = field(default_factory=threading.Event, repr=False)
    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)
    _start_time: float = field(default=0.0, repr=False)
    _restart_count: int = field(default=0, repr=False)
    _failed: bool = field(default=False, repr=False)
    _fail_reason: str | None = field(default=None, repr=False)
    _last_file_size: int = field(default=0, repr=False)
    _last_growth_time: float = field(default=0.0, repr=False)
    _actual_monitor: str = field(default="", repr=False)

    # System-channel silence tracking (see _check_system_channel)
    _system_silent: bool = field(default=False, repr=False)
    _system_ever_active: bool = field(default=False, repr=False)
    _system_silent_detected: bool = field(default=False, repr=False)
    _mic_active_since_sys: float = field(default=0.0, repr=False)
    _last_channel_check: float = field(default=0.0, repr=False)

    # Recording-lock state (0.6.0).  ``_lock_dir`` is the output root the
    # lock guards; set by ``create_session`` (the recordings root, not the
    # per-session subdir).  Direct ``RecordingSession(...)`` construction
    # leaves it None → no locking.  ``_lock_path`` is non-None only while
    # THIS session holds the lock (so _release_lock never deletes another
    # session's lock).
    _lock_dir: Path | None = field(default=None, repr=False)
    _lock_path: Path | None = field(default=None, repr=False)

    def start(self) -> None:
        """Start recording with watchdog monitoring.

        Raises RecordingInProgressError when another live recording holds
        the output-root lock (see ``create_session`` / MEET_RECORD_LOCK).
        """
        self._acquire_lock()

        self._actual_monitor = self.monitor_source

        if self.use_virtual_sink:
            if _darwin_backend_enabled():
                # Virtual sinks are a PulseAudio (`pactl module-null-sink`)
                # construct; the macOS sidecar uses Process Tap which has
                # no equivalent. Refuse early rather than fail mid-start.
                raise RuntimeError(
                    "use_virtual_sink=True is not supported on the macOS "
                    "sidecar backend. Per-app capture on darwin is achieved "
                    "via `--system app:<bundle-id>` (passed as the "
                    "`monitor=` arg to create_session)."
                )
            self._actual_monitor = self._setup_virtual_sink()

        self._metadata = {
            "started_at": datetime.now().isoformat(),
            "mic_source": self.mic_source,
            "monitor_source": self._actual_monitor,
            "virtual_sink": self.use_virtual_sink,
            "output_file": str(self.output_file),
            # 0.6.0: written to disk at start (status "recording") and
            # rewritten at stop (status "stopped"), so a dir whose parent
            # process died mid-recording is self-describing.
            "status": "recording",
            "owner_pid": os.getpid(),
        }

        self._stop_event.clear()
        self._failed = False
        self._fail_reason = None
        self._restart_count = 0
        self._paused = False
        self._chunks = []

        # Start first chunk — this polls until ffmpeg is actually
        # writing audio data before we continue.  On failure, tear down
        # everything we set up: a raised RuntimeError here previously
        # left the log handle open, the PulseAudio null-sink/loopback
        # modules loaded (breaking the user's audio routing until a
        # manual `pactl unload-module`), and an empty chunk on disk.
        try:
            self._start_ffmpeg_chunk()
        except BaseException:
            self._cleanup_failed_start()
            raise

        # Record when we started (for metadata); elapsed time is derived
        # from file size, not from this timestamp.
        self._start_time = time.monotonic()
        self._last_growth_time = self._start_time

        # Launch watchdog thread
        self._watchdog_thread = threading.Thread(
            target=self._watchdog_loop,
            name="meet-watchdog",
            daemon=True,
        )
        self._watchdog_thread.start()

        # 0.6.0: write the session metadata NOW (status "recording") so
        # an interrupted session dir is self-describing even if stop()
        # never runs.  Rewritten with final stats at stop().
        self._write_session_meta()

    def _write_session_meta(self) -> None:
        """Best-effort write of ``<stem>.session.json`` (never raises)."""
        meta_file = self.output_file.with_suffix(".session.json")
        try:
            meta_file.write_text(json.dumps(self._metadata, indent=2))
        except OSError:
            pass

    # ── Recording lock + recorder marker (0.6.0) ─────────────────────────

    def _acquire_lock(self) -> None:
        """Take the output-root recording lock, reclaiming stale holders.

        No-op when the session has no lock dir (direct construction) or
        MEET_RECORD_LOCK=0.  Raises RecordingInProgressError when a live
        process holds the lock.
        """
        if self._lock_dir is None or os.environ.get(_LOCK_ENV) == "0":
            return
        lock_path = self._lock_dir / _LOCK_FILENAME
        holder = {
            "pid": os.getpid(),
            "pid_start_ticks": _proc_start_ticks(os.getpid()),
            "started_at": datetime.now().isoformat(),
            "session_dir": str(self.output_dir),
            "output_file": str(self.output_file),
        }
        for attempt in (0, 1):
            try:
                fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            except FileExistsError:
                if attempt == 0 and self._reclaim_stale_lock(lock_path):
                    continue
                raise RecordingInProgressError(
                    _read_json_quietly(lock_path), lock_path
                ) from None
            else:
                with os.fdopen(fd, "w") as f:
                    json.dump(holder, f, indent=2)
                self._lock_path = lock_path
                return

    def _reclaim_stale_lock(self, lock_path: Path) -> bool:
        """Delete *lock_path* iff its recorded holder is dead. Never raises."""
        holder = _read_json_quietly(lock_path)
        if _process_alive(holder.get("pid"), holder.get("pid_start_ticks")):
            return False  # genuinely held by a live process
        try:
            lock_path.unlink()
        except OSError:
            return False
        return True

    def _release_lock(self) -> None:
        """Drop the lock if THIS session holds it. Never raises."""
        path = self._lock_path
        self._lock_path = None
        if path is None:
            return
        try:
            path.unlink()
        except OSError:
            pass

    def _recorder_marker_path(self) -> Path:
        return self.output_file.with_suffix(_RECORDER_MARKER_SUFFIX)

    def _write_recorder_marker(self, proc: subprocess.Popen, chunk_path: Path) -> None:
        """Record the live recorder's identity for post-crash forensics.

        Advisory: a write failure — or a process handle that doesn't
        quack like Popen (test doubles) — must never fail the recording.
        """
        pid = getattr(proc, "pid", None)
        if not pid:
            return
        marker = {
            "pid": pid,
            "pid_start_ticks": _proc_start_ticks(pid),
            "owner_pid": os.getpid(),
            "owner_start_ticks": _proc_start_ticks(os.getpid()),
            "backend": "meet-record-mac" if _darwin_backend_enabled() else "ffmpeg",
            "chunk": chunk_path.name,
            "started_at": datetime.now().isoformat(),
        }
        try:
            self._recorder_marker_path().write_text(json.dumps(marker, indent=2))
        except OSError:
            pass

    def _remove_recorder_marker(self) -> None:
        try:
            self._recorder_marker_path().unlink(missing_ok=True)
        except OSError:
            pass

    def _cleanup_failed_start(self) -> None:
        """Best-effort teardown after a failed ``start()``.

        Kills any half-started recorder, closes the log handle, unloads
        PulseAudio virtual-sink modules, and removes header-only chunk
        files.  Never raises — the original startup exception is the
        one the caller should see.
        """
        try:
            self._stop_ffmpeg()
        except Exception:
            pass

        if self._ffmpeg_log:
            try:
                self._ffmpeg_log.close()
            except OSError:
                pass
            self._ffmpeg_log = None

        if self.use_virtual_sink:
            try:
                self._teardown_virtual_sink()
            except Exception:
                pass

        # Remove chunks that never got real audio (header-only or less);
        # anything larger is kept — never destroy captured audio.
        for chunk in self._chunks:
            try:
                if chunk.exists() and chunk.stat().st_size <= _WAV_HEADER_BYTES:
                    chunk.unlink()
            except OSError:
                pass

        # 0.6.0: mark the session as failed and drop the lock/marker so a
        # later process doesn't see a phantom active recording.
        self._metadata["status"] = "failed"
        self._write_session_meta()
        self._remove_recorder_marker()
        self._release_lock()

    def stop(self) -> Path:
        """Stop recording, stitch chunks, and return the output file path.

        Works from both recording and paused states.

        Returns:
            Path to the final output WAV file.
        """
        # Signal watchdog to stop, then JOIN IT FIRST.  Order matters:
        # if we killed the recorder before the watchdog exited, a
        # watchdog thread already inside `_attempt_restart` could spawn
        # a fresh recorder *after* our kill — and because recorders run
        # `start_new_session=True`-detached, that orphan would record
        # forever with nobody left to stop it (race observed in the
        # 0.5.0 review).  Joining first guarantees no restart can be
        # in flight when we stop the process below.  The join budget
        # covers a worst-case in-flight restart (startup poll timeout
        # plus stop-ladder escalation).
        self._stop_event.set()
        if self._watchdog_thread and self._watchdog_thread.is_alive():
            self._watchdog_thread.join(timeout=_STARTUP_TIMEOUT + 20)

        with self._lock:
            # Stop current recorder process (no-op if already paused/stopped)
            if not self._paused:
                self._stop_ffmpeg()
            self._paused = False

            # Close recorder log — only after the watchdog is gone, so a
            # racing restart can never write to (or reopen) a closed handle.
            if self._ffmpeg_log:
                try:
                    self._ffmpeg_log.close()
                except OSError:
                    pass
                self._ffmpeg_log = None

        # The recorder process is gone (or the session was paused): the
        # recorder marker must not outlive it.
        self._remove_recorder_marker()

        if self.use_virtual_sink:
            self._teardown_virtual_sink()

        # Stitch chunks into final output
        valid_chunks = [c for c in self._chunks if c.exists() and c.stat().st_size > 0]

        # Repair WAV headers before stitching/renaming.  A recorder that
        # died via SIGKILL (or a hard host crash) never patched its
        # RIFF/data sizes; ffmpeg's `-f concat -c copy` trusts the header
        # and would silently truncate such a chunk to zero samples.
        for chunk in valid_chunks:
            try:
                _repair_wav_header(chunk)
            except OSError:
                pass

        if len(valid_chunks) == 0:
            # No audio captured at all
            pass
        elif len(valid_chunks) == 1:
            # Single chunk — just rename
            valid_chunks[0].rename(self.output_file)
        else:
            # Multiple chunks — concatenate with ffmpeg
            self._concat_chunks(valid_chunks)

        # Clean up any remaining chunk files
        for chunk in self._chunks:
            if chunk.exists() and chunk != self.output_file:
                try:
                    chunk.unlink()
                except OSError:
                    pass

        # Write session metadata
        self._metadata["status"] = "stopped"
        self._metadata["stopped_at"] = datetime.now().isoformat()
        self._metadata["restart_count"] = self._restart_count
        self._metadata["chunk_count"] = len(valid_chunks)
        self._metadata["failed"] = self._failed
        if self._fail_reason:
            self._metadata["fail_reason"] = self._fail_reason
        self._metadata["file_exists"] = self.output_file.exists()
        if self.output_file.exists():
            self._metadata["file_size_bytes"] = self.output_file.stat().st_size

        # Per-channel outcome: was the system (remote) channel ever active,
        # and did it go silent mid-recording?  Lets downstream tooling flag a
        # recording where remote participants were likely not captured without
        # re-analyzing the audio.
        self._metadata["system_ever_active"] = self._system_ever_active
        self._metadata["system_silent_detected"] = self._system_silent_detected

        # F7 fix (M8, reported by @patternn 2026-05-17): propagate
        # ``stop_reason`` from the recorder log into session.json.
        # The recorder (Mac sidecar via meet-record-mac, Linux via ffmpeg)
        # prints a ``stop_reason: <value>`` line per chunk into the shared
        # ``.ffmpeg.log`` file. Previously we never lifted it back into
        # the metadata, so downstream code couldn't tell whether the
        # recording ended via stdin-q (the clean path) or SIGINT /
        # SIGTERM / max-seconds / stdin-eof. Take the *last* such line
        # in the log (i.e. the final chunk's stop reason — the one
        # that ended the session as a whole). Falls back to "unknown"
        # if the log is missing or holds no stop_reason line (e.g.
        # hard crash before the recorder flushed its summary).
        log_path = self.output_file.with_suffix(".ffmpeg.log")
        self._metadata["stop_reason"] = _extract_last_stop_reason(log_path)

        self._write_session_meta()

        # Recording fully over — release the output-root lock last so the
        # lock's "session active" semantics cover the whole lifecycle.
        self._release_lock()

        return self.output_file

    def pause(self) -> None:
        """Pause recording by stopping the current ffmpeg chunk.

        The current chunk is finalized so no audio is lost.  Call
        :meth:`resume` to start a new chunk and continue recording.

        Raises:
            RuntimeError: If not currently recording or already paused.
        """
        # Stop + flag-set must be atomic w.r.t. the watchdog: if the
        # chunk process exited but `_paused` wasn't yet set, the
        # watchdog would see a dead, unpaused recorder and restart it —
        # and a later stop() (which skips `_stop_ffmpeg` for paused
        # sessions) would leak that restarted process forever.
        with self._lock:
            if self._paused:
                raise RuntimeError("Recording is already paused")
            if self._failed:
                raise RuntimeError("Recording has failed; cannot pause")

            # Stop the current recorder process (finalizes the chunk WAV)
            self._stop_ffmpeg()
            self._paused = True

        # No live recorder while paused — the marker must reflect that so
        # an external scan doesn't report a phantom active recorder.
        self._remove_recorder_marker()

    def resume(self) -> None:
        """Resume recording after a pause by starting a new chunk.

        Raises:
            RuntimeError: If not currently paused.
        """
        with self._lock:
            if not self._paused:
                raise RuntimeError("Recording is not paused")
            self._paused = False
            proc, chunk_path, log_path = self._spawn_recorder_chunk()

        # Blocking startup poll happens outside the lock so status()
        # stays responsive while the new chunk warms up.
        self._wait_for_recorder_data(proc, chunk_path, log_path)
        with self._lock:
            self._last_file_size = 0
            self._last_growth_time = time.monotonic()

    def status(self) -> RecordingStatus:
        """Get current recording status (thread-safe).

        Elapsed time is derived from the actual WAV file size on disk,
        so it always matches the real audio duration exactly.
        """
        with self._lock:
            # Total audio bytes across all chunks (each has its own WAV header)
            total_audio_bytes = 0
            for chunk in self._chunks:
                try:
                    if chunk.exists():
                        sz = chunk.stat().st_size
                        if sz > _WAV_HEADER_BYTES:
                            total_audio_bytes += sz - _WAV_HEADER_BYTES
                except OSError:
                    pass

            total_size = total_audio_bytes + _WAV_HEADER_BYTES * len(self._chunks)
            elapsed = (
                total_audio_bytes / _BYTES_PER_SECOND if _BYTES_PER_SECOND else 0.0
            )

            is_alive = (
                self._ffmpeg_proc is not None
                and self._ffmpeg_proc.poll() is None
                and not self._failed
            )

            return RecordingStatus(
                is_alive=is_alive,
                elapsed_seconds=elapsed,
                file_size_bytes=total_size,
                restart_count=self._restart_count,
                failed=self._failed,
                fail_reason=self._fail_reason,
                paused=self._paused,
                system_silent=self._system_silent,
                system_ever_active=self._system_ever_active,
            )

    # ── ffmpeg process management ────────────────────────────────────────

    def _build_ffmpeg_cmd(self, output_path: Path) -> list[str]:
        """Build the ffmpeg command for dual-channel recording.

        Uses -use_wallclock_as_timestamps 1 on both inputs so that amerge
        syncs them by real wall-clock time instead of waiting for both sources
        to start producing samples. Without this, the PulseAudio monitor
        source typically starts ~3-4 seconds after the mic, and amerge blocks
        until then — silently losing those seconds of mic audio.

        Uses -flush_packets 1 so data is flushed to disk promptly, improving
        both the watchdog file-growth check and SIGINT graceful shutdown.
        """
        return [
            "ffmpeg",
            "-y",
            # Mic input (wall-clock timestamps to avoid amerge blocking)
            "-use_wallclock_as_timestamps",
            "1",
            "-f",
            "pulse",
            "-ac",
            "1",
            "-i",
            self.mic_source,
            # System audio monitor input (wall-clock timestamps)
            "-use_wallclock_as_timestamps",
            "1",
            "-f",
            "pulse",
            "-ac",
            "1",
            "-i",
            self._actual_monitor,
            # Merge into 2-channel stereo (left=mic, right=system)
            "-filter_complex",
            "[0:a]aformat=sample_fmts=s16:sample_rates=16000:channel_layouts=mono[mic];"
            "[1:a]aformat=sample_fmts=s16:sample_rates=16000:channel_layouts=mono[sys];"
            "[mic][sys]amerge=inputs=2[out]",
            "-map",
            "[out]",
            "-ac",
            "2",
            "-ar",
            "16000",
            # Output as WAV — flush packets for reliable watchdog + clean shutdown
            "-flush_packets",
            "1",
            "-c:a",
            "pcm_s16le",
            str(output_path),
        ]

    def _build_recorder_cmd_darwin(self, output_path: Path) -> list[str]:
        """Build the meet-record-mac command for the macOS sidecar (M6a).

        Drop-in for ``_build_ffmpeg_cmd`` from ``_start_ffmpeg_chunk``'s
        perspective: produces a Popen-ready argv that writes a stereo
        s16le 16 kHz WAV to ``output_path`` with L=mic, R=system, and
        accepts the same ``b"q"``-on-stdin / SIGINT / SIGTERM stop ladder
        ``_stop_ffmpeg`` already drives.

        On darwin, ``self.mic_source`` and ``self._actual_monitor`` carry
        sidecar selectors instead of PulseAudio source names:

        * mic_source: "default" | "none" | <kAudioDevicePropertyDeviceUID>
        * monitor:    "system"  | "none" | "app:<bundle-id>"

        ``create_session`` injects the right defaults via
        ``_default_darwin_mic`` / ``_default_darwin_monitor`` when the
        caller doesn't pass explicit overrides.

        ``--max-seconds 0`` keeps the recorder running until Python sends
        the stop signal; matches the Linux/ffmpeg semantics where the
        parent owns chunk boundary timing.
        """
        recorder = _resolve_darwin_recorder()
        return [
            str(recorder),
            "record",
            "--output",
            str(output_path),
            "--mic",
            self.mic_source,
            "--system",
            self._actual_monitor,
            "--sample-rate",
            str(_SAMPLE_RATE),
            "--max-seconds",
            "0",
        ]

    def _start_ffmpeg_chunk(self) -> None:
        """Start the recorder writing to a new chunk file and wait for data.

        Convenience wrapper for the non-contended call sites
        (``start()``); spawns the recorder, then blocks until it
        produces audio data (or the startup budget expires).  The
        watchdog restart path uses the split
        ``_spawn_recorder_chunk`` / ``_wait_for_recorder_data``
        primitives directly so the blocking poll happens outside
        ``_lock``.
        """
        with self._lock:
            proc, chunk_path, log_path = self._spawn_recorder_chunk()
        self._wait_for_recorder_data(proc, chunk_path, log_path)
        with self._lock:
            self._last_file_size = 0
            self._last_growth_time = time.monotonic()

    def _spawn_recorder_chunk(self) -> tuple[subprocess.Popen, Path, Path]:
        """Spawn the recorder for a new chunk file (state mutation only).

        Despite the legacy naming around "ffmpeg", this dispatches
        between the Linux ffmpeg path and the macOS sidecar path based
        on ``_darwin_backend_enabled()``. The ``Popen`` setup, log-file
        handling, and downstream watchdog are identical across backends
        because the sidecar speaks ffmpeg's stop protocol.

        Caller must hold ``_lock`` (mutates ``_chunks``,
        ``_current_chunk``, ``_ffmpeg_log``, ``_ffmpeg_proc``).  Returns
        ``(proc, chunk_path, log_path)`` for a subsequent
        ``_wait_for_recorder_data`` call made *outside* the lock.
        """
        chunk_idx = len(self._chunks)
        stem = self.output_file.stem
        chunk_path = self.output_dir / f"{stem}.chunk-{chunk_idx:03d}.wav"

        self._current_chunk = chunk_path
        self._chunks.append(chunk_path)

        # Open log file for recorder stderr (append mode — shared across
        # restarts). Filename retains `.ffmpeg.log` for backward-compat
        # with anyone scripting log triage; the file's contents are
        # sidecar stderr on darwin.
        log_path = self.output_file.with_suffix(".ffmpeg.log")
        if self._ffmpeg_log is None or self._ffmpeg_log.closed:
            self._ffmpeg_log = open(log_path, "a")

        self._ffmpeg_log.write(
            f"\n--- Chunk {chunk_idx} started at {datetime.now().isoformat()} ---\n"
        )
        self._ffmpeg_log.flush()

        if _darwin_backend_enabled():
            cmd = self._build_recorder_cmd_darwin(chunk_path)
        else:
            cmd = self._build_ffmpeg_cmd(chunk_path)

        # start_new_session=True moves the recorder into its own POSIX
        # session (setsid), detaching it from the parent's process group.
        # Without this, a terminal SIGINT (Ctrl-C) is delivered to BOTH
        # the Python parent and the recorder simultaneously, racing with
        # the parent's intent-to-stop being translated into a `b"q"`
        # write via `_stop_ffmpeg`. The recorder exits first via the
        # signal (clean exit code 0); the parent's watchdog sees an
        # unexpected exit and triggers a spurious restart cycle —
        # observed in @patternn's M6c.ii integration round as
        # `restart_count: 1`, `chunk_count: 2`, with Chunk 0
        # `stop_reason: SIGINT` and Chunk 1 `stop_reason: stdin-q`.
        #
        # With this flag, terminal SIGINT only reaches the Python
        # parent; the parent's Click `KeyboardInterrupt` handler then
        # runs `_stop_ffmpeg` cleanly via the q-byte ladder.
        #
        # Applies to both backends: ffmpeg (Linux) also exits cleanly
        # on SIGINT, so the Linux path had the same latent bug — just
        # less visible because ffmpeg's startup cost is lower than the
        # sidecar's ~0.2 s AVAudioEngine warmup. Fixed for both here.
        self._ffmpeg_proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=self._ffmpeg_log,
            start_new_session=True,
        )
        # 0.6.0: record the detached recorder's identity.  Because the
        # recorder survives the parent's death (start_new_session=True),
        # this marker is the only way a later process can distinguish
        # "recording right now" from "orphaned recorder still writing".
        self._write_recorder_marker(self._ffmpeg_proc, chunk_path)
        return self._ffmpeg_proc, chunk_path, log_path

    def _wait_for_recorder_data(
        self, proc: subprocess.Popen, chunk_path: Path, log_path: Path
    ) -> None:
        """Block until the recorder produces audio data (or budget expires).

        Instead of a fixed sleep, poll the output file until it has
        actual audio data (size > WAV header ~44 bytes).  This way our
        elapsed timer starts from when recording truly begins.

        Must be called *without* holding ``_lock``: the poll can take up
        to ``_STARTUP_TIMEOUT`` seconds and must not freeze ``status()``
        / ``pause()`` callers.  Reads only the ``proc`` handle it was
        given, so a concurrent stop/restart can't confuse it.  Bails out
        early when ``_stop_event`` is set (session is being stopped).

        Raises RuntimeError if the recorder exited during startup.
        """
        deadline = time.monotonic() + _STARTUP_TIMEOUT
        while time.monotonic() < deadline:
            if self._stop_event.is_set():
                return
            # Check if the recorder died during startup
            if proc.poll() is not None:
                raise RuntimeError(
                    f"ffmpeg failed to start (exit code {proc.returncode}). "
                    f"Check log: {log_path}"
                )
            # Check if output file has audio data (WAV header is ~44 bytes)
            try:
                if chunk_path.exists() and chunk_path.stat().st_size > 1024:
                    return
            except OSError:
                pass
            time.sleep(_STARTUP_POLL_INTERVAL)

        # Timed out — check if the recorder is still alive at least
        if proc.poll() is not None:
            raise RuntimeError(
                f"ffmpeg failed to start (exit code {proc.returncode}). "
                f"Check log: {log_path}"
            )
        # Recorder is alive but no data yet — continue anyway,
        # the watchdog will handle stalls

    def _stop_ffmpeg(self) -> None:
        """Gracefully stop the current ffmpeg process.

        Sends 'q' to ffmpeg's stdin for a clean shutdown that flushes all
        buffered audio and writes a proper WAV trailer.  Falls back to
        SIGINT → SIGTERM → SIGKILL if ffmpeg doesn't exit in time.
        """
        proc = self._ffmpeg_proc
        if proc is None:
            return

        if proc.poll() is not None:
            # Already exited
            self._ffmpeg_proc = None
            return

        # Step 1: Send 'q' command via stdin for graceful flush.
        # This tells ffmpeg to finish processing buffered data, write the
        # WAV trailer, and exit — no audio samples lost.
        try:
            if proc.stdin and not proc.stdin.closed:
                proc.stdin.write(b"q")
                proc.stdin.flush()
                proc.stdin.close()
        except (BrokenPipeError, OSError):
            pass

        try:
            proc.wait(timeout=5)
            self._ffmpeg_proc = None
            return
        except subprocess.TimeoutExpired:
            pass

        # Step 2: Fall back to SIGINT
        try:
            proc.send_signal(signal.SIGINT)
            proc.wait(timeout=5)
            self._ffmpeg_proc = None
            return
        except subprocess.TimeoutExpired:
            pass

        # Step 3: SIGTERM
        try:
            proc.terminate()
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()

        self._ffmpeg_proc = None

    def _attempt_restart(self, reason: str) -> bool:
        """Try to restart the recorder into a new chunk. Returns True if OK.

        Called from the watchdog thread *without* ``_lock`` held.  All
        shared-state mutation happens under the lock; only the blocking
        startup poll runs unlocked (so ``status()``/``pause()`` don't
        freeze for up to ``_STARTUP_TIMEOUT`` seconds during a restart).
        Re-checks the session state after acquiring the lock: a
        concurrent ``stop()``/``pause()`` won the race and the restart
        must be abandoned (returning True — the session state is valid,
        just no longer ours to restart).
        """
        with self._lock:
            if self._stop_event.is_set() or self._paused or self._failed:
                return True

            if self._restart_count >= _MAX_RESTART_ATTEMPTS:
                self._failed = True
                self._fail_reason = f"Max restart attempts ({_MAX_RESTART_ATTEMPTS}) exceeded. Last: {reason}"
                return False

            # Stop current (possibly dead) process
            self._stop_ffmpeg()

            self._restart_count += 1

            if self._ffmpeg_log and not self._ffmpeg_log.closed:
                self._ffmpeg_log.write(
                    f"\n--- RESTART #{self._restart_count} at {datetime.now().isoformat()} "
                    f"reason: {reason} ---\n"
                )
                self._ffmpeg_log.flush()

            try:
                proc, chunk_path, log_path = self._spawn_recorder_chunk()
            except Exception as e:
                self._failed = True
                self._fail_reason = f"Restart failed: {e}"
                return False

        try:
            self._wait_for_recorder_data(proc, chunk_path, log_path)
        except RuntimeError as e:
            with self._lock:
                self._failed = True
                self._fail_reason = f"Restart failed: {e}"
            return False

        with self._lock:
            self._last_file_size = 0
            self._last_growth_time = time.monotonic()
        return True

    # ── Watchdog ─────────────────────────────────────────────────────────

    def _watchdog_loop(self) -> None:
        """Background thread that monitors recorder health.

        Health checks run under ``_lock``; the (potentially slow)
        restart itself runs outside it — see ``_attempt_restart``.
        """
        while not self._stop_event.is_set():
            self._stop_event.wait(timeout=_WATCHDOG_INTERVAL)
            if self._stop_event.is_set():
                break

            restart_reason: str | None = None
            channel_check_chunk: Path | None = None
            with self._lock:
                if self._failed:
                    break

                # Skip health checks while paused (no recorder running)
                if self._paused:
                    continue

                proc = self._ffmpeg_proc
                if proc is None:
                    continue

                # Check 1: Is the recorder still running?
                exit_code = proc.poll()
                if exit_code is not None:
                    restart_reason = f"ffmpeg exited with code {exit_code}"
                else:
                    # Check 2: Is the file still growing?
                    chunk = self._current_chunk
                    if chunk and chunk.exists():
                        try:
                            current_size = chunk.stat().st_size
                        except OSError:
                            continue

                        if current_size > self._last_file_size:
                            self._last_file_size = current_size
                            self._last_growth_time = time.monotonic()
                        else:
                            stall_duration = time.monotonic() - self._last_growth_time
                            if stall_duration > _STALL_TIMEOUT:
                                restart_reason = (
                                    f"Output file stalled for {stall_duration:.0f}s"
                                )

                # Check 3: Is the system (remote) channel still carrying audio?
                # Sampling decodes ffmpeg (slow), so do it outside the lock —
                # here we only decide whether it's due and grab the chunk path.
                if restart_reason is None and chunk and chunk.exists():
                    now = time.monotonic()
                    if now - self._last_channel_check >= _CHANNEL_CHECK_INTERVAL:
                        self._last_channel_check = now
                        channel_check_chunk = chunk

            if restart_reason is not None:
                self._attempt_restart(restart_reason)
            elif channel_check_chunk is not None:
                self._check_system_channel(channel_check_chunk)

    def _check_system_channel(self, chunk: Path) -> None:
        """Detect a silent system (remote) channel while the mic is active.

        Samples the tail of the current chunk and flags ``_system_silent``
        when the mic has been active but the system channel has stayed silent
        for ``_SYSTEM_SILENCE_TIMEOUT`` — the signature of the meeting app's
        output being routed away from the recorded monitor (e.g. an app/sink
        switch mid-call).  Never interrupts recording; only sets state the UI
        reads.  Gated on the system channel having been active at least once,
        so genuine in-room meetings (no system audio at all) never warn.
        """
        rms = sample_channel_rms(chunk)
        if rms is None:
            return  # unknown ≠ silent — stay conservative
        mic_rms, sys_rms = rms

        # Is the mic actually carrying speech right now?  If nobody is
        # talking on either channel, silence is expected — don't count it.
        mic_active = mic_rms > _SILENCE_FLOOR
        sys_active = sys_rms > _SILENCE_FLOOR and sys_rms > _SYSTEM_SILENT_RATIO * mic_rms

        now = time.monotonic()
        with self._lock:
            if sys_active:
                self._system_ever_active = True
                self._system_silent = False
                self._mic_active_since_sys = 0.0
                return

            # System channel is silent.  Only meaningful once it has been
            # active before (otherwise treat as an intentional in-room mic).
            if not self._system_ever_active:
                return

            if not mic_active:
                # Nobody talking — reset the silence timer, this is a lull.
                self._mic_active_since_sys = 0.0
                return

            # Mic active, system silent: start/continue the timer.
            if self._mic_active_since_sys == 0.0:
                self._mic_active_since_sys = now
            elif now - self._mic_active_since_sys >= _SYSTEM_SILENCE_TIMEOUT:
                self._system_silent = True
                self._system_silent_detected = True

    # ── Chunk stitching ──────────────────────────────────────────────────

    def _concat_chunks(self, chunks: list[Path]) -> None:
        """Concatenate multiple WAV chunks into the final output file."""
        _concat_wav_files(chunks, self.output_file, self.output_dir)

    # ── Virtual sink management ──────────────────────────────────────────

    def _setup_virtual_sink(self) -> str:
        """Create a virtual null sink for isolated meeting audio capture."""
        sink_name = "meet_capture"

        result = subprocess.run(
            [
                "pactl",
                "load-module",
                "module-null-sink",
                f"sink_name={sink_name}",
                "sink_properties=device.description=Meet-Capture",
                "rate=16000",
                "channels=1",
            ],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise RuntimeError(f"Failed to create virtual sink: {result.stderr}")
        self._virtual_sink_module = int(result.stdout.strip())

        result = subprocess.run(
            [
                "pactl",
                "load-module",
                "module-loopback",
                f"source={sink_name}.monitor",
                "sink=@DEFAULT_SINK@",
                "latency_msec=1",
            ],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            self._loopback_module = int(result.stdout.strip())

        return f"{sink_name}.monitor"

    def _teardown_virtual_sink(self) -> None:
        """Remove virtual sink and loopback modules."""
        if self._loopback_module is not None:
            subprocess.run(
                ["pactl", "unload-module", str(self._loopback_module)],
                capture_output=True,
            )
            self._loopback_module = None

        if self._virtual_sink_module is not None:
            subprocess.run(
                ["pactl", "unload-module", str(self._virtual_sink_module)],
                capture_output=True,
            )
            self._virtual_sink_module = None


# ─── Module-level helpers ────────────────────────────────────────────────────


def list_sources() -> list[AudioDevice]:
    """List all PulseAudio/PipeWire audio sources."""
    result = subprocess.run(
        ["pactl", "list", "short", "sources"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Failed to list sources: {result.stderr}")

    devices = []
    for line in result.stdout.strip().split("\n"):
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) >= 5:
            devices.append(
                AudioDevice(
                    index=int(parts[0]),
                    name=parts[1],
                    driver=parts[2],
                    sample_spec=parts[3],
                    state=parts[4],
                )
            )
    return devices


def get_default_sink() -> str:
    """Get the name of the default audio output sink."""
    result = subprocess.run(
        ["pactl", "get-default-sink"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Failed to get default sink: {result.stderr}")
    return result.stdout.strip()


def get_default_source() -> str:
    """Get the name of the default audio input source (mic)."""
    result = subprocess.run(
        ["pactl", "get-default-source"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Failed to get default source: {result.stderr}")
    return result.stdout.strip()


def get_monitor_source() -> str:
    """Get the monitor source for the default sink (captures system audio)."""
    return f"{get_default_sink()}.monitor"


def create_session(
    output_dir: str | Path | None = None,
    filename: str | None = None,
    mic: str | None = None,
    monitor: str | None = None,
    virtual_sink: bool = False,
) -> RecordingSession:
    """Create a new recording session.

    Args:
        output_dir: Directory to save recordings. Defaults to ~/meet-recordings.
        filename: Output filename. Defaults to timestamped name.
        mic: Mic source name. Defaults to system default.
        monitor: Monitor source name. Defaults to default sink monitor.
        virtual_sink: Whether to create an isolated virtual sink.

    Returns:
        A RecordingSession ready to start.
    """
    if output_dir is None:
        output_dir = Path.home() / "meet-recordings"
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    lock_dir = output_dir

    if filename is None:
        # Auto-generated name: create a per-session subdirectory so all
        # session artefacts (wav, logs, transcripts) live together.
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        session_name = f"meeting-{timestamp}"
        session_dir = output_dir / session_name
        session_dir.mkdir(parents=True, exist_ok=True)
        filename = f"{session_name}.wav"
        output_dir = session_dir
    # When filename is explicitly provided via -f, keep flat layout.

    if _darwin_backend_enabled():
        # macOS sidecar selector defaults. "default" tells the Swift
        # binary to use AVAudioEngine's default input; "system" tells it
        # to use a system-wide Process Tap (every output process). The
        # caller can still override either via explicit `mic=` /
        # `monitor=` (e.g. mic="<device-uid>", monitor="app:us.zoom.xos").
        mic_source = mic or "default"
        monitor_source = monitor or "system"
    else:
        mic_source = mic or get_default_source()
        monitor_source = monitor or get_monitor_source()

    session = RecordingSession(
        output_dir=output_dir,
        output_file=output_dir / filename,
        mic_source=mic_source,
        monitor_source=monitor_source,
        use_virtual_sink=virtual_sink,
    )
    # The lock guards the recording ROOT (one active recording per root),
    # not the per-session subdir, so concurrent sessions collide even
    # though their output dirs differ.
    session._lock_dir = lock_dir
    return session


# ─── Interrupted-session scan + recovery (0.6.0) ─────────────────────────────

_CHUNK_RE = re.compile(r"^(?P<stem>.+)\.chunk-(?P<idx>\d+)\.wav$")


def _read_json_quietly(path: Path) -> dict:
    """Parse a JSON file into a dict; {} on missing/corrupt/wrong type."""
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _concat_wav_files(chunks: list[Path], output_file: Path, work_dir: Path) -> None:
    """Concatenate WAV chunks into *output_file* via ffmpeg stream copy.

    On any ffmpeg failure/timeout, falls back to the largest chunk so the
    bulk of the audio is never lost to a stitching problem.
    """
    # Build ffmpeg concat demuxer input file
    concat_list = tempfile.NamedTemporaryFile(
        mode="w",
        suffix=".txt",
        delete=False,
        dir=work_dir,
    )
    try:
        for chunk in chunks:
            # ffmpeg concat requires single-quoted paths with escaped quotes
            safe_path = str(chunk).replace("'", "'\\''")
            concat_list.write(f"file '{safe_path}'\n")
        concat_list.close()

        cmd = [
            "ffmpeg",
            "-y",
            "-f",
            "concat",
            "-safe",
            "0",
            "-i",
            concat_list.name,
            "-c",
            "copy",
            str(output_file),
        ]
        # Stream-copy concat is I/O bound; budget generously (assume
        # >= 20 MB/s) but never hang forever on a wedged ffmpeg —
        # subprocess.run kills the child on timeout.
        try:
            total_bytes = sum(c.stat().st_size for c in chunks)
        except OSError:
            total_bytes = 0
        timeout = max(120.0, total_bytes / (20 * 1024 * 1024))
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
            concat_failed = result.returncode != 0
        except subprocess.TimeoutExpired:
            concat_failed = True
        if concat_failed:
            # Fallback: just use the largest chunk
            largest = max(chunks, key=lambda c: c.stat().st_size)
            largest.rename(output_file)
    finally:
        try:
            Path(concat_list.name).unlink()
        except OSError:
            pass


@dataclass
class InterruptedSession:
    """A recording directory whose session never reached a clean ``stop()``.

    ``recorder_alive``/``owner_alive`` distinguish the three states a
    caller must handle differently:

    * owner alive + recorder alive → recording in progress; leave it alone
    * owner dead + recorder alive  → orphaned recorder (``orphaned``);
      stop the recorder (SIGINT finalizes the chunk WAV), then recover
    * recorder dead                → interrupted; just recover the chunks
    """

    session_dir: Path
    chunks: list[Path]
    total_bytes: int
    recorder_pid: int | None  # from <stem>.recorder.json (0.6.0+), else None
    recorder_alive: bool
    owner_pid: int | None  # from marker or session meta, if known
    owner_alive: bool
    started_at: str | None  # ISO string from marker/session meta
    backend: str | None  # "ffmpeg" | "meet-record-mac" | None (unknown)

    @property
    def orphaned(self) -> bool:
        """Recorder still running but its controlling process is gone."""
        return self.recorder_alive and not self.owner_alive


def find_interrupted_sessions(root: str | Path) -> list[InterruptedSession]:
    """Scan *root* (a recordings dir) for sessions that never finished.

    A session dir counts as interrupted when it holds ``*.chunk-*.wav``
    files but no stitched final ``<stem>.wav``.  Newest-first by directory
    mtime.  Never raises on filesystem races — a dir that vanishes or
    finishes mid-scan is simply skipped.
    """
    root = Path(root)
    try:
        entries = list(root.iterdir())
    except OSError:
        return []

    found: list[InterruptedSession] = []
    for d in entries:
        if not d.is_dir():
            continue
        chunks = sorted(p for p in d.glob("*.chunk-*.wav") if _CHUNK_RE.match(p.name))
        if not chunks:
            continue
        stem = _CHUNK_RE.match(chunks[0].name).group("stem")  # type: ignore[union-attr]
        if (d / f"{stem}.wav").exists():
            continue  # finished (or already recovered)

        marker = _read_json_quietly(d / f"{stem}{_RECORDER_MARKER_SUFFIX}")
        meta = _read_json_quietly(d / f"{stem}.session.json")
        recorder_pid = marker.get("pid")
        owner_pid = marker.get("owner_pid") or meta.get("owner_pid")
        try:
            total = sum(c.stat().st_size for c in chunks)
        except OSError:
            total = 0
        found.append(
            InterruptedSession(
                session_dir=d,
                chunks=chunks,
                total_bytes=total,
                recorder_pid=recorder_pid,
                recorder_alive=_process_alive(recorder_pid, marker.get("pid_start_ticks")),
                owner_pid=owner_pid,
                owner_alive=_process_alive(owner_pid, marker.get("owner_start_ticks")),
                started_at=marker.get("started_at") or meta.get("started_at"),
                backend=marker.get("backend"),
            )
        )

    def _mtime(s: InterruptedSession) -> float:
        try:
            return s.session_dir.stat().st_mtime
        except OSError:
            return 0.0

    found.sort(key=_mtime, reverse=True)
    return found


def recover_session(session_dir: str | Path) -> Path:
    """Stitch the leftover chunks of an interrupted recording into a WAV.

    Repairs each chunk's WAV header first (a SIGKILLed recorder never
    patched its RIFF/data sizes, and ffmpeg's concat trusts the header),
    concatenates in chunk order, removes the chunk files, and marks the
    session metadata ``status: "recovered"`` (creating a minimal one for
    pre-0.6.0 dirs that never wrote one).

    Returns the path to the recovered ``<stem>.wav``.

    Raises:
        FileNotFoundError: no (non-empty) chunk files in *session_dir*.
        FileExistsError: the final WAV already exists — nothing to recover.
        RuntimeError: a recorder is still writing into the directory;
            stop it first (see ``find_interrupted_sessions``).
    """
    session_dir = Path(session_dir)
    chunks = sorted(p for p in session_dir.glob("*.chunk-*.wav") if _CHUNK_RE.match(p.name))
    if not chunks:
        raise FileNotFoundError(f"no recording chunks found in {session_dir}")
    stem = _CHUNK_RE.match(chunks[0].name).group("stem")  # type: ignore[union-attr]
    output = session_dir / f"{stem}.wav"
    if output.exists():
        raise FileExistsError(f"{output} already exists; nothing to recover")

    marker_path = session_dir / f"{stem}{_RECORDER_MARKER_SUFFIX}"
    marker = _read_json_quietly(marker_path)
    if _process_alive(marker.get("pid"), marker.get("pid_start_ticks")):
        raise RuntimeError(
            f"a recorder (pid {marker['pid']}) is still writing into {session_dir}; "
            "stop it before recovering"
        )

    valid = [c for c in chunks if c.stat().st_size > 0]
    for chunk in valid:
        try:
            _repair_wav_header(chunk)
        except OSError:
            pass
    if not valid:
        raise FileNotFoundError(f"all recording chunks in {session_dir} are empty")

    if len(valid) == 1:
        valid[0].rename(output)
    else:
        _concat_wav_files(valid, output, session_dir)

    # Clean up any remaining chunk files
    for chunk in chunks:
        if chunk.exists() and chunk != output:
            try:
                chunk.unlink()
            except OSError:
                pass

    meta_path = session_dir / f"{stem}.session.json"
    meta = _read_json_quietly(meta_path)
    meta.update(
        {
            "status": "recovered",
            "recovered_at": datetime.now().isoformat(),
            "chunk_count": len(valid),
            "file_exists": True,
            "file_size_bytes": output.stat().st_size,
            "output_file": str(output),
        }
    )
    try:
        meta_path.write_text(json.dumps(meta, indent=2))
    except OSError:
        pass

    # The marker describes a recorder that no longer exists.
    try:
        marker_path.unlink(missing_ok=True)
    except OSError:
        pass

    return output


def check_prerequisites() -> list[str]:
    """Check that required system tools are available. Returns list of issues.

    On darwin with the sidecar backend opted in, the checks shift from
    pactl/PulseAudio to (a) the meet-record-mac binary being resolvable,
    and (b) ``meet-record-mac probe-permissions`` reporting both mic and
    system-audio TCC granted. ffmpeg is still required for chunk
    stitching at session stop.
    """
    issues = []

    try:
        subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)
    except (FileNotFoundError, subprocess.CalledProcessError):
        if sys.platform == "darwin":
            issues.append(
                "ffmpeg is not installed. Install with: brew install ffmpeg"
            )
        else:
            issues.append(
                "ffmpeg is not installed. Install with: sudo apt install ffmpeg"
            )

    if _darwin_backend_enabled():
        # Sidecar resolution
        try:
            recorder = _resolve_darwin_recorder()
        except FileNotFoundError as e:
            issues.append(str(e))
            return issues

        # Permission request — sidecar exit 0 means both mic + system-
        # audio are granted. On first run, `request-permissions` triggers
        # the macOS TCC dialog so the user can grant access interactively
        # (unlike `probe-permissions` which only reads the status).
        # Non-zero exit yields human-readable status lines verbatim.
        try:
            result = subprocess.run(
                [str(recorder), "request-permissions"],
                capture_output=True,
                text=True,
                timeout=30,
            )
            if result.returncode != 0:
                issues.append(
                    "macOS audio permissions not granted:\n"
                    + result.stdout.strip()
                    + "\n  Grant via System Settings → Privacy & Security →"
                    " Microphone, and → System Audio Recording."
                    "\n  On macOS Sequoia+, if your terminal app is not"
                    " listed, run:\n"
                    "    tccutil reset Microphone\n"
                    "    tccutil reset SystemAudioRecording\n"
                    "  then retry."
                )
        except subprocess.TimeoutExpired:
            issues.append(
                f"meet-record-mac request-permissions timed out (>30 s); "
                f"binary at {recorder} may be hung or waiting for a "
                f"permission dialog behind other windows."
            )
        except OSError as e:
            issues.append(f"Cannot run meet-record-mac: {e}")

        return issues

    try:
        subprocess.run(["pactl", "--version"], capture_output=True, check=True)
    except (FileNotFoundError, subprocess.CalledProcessError):
        issues.append("pactl is not available. Install PulseAudio or PipeWire.")

    try:
        result = subprocess.run(
            ["pactl", "list", "short", "sources"],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            issues.append("PulseAudio/PipeWire server is not running.")
        elif not result.stdout.strip():
            issues.append("No audio sources detected.")
    except Exception as e:
        issues.append(f"Cannot communicate with audio server: {e}")

    return issues
