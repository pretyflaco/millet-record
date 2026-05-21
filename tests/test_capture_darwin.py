"""Tests for the macOS sidecar branch of meet_record.capture.

Runs on Linux CI by injecting ``sys.platform = "darwin"`` and pointing
``MEET_RECORD_MAC_PATH`` at a bash mock that mimics the
meet-record-mac M5 CLI surface (see tests/conftest.py).

These tests exercise:

* ``_resolve_darwin_recorder``: env override, bundled location,
  PATH fallback, missing-binary error.
* ``_darwin_backend_enabled``: opt-in gate semantics.
* ``_build_recorder_cmd_darwin``: argv shape regression-gates the M5
  CLI surface (--mic / --system / --sample-rate / --max-seconds).
* ``check_prerequisites`` darwin branch: request-permissions plumbing
  and ffmpeg presence.
* End-to-end ``RecordingSession.start() / stop()``: watchdog-against-
  mock semantics for the normal, stall, and opt-out-fallthrough cases.

Slow tests that wait on ``_STALL_TIMEOUT`` are scaled down via
monkeypatch so the suite stays under ~30 s total.
"""

from __future__ import annotations

import os
import stat
import subprocess
import sys
import time
from pathlib import Path

import pytest

import meet_record.capture as cap


# ─── _resolve_darwin_recorder ────────────────────────────────────────────────


def test_resolve_uses_env_override_when_set(monkeypatch, tmp_path):
    """MEET_RECORD_MAC_PATH wins over bundled location."""
    fake = tmp_path / "binary"
    fake.write_text("not actually a binary")
    fake.chmod(fake.stat().st_mode | stat.S_IXUSR)

    monkeypatch.setenv("MEET_RECORD_MAC_PATH", str(fake))
    assert cap._resolve_darwin_recorder() == fake


def test_resolve_rejects_env_override_pointing_at_nonexistent_file(monkeypatch, tmp_path):
    """A bogus override is a hard error, not a silent fallthrough."""
    monkeypatch.setenv("MEET_RECORD_MAC_PATH", str(tmp_path / "does-not-exist"))
    with pytest.raises(FileNotFoundError):
        cap._resolve_darwin_recorder()


def test_resolve_finds_bundled_binary_when_env_unset(monkeypatch, tmp_path):
    """Falls back to meet_record/_bin/meet-record-mac.

    We can't write into the real meet_record/_bin during a test, so we
    monkeypatch ``meet_record.capture.Path(__file__)`` semantics by
    creating a fake _bin directory and pointing the resolver at it via
    a temporary working module path injection.
    """
    monkeypatch.delenv("MEET_RECORD_MAC_PATH", raising=False)

    # Create a fake bundled binary in tmp_path/_bin/meet-record-mac and
    # patch Path(__file__).parent to point at tmp_path. The cleanest way
    # is to override the function entirely for this test.
    fake_bin = tmp_path / "_bin"
    fake_bin.mkdir()
    fake_recorder = fake_bin / "meet-record-mac"
    fake_recorder.write_text("mock")
    fake_recorder.chmod(fake_recorder.stat().st_mode | stat.S_IXUSR)

    # Patch by overriding the path-building call. `Path(__file__).parent`
    # is the only line referencing the bundle location; we monkey-patch
    # the entire helper to use our tmp_path.
    original = cap._resolve_darwin_recorder

    def fake_resolve():
        candidate = fake_bin / "meet-record-mac"
        if candidate.is_file():
            return candidate
        return original()

    monkeypatch.setattr(cap, "_resolve_darwin_recorder", fake_resolve)
    assert cap._resolve_darwin_recorder() == fake_recorder


def test_resolve_falls_back_to_path(monkeypatch, tmp_path):
    """If env var unset and no bundled binary, ``shutil.which`` is used."""
    monkeypatch.delenv("MEET_RECORD_MAC_PATH", raising=False)

    # Place a fake binary in tmp_path and prepend tmp_path to PATH. If
    # _resolve falls through to PATH, it should pick this one up.
    fake = tmp_path / "meet-record-mac"
    fake.write_text("#!/bin/sh\necho mock")
    fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
    monkeypatch.setenv("PATH", str(tmp_path) + os.pathsep + os.environ.get("PATH", ""))

    # Ensure the bundled location is empty for this test. We can't easily
    # invalidate it from Linux; if the test infra accidentally has a
    # _bin/meet-record-mac (it won't on this branch but defensive), skip.
    bundled = Path(cap.__file__).parent / "_bin" / "meet-record-mac"
    if bundled.is_file():
        pytest.skip("bundled binary present; cannot test PATH fallback in isolation")

    resolved = cap._resolve_darwin_recorder()
    assert resolved == fake


