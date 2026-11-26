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


def _build_raw_wav(
    *,
    audio_fmt: int = 1,
    channels: int = 2,
    sr: int = 16000,
    bits_per_sample: int = 16,
    data_payload: bytes = b"",
    declared_data_size: int | None = None,
    trailing_chunks: bytes = b"",
) -> bytes:
    block_align = channels * (bits_per_sample // 8)
    byte_rate = sr * block_align
    fmt_body = struct.pack(
        "<HHIIHH", audio_fmt, channels, sr, byte_rate, block_align, bits_per_sample
    )
    fmt_chunk = b"fmt " + struct.pack("<I", len(fmt_body)) + fmt_body
    dsize = len(data_payload) if declared_data_size is None else declared_data_size
    data_chunk = b"data" + struct.pack("<I", dsize) + data_payload
    body = b"WAVE" + fmt_chunk + data_chunk + trailing_chunks
    return b"RIFF" + struct.pack("<I", len(body)) + body


def test_sample_channel_rms_ignores_trailing_list_metadata_chunk(
    tmp_path: Path, monkeypatch
):
    """Trailing LIST/INFO chunks after `data` must never be decoded as PCM."""
    # 4 bytes of silent stereo PCM16 followed by a 64 KB LIST chunk filled with
    # loud int16-valued bytes (2000).
    loud_meta = np.full(32000, 2000, dtype="<i2").tobytes()
    list_chunk = b"LIST" + struct.pack("<I", len(loud_meta)) + loud_meta
    wav_path = tmp_path / "with_list.wav"
    wav_path.write_bytes(
        _build_raw_wav(data_payload=b"\x00\x00\x00\x00", trailing_chunks=list_chunk)
    )

    monkeypatch.setattr(
        subprocess,
        "run",
        lambda *_a, **_kw: (_ for _ in ()).throw(AssertionError("should not fork")),
    )
    res = audio.sample_channel_rms(wav_path, tail_seconds=2.0)
    assert res == (0.0, 0.0)


def test_sample_channel_rms_live_sentinel_0xffffffff_uses_physical_size(
    tmp_path: Path, monkeypatch
):
    payload = np.full(16000 * 2, 1500, dtype="<i2").tobytes()
    wav_path = tmp_path / "streaming.wav"
    wav_path.write_bytes(
        _build_raw_wav(data_payload=payload, declared_data_size=0xFFFFFFFF)
    )
    monkeypatch.setattr(
        subprocess,
        "run",
        lambda *_a, **_kw: (_ for _ in ()).throw(AssertionError("should not fork")),
    )
    res = audio.sample_channel_rms(wav_path, tail_seconds=1.0)
    assert res is not None
    assert abs(res[0] - 1500.0) < 1.0
    assert abs(res[1] - 1500.0) < 1.0


def test_sample_channel_rms_stale_positive_live_header_reads_physical_tail(
    tmp_path: Path, monkeypatch
):
    """Model MeetRecordMac WavWriter's 10s-stale positive header during live capture.

    When RIFF/data sizes reflect an earlier header patch (10s of 1000-level PCM)
    while newer PCM (10s of 3000-level PCM) has been appended physically, the
    live tail check must read the appended audio rather than the stale prefix.
    """
    sr = 16000
    old_pcm = np.full(sr * 10 * 2, 1000, dtype="<i2").tobytes()
    new_pcm = np.full(sr * 10 * 2, 3000, dtype="<i2").tobytes()
    # Header was last patched at the 10-second mark (riff_size + data_size = old_pcm only).
    base_wav = _build_raw_wav(sr=sr, data_payload=old_pcm)
    wav_path = tmp_path / "live_stale.wav"
    wav_path.write_bytes(base_wav + new_pcm)

    monkeypatch.setattr(
        subprocess,
        "run",
        lambda *_a, **_kw: (_ for _ in ()).throw(AssertionError("should not fork")),
    )
    res = audio.sample_channel_rms(wav_path, tail_seconds=8.0)
    assert res is not None
    assert abs(res[0] - 3000.0) < 1.0
    assert abs(res[1] - 3000.0) < 1.0


def test_sample_channel_rms_non_pcm16_wav_falls_back(tmp_path: Path):
    """24-bit PCM, IEEE float (fmt=3), and A-law (fmt=6) must return _FALLBACK."""
    cases = [
        ("pcm24.wav", 1, 24, b"\x00" * 60),
        ("float32.wav", 3, 32, b"\x00" * 80),
        ("alaw.wav", 6, 8, b"\x00" * 40),
    ]
    for name, fmt, bits, payload in cases:
        p = tmp_path / name
        p.write_bytes(_build_raw_wav(audio_fmt=fmt, bits_per_sample=bits, data_payload=payload))
        assert audio._sample_pcm16_wav_tail_rms(p, 2.0) is audio._FALLBACK


def test_sample_channel_rms_truncated_and_empty_wav(tmp_path: Path, monkeypatch):
    monkeypatch.setattr(
        subprocess,
        "run",
        lambda *_a, **_kw: (_ for _ in ()).throw(AssertionError("should not fork")),
    )
    empty = tmp_path / "empty.wav"
    empty.write_bytes(b"")
    assert audio.sample_channel_rms(empty) is None

    short_hdr = tmp_path / "short.wav"
    short_hdr.write_bytes(b"RIFF\x00\x00\x00\x00WAVE")
    assert audio.sample_channel_rms(short_hdr) is None

    header_only = tmp_path / "header_only.wav"
    header_only.write_bytes(_build_raw_wav(data_payload=b""))
    assert audio.sample_channel_rms(header_only) is None

    # Declared 4000 bytes of data, but file truncated to 40 bytes (10 frames) of 1000.
    trunc_payload = np.full(20, 1000, dtype="<i2").tobytes()
    trunc = tmp_path / "truncated.wav"
    trunc.write_bytes(_build_raw_wav(data_payload=trunc_payload, declared_data_size=4000))
    res = audio.sample_channel_rms(trunc, tail_seconds=1.0)
    assert res is not None
    assert abs(res[0] - 1000.0) < 1.0
    assert abs(res[1] - 1000.0) < 1.0
