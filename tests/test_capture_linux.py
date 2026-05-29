"""Tests for the Linux PulseAudio/PipeWire + ffmpeg capture path.

The macOS sidecar path is covered by ``test_capture_darwin.py``; this
file covers the Linux primitives that every Linux user actually hits:
the ``pactl`` source/sink discovery helpers and the Linux branch of
``check_prerequisites``.  Like the darwin tests, real ``pactl`` /
``ffmpeg`` are never invoked — ``subprocess.run`` is mocked.
"""
from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import patch

import pytest

import millet_record.capture as capture


def _completed(stdout="", returncode=0, stderr=""):
    return SimpleNamespace(stdout=stdout, returncode=returncode, stderr=stderr)


# ── list_sources ─────────────────────────────────────────────────────────────

_PACTL_SOURCES = (
    "0\talsa_input.usb-RODE_NT-USB-00.analog-stereo\tmodule-alsa-card.c\t"
    "s16le 2ch 44100Hz\tRUNNING\n"
    "1\talsa_output.pci-0000_00_1b.0.analog-stereo.monitor\tmodule-alsa-card.c\t"
    "s16le 2ch 44100Hz\tIDLE"
)


def test_list_sources_parses_pactl_output():
    with patch.object(capture.subprocess, "run",
                      return_value=_completed(stdout=_PACTL_SOURCES)) as m:
        devices = capture.list_sources()
    # Correct command issued.
    assert m.call_args[0][0] == ["pactl", "list", "short", "sources"]
    assert len(devices) == 2
    assert devices[0].index == 0
    assert devices[0].name == "alsa_input.usb-RODE_NT-USB-00.analog-stereo"
    assert devices[0].state == "RUNNING"
    assert devices[1].name.endswith(".monitor")


def test_list_sources_raises_on_pactl_failure():
    with patch.object(capture.subprocess, "run",
                      return_value=_completed(returncode=1, stderr="boom")):
        with pytest.raises(RuntimeError, match="Failed to list sources"):
            capture.list_sources()


def test_list_sources_skips_malformed_lines():
    bad = "garbage\n\n0\tname\tdriver\tspec\tRUNNING"
    with patch.object(capture.subprocess, "run",
                      return_value=_completed(stdout=bad)):
        devices = capture.list_sources()
    assert len(devices) == 1
    assert devices[0].name == "name"


# ── get_default_sink / source / monitor ──────────────────────────────────────

def test_get_default_sink():
    with patch.object(capture.subprocess, "run",
                      return_value=_completed(stdout="alsa_output.x\n")) as m:
        sink = capture.get_default_sink()
    assert m.call_args[0][0] == ["pactl", "get-default-sink"]
    assert sink == "alsa_output.x"


def test_get_default_source():
    with patch.object(capture.subprocess, "run",
                      return_value=_completed(stdout="alsa_input.y\n")) as m:
        src = capture.get_default_source()
    assert m.call_args[0][0] == ["pactl", "get-default-source"]
    assert src == "alsa_input.y"


def test_get_monitor_source_derives_from_sink():
    with patch.object(capture.subprocess, "run",
                      return_value=_completed(stdout="alsa_output.z\n")):
        mon = capture.get_monitor_source()
    assert mon == "alsa_output.z.monitor"


def test_get_default_sink_raises_on_failure():
    with patch.object(capture.subprocess, "run",
                      return_value=_completed(returncode=1, stderr="no sink")):
        with pytest.raises(RuntimeError, match="Failed to get default sink"):
            capture.get_default_sink()


# ── check_prerequisites (Linux branch) ───────────────────────────────────────

def test_check_prerequisites_all_present_on_linux(monkeypatch):
    monkeypatch.setattr(capture.sys, "platform", "linux")

    def fake_run(cmd, *a, **k):
        # ffmpeg -version and pactl info both succeed.
        return _completed(returncode=0, stdout="ok")

    with patch.object(capture.subprocess, "run", side_effect=fake_run):
        issues = capture.check_prerequisites()
    assert issues == []


def test_check_prerequisites_reports_missing_ffmpeg(monkeypatch):
    monkeypatch.setattr(capture.sys, "platform", "linux")

    def fake_run(cmd, *a, **k):
        if cmd[0] == "ffmpeg":
            raise FileNotFoundError("ffmpeg")
        return _completed(returncode=0)

    with patch.object(capture.subprocess, "run", side_effect=fake_run):
        issues = capture.check_prerequisites()
    assert any("ffmpeg" in i.lower() for i in issues)


def test_check_prerequisites_reports_missing_pactl(monkeypatch):
    monkeypatch.setattr(capture.sys, "platform", "linux")

    def fake_run(cmd, *a, **k):
        if cmd[0] == "ffmpeg":
            return _completed(returncode=0)
        raise FileNotFoundError("pactl")

    with patch.object(capture.subprocess, "run", side_effect=fake_run):
        issues = capture.check_prerequisites()
    assert any("pactl" in i.lower() or "pulseaudio" in i.lower()
               for i in issues)