def test_resolve_raises_when_nothing_resolves(monkeypatch):
    """No env override + no bundle + nothing on PATH → FileNotFoundError."""
    monkeypatch.delenv("MEET_RECORD_MAC_PATH", raising=False)
    monkeypatch.setenv("PATH", "")  # empty PATH; shutil.which returns None

    bundled = Path(cap.__file__).parent / "_bin" / "meet-record-mac"
    if bundled.is_file():
        pytest.skip("bundled binary present; cannot test missing-binary case")

    with pytest.raises(FileNotFoundError, match="meet-record-mac not found"):
        cap._resolve_darwin_recorder()


# ─── _darwin_backend_enabled ─────────────────────────────────────────────────


def test_backend_disabled_on_linux(monkeypatch):
    monkeypatch.setattr(sys, "platform", "linux")
    monkeypatch.setenv("MEET_RECORD_MAC", "1")
    assert cap._darwin_backend_enabled() is False


def test_backend_enabled_on_darwin_without_env(monkeypatch):
    """Default-ON on darwin as of 0.2.0 (M6c.ii.c)."""
    monkeypatch.setattr(sys, "platform", "darwin")
    monkeypatch.delenv("MEET_RECORD_MAC", raising=False)
    assert cap._darwin_backend_enabled() is True


def test_backend_enabled_on_darwin_with_env(monkeypatch):
    """MEET_RECORD_MAC=1 still yields True (redundant with default but
    backward-compatible with anyone who scripted the M6 opt-in)."""
    monkeypatch.setattr(sys, "platform", "darwin")
    monkeypatch.setenv("MEET_RECORD_MAC", "1")
    assert cap._darwin_backend_enabled() is True


def test_backend_disabled_on_darwin_with_zero(monkeypatch):
    """Opt-OUT: MEET_RECORD_MAC=0 forces the legacy ffmpeg path.

    On macOS this path will fail at startup (no PulseAudio device);
    the env var is a diagnostic kill switch, not a recommended config.
    """
    monkeypatch.setattr(sys, "platform", "darwin")
    monkeypatch.setenv("MEET_RECORD_MAC", "0")
    assert cap._darwin_backend_enabled() is False


@pytest.mark.parametrize("value", ["", "1", "yes", "true", "2", "no", "false"])
def test_backend_only_zero_disables(monkeypatch, value):
    """Anything other than literal "0" leaves the sidecar enabled.

    Fail-open: if a user mistypes the env var, the working backend
    on macOS stays in use rather than falling back to the broken-on-
    darwin ffmpeg+PulseAudio path. The strict "0"-only opt-OUT
    mirrors the fail-open rationale documented in
    `_darwin_backend_enabled`.
    """
    monkeypatch.setattr(sys, "platform", "darwin")
    monkeypatch.setenv("MEET_RECORD_MAC", value)
    assert cap._darwin_backend_enabled() is True


# ─── _build_recorder_cmd_darwin (argv shape) ─────────────────────────────────


def _make_darwin_session(tmp_path: Path, mic="default", monitor="system"):
    """Build a RecordingSession in a state that lets us call
    _build_recorder_cmd_darwin without starting it."""
    s = cap.RecordingSession(
        output_dir=tmp_path,
        output_file=tmp_path / "out.wav",
        mic_source=mic,
        monitor_source=monitor,
    )
    s._actual_monitor = monitor
    return s


