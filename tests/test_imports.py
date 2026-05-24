"""Smoke tests for meetscribe-record."""


def test_capture_module_imports():
    from millet_record import capture
    assert hasattr(capture, "DRAIN_SECONDS")
    assert hasattr(capture, "create_session")
    assert hasattr(capture, "check_prerequisites")
    assert hasattr(capture, "list_sources")
    assert hasattr(capture, "get_default_sink")
    assert hasattr(capture, "get_default_source")


def test_audio_module_imports():
    from millet_record import audio
    assert hasattr(audio, "StereoChannels")
    assert hasattr(audio, "read_stereo_channels")
    assert hasattr(audio, "compress_audio")
    assert hasattr(audio, "compute_speaker_channel_energy")


def test_utils_module_imports():
    from millet_record import utils
    assert utils.fmt_elapsed(3661) == "01:01:01"
    assert utils.fmt_size(1024) == "1.0 KB"


def test_languages_module_imports():
    from millet_record import languages
    assert "en" in languages.LANG_NAMES
    assert languages.is_rtl("fa")
    assert not languages.is_rtl("en")


def test_cli_imports_and_has_subcommands():
    from millet_record.cli import main
    cmd_names = set(main.commands.keys())
    # The 4 capture-only built-ins
    assert {"record", "devices", "check", "archive"}.issubset(cmd_names)


def test_meetscribe_offline_shims_still_work_when_installed():
    """If meetscribe-offline is also installed, its compat shims should
    re-export from millet_record correctly. Skipped if not installed."""
    try:
        from meet import capture as meet_capture
        from meet import utils as meet_utils
        from meet import audio as meet_audio
        from meet import languages as meet_languages
    except ImportError:
        return  # meetscribe-offline not installed; not a failure
    from millet_record import capture, utils, audio, languages
    assert meet_capture.DRAIN_SECONDS == capture.DRAIN_SECONDS
    assert meet_utils.fmt_elapsed is utils.fmt_elapsed
    assert meet_audio.read_stereo_channels is audio.read_stereo_channels
    assert meet_languages.LANG_NAMES is languages.LANG_NAMES
