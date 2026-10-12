"""«Elegir punto…»: la ventana bajo el punto es la real, no el marco que le pone el gestor de ventanas."""
from __future__ import annotations

import subprocess
import types

from conftest import require_tools, wait_until


def fake_x(monkeypatch, app, *, xwininfo=True):
    """xdotool/xwininfo falsos: el ratón señala el marco 100 (sin título), cuyo hijo 200 es la ventana real."""
    nombres = {'100': '', '200': 'Notes (draft)'}
    geometrias = {'100': 'X=80\nY=60\n', '200': 'X=82\nY=100\n'}

    def run(cmd, *a, **k):
        if cmd[:2] == ['xdotool', 'getmouselocation']:
            return types.SimpleNamespace(stdout='X=300\nY=300\nWINDOW=100\n')
        if cmd[:2] == ['xdotool', 'getwindowname']:
            return types.SimpleNamespace(stdout=nombres.get(str(int(cmd[2], 0)), '') + '\n')
        if cmd[:2] == ['xdotool', 'getwindowgeometry']:
            return types.SimpleNamespace(stdout=geometrias[str(int(cmd[3], 0))])
        if cmd[0] == 'xwininfo':
            hijas = {'100': '     2 children:\n     0x64 (has no name): ()  302x20+0+0  +80+60\n     0xc8 "Notes (draft)": ("a" "A")  300x120+2+40  +82+100\n'}
            return types.SimpleNamespace(stdout='xwininfo: Window id: ' + cmd[3] + '\n\n' + hijas.get(str(int(cmd[3], 0)), '     0 children:\n'))
        raise AssertionError(cmd)

    monkeypatch.setattr(app.subprocess, 'run', run)
    monkeypatch.setattr(app.shutil, 'which', lambda n: '/fake/' + n if n != 'xwininfo' or xwininfo else None)


def test_the_window_manager_frame_is_replaced_by_the_window_inside_it(app, monkeypatch):
    fake_x(monkeypatch, app)
    assert app._resolver_ventana_bajo_punto(300, 300) == (218, 200, 'Notes (draft)')   # relativo a la ventana, no al marco


def test_without_xwininfo_the_frame_is_kept_and_nothing_breaks(app, monkeypatch):
    fake_x(monkeypatch, app, xwininfo=False)
    assert app._resolver_ventana_bajo_punto(300, 300) == (220, 240, '')


def test_a_window_without_children_and_without_title_gives_an_empty_title(app, monkeypatch):
    fake_x(monkeypatch, app)
    monkeypatch.setattr(app, '_hijas_de_ventana_x', lambda win: [])
    assert app._resolver_ventana_bajo_punto(300, 300)[2] == ''


def test_with_a_real_window_manager_the_title_and_relative_point_are_those_of_the_window(app, monkeypatch, x11):
    """X, openbox, xdotool y xmessage reales (el título precargado en «Buscar título» salía vacío)."""
    for tool in ('xdotool', 'xmessage', 'xwininfo'):
        require_tools(tool)
    monkeypatch.setenv('DISPLAY', x11)
    ventana = subprocess.Popen(['xmessage', '-timeout', '60', '-title', 'Notes (draft)', '-geometry', '300x120+200+150', 'hola'],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        def cliente():
            return subprocess.run(['xdotool', 'search', '--name', r'Notes \(draft\)'], capture_output=True, text=True).stdout.split()
        assert wait_until(lambda: len(cliente()) == 1, 15), cliente()
        geo = dict(l.split('=') for l in subprocess.run(['xdotool', 'getwindowgeometry', '--shell', cliente()[0]],
                                                        capture_output=True, text=True).stdout.split())
        x, y = int(geo['X']) + 58, int(geo['Y']) + 7
        subprocess.run(['xdotool', 'mousemove', str(x), str(y)], check=True)
        assert wait_until(lambda: app._resolver_ventana_bajo_punto(x, y) == (58, 7, 'Notes (draft)'), 5), app._resolver_ventana_bajo_punto(x, y)
    finally:
        ventana.kill()
