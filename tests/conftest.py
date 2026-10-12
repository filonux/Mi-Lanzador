"""Shared helpers and fixtures for the Mi Lanzador test suite.

Everything here runs the REAL program (real bash, real PyGObject/GTK3, a real
X server) in an isolated HOME, so a regression such as a startup crash cannot
hide behind stubs.  Point the suite at another build with:

    MI_LANZADOR_TEST_SCRIPT=/path/to/mi-lanzador.sh pytest tests
"""
from __future__ import annotations

import contextlib
import json
import os
import pathlib
import select
import shutil
import signal
import subprocess
import sys
import textwrap
import time
import types

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = pathlib.Path(os.environ.get('MI_LANZADOR_TEST_SCRIPT') or ROOT / 'script' / 'mi-lanzador.sh')
HEREDOC_OPEN = "exec python3 - \"$@\" <<'PYEOF'\n"
INSTALL_HINT = 'sudo apt install xvfb openbox x11-utils x11-apps xdotool wmctrl xdg-user-dirs python3-gi gir1.2-gtk-3.0 gir1.2-notify-0.7 libgtk-3-bin librsvg2-common dbus-daemon'


def pytest_configure(config):
    """The repo root has no pytest.ini: the suite's only setting, its marker, is registered here so that it holds
    whatever the directory pytest is launched from (`pytest`, `pytest tests`, `cd tests && pytest`)."""
    config.addinivalue_line('markers', 'real_gtk: tests that bind directly to GTK3 through the native library')


def embedded_python(script: pathlib.Path = SCRIPT) -> str:
    """Return the Python program embedded in the .sh heredoc."""
    return script.read_text(encoding='utf-8').split(HEREDOC_OPEN, 1)[1].split('\nPYEOF', 1)[0]


def bash_part(script: pathlib.Path = SCRIPT) -> str:
    """Return the bash code that runs before the embedded Python."""
    return script.read_text(encoding='utf-8').split(HEREDOC_OPEN, 1)[0]


def require_tools(*names: str) -> None:
    missing = [n for n in names if shutil.which(n) is None]
    if missing:
        pytest.fail(f'Missing tools: {", ".join(missing)}. Install them with: {INSTALL_HINT}')


# Terminals the generated script tries, in order, for the «command» step. A test that fakes one must hide the
# real ones: the script takes the first installed, so a real tilix or gnome-terminal would win over the fake.
TERMINALES = ('gnome-terminal', 'mate-terminal', 'xfce4-terminal', 'tilix', 'terminator', 'konsole', 'xterm',
              'x-terminal-emulator')


# The command of the «command» step is typed by the user: every quote, backslash and newline must reach the shell intact.
COMANDO_HOSTIL = "printf '%s|' \"q'q\" 'd\"d' 'b\\\\b' '$HOME' '%s' 'a\nb'; (exit 3)"
SALIDA_HOSTIL = "q'q|d\"d|b\\\\b|$HOME|%s|a\nb|"


def path_without(directory: pathlib.Path, *names: str) -> str:
    """The current PATH minus the commands `names` (a desktop without them). A directory such as /usr/bin cannot
    simply be dropped from PATH, so this builds `directory` with links to every other executable and returns it."""
    directory.mkdir(parents=True, exist_ok=True)
    for entry in os.environ.get('PATH', '').split(os.pathsep):
        try:
            found = list(os.scandir(entry))
        except OSError:
            continue
        for item in found:
            link = directory / item.name
            if item.name not in names and not link.is_symlink() and item.is_file() and os.access(item.path, os.X_OK):
                link.symlink_to(item.path)
    return str(directory)


