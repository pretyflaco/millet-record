"""CLI entry point for meetscribe-record.

Provides the `meet` console script with capture-only subcommands:
    record    — record dual-channel meeting audio
    devices   — list audio sources
    check     — verify prerequisites
    archive   — compress past WAV recordings to OGG/Opus

When the optional `meetscribe-offline` package is installed, additional
subcommands (transcribe, run, label, sync, gui, ...) are discovered
through the `meet.subcommands` entry-point group and added dynamically.

This is the Click "plugin" pattern: every package wishing to extend the
`meet` command registers Click command objects in `pyproject.toml`:

    [project.entry-points."meet.subcommands"]
    transcribe = "meet.cli:transcribe_cmd"
"""
from __future__ import annotations

import datetime
import signal
import sys
import time
from pathlib import Path

import click

from .capture import DRAIN_SECONDS
from .utils import fmt_elapsed, fmt_size

# ─── Drain countdown + recording loop ────────────────────────────────────────


def _drain_countdown(session, seconds: int = DRAIN_SECONDS) -> None:
    """Keep recording for *seconds* more to let ffmpeg's delayed pipeline flush.

    During the countdown:
    - Additional Ctrl+C signals are ignored (SIGINT → SIG_IGN)
    - A single status line updates in-place each second showing remaining time,
      elapsed recording time, and file size
    After the countdown, default SIGINT handling is restored.
    """
    prev_handler = signal.signal(signal.SIGINT, signal.SIG_IGN)
    try:
        for remaining in range(seconds, 0, -1):
            status = session.status()
            elapsed = fmt_elapsed(status.elapsed_seconds)
            size = fmt_size(status.file_size_bytes)
            click.echo(
                f"\r\033[K\033[1;33m⏳ Flushing audio buffer... {remaining}s\033[0m"
                f"  {elapsed}  {size}",
                nl=False,
            )
            time.sleep(1)
        status = session.status()
        elapsed = fmt_elapsed(status.elapsed_seconds)
        size = fmt_size(status.file_size_bytes)
        click.echo(f"\r\033[K\033[1;32m✔ Buffer flushed\033[0m  {elapsed}  {size}")
    finally:
        signal.signal(signal.SIGINT, prev_handler)


def _recording_loop(session) -> None:
    """Run the live recording status display loop.

    Shows an updating single-line status indicator. Replaces signal.pause()
    with an active monitoring loop. Re-raises KeyboardInterrupt so the
    caller can drain and stop the session.
    """
    last_restart_count = 0
    warned_failed = False

    try:
        while True:
            status = session.status()
            elapsed = fmt_elapsed(status.elapsed_seconds)
            size = fmt_size(status.file_size_bytes)

            if status.failed and not warned_failed:
                reason = status.fail_reason or "unknown error"
                click.echo(
                    f"\r\033[K\033[1;31m✖ RECORDING FAILED\033[0m  "
                    f"{elapsed}  {size}  — {reason}"
                )
                click.echo("  Press Ctrl+C to keep what was captured.")
                warned_failed = True
            elif status.restart_count > last_restart_count:
                last_restart_count = status.restart_count
                click.echo(
                    f"\r\033[K\033[1;33m⚠ Recording restarted\033[0m "
                    f"(attempt {status.restart_count})  {elapsed}  {size}"
                )
            elif not warned_failed:
                if status.is_alive:
                    line = (
                        f"\r\033[K\033[1;32m● REC\033[0m  "
                        f"{elapsed}  {size}  Ctrl+C to stop"
                    )
                else:
                    line = (
                        f"\r\033[K\033[1;33m● REC (starting...)\033[0m  "
                        f"{elapsed}  {size}"
                    )
                click.echo(line, nl=False)

            time.sleep(1)
    except KeyboardInterrupt:
        click.echo("\r\033[K", nl=False)
        raise


# ─── Top-level group with entry-point plugin discovery ───────────────────────


def _load_plugin_subcommands(group: click.Group) -> None:
    """Discover and add subcommands registered under `meet.subcommands`.

    Other packages (e.g. `meetscribe-offline`) extend the `meet` CLI by
    declaring `meet.subcommands` entry points pointing at Click command
    objects. Failure to load any one plugin is logged but does not break
    the CLI.
    """
    try:
        from importlib.metadata import entry_points
    except ImportError:  # pragma: no cover — Python < 3.10 not supported
        return

    try:
        eps = entry_points(group="meet.subcommands")
    except TypeError:
        # Older importlib_metadata API
        eps = entry_points().get("meet.subcommands", [])

    for ep in eps:
        try:
            cmd = ep.load()
        except Exception as exc:
            # Don't let a broken plugin take down the whole CLI; warn and skip.
            click.echo(
                f"warning: failed to load `meet` plugin {ep.name!r}: {exc}",
                err=True,
            )
            continue
        if isinstance(cmd, click.Command) and ep.name not in group.commands:
            group.add_command(cmd, name=ep.name)


from . import __version__