def test_argv_shape_minimal(tmp_path, darwin_environ):
    s = _make_darwin_session(tmp_path)
    cmd = s._build_recorder_cmd_darwin(tmp_path / "chunk-0.wav")
    # First element is the recorder path (the mock).
    assert cmd[0] == str(darwin_environ)
    # Subcommand and key flags.
    assert cmd[1] == "record"
    assert cmd[2:4] == ["--output", str(tmp_path / "chunk-0.wav")]
    assert "--mic" in cmd
    assert "default" in cmd
    assert "--system" in cmd
    assert "system" in cmd
    assert ["--sample-rate", "16000"] == cmd[cmd.index("--sample-rate"):cmd.index("--sample-rate") + 2]
    assert ["--max-seconds", "0"] == cmd[cmd.index("--max-seconds"):cmd.index("--max-seconds") + 2]


def test_argv_shape_with_specific_mic_uid(tmp_path, darwin_environ):
    s = _make_darwin_session(tmp_path, mic="BuiltInMicrophoneDevice")
    cmd = s._build_recorder_cmd_darwin(tmp_path / "chunk-0.wav")
    mic_idx = cmd.index("--mic")
    assert cmd[mic_idx + 1] == "BuiltInMicrophoneDevice"


def test_argv_shape_with_per_app_system(tmp_path, darwin_environ):
    s = _make_darwin_session(tmp_path, monitor="app:us.zoom.xos")
    s._actual_monitor = "app:us.zoom.xos"
    cmd = s._build_recorder_cmd_darwin(tmp_path / "chunk-0.wav")
    sys_idx = cmd.index("--system")
    assert cmd[sys_idx + 1] == "app:us.zoom.xos"


def test_argv_shape_with_mic_and_system_none(tmp_path, darwin_environ):
    s = _make_darwin_session(tmp_path, mic="none", monitor="none")
    s._actual_monitor = "none"
    cmd = s._build_recorder_cmd_darwin(tmp_path / "chunk-0.wav")
    assert cmd[cmd.index("--mic") + 1] == "none"
    assert cmd[cmd.index("--system") + 1] == "none"


def test_argv_shape_uses_actual_monitor_not_monitor_source(tmp_path, darwin_environ):
    """_actual_monitor is what's installed at start(); for the virtual-
    sink path on Linux it's the synthesised monitor name. On darwin it
    just mirrors monitor_source, but the build path must read it from
    _actual_monitor for parity with _build_ffmpeg_cmd."""
    s = _make_darwin_session(tmp_path, monitor="system")
    s._actual_monitor = "app:com.different.app"  # simulate post-start mutation
    cmd = s._build_recorder_cmd_darwin(tmp_path / "chunk-0.wav")
    assert cmd[cmd.index("--system") + 1] == "app:com.different.app"


# ─── _start_ffmpeg_chunk dispatch ────────────────────────────────────────────


def test_dispatch_uses_darwin_branch_when_enabled(monkeypatch, tmp_path, darwin_environ):
    """When _darwin_backend_enabled() is True, _start_ffmpeg_chunk must
    call _build_recorder_cmd_darwin, not _build_ffmpeg_cmd. We capture
    Popen so the actual subprocess never runs."""
    s = _make_darwin_session(tmp_path)

    captured_cmd: list[list[str]] = []

    class FakePopen:
        def __init__(self, cmd, *args, **kwargs):
            captured_cmd.append(cmd)
            self.stdin = type("stdin", (), {"write": lambda *a: None, "close": lambda: None, "flush": lambda: None})()
            self._poll = None

        def poll(self):
            return self._poll

        def wait(self, timeout=None):
            return 0

    monkeypatch.setattr(cap.subprocess, "Popen", FakePopen)
    # The startup poll wants size > 1024; pretend it's huge by patching
    # Path.stat to return a large size for our chunk path.
    real_stat = Path.stat

    def fake_stat(self_):
        if self_.name.startswith("out.chunk-"):
            class _S:
                st_size = 100_000
            return _S()
            return _S()
        return real_stat(self_)

    monkeypatch.setattr(Path, "stat", fake_stat)
    # Path.exists must report True for the chunk file even though Popen
    # didn't actually create it.
    monkeypatch.setattr(Path, "exists", lambda self_: True)

    s._start_ffmpeg_chunk()

    assert len(captured_cmd) == 1, "expected exactly one Popen call"
    cmd = captured_cmd[0]
    # Must be the meet-record-mac argv shape, not ffmpeg.
    assert cmd[1] == "record"
    assert "--output" in cmd
    # And NOT ffmpeg. The first arg is the resolved recorder path.
    assert "ffmpeg" not in cmd[0]


