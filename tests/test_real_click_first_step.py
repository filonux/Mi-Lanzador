"""A click as the first step, end to end: the real program, a real X server and window manager, a real xdotool
click and a real window underneath.

The click used to fire before the window manager had minimised Mi Lanzador, so it landed on Mi Lanzador itself
instead of on the window below (test_dialog_robustness.py covers the order of the calls; this one covers where
the click ends up). Also covered: the pointer already resting on the click point, where `xdotool mousemove --sync`
waits ~15 s for a move that never comes (xdotool 3.20160805). Every test starts its own X server: pointer position,
windows and focus of one run must not leak into the next.
"""
import subprocess
import sys
import time

import pytest

from conftest import run_gui, wait_until, window_titles, x_session

TITLE = 'ML-WINDOW-BELOW'
SCREEN = (1280, 800)
POINTER_AWAY = (3, 3)   # far from any click point

# A maximised window that appends "<button> <x_root> <y_root>" to a file for every mouse press it receives. GTK adds a
# synthetic 2BUTTON_PRESS to the second of two quick clicks on one point: only the real presses are counted.
WINDOW_BELOW = f'''
import sys
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gdk, Gtk

log = sys.argv[1]
window = Gtk.Window(title={TITLE!r})
window.add_events(Gdk.EventMask.BUTTON_PRESS_MASK)
def on_press(widget, event):
    if event.type == Gdk.EventType.BUTTON_PRESS:
        with open(log, 'a') as f:
            f.write('%d %d %d\\n' % (event.button, event.x_root, event.y_root))
    return True
window.connect('button-press-event', on_press)
window.connect('destroy', Gtk.main_quit)
window.maximize()
window.show_all()
Gtk.main()
'''

# Runs inside the program's own interpreter (see run_gui). DELAY_MS emulates a window manager that takes that long
# to act on the minimise request; 0 leaves the real one alone.
CLICK_FIRST_STEP = '''
import os, subprocess, time
from gi.repository import Gdk

presses_on_launcher = []
def count_presses(event, data=None):        # every event of this process, before GTK handles it
    if event.type == Gdk.EventType.BUTTON_PRESS:
        presses_on_launcher.append([event.x_root, event.y_root])
    Gtk.main_do_event(event)
Gdk.event_handler_set(count_presses, None)

def pump_until(condition, seconds=20):
    end = time.monotonic() + seconds
    while not condition() and time.monotonic() < end:
        pump(20)
    return condition()

main = mod.VentanaPrincipal(); main.show_all(); pump_until(main.is_active)
minimised = lambda: bool(main.get_window().get_state() & Gdk.WindowState.ICONIFIED)
_, left, top = main.get_window().get_origin()
width, height = main.get_size()
x, y = left + width // 2, top + height // 2
stack = Gdk.Screen.get_default().get_window_stack()      # bottom to top
on_top = bool(stack) and stack[-1] == main.get_window()

subprocess.run(['xdotool', 'mousemove', *map(str, (x, y) if ON_POINT else AWAY)], check=True); pump(200)
if DELAY_MS:
    request = main.iconify
    main.iconify = lambda: GLib.timeout_add(DELAY_MS, lambda: (request(), False)[1])
action = {'nombre': 'Click first', 'pasos': [
    {'tipo': 'clic', 'x': x, 'y': y, 'coords_absolutas': True, 'activar_ventana': False, 'boton': '1'}]}
started = time.monotonic()
main._lanzar_accion(action)
pump_until(lambda: os.path.exists(LOG) and os.path.getsize(LOG) > 0, seconds=8)
elapsed = time.monotonic() - started
result = {'point': [x, y], 'on_top': on_top, 'presses_on_launcher': presses_on_launcher,
          'minimised': pump_until(minimised, seconds=5), 'elapsed': round(elapsed, 2)}
'''


