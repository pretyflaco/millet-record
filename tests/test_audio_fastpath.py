"""Tests for zero-fork PCM16 WAV RMS fast-path and backend-aware drain defaults."""

from __future__ import annotations

import struct
import subprocess
import wave
from pathlib import Path

import numpy as np

from millet_record import audio, capture


def _write_stereo_wav(
    path: Path,
    left: np.ndarray,
    right: np.ndarray,
    *,
    sr: int = 16000,
    zero_header_sizes: bool = False,
) -> None:
    interleaved = np.empty(len(left) * 2, dtype=np.int16)
    interleaved[0::2] = left.astype(np.int16)
    interleaved[1::2] = right.astype(np.int16)
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(2)
        wf.setsampwidth(2)
        wf.setframerate(sr)
        wf.writeframes(interleaved.tobytes())
    if zero_header_sizes:
        # Simulate a live chunk whose RIFF/data sizes have not been finalized yet.
        with path.open("r+b") as f:
            f.seek(4)
            f.write(struct.pack("<I", 0))
            f.seek(40)
            f.write(struct.pack("<I", 0))


def test_sample_channel_rms_wav_fastpath_zero_subprocesses(tmp_path: Path, monkeypatch):
    sr = 16000
    # First 5s: quiet mic, loud system. Last 2s: loud mic (2000), silent system (0).
    left = np.concatenate([np.full(sr * 5, 100, dtype=np.int16), np.full(sr * 2, 2000, dtype=np.int16)])
    right = np.concatenate([np.full(sr * 5, 3000, dtype=np.int16), np.zeros(sr * 2, dtype=np.int16)])
    wav_path = tmp_path / "live.wav"
    _write_stereo_wav(wav_path, left, right, sr=sr, zero_header_sizes=True)

    def _forbid_subprocess(*_a, **_kw):
        raise AssertionError("WAV fast path must not spawn ffprobe/ffmpeg")

    monkeypatch.setattr(subprocess, "run", _forbid_subprocess)

    # Tail = 2.0s should reflect only the last 2s (mic=2000, sys=0).
    res = audio.sample_channel_rms(wav_path, tail_seconds=2.0)
    assert res is not None
    mic_rms, sys_rms = res
    assert abs(mic_rms - 2000.0) < 1.0
    assert sys_rms == 0.0


def test_sample_channel_rms_mono_wav_returns_none_without_subprocess(tmp_path: Path, monkeypatch):
    mono_path = tmp_path / "mono.wav"
    with wave.open(str(mono_path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(16000)
        wf.writeframes(np.full(16000, 1000, dtype=np.int16).tobytes())

    monkeypatch.setattr(
        subprocess,
        "run",
        lambda *_a, **_kw: (_ for _ in ()).throw(AssertionError("should not fork")),
    )
    assert audio.sample_channel_rms(mono_path) is None


def test_default_drain_seconds_is_backend_aware(monkeypatch):
    monkeypatch.setattr(capture, "_darwin_backend_enabled", lambda: True)
    assert capture.default_drain_seconds() == capture.DRAIN_SECONDS_DARWIN == 1

    monkeypatch.setattr(capture, "_darwin_backend_enabled", lambda: False)
    assert capture.default_drain_seconds() == capture.DRAIN_SECONDS == 10
