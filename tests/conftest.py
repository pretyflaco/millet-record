"""Pytest fixtures for millet_record tests.

This is the project's first conftest.py. It introduces:

* ``tmp_session_dir``: a tmp_path-derived directory ready to hold a
  RecordingSession's chunks + log + session.json.
* ``fake_recorder_factory``: builds a bash script that mimics the
  meet-record-mac CLI surface enough to exercise the Python capture.py
  darwin branch (PR #7 / 22e0b77) on Linux CI without an actual macOS
  build.

The mock is bash because the real recorder is a compiled binary that
reads stdin via blocking ``read(2)`` and writes a WAV header + growing
data on a timer. Bash mirrors all four contracts cheaply:

* ``record --output X``       → starts writing X with a 44-byte header
                                and grows it via a background loop.
* ``probe-permissions``       → exits 0 (granted) or 1 (denied).
* ``--version`` / ``--help``  → noop, exit 0.
* stdin ``q`` byte / EOF /    → flushes RIFF size, kills bg loop,
  SIGINT / SIGTERM             exits 0.

The mock accepts a ``MOCK_BEHAVIOR`` env var that the test injects, so
the same generated script can act normal, crash, stall, or deny
permissions without us regenerating it per scenario.

Constraints we explicitly model:

* The watchdog at millet_record/capture.py:_watchdog_loop checks
  ``proc.poll()`` (process liveness), ``stat(chunk).st_size`` growth
  (against ``_STALL_TIMEOUT = 15s``), and the per-chunk startup poll
  uses ``size > 1024`` as "ffmpeg has produced data" — see
  capture.py:_STARTUP_POLL_INTERVAL et seq.

What we deliberately don't model:

* Real audio. The mock writes growing zero-padded data and an ad-hoc
  RIFF trailer; ``ffprobe`` will recognise the file as a WAV but the
  data isn't audibly meaningful. No test reads the audio back.
* TCC permission prompts on first run. probe-permissions just returns
  the canned status; the real macOS first-launch prompt is patternn's
  M6c.ii territory.
"""

from __future__ import annotations

import os
import stat
import textwrap
from pathlib import Path

import pytest


# ─── tmp_session_dir ─────────────────────────────────────────────────────────


@pytest.fixture
def tmp_session_dir(tmp_path: Path) -> Path:
    """A clean directory for one RecordingSession's artefacts."""
    d = tmp_path / "session"
    d.mkdir()
    return d


# ─── Mock recorder ───────────────────────────────────────────────────────────


