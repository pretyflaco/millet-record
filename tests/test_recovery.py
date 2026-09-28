"""Tests for the 0.6.0 crash-resilience features in millet_record.capture.

Pins the contracts added after the 2026-09-28 incident, where a crashed
TUI left a detached recorder writing for 12 more minutes (into two
subsequent meetings' session dirs) and the 87-minute recording appeared
lost because nothing on disk said "interrupted, recoverable":

* ``recording.lock`` — one active recording per output root; stale locks
  (dead holder pid) are reclaimed; ``MEET_RECORD_LOCK=0`` disables.
* ``<stem>.recorder.json`` — identifies the live recorder (pid + owner),
  removed on stop/pause.
* ``<stem>.session.json`` — written at start (status "recording"), not
  only at stop.
* ``find_interrupted_sessions`` / ``recover_session`` — scan and stitch
  dirs the parent never came back for.
"""
from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path
from unittest.mock import patch

import pytest

import millet_record.capture as cap

# ─── helpers ─────────────────────────────────────────────────────────────────


def _write_chunk(path: Path, payload: bytes, declared_data: int = 0xFFFFFFFF) -> None:
    """Write a WAV chunk with a SIGKILL-damaged (placeholder) header.

    Real ffmpeg leaves the RIFF/data sizes at their max-value placeholder
    when killed; the sizes only get patched on a graceful close.
    """
    header = (
        b"RIFF" + (0xFFFFFFFF).to_bytes(4, "little") + b"WAVE"
        b"fmt " + (16).to_bytes(4, "little") + (1).to_bytes(2, "little")
        + (2).to_bytes(2, "little") + (16000).to_bytes(4, "little")
        + (64000).to_bytes(4, "little") + (4).to_bytes(2, "little")
        + (16).to_bytes(2, "little")
        + b"data" + declared_data.to_bytes(4, "little")
    )
    path.write_bytes(header + payload)


def _dead_pid() -> int:
    """A pid that is certainly dead (recently exited child)."""
    proc = subprocess.Popen(["true"])
    proc.wait()
    return proc.pid


def _make_interrupted_dir(root: Path, name: str = "meeting-20260928-135948") -> Path:
    """A session dir as a crashed pre-0.6.0 recorder would leave it."""
    d = root / name
    d.mkdir()
    _write_chunk(d / f"{name}.chunk-000.wav", b"\x00" * 2048)
    (d / f"{name}.ffmpeg.log").write_text("...recording...\n")
    return d


# ─── session.json at start ───────────────────────────────────────────────────


@pytest.mark.timeout(30)
def test_session_json_written_at_start_and_rewritten_at_stop(tmp_path, darwin_environ):
    s = cap.create_session(output_dir=tmp_path, filename="meeting.wav")
    s.start()
    try:
        meta_path = tmp_path / "meeting.session.json"
        assert meta_path.exists(), "session.json must exist while recording"
        meta = json.loads(meta_path.read_text())
        assert meta["status"] == "recording"
        assert meta["owner_pid"] == os.getpid()
        assert "started_at" in meta
    finally:
        s.stop()

    meta = json.loads((tmp_path / "meeting.session.json").read_text())
    assert meta["status"] == "stopped"
    assert "stopped_at" in meta


# ─── recorder marker ──────────────────────────────────────────────────────────


@pytest.mark.timeout(30)
def test_recorder_marker_lifecycle(tmp_path, darwin_environ):
    s = cap.create_session(output_dir=tmp_path, filename="meeting.wav")
    s.start()
    marker_path = tmp_path / "meeting.recorder.json"
    try:
        assert marker_path.exists()
        marker = json.loads(marker_path.read_text())
        assert marker["pid"] == s._ffmpeg_proc.pid
        assert marker["owner_pid"] == os.getpid()
        assert marker["chunk"] == "meeting.chunk-000.wav"
        assert marker["backend"] == "meet-record-mac"
        assert cap._process_alive(marker["pid"], marker["pid_start_ticks"])
    finally:
        s.stop()
    assert not marker_path.exists(), "clean stop must remove the marker"