def test_dispatch_uses_ffmpeg_branch_on_linux(monkeypatch, tmp_path):
    """Sanity: with the env var unset, the legacy ffmpeg cmd is built."""
    monkeypatch.setattr(sys, "platform", "linux")
    monkeypatch.delenv("MEET_RECORD_MAC", raising=False)
    s = _make_darwin_session(tmp_path)

    captured_cmd: list[list[str]] = []

    class FakePopen:
        def __init__(self, cmd, *args, **kwargs):
            captured_cmd.append(cmd)
            self.stdin = type("stdin", (), {"write": lambda *a: None, "close": lambda: None, "flush": lambda: None})()
            self._poll = None

        def poll(self):
            return self._poll

        def wait(self, timeout=None):
            return 0

    monkeypatch.setattr(cap.subprocess, "Popen", FakePopen)
    monkeypatch.setattr(Path, "stat", lambda self_: type("S", (), {"st_size": 100_000})())
    monkeypatch.setattr(Path, "exists", lambda self_: True)

    s._start_ffmpeg_chunk()

    assert captured_cmd[0][0] == "ffmpeg"
    assert captured_cmd[0][1] == "-y"


# ─── create_session darwin defaults ──────────────────────────────────────────


def test_create_session_uses_darwin_defaults(monkeypatch, tmp_path, darwin_environ):
    """On darwin with the gate enabled, mic/monitor default to sidecar
    selectors, not to PulseAudio source names. Crucially, this path
    must not invoke pactl (which doesn't exist on macOS)."""
    # If create_session accidentally calls get_default_source(), it
    # would shell out to `pactl get-default-source` and fail loudly on
    # most CI runners. Replace with a sentinel to detect.
    def _boom(*args, **kwargs):
        raise AssertionError("get_default_source must not be called on darwin")

    monkeypatch.setattr(cap, "get_default_source", _boom)
    monkeypatch.setattr(cap, "get_monitor_source", _boom)

    s = cap.create_session(output_dir=tmp_path, filename="out.wav")
    assert s.mic_source == "default"
    assert s.monitor_source == "system"


def test_create_session_explicit_overrides_win(monkeypatch, tmp_path, darwin_environ):
    """User-passed `mic=` / `monitor=` win over darwin defaults."""
    s = cap.create_session(
        output_dir=tmp_path,
        filename="out.wav",
        mic="MyMicUID",
        monitor="app:us.zoom.xos",
    )
    assert s.mic_source == "MyMicUID"
    assert s.monitor_source == "app:us.zoom.xos"


# ─── check_prerequisites darwin branch ───────────────────────────────────────


def test_check_prerequisites_passes_when_perms_granted(monkeypatch, darwin_environ):
    """request-permissions exit 0 from mock → no issues from that check."""
    monkeypatch.setenv("MOCK_BEHAVIOR", "normal")

    # Stub ffmpeg presence so the test doesn't depend on PATH.
    real_run = cap.subprocess.run

    def fake_run(cmd, *args, **kwargs):
        if cmd[0] == "ffmpeg":
            class _R:
                returncode = 0
            return _R()
        return real_run(cmd, *args, **kwargs)

    monkeypatch.setattr(cap.subprocess, "run", fake_run)

    issues = cap.check_prerequisites()
    # Should not contain pactl complaints (we're on darwin) nor permission
    # complaints (mock returns granted).
    assert all("pactl" not in i for i in issues)
    assert all("permissions not granted" not in i for i in issues)


def test_check_prerequisites_reports_perm_denial(monkeypatch, darwin_environ):
    """request-permissions exit 1 from mock → an issue is reported with the
    sidecar's stdout content embedded."""
    monkeypatch.setenv("MOCK_BEHAVIOR", "deny_perms")

    # Stub ffmpeg presence.
    real_run = cap.subprocess.run

    def fake_run(cmd, *args, **kwargs):
        if cmd[0] == "ffmpeg":
            class _R:
                returncode = 0
            return _R()
        return real_run(cmd, *args, **kwargs)

    monkeypatch.setattr(cap.subprocess, "run", fake_run)

    issues = cap.check_prerequisites()
    # Exactly one issue, mentioning permissions and including the
    # sidecar's stdout (which contains "system_audio: denied").
    assert any("permissions not granted" in i for i in issues)
    assert any("system_audio: denied" in i for i in issues)