@pytest.fixture
def own_x(sandbox):
    """`sandbox` pointed at an X server of its own (Xvfb + Openbox) instead of the one the suite shares."""
    with x_session(f'{SCREEN[0]}x{SCREEN[1]}x24') as display:
        sandbox.env['DISPLAY'] = display
        yield sandbox


@pytest.fixture
def window_below(own_x, tmp_path):
    """A maximised window under everything else; yields the file where it logs the mouse presses it receives."""
    log, errors = tmp_path / 'presses.log', tmp_path / 'below.err'
    with errors.open('w') as err:
        proc = subprocess.Popen([sys.executable, '-c', WINDOW_BELOW, str(log)], env=own_x.env,
                                stdout=subprocess.DEVNULL, stderr=err)
        try:
            def maximised():
                out = subprocess.run(['wmctrl', '-lG'], env=own_x.env, capture_output=True, text=True).stdout
                return any(line.split(None, 7)[7:] == [TITLE] and int(line.split()[4]) >= SCREEN[0] - 10
                           for line in out.splitlines() if len(line.split(None, 7)) == 8)
            assert wait_until(maximised, 20), (f'the window below did not appear maximised: {window_titles(own_x.env)} '
                                               f'{errors.read_text()[-500:]}')
            yield log
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()


@pytest.mark.parametrize('delay_ms, on_point', [(0, False), (600, False), (0, True)],
                         ids=['prompt_window_manager', 'window_manager_minimising_after_600_ms',
                              'pointer_already_on_the_click_point'])
def test_a_click_as_first_step_lands_on_the_window_below_not_on_the_program(own_x, window_below, delay_ms, on_point):
    # Slow manager: the minimise request is acted on 600 ms late, as on a loaded desktop. Without the wait of
    # _lanzar_accion the script clicks after about 170 ms, on Mi Lanzador, which is still in view.
    result = run_gui(own_x, f'LOG = {str(window_below)!r}\nDELAY_MS = {delay_ms}\nON_POINT = {on_point}\nAWAY = {POINTER_AWAY}\n',
                     CLICK_FIRST_STEP)
    x, y = result['point']
    received = window_below.read_text().splitlines() if window_below.exists() else []
    assert result['on_top'], f'the harness is void: Mi Lanzador is not the topmost window {result}'
    assert result['presses_on_launcher'] == [], f'the click landed on Mi Lanzador, still in view: {result}'
    assert received == [f'1 {x} {y}'], f'expected one left click at {x},{y} on the window below, got {received}: '\
                                       f'{result}'
    assert result['minimised'], result


@pytest.mark.parametrize('pointer_start', ['away', 'on_the_point'])
def test_clicks_on_the_same_point_do_not_wait_for_a_pointer_that_cannot_move(app, own_x, window_below, tmp_path, pointer_start):
    point = (SCREEN[0] // 2, SCREEN[1] // 2)
    step = {'tipo': 'clic', 'x': point[0], 'y': point[1], 'coords_absolutas': True, 'activar_ventana': False, 'boton': '1'}
    script = tmp_path / 'two_clicks.sh'
    script.write_text(app.generar_script_bash([step, step], 'two clicks'), encoding='utf-8')
    subprocess.run(['xdotool', 'mousemove', *map(str, point if pointer_start == 'on_the_point' else POINTER_AWAY)],
                   env=own_x.env, check=True)
    started = time.monotonic()
    done = subprocess.run(['bash', str(script)], env=own_x.env, capture_output=True, text=True, timeout=60)
    elapsed = time.monotonic() - started
    wait_until(lambda: window_below.exists() and len(window_below.read_text().splitlines()) >= 2, 5)
    received = window_below.read_text().splitlines() if window_below.exists() else []
    assert received == [f'1 {point[0]} {point[1]}'] * 2, f'{received} {done.stderr}'
    assert elapsed < 5, f'two clicks took {elapsed:.1f} s: each stalled move costs ~15 s'
