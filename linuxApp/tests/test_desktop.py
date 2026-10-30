import pytest

from auraflow import AuraFlowError
from auraflow.desktop import DesktopIntegration, desktop_exec


def test_desktop_entry_escapes_exec_arguments():
    assert desktop_exec(["/a path/100%/python", "-m", "auraflow"]) == (
        '"/a path/100%%/python" "-m" "auraflow"'
    )
    assert desktop_exec(['a"b', "$HOME", "`command`", "a\\b"]) == (
        '"a\\\\"b" "\\\\$HOME" "\\\\`command\\\\`" "a\\\\\\\\b"'
    )
    with pytest.raises(AuraFlowError):
        desktop_exec(["/a\nb/python"])


def test_unmanaged_launcher_is_preserved(paths):
    paths.autostart.parent.mkdir(parents=True)
    paths.autostart.write_text("[Desktop Entry]\nExec=user-command\n")
    with pytest.raises(AuraFlowError, match="not managed"):
        DesktopIntegration(paths).set_autostart(True)
    assert "Exec=user-command" in paths.autostart.read_text()


def test_disable_writes_hidden_override_and_launcher_does_not_restore(paths):
    integration = DesktopIntegration(paths, ["/venv/python", "-m", "auraflow"])
    integration.set_autostart(False)
    assert "Hidden=true" in paths.autostart.read_text()
    assert not integration.autostart_enabled()
    integration.set_autostart(True)
    assert '"restore"' in paths.autostart.read_text()
    launcher = integration.install_launcher()
    assert '"gui"' in launcher.read_text()
    assert '"restore"' not in launcher.read_text()