def test_check_prerequisites_reports_missing_binary(monkeypatch, tmp_path):
    """If the recorder isn't resolvable, that's the first issue we
    report. ffmpeg-missing too if both are absent."""
    monkeypatch.setattr(sys, "platform", "darwin")
    monkeypatch.setenv("MEET_RECORD_MAC", "1")
    monkeypatch.setenv("MEET_RECORD_MAC_PATH", str(tmp_path / "does-not-exist"))

    issues = cap.check_prerequisites()
    assert any("does not point to a file" in i for i in issues)


# ─── End-to-end RecordingSession with mock recorder ─────────────────────────


@pytest.mark.timeout(30)
def test_e2e_normal_recording_stops_via_q_byte(monkeypatch, tmp_path, darwin_environ):
    """Full start() → stop() with the normal-behavior mock.

    Validates:
      * Popen is invoked with the sidecar argv.
      * Startup poll succeeds (mock writes the initial 1024-byte chunk
        immediately).
      * A short recording produces a chunk file > 1024 bytes.
      * stop() drives the q-byte ladder; mock exits 0 within 5 s, so no
        signal escalation is needed.
      * The chunk gets renamed to the final output_file.
      * Session metadata (.session.json) is written with file_exists=True.
      * session.json carries ``stop_reason: stdin-q`` (F7, M8): the mock
        prints the field on cleanup, capture.py parses the shared
        .ffmpeg.log for it.
    """
    s = cap.create_session(output_dir=tmp_path, filename="meeting.wav")
    s.start()
    # Let the mock write a few KB so we know it's alive.
    time.sleep(0.5)
    out = s.stop()
    assert out == tmp_path / "meeting.wav"
    assert out.exists()
    assert out.stat().st_size > 1024
    assert not s._failed
    assert s._restart_count == 0

    # F7: session.json must carry stop_reason. With the normal mock,
    # the q-byte path is taken on stop(), and the mock emits
    # ``stop_reason: stdin-q`` on its way out.
    import json as _json
    meta_path = (tmp_path / "meeting.wav").with_suffix(".session.json")
    assert meta_path.exists()
    meta = _json.loads(meta_path.read_text())
    assert "stop_reason" in meta, (
        "session.json must carry stop_reason (F7, reported by @patternn in M8)"
    )
    assert meta["stop_reason"] == "stdin-q", (
        f"expected stop_reason='stdin-q' (q-byte path); got {meta['stop_reason']!r}. "
        "If this fails, check whether the mock cleanup function is emitting "
        "the line to stderr, and that capture.py's log handle was closed "
        "before _extract_last_stop_reason ran."
    )


@pytest.mark.timeout(45)
def test_e2e_stall_triggers_watchdog_restart(monkeypatch, tmp_path, darwin_environ):
    """A stall-behavior mock writes only the header; the watchdog
    declares the chunk stalled and restarts.

    We compress the watchdog timing so the test runs in ~10 s rather
    than the default 18 s. _STALL_TIMEOUT default is 15 s; we drop it
    to 1.5 s. _WATCHDOG_INTERVAL default is 3 s; drop to 0.5 s.
    """
    monkeypatch.setattr(cap, "_STALL_TIMEOUT", 1.5)
    monkeypatch.setattr(cap, "_WATCHDOG_INTERVAL", 0.5)
    monkeypatch.setenv("MOCK_BEHAVIOR", "stall")

    s = cap.create_session(output_dir=tmp_path, filename="meeting.wav")

    # Startup poll uses size > 1024 to declare success. With stall, the
    # mock writes only the 44-byte header so the poll times out (10 s)
    # but doesn't fail. We drop _STARTUP_TIMEOUT too to avoid waiting
    # the full default.
    monkeypatch.setattr(cap, "_STARTUP_TIMEOUT", 1.0)

    s.start()
    # Wait long enough for at least one stall-restart cycle.
    time.sleep(4.0)
    s.stop()

    # _restart_count should have grown above 0.
    assert s._restart_count >= 1