# Bash source for the mock. ``MOCK_BEHAVIOR`` env var (set per-test) selects
# the runtime behavior. The script runs unmodified across behaviors so we
# can test "starts normal, then injection of a stall on restart" if we
# ever need it (we don't right now, but the shape is there).
_MOCK_RECORDER_SCRIPT = r"""#!/usr/bin/env bash
# meet-record-mac mock for tests/test_capture_darwin.py
#
# Implements the subset of the M5 CLI surface that capture.py drives:
#   record --output <path> --mic <sel> --system <sel>
#       --sample-rate 16000 --max-seconds 0
#   probe-permissions
#   --version / --help
#
# Stop protocol: q-byte on stdin OR EOF OR SIGINT OR SIGTERM → graceful
# flush + exit 0.
#
# Behavior selector: MOCK_BEHAVIOR={normal,stall,crash_after,deny_perms}
# Optional: MOCK_CRASH_AFTER=<seconds> for crash_after.
# Optional: MOCK_GROWTH_INTERVAL_MS=<int> for unit testing the watchdog.

set -u

behavior="${MOCK_BEHAVIOR:-normal}"
growth_ms="${MOCK_GROWTH_INTERVAL_MS:-100}"

case "${1:-}" in
    --version)
        echo "meet-record-mac 0.6.0 (mock)"
        exit 0
        ;;
    --help|-h)
        echo "mock meet-record-mac"
        exit 0
        ;;
    probe-permissions|request-permissions)
        if [ "$behavior" = "deny_perms" ]; then
            echo "mic: granted"
            echo "system_audio: denied"
            echo "overall: blocked"
            exit 1
        else
            echo "mic: granted"
            echo "system_audio: granted"
            echo "overall: ok"
            exit 0
        fi
        ;;
    devices)
        # Minimal JSON for callers that ask for it; not yet exercised by
        # capture.py but kept honest with the real CLI surface.
        if [ "${2:-}" = "--json" ]; then
            echo '[]'
        else
            echo '(no input devices found)'
        fi
        exit 0
        ;;
    record)
        ;;
    *)
        echo "mock: unknown subcommand: ${1:-<empty>}" >&2
        exit 2
        ;;
esac

# ── record ──
shift  # consume "record"
output_path=""
while [ $# -gt 0 ]; do
    case "$1" in
        --output)         output_path="$2"; shift 2 ;;
        --mic)            shift 2 ;;
        --system)         shift 2 ;;
        --sample-rate)    shift 2 ;;
        --max-seconds)    shift 2 ;;
        *) echo "mock: unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$output_path" ]; then
    echo "mock: --output is required" >&2
    exit 2
fi

# Write a minimal 44-byte WAV header. RIFF size (bytes 4-7) and data
# size (bytes 40-43) are placeholders we patch on graceful exit. Format:
# 16 kHz, 2 ch, s16le, 64000 B/s.
write_header() {
    # 'RIFF' <size:4=0> 'WAVE'
    printf 'RIFF\x00\x00\x00\x00WAVE' > "$output_path"
    # 'fmt ' <16> <PCM=1> <ch=2> <sr=16000> <byterate=64000> <blockalign=4> <bits=16>
    printf 'fmt \x10\x00\x00\x00\x01\x00\x02\x00\x80\x3e\x00\x00\x00\xfa\x00\x00\x04\x00\x10\x00' >> "$output_path"
    # 'data' <size:4=0>
    printf 'data\x00\x00\x00\x00' >> "$output_path"
}

# Patch the placeholder sizes on stop. data_bytes = file_size - 44.
finalize_header() {
    local total
    total=$(wc -c < "$output_path")
    local data_bytes=$((total - 44))
    local riff_size=$((data_bytes + 36))
    # Write riff_size at offset 4 (little-endian uint32).
    printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' \
        $((riff_size & 0xff)) \
        $(((riff_size >> 8) & 0xff)) \
        $(((riff_size >> 16) & 0xff)) \
        $(((riff_size >> 24) & 0xff)))" \
        | dd of="$output_path" bs=1 seek=4 count=4 conv=notrunc 2>/dev/null
    # Write data_bytes at offset 40.
    printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' \
        $((data_bytes & 0xff)) \
        $(((data_bytes >> 8) & 0xff)) \
        $(((data_bytes >> 16) & 0xff)) \
        $(((data_bytes >> 24) & 0xff)))" \
        | dd of="$output_path" bs=1 seek=40 count=4 conv=notrunc 2>/dev/null
}

write_header

# Background growth loop. Writes a 1024-byte chunk every $growth_ms ms
# so the parent's "size > 1024 within 10 s" startup poll succeeds in
# well under the budget. Real recorder grows at 64000 B/s; this is
# slower but test-budget-friendly. Behaviors:
#   normal       → grow until stop
#   stall        → header only, never grow (parent watchdog should
#                  declare a stall after _STALL_TIMEOUT=15 s)
#   crash_after  → grow normally, then exit 1 after MOCK_CRASH_AFTER s
growth_pid=""
case "$behavior" in
    normal|crash_after)
        (
            # First chunk written immediately so the startup poll
            # (which budgets 10 s) clears in <1 s.
            head -c 1024 /dev/zero >> "$output_path" 2>/dev/null
            while true; do
                head -c 1024 /dev/zero >> "$output_path" 2>/dev/null
                # Bash sleep takes float seconds.
                sleep "$(awk "BEGIN { printf \"%.3f\", $growth_ms / 1000 }")"
            done
        ) &
        growth_pid=$!
        ;;
    stall)
        # No growth loop. File stays at 44 bytes header-only.
        :
        ;;
    *)
        echo "mock: unknown behavior: $behavior" >&2
        exit 2
        ;;
esac

# Cleanup function — finalize header and exit cleanly.
# Accepts a single argument that becomes the ``stop_reason:`` line
# written to stderr (which capture.py captures into the shared
# ``.ffmpeg.log``). The real meet-record-mac sidecar prints the same
# field as part of its end-of-chunk summary block (see
# mac/Sources/MeetRecordMac/main.swift); F7 (M8) added a parser in
# capture.py that lifts it into session.json, so the mock must emit
# something for the e2e tests to exercise the field.
cleanup() {
    if [ -n "$growth_pid" ]; then
        kill "$growth_pid" 2>/dev/null || :
        wait "$growth_pid" 2>/dev/null || :
    fi
    finalize_header
    local reason="${1:-stdin-q}"
    printf '  stop_reason:      %s\n' "$reason" >&2
    exit 0
}

# Signal traps (graceful stop on parent escalation).
trap 'cleanup SIGINT' INT
trap 'cleanup SIGTERM' TERM

# crash_after behavior: schedule a non-graceful exit.
if [ "$behavior" = "crash_after" ]; then
    crash_at="${MOCK_CRASH_AFTER:-1}"
    (
        sleep "$crash_at"
        # Kill the parent shell with SIGKILL equivalent (exit 1 from
        # subshell in the same process group). We just kill the parent
        # PID so it dies without running cleanup.
        kill -9 "$PPID" 2>/dev/null || :
    ) &
fi

# Read stdin one byte at a time. q (0x71) → graceful stop. EOF → graceful
# stop. Any other byte → keep reading.
while IFS= read -r -n 1 c; do
    if [ "$c" = "q" ]; then
        cleanup stdin-q
    fi
done

# Reached EOF on stdin → graceful stop, same as q (but different reason).
cleanup stdin-eof
"""