@pytest.mark.timeout(30)
def test_pause_removes_marker_but_keeps_lock(tmp_path, darwin_environ):
    s = cap.create_session(output_dir=tmp_path, filename="meeting.wav")
    s.start()
    time.sleep(0.2)
    s.pause()
    try:
        assert not (tmp_path / "meeting.recorder.json").exists()
        # The lock stays held across a pause — the session is still active.
        assert (tmp_path / "recording.lock").exists()
    finally:
        s.resume()
        assert (tmp_path / "meeting.recorder.json").exists()
        s.stop()


# ─── recording lock ──────────────────────────────────────────────────────────


@pytest.mark.timeout(30)
def test_lock_blocks_concurrent_session(tmp_path, darwin_environ):
    s1 = cap.create_session(output_dir=tmp_path, filename="a.wav")
    s1.start()
    try:
        s2 = cap.create_session(output_dir=tmp_path, filename="b.wav")
        with pytest.raises(cap.RecordingInProgressError) as exc_info:
            s2.start()
        assert exc_info.value.holder["pid"] == os.getpid()
        assert exc_info.value.lock_path == tmp_path / "recording.lock"
    finally:
        s1.stop()

    # Lock is released on stop — the second session can start now.
    s2.start()
    s2.stop()


@pytest.mark.timeout(30)
def test_stale_lock_reclaimed(tmp_path, darwin_environ):
    lock_path = tmp_path / "recording.lock"
    lock_path.write_text(
        json.dumps({"pid": _dead_pid(), "pid_start_ticks": None,
                    "started_at": "2026-09-28T13:59:48", "session_dir": "/old"})
    )
    s = cap.create_session(output_dir=tmp_path, filename="meeting.wav")
    s.start()
    try:
        holder = json.loads(lock_path.read_text())
        assert holder["pid"] == os.getpid(), "stale lock must be reclaimed"
    finally:
        s.stop()


@pytest.mark.timeout(30)
def test_lock_released_on_failed_start(monkeypatch, tmp_path, darwin_environ):
    s = cap.create_session(output_dir=tmp_path, filename="meeting.wav")

    def boom():
        raise RuntimeError("simulated spawn failure")

    monkeypatch.setattr(s, "_spawn_recorder_chunk", boom)
    with pytest.raises(RuntimeError, match="simulated spawn failure"):
        s.start()

    assert not (tmp_path / "recording.lock").exists()
    meta = json.loads((tmp_path / "meeting.session.json").read_text())
    assert meta["status"] == "failed"


@pytest.mark.timeout(30)
def test_lock_disabled_via_env(monkeypatch, tmp_path, darwin_environ):
    monkeypatch.setenv("MEET_RECORD_LOCK", "0")
    s1 = cap.create_session(output_dir=tmp_path, filename="a.wav")
    s2 = cap.create_session(output_dir=tmp_path, filename="b.wav")
    s1.start()
    s2.start()  # no RecordingInProgressError
    assert not (tmp_path / "recording.lock").exists()
    s1.stop()
    s2.stop()


@pytest.mark.timeout(30)
def test_direct_construction_has_no_lock(tmp_path, darwin_environ):
    """RecordingSession(...) built without create_session skips locking
    (backward compat for embedders that manage their own lifecycle)."""
    s = cap.RecordingSession(
        output_dir=tmp_path,
        output_file=tmp_path / "out.wav",
        mic_source="default",
        monitor_source="system",
    )
    s.start()
    try:
        assert not (tmp_path / "recording.lock").exists()
    finally:
        s.stop()


# ─── find_interrupted_sessions ────────────────────────────────────────────────


def test_find_interrupted_sessions_detects_chunk_only_dir(tmp_path):
    d = _make_interrupted_dir(tmp_path)
    found = cap.find_interrupted_sessions(tmp_path)
    assert [f.session_dir for f in found] == [d]
    s = found[0]
    assert len(s.chunks) == 1
    assert s.total_bytes == 44 + 2048
    assert not s.recorder_alive
    assert not s.owner_alive
    assert not s.orphaned
    assert s.recorder_pid is None  # pre-0.6.0 dir: no marker