def _combined_version() -> str:
    """Format a `meet --version` string mentioning both packages when present.

    Example outputs:
        meet 0.5.0 (meetscribe-record 0.1.0)
        meet 0.1.0 (meetscribe-record 0.1.0; meetscribe-offline NOT installed)
    """
    record_v = __version__
    try:
        from importlib.metadata import version, PackageNotFoundError
        try:
            offline_v = version("meetscribe-offline")
        except PackageNotFoundError:
            offline_v = None
    except Exception:
        offline_v = None

    if offline_v:
        return (
            f"{offline_v} (meetscribe-offline {offline_v}; "
            f"meetscribe-record {record_v})"
        )
    return (
        f"{record_v} (meetscribe-record {record_v}; "
        f"meetscribe-offline not installed — "
        f"`pip install meetscribe-offline` for transcription/diarization)"
    )


@click.group()
@click.version_option(version=_combined_version(), prog_name="meet")
def main():
    """Meeting audio recorder.

    Capture-only subcommands ship in `meetscribe-record`. Install
    `meetscribe-offline` to add transcription, diarization, labeling,
    summarization, sync, and GUI subcommands.
    """
    pass


# ─── record ──────────────────────────────────────────────────────────────────


@main.command()
@click.option(
    "--output-dir", "-o", type=click.Path(), default=None,
    help="Directory to save recordings (default: ~/meet-recordings)",
)
@click.option(
    "--filename", "-f", type=str, default=None,
    help="Output filename (default: meeting-YYYYMMDD-HHMMSS.wav)",
)
@click.option(
    "--mic", type=str, default=None,
    help="Mic source name (default: system default)",
)
@click.option(
    "--monitor", type=str, default=None,
    help="Monitor source name (default: default sink monitor)",
)
@click.option(
    "--virtual-sink", is_flag=True, default=False,
    help="Use a virtual sink for isolated capture",
)
def record(output_dir, filename, mic, monitor, virtual_sink):
    """Record meeting audio. Press Ctrl+C to stop."""
    from .capture import create_session, check_prerequisites

    issues = check_prerequisites()
    if issues:
        click.echo("Prerequisites check failed:", err=True)
        for issue in issues:
            click.echo(f"  - {issue}", err=True)
        sys.exit(1)

    session = create_session(
        output_dir=output_dir,
        filename=filename,
        mic=mic,
        monitor=monitor,
        virtual_sink=virtual_sink,
    )

    click.echo(f"Recording to: {session.output_file}")
    click.echo(f"  Mic source:     {session.mic_source}")
    click.echo(f"  Monitor source: {session.monitor_source}")
    click.echo(f"  Virtual sink:   {session.use_virtual_sink}")
    if virtual_sink:
        click.echo(
            "  NOTE: Route your meeting app's audio to 'Meet-Capture' in pavucontrol"
        )
    click.echo()

    session.start()

    try:
        _recording_loop(session)
    except KeyboardInterrupt:
        _drain_countdown(session)
        click.echo("Stopping recording...")
        output = session.stop()
        if output.exists():
            size_mb = output.stat().st_size / (1024 * 1024)
            click.echo(f"Saved: {output} ({size_mb:.1f} MB)")
            status = session.status()
            if status.restart_count > 0:
                click.echo(
                    f"  Note: recording restarted {status.restart_count} time(s) "
                    f"— check .ffmpeg.log if audio seems off"
                )
        else:
            click.echo("Warning: output file was not created", err=True)
        sys.exit(0)


# ─── devices ─────────────────────────────────────────────────────────────────


@main.command()
def devices():
    """List available audio devices."""
    from .capture import list_sources, get_default_sink, get_default_source

    try:
        default_source = get_default_source()
        default_sink = get_default_sink()
    except RuntimeError as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)

    click.echo(f"Default mic (source):  {default_source}")
    click.echo(f"Default output (sink): {default_sink}")
    click.echo(f"Monitor source:        {default_sink}.monitor")
    click.echo()

    sources = list_sources()

    click.echo("All sources:")
    click.echo(f"  {'IDX':<5} {'STATE':<12} {'NAME'}")
    click.echo(f"  {'---':<5} {'-----':<12} {'----'}")
    for src in sources:
        marker = ""
        if src.name == default_source:
            marker = " <-- default mic"
        elif src.is_monitor and src.name == f"{default_sink}.monitor":
            marker = " <-- default monitor"
        click.echo(f"  {src.index:<5} {src.state:<12} {src.name}{marker}")


# ─── check ───────────────────────────────────────────────────────────────────


