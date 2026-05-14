"""meetscribe-record — lightweight capture-only subset of meetscribe.

Public modules:
    meet_record.capture    — RecordingSession, dual-channel capture
                             (Linux: ffmpeg+PulseAudio; macOS 14.4+
                             arm64: meet-record-mac sidecar)
    meet_record.audio      — stereo channel reading + ffmpeg compression
    meet_record.utils      — formatting helpers
    meet_record.languages  — language constants
    meet_record.cli        — `meet` console-script entry point

Version is the single source of truth here; pyproject.toml's
[project] section pulls it dynamically via setuptools.dynamic.
"""

__version__ = "0.2.0"