def test_find_interrupted_sessions_skips_finished_dirs(tmp_path):
    d = _make_interrupted_dir(tmp_path)
    # A stitched final WAV means the session completed (or was recovered).
    (d / f"{d.name}.wav").write_bytes(b"RIFF....")
    assert cap.find_interrupted_sessions(tmp_path) == []


def test_find_interrupted_sessions_skips_clean_dirs(tmp_path):
    (tmp_path / "meeting-20260928-140000").mkdir()
    assert cap.find_interrupted_sessions(tmp_path) == []


def test_find_interrupted_sessions_missing_root(tmp_path):
    assert cap.find_interrupted_sessions(tmp_path / "nonexistent") == []


def test_find_interrupted_sessions_orphan_detection(tmp_path):
    """Live recorder + dead owner = orphaned (stop & salvage)."""
    d = _make_interrupted_dir(tmp_path)
    proc = subprocess.Popen(["sleep", "30"])
    try:
        marker = {
            "pid": proc.pid,
            "pid_start_ticks": cap._proc_start_ticks(proc.pid),
            "owner_pid": _dead_pid(),
            "owner_start_ticks": None,
            "backend": "ffmpeg",
            "chunk": f"{d.name}.chunk-000.wav",
            "started_at": "2026-09-28T13:59:48",
        }
        (d / f"{d.name}.recorder.json").write_text(json.dumps(marker))

        found = cap.find_interrupted_sessions(tmp_path)
        assert len(found) == 1
        s = found[0]
        assert s.recorder_alive
        assert not s.owner_alive
        assert s.orphaned
        assert s.backend == "ffmpeg"
        assert s.started_at == "2026-09-28T13:59:48"
    finally:
        proc.kill()
        proc.wait()

    # Once the recorder dies, the same dir reads as plain interrupted.
    found = cap.find_interrupted_sessions(tmp_path)
    assert len(found) == 1
    assert not found[0].recorder_alive
    assert not found[0].orphaned


def test_find_interrupted_sessions_in_progress_detection(tmp_path):
    """Live recorder + live owner (us) = recording in progress, hands off."""
    d = _make_interrupted_dir(tmp_path)
    proc = subprocess.Popen(["sleep", "30"])
    try:
        marker = {
            "pid": proc.pid,
            "pid_start_ticks": cap._proc_start_ticks(proc.pid),
            "owner_pid": os.getpid(),  # alive: this very test process
            "owner_start_ticks": cap._proc_start_ticks(os.getpid()),
            "backend": "ffmpeg",
            "chunk": f"{d.name}.chunk-000.wav",
            "started_at": "2026-09-28T13:59:48",
        }
        (d / f"{d.name}.recorder.json").write_text(json.dumps(marker))

        s = cap.find_interrupted_sessions(tmp_path)[0]
        assert s.recorder_alive
        assert s.owner_alive
        assert not s.orphaned
    finally:
        proc.kill()
        proc.wait()


def test_find_interrupted_sessions_pid_reuse_guard(tmp_path):
    """A live pid whose start ticks differ from the marker is a DIFFERENT
    process (pid was reused) — must not count as alive."""
    d = _make_interrupted_dir(tmp_path)
    proc = subprocess.Popen(["sleep", "30"])
    try:
        real_ticks = cap._proc_start_ticks(proc.pid)
        if real_ticks is None:
            pytest.skip("/proc start ticks unavailable on this platform")
        marker = {
            "pid": proc.pid,
            "pid_start_ticks": real_ticks + 1,  # wrong start time
            "owner_pid": proc.pid,
            "owner_start_ticks": real_ticks + 1,
        }
        (d / f"{d.name}.recorder.json").write_text(json.dumps(marker))

        s = cap.find_interrupted_sessions(tmp_path)[0]
        assert not s.recorder_alive
        assert not s.owner_alive
    finally:
        proc.kill()
        proc.wait()


# ─── recover_session ──────────────────────────────────────────────────────────