@contextlib.contextmanager
def x_session(size: str = '1280x800x24'):
    """A private Xvfb + Openbox on a free display; yields its DISPLAY and tears both down on exit."""
    require_tools('Xvfb', 'openbox', 'wmctrl')
    read_fd, write_fd = os.pipe()
    procs = []
    try:
        xvfb = subprocess.Popen(
            ['Xvfb', '-displayfd', str(write_fd), '-screen', '0', size, '-nolisten', 'tcp'],
            pass_fds=(write_fd,), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        procs.append(xvfb)
        os.close(write_fd)
        # Xvfb writes "<n>\n"; keep the pipe open until teardown or it dies with EPIPE.
        buffer, deadline = b'', time.time() + 15
        while not buffer.endswith(b'\n') and time.time() < deadline:
            if select.select([read_fd], [], [], 0.5)[0]:
                chunk = os.read(read_fd, 32)
                if not chunk:
                    break
                buffer += chunk
        if not buffer.endswith(b'\n'):
            pytest.fail('Xvfb did not report a display number within 15 s')
        display = ':' + buffer.decode().strip()
        env = {**os.environ, 'DISPLAY': display}
        procs.append(subprocess.Popen(['openbox'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        deadline = time.time() + 15
        while time.time() < deadline:
            if subprocess.run(['wmctrl', '-m'], env=env, capture_output=True).returncode == 0:
                break
            time.sleep(0.1)
        else:
            pytest.fail('Openbox did not become ready within 15 s')
        yield display
    finally:
        for proc in reversed(procs):
            proc.terminate()
        for proc in reversed(procs):
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
        os.close(read_fd)


@pytest.fixture(scope='session')
def x11():
    """The session-wide private X server; yields its DISPLAY."""
    require_tools('xdotool')
    with x_session() as display:
        yield display


@pytest.fixture(scope='session')
def path_sin_dialogos(tmp_path_factory):
    """A PATH with no zenity or yad: with either installed, the startup warnings would open a blocking dialog
    on a real desktop (and never reach stderr)."""
    return path_without(tmp_path_factory.mktemp('path'), 'zenity', 'yad')


@pytest.fixture
def sandbox(tmp_path, x11, path_sin_dialogos):
    """An isolated HOME plus a clean environment for launching the program."""
    home = tmp_path / 'home'
    (home / 'Desktop').mkdir(parents=True)
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('MI_LANZADOR_', 'XDG_', 'LC_')) and k not in ('LANG', 'LANGUAGE')}
    env.update(HOME=str(home), DISPLAY=x11, XDG_SESSION_TYPE='x11', LANG='en_US.UTF-8', PATH=path_sin_dialogos)
    return types.SimpleNamespace(
        home=home, env=env, desktop=home / 'Desktop',
        config=home / '.config' / 'mi-lanzador',
        app_dir=home / '.local' / 'share' / 'mi-lanzador',
        applications=home / '.local' / 'share' / 'applications',
        icons=home / '.local' / 'share' / 'icons' / 'hicolor' / 'scalable' / 'apps')


def window_titles(env) -> list[str]:
    out = subprocess.run(['wmctrl', '-l'], env=env, capture_output=True, text=True).stdout
    return [line.split(None, 3)[3] for line in out.splitlines() if len(line.split(None, 3)) == 4]


def wait_until(condition, timeout: float = 10.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if condition():
            return True
        time.sleep(0.2)
    return False


def wait_for_window(env, title: str, proc=None, timeout: float = 20.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if title in window_titles(env):
            return True
        if proc is not None and proc.poll() is not None:
            return False
        time.sleep(0.2)
    return False


def stop_gui(proc, env, title: str = 'Mi Lanzador', timeout: float = 10.0) -> int | None:
    """Close the main window politely; fall back to SIGTERM/SIGKILL."""
    if proc.poll() is None:
        subprocess.run(['wmctrl', '-c', title], env=env, capture_output=True)
        try:
            proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
    return proc.returncode


def launch_gui(sandbox, **extra_env) -> subprocess.Popen:
    env = {**sandbox.env, **extra_env}
    return subprocess.Popen(['bash', str(SCRIPT)], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, start_new_session=True)


@pytest.fixture
def app(tmp_path, monkeypatch):
    """The embedded Python program executed as a module (real PyGObject) with an isolated config dir."""
    monkeypatch.setenv('MI_LANZADOR_CONFIG_DIR', str(tmp_path / 'config'))
    monkeypatch.setenv('MI_LANZADOR_IDIOMA', 'en')
    monkeypatch.setattr(sys, 'excepthook', sys.excepthook)  # the program installs its own hook; undone on teardown
    module = types.ModuleType('mi_lanzador_under_test')  # a real module: monkeypatching its globals works
    module.__file__ = str(SCRIPT)
    exec(compile(embedded_python(), str(SCRIPT), 'exec'), module.__dict__)
    return module


GUI_PRELUDE = r'''
import json, pathlib, sys, types
script = pathlib.Path(sys.argv[1])
src = script.read_text(encoding='utf-8').split(sys.argv[2], 1)[1].split('\nPYEOF', 1)[0]
mod = types.ModuleType('m'); mod.__file__ = str(script)
exec(compile(src, str(script), 'exec'), mod.__dict__)
Gtk, GLib = mod.Gtk, mod.GLib
def pump(ms):
    loop = GLib.MainLoop(); GLib.timeout_add(ms, loop.quit); loop.run()
'''


def run_gui(sandbox, *parts: str, lang: str = 'en', timeout: int = 60) -> dict:
    """Run `parts` in a fresh interpreter with the real program loaded as `mod` (+ Gtk, GLib, pump(ms)).

    The code must leave a JSON-serialisable dict in `result`; it is returned.
    """
    code = GUI_PRELUDE + ''.join(textwrap.dedent(part) for part in parts) + '\nprint(json.dumps(result))\n'
    env = {**sandbox.env, 'MI_LANZADOR_IDIOMA': lang, 'MI_LANZADOR_CONFIG_DIR': str(sandbox.config)}
    out = subprocess.run([sys.executable, '-c', code, str(SCRIPT), HEREDOC_OPEN], env=env,
                         capture_output=True, text=True, timeout=timeout)
    assert out.returncode == 0, out.stderr[-2000:]
    return json.loads(out.stdout.strip().splitlines()[-1])