@pytest.fixture
def fake_recorder_factory(tmp_path: Path):
    """Factory for bash-script mock recorders.

    Returns a callable ``make(behavior="normal", **env)`` that writes a
    fresh script to a unique path inside ``tmp_path`` and returns it.
    Caller passes the path to ``MEET_RECORD_MAC_PATH`` so capture.py
    resolves it as the recorder.

    The script contents are identical across calls; behavior is
    selected per-spawn by the ``MOCK_BEHAVIOR`` env var, which the test
    sets on ``os.environ`` (since capture.py inherits the parent's env
    when launching subprocesses — confirmed by survey of the Popen call
    site at millet_record/capture.py:_start_ffmpeg_chunk, which doesn't
    pass an explicit ``env=`` kwarg).
    """
    counter = {"n": 0}

    def _make() -> Path:
        counter["n"] += 1
        path = tmp_path / f"mock-recorder-{counter['n']}.sh"
        path.write_text(_MOCK_RECORDER_SCRIPT)
        # rwx for owner; chmod +x so subprocess.Popen can exec it.
        path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        return path

    return _make


# ─── darwin_environ ──────────────────────────────────────────────────────────


@pytest.fixture
def darwin_environ(monkeypatch, fake_recorder_factory):
    """Activate the macOS sidecar code path on a Linux CI runner.

    Sets, for the duration of the test:
      sys.platform           → "darwin"
      MEET_RECORD_MAC        → "1"   (redundant since 0.2.0 default-ON;
                                      kept as an explicit signal in tests
                                      so a future re-flip of the gate
                                      doesn't silently bypass coverage)
      MEET_RECORD_MAC_PATH   → path to a freshly-generated mock recorder

    Yields the mock recorder path so tests can inspect it (e.g. the
    bytes of the script, or rewrite the MOCK_BEHAVIOR env var directly).

    monkeypatch handles teardown; subsequent tests see the real
    sys.platform and clean env again.
    """
    import sys

    recorder = fake_recorder_factory()
    monkeypatch.setattr(sys, "platform", "darwin")
    monkeypatch.setenv("MEET_RECORD_MAC", "1")
    monkeypatch.setenv("MEET_RECORD_MAC_PATH", str(recorder))
    monkeypatch.setenv("MOCK_BEHAVIOR", "normal")
    yield recorder