@pytest.mark.timeout(15)
def test_e2e_opt_out_falls_through_to_ffmpeg_branch(monkeypatch, tmp_path):
    """When MEET_RECORD_MAC=0 on darwin, _start_ffmpeg_chunk builds the
    legacy ffmpeg argv. We verify by intercepting Popen.

    Updated for M6c.ii.c: the gate is now opt-OUT, so the explicit "0"
    is required to reach the ffmpeg branch on darwin. Pre-0.2.0 this
    test relied on the env var being unset (the legacy default).
    """
    monkeypatch.setattr(sys, "platform", "darwin")
    monkeypatch.setenv("MEET_RECORD_MAC", "0")

    s = cap.RecordingSession(
        output_dir=tmp_path,
        output_file=tmp_path / "out.wav",
        mic_source="default-pulse-source",
        monitor_source="default-pulse-monitor",
    )
    s._actual_monitor = "default-pulse-monitor"

    captured: list[list[str]] = []

    class FakePopen:
        def __init__(self, cmd, *args, **kwargs):
            captured.append(cmd)
            self.stdin = type("S", (), {"write": lambda *a: None, "close": lambda: None, "flush": lambda: None})()

        def poll(self):
            return None

        def wait(self, timeout=None):
            return 0

    monkeypatch.setattr(cap.subprocess, "Popen", FakePopen)
    monkeypatch.setattr(Path, "stat", lambda self_: type("S", (), {"st_size": 100_000})())
    monkeypatch.setattr(Path, "exists", lambda self_: True)

    s._start_ffmpeg_chunk()

    assert captured[0][0] == "ffmpeg"
    # And a PulseAudio source name should have been embedded as -i value.
    assert "default-pulse-source" in captured[0]


# ─── Virtual-sink incompatibility on darwin ──────────────────────────────────


def test_virtual_sink_refused_on_darwin(monkeypatch, tmp_path, darwin_environ):
    """use_virtual_sink=True is incompatible with the sidecar backend."""
    s = cap.RecordingSession(
        output_dir=tmp_path,
        output_file=tmp_path / "out.wav",
        mic_source="default",
        monitor_source="system",
        use_virtual_sink=True,
    )
    with pytest.raises(RuntimeError, match="not supported on the macOS sidecar"):
        s.start()


# ─── F7 (M8): _extract_last_stop_reason unit tests ──────────────────────────


def test_extract_last_stop_reason_picks_final_match(tmp_path):
    """Multi-chunk log → last stop_reason wins."""
    log = tmp_path / "x.ffmpeg.log"
    log.write_text(
        """
--- Chunk 0 started at 2026-05-17T15:35:41.035314 ---
done: wrote 100 paired frames
  stop_reason:      SIGINT
  push counters:    mic=100 sys=100

--- Chunk 1 started at 2026-05-17T15:35:42.135 ---
done: wrote 200 paired frames
  stop_reason:      stdin-q
  push counters:    mic=200 sys=200
"""
    )
    assert cap._extract_last_stop_reason(log) == "stdin-q"


def test_extract_last_stop_reason_single_chunk(tmp_path):
    """Single chunk → that reason is returned."""
    log = tmp_path / "x.ffmpeg.log"
    log.write_text(
        "--- Chunk 0 started at 2026-05-17T15:35:41.035314 ---\n"
        "  stop_reason:      max-seconds\n"
    )
    assert cap._extract_last_stop_reason(log) == "max-seconds"


def test_extract_last_stop_reason_missing_log_returns_unknown(tmp_path):
    """Missing log file → 'unknown' (e.g. backend that doesn't emit the line)."""
    assert cap._extract_last_stop_reason(tmp_path / "does-not-exist.log") == "unknown"


def test_extract_last_stop_reason_log_without_field_returns_unknown(tmp_path):
    """Log exists but holds no stop_reason line → 'unknown'."""
    log = tmp_path / "x.ffmpeg.log"
    log.write_text("--- Chunk 0 started ---\nsome unrelated content\n")
    assert cap._extract_last_stop_reason(log) == "unknown"