def test_recover_session_single_chunk_repairs_header(tmp_path):
    d = _make_interrupted_dir(tmp_path)
    out = cap.recover_session(d)

    assert out == d / f"{d.name}.wav"
    assert out.exists()
    assert not list(d.glob("*.chunk-*.wav")), "chunks must be cleaned up"

    data = out.read_bytes()
    assert data[0:4] == b"RIFF"
    # Header repaired: data size (offset 40) == payload bytes.
    assert int.from_bytes(data[40:44], "little") == 2048
    assert int.from_bytes(data[4:8], "little") == len(data) - 8

    meta = json.loads((d / f"{d.name}.session.json").read_text())
    assert meta["status"] == "recovered"
    assert meta["chunk_count"] == 1
    assert meta["file_size_bytes"] == out.stat().st_size


def test_recover_session_multi_chunk_concats(tmp_path):
    d = _make_interrupted_dir(tmp_path)
    _write_chunk(d / f"{d.name}.chunk-001.wav", b"\x01" * 1024)

    def fake_concat(cmd, *a, **k):
        assert cmd[0] == "ffmpeg" and "-f" in cmd and "concat" in cmd
        # Simulate ffmpeg concat: write an output with both payloads.
        Path(cmd[-1]).write_bytes(b"\x00" * 2048 + b"\x01" * 1024)
        return subprocess.CompletedProcess(cmd, 0)

    with patch.object(cap.subprocess, "run", side_effect=fake_concat):
        out = cap.recover_session(d)

    assert out.exists()
    assert not list(d.glob("*.chunk-*.wav"))
    meta = json.loads((d / f"{d.name}.session.json").read_text())
    assert meta["chunk_count"] == 2


def test_recover_session_concat_falls_back_to_largest_chunk(tmp_path):
    d = _make_interrupted_dir(tmp_path)
    _write_chunk(d / f"{d.name}.chunk-001.wav", b"\x01" * 1024)

    with patch.object(cap.subprocess, "run",
                      return_value=subprocess.CompletedProcess([], 1)):
        out = cap.recover_session(d)

    assert out.exists()
    # Fallback = largest chunk renamed; the larger payload survives.
    assert out.stat().st_size == 44 + 2048


def test_recover_session_refuses_live_recorder(tmp_path):
    d = _make_interrupted_dir(tmp_path)
    proc = subprocess.Popen(["sleep", "30"])
    try:
        marker = {
            "pid": proc.pid,
            "pid_start_ticks": cap._proc_start_ticks(proc.pid),
        }
        (d / f"{d.name}.recorder.json").write_text(json.dumps(marker))
        with pytest.raises(RuntimeError, match="still writing"):
            cap.recover_session(d)
        # Nothing touched.
        assert list(d.glob("*.chunk-*.wav"))
    finally:
        proc.kill()
        proc.wait()


def test_recover_session_removes_dead_marker(tmp_path):
    d = _make_interrupted_dir(tmp_path)
    (d / f"{d.name}.recorder.json").write_text(
        json.dumps({"pid": _dead_pid(), "pid_start_ticks": None})
    )
    cap.recover_session(d)
    assert not (d / f"{d.name}.recorder.json").exists()


def test_recover_session_no_chunks(tmp_path):
    d = tmp_path / "empty-session"
    d.mkdir()
    with pytest.raises(FileNotFoundError, match="no recording chunks"):
        cap.recover_session(d)


def test_recover_session_final_wav_exists(tmp_path):
    d = _make_interrupted_dir(tmp_path)
    (d / f"{d.name}.wav").write_bytes(b"RIFF....")
    with pytest.raises(FileExistsError, match="nothing to recover"):
        cap.recover_session(d)


def test_recover_session_all_chunks_empty(tmp_path):
    d = tmp_path / "meeting-20260928-150000"
    d.mkdir()
    (d / f"{d.name}.chunk-000.wav").write_bytes(b"")  # never got data
    with pytest.raises(FileNotFoundError, match="empty"):
        cap.recover_session(d)
