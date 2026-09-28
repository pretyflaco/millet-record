"""millet-record — lightweight capture-only subset of millet (formerly meetscribe-record).

Public modules:
    millet_record.capture    — RecordingSession, dual-channel capture
                             (Linux: ffmpeg+PulseAudio; macOS 14.4+
                             arm64: meet-record-mac sidecar)
    millet_record.audio      — stereo channel reading + ffmpeg compression
    millet_record.utils      — formatting helpers
    millet_record.languages  — language constants
    millet_record.cli        — `millet` console-script entry point

Named after the Ottoman millet system.  Part of the vezir ecosystem.

Version is the single source of truth here; pyproject.toml's
[project] section pulls it dynamically via setuptools.dynamic.

History: until 0.5.1 the package was also importable as ``meet_record``
(via a MetaPathFinder alias) and the CLI was also installed as ``meet``;
both deprecation aliases were removed in 0.6.0 after the announced
two-minor-version window.
"""

__version__ = "0.6.0"
