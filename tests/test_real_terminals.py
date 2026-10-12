"""The «command» step run through each REAL terminal, on a private X server with Openbox.

The fake terminals of test_generated_script.py check HOW the script calls each terminal; only the real program shows
what that terminal does with the call. A terminal that is not installed is skipped (the others still run).
"""
import contextlib
import os
import pathlib
import shlex
import shutil
import subprocess

import pytest

from conftest import COMANDO_HOSTIL, SALIDA_HOSTIL, TERMINALES, path_without, require_tools, wait_until

# Terminals the script reaches by name; x-terminal-emulator is a link chosen by the system, so it is run as an alias
# of other terminals instead (see ALIAS_OBJETIVOS).
POR_NOMBRE = [terminal for terminal in TERMINALES if terminal != 'x-terminal-emulator']
# What `x-terminal-emulator` can point to. The script calls it like konsole and xterm (`-e`), so those two stand for it;
# the others register that alternative in Ubuntu and also take `-e`.
ALIAS_OBJETIVOS = ['xterm', 'konsole', 'lxterminal', 'urxvt', 'kitty', 'alacritty']


def window_ids(env):
    out = subprocess.run(['wmctrl', '-l'], env=env, capture_output=True, text=True).stdout
    return {line.split(None, 1)[0] for line in out.splitlines() if line.strip()}


@contextlib.contextmanager
def session_bus(env):
    """A private D-Bus session: gnome-terminal and konsole start their server through it, and that server takes its
    DISPLAY from the environment of the bus, not from the program that calls it."""
    require_tools('dbus-daemon')
    bus = subprocess.Popen(['dbus-daemon', '--session', '--nofork', '--print-address'], env=env,
                           stdout=subprocess.PIPE, text=True)
    try:
        address = bus.stdout.readline().strip()
        assert address, 'dbus-daemon did not print its address'
        yield address
    finally:
        bus.terminate()
        bus.wait(timeout=5)


def run_command_step(app, tmp_path, x11, bin_dir):
    """Runs a «command» step with the hostile command and PATH `bin_dir`; returns what the real terminal did."""
    out = tmp_path / 'salida.txt'
    assert '; (exit 3)' in COMANDO_HOSTIL
    command = COMANDO_HOSTIL.replace('; (exit 3)', f' > {shlex.quote(str(out))}; (exit 3)')   # what the command prints
    script = tmp_path / 'accion.sh'
    script.write_text(app.generar_script_bash([{'tipo': 'comando', 'comando': command, 'espera': 0.2}], 'demo'),
                      encoding='utf-8')
    home, runtime = tmp_path / 'home', tmp_path / 'run'
    home.mkdir()
    runtime.mkdir(mode=0o700)
    x_env = {**os.environ, 'DISPLAY': x11}   # wmctrl and xdotool
    # gnome-terminal refuses a locale that is not UTF-8; konsole (Qt) needs to be told to use X11.
    env = {'PATH': str(bin_dir), 'HOME': str(home), 'XDG_RUNTIME_DIR': str(runtime), 'DISPLAY': x11,
           'LANG': 'C.UTF-8', 'QT_QPA_PLATFORM': 'xcb', 'GDK_BACKEND': 'x11', 'MI_LANZADOR_IDIOMA': 'en'}
    before = window_ids(x_env)
    result = {'opened': False, 'closed': False, 'output': None}
    with session_bus(env) as address:
        env['DBUS_SESSION_BUS_ADDRESS'] = address
        try:
            result['run'] = subprocess.run(['bash', str(script)], env=env, capture_output=True, text=True, timeout=30)
            result['opened'] = wait_until(lambda: window_ids(x_env) - before, 20)
            wait_until(out.exists, 20)
            wait_until(lambda: out.exists() and out.read_bytes().endswith(b'|'), 5)   # the command has finished printing
            if result['opened']:
                window = sorted(window_ids(x_env) - before)[0]
                subprocess.run(['wmctrl', '-i', '-a', window], env=x_env, capture_output=True)
                subprocess.run(['xdotool', 'key', '--clearmodifiers', 'Return'], env=x_env, capture_output=True)
                result['closed'] = wait_until(lambda: not window_ids(x_env) - before, 15)
            result['output'] = out.read_text(encoding='utf-8') if out.exists() else None
        finally:
            for window in window_ids(x_env) - before:   # a terminal that stayed open must not reach the next test
                subprocess.run(['wmctrl', '-i', '-c', window], env=x_env, capture_output=True)
    return result


def check(result, name):
    run = result['run']
    assert run.returncode == 0 and 'no installed terminal' not in run.stderr, (name, run.stderr)
    assert result['opened'], f'{name} opened no window: {run.stderr}'
    assert result['output'] == SALIDA_HOSTIL, (name, result['output'])   # the command reached bash byte for byte
    assert result['closed'], f'{name} did not close its window after Enter'


@pytest.mark.parametrize('terminal', POR_NOMBRE)
def test_the_command_step_runs_intact_and_closes_on_enter_in_the_real_terminal(app, tmp_path, x11, terminal):
    if shutil.which(terminal) is None:
        pytest.skip(f'{terminal} is not installed')
    bin_dir = path_without(tmp_path / 'bin', *[other for other in TERMINALES if other != terminal])
    check(run_command_step(app, tmp_path, x11, bin_dir), terminal)


@pytest.mark.parametrize('objetivo', ALIAS_OBJETIVOS)
def test_the_command_step_works_through_x_terminal_emulator_pointing_to_a_real_terminal(app, tmp_path, x11, objetivo):
    """With none of the seven by name, `x-terminal-emulator` is the last resort: here it is a link to a real terminal."""
    if shutil.which(objetivo) is None:
        pytest.skip(f'{objetivo} is not installed')
    bin_dir = pathlib.Path(path_without(tmp_path / 'bin', *TERMINALES))
    (bin_dir / 'x-terminal-emulator').symlink_to(shutil.which(objetivo))
    check(run_command_step(app, tmp_path, x11, bin_dir), f'x-terminal-emulator -> {objetivo}')