@main.command()
def check():
    """Check system prerequisites for recording.

    Verifies ffmpeg + PulseAudio/PipeWire. If meetscribe-offline is also
    installed, additionally probes whisperx, CUDA, and HF_TOKEN.
    """
    from .capture import check_prerequisites
    import os

    click.echo("Checking prerequisites...")
    click.echo()

    issues = check_prerequisites()
    if issues:
        click.echo("Issues found:")
        for issue in issues:
            click.echo(f"  - {issue}")
        sys.exit(1)
    else:
        click.echo("  ffmpeg:           OK")
        click.echo("  PulseAudio/PipeWire: OK")

    # Probe optional offline-only deps without requiring them.
    click.echo()
    try:
        import whisperx  # noqa: F401
        click.echo("  whisperx:         OK")
        offline_present = True
    except ImportError:
        click.echo("  whisperx:         NOT INSTALLED  "
                   "(only needed if you also want transcription; "
                   "pip install meetscribe-offline)")
        offline_present = False

    if offline_present:
        try:
            import torch
            cuda_available = torch.cuda.is_available()
            if cuda_available:
                gpu_name = torch.cuda.get_device_name(0)
                click.echo(f"  CUDA:             OK ({gpu_name})")
            else:
                click.echo("  CUDA:             Not available (will use CPU)")
        except ImportError:
            click.echo("  torch:            NOT INSTALLED")

        hf_token = os.environ.get("HF_TOKEN")
        if not hf_token:
            token_path = Path.home() / ".cache" / "huggingface" / "token"
            if token_path.exists():
                hf_token = token_path.read_text().strip()
        if hf_token:
            click.echo("  HF_TOKEN:         OK")
        else:
            click.echo("  HF_TOKEN:         NOT SET (diarization won't work)")
            click.echo("                    Set with: export HF_TOKEN=hf_...")

    click.echo()
    click.echo("All recording prerequisites met.")


# ─── archive ─────────────────────────────────────────────────────────────────


@main.command()
@click.argument("session_dirs", nargs=-1, type=click.Path(exists=True))
@click.option(
    "--older-than", type=int, default=None,
    help="Only compress sessions older than N days",
)
@click.option(
    "--keep-wav", is_flag=True, default=False,
    help="Keep original WAV files after compression",
)
@click.option(
    "--dry-run", is_flag=True, default=False,
    help="Show what would be compressed without doing it",
)
def archive(session_dirs, older_than, keep_wav, dry_run):
    """Compress session WAV files to OGG/Opus to save disk space.

    If no SESSION_DIRS are given, scans ~/meet-recordings/ for all sessions
    that still have uncompressed WAV files.

    \b
    Examples:
        meet archive
        meet archive --dry-run
        meet archive --older-than 7
        meet archive ~/meet-recordings/meeting-20260325-150203_LABEL
        meet archive --keep-wav ~/meet-recordings/meeting-*
    """
    from .audio import compress_audio

    recordings_dir = Path.home() / "meet-recordings"

    if session_dirs:
        dirs = [Path(d) for d in session_dirs]
    elif recordings_dir.is_dir():
        dirs = sorted([d for d in recordings_dir.iterdir() if d.is_dir()])
    else:
        click.echo(f"No session directories found in {recordings_dir}")
        return

    targets: list[Path] = []
    for d in dirs:
        for wav in sorted(d.glob("*.wav")):
            if ".chunk-" in wav.name:
                continue
            if wav.with_suffix(".ogg").exists():
                continue
            if older_than is not None:
                mtime = datetime.datetime.fromtimestamp(wav.stat().st_mtime)
                age_days = (datetime.datetime.now() - mtime).days
                if age_days < older_than:
                    continue
            targets.append(wav)

    if not targets:
        click.echo("No uncompressed WAV files to archive.")
        return

    total_wav_size = sum(w.stat().st_size for w in targets)
    click.echo(
        f"Found {len(targets)} WAV file(s) totaling "
        f"{total_wav_size / 1_048_576:.1f} MB"
    )

    if dry_run:
        click.echo()
        for wav in targets:
            size_mb = wav.stat().st_size / 1_048_576
            click.echo(
                f"  [DRY RUN] {wav.parent.name}/{wav.name} ({size_mb:.1f} MB)"
            )
        estimated_ratio = 10.5
        estimated_ogg = total_wav_size / estimated_ratio
        click.echo(
            f"\n  Estimated compressed size: ~{estimated_ogg / 1_048_576:.0f} MB "
            f"(~{estimated_ratio:.0f}x reduction)"
        )
        return

    compressed_count = 0
    saved_bytes = 0
    for wav in targets:
        label = f"{wav.parent.name}/{wav.name}"
        wav_size = wav.stat().st_size
        click.echo(
            f"  Compressing {label} ({wav_size / 1_048_576:.1f} MB)...",
            nl=False,
        )
        try:
            ogg_path = compress_audio(wav, keep_wav=keep_wav)
            ogg_size = ogg_path.stat().st_size
            ratio = wav_size / ogg_size if ogg_size > 0 else 0
            saved = wav_size - ogg_size
            saved_bytes += saved
            compressed_count += 1
            click.echo(f" -> {ogg_size / 1_048_576:.1f} MB ({ratio:.0f}x)")
        except Exception as exc:
            click.echo(f" FAILED: {exc}", err=True)

    click.echo(
        f"\nDone: {compressed_count}/{len(targets)} files compressed, "
        f"{saved_bytes / 1_048_576:.0f} MB saved"
    )


# Hook plugin discovery onto the group AFTER all built-in commands are
# registered, so plugins can override (the entry-points loader skips names
# already present, preserving built-in semantics).
_load_plugin_subcommands(main)


if __name__ == "__main__":
    main()
