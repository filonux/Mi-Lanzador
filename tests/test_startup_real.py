"""Real start-up tests: the actual script, real GTK3, a real X server.

Regression guard for the crash `NameError: name 'CONFIG_DIR' is not defined`
that made the translated program die before showing any window while the
stub-based suite stayed green (the harness used to pre-seed CONFIG_DIR).
"""
import builtins
import ast
import os
import re
import subprocess

import pytest

from conftest import SCRIPT, bash_part, embedded_python, launch_gui, stop_gui, wait_for_window


@pytest.mark.parametrize('lang', ['es', 'en'])
def test_real_gui_starts_maps_main_window_and_exits_cleanly(sandbox, lang):
    proc = launch_gui(sandbox, MI_LANZADOR_LANG=lang)
    try:
        assert wait_for_window(sandbox.env, 'Mi Lanzador', proc), 'main window never appeared'
        assert proc.poll() is None, 'the program died right after mapping its window'
    finally:
        code = stop_gui(proc, sandbox.env)
    output = proc.stdout.read()
    assert 'Traceback' not in output and 'NameError' not in output, output
    assert code == 0, (code, output)


def test_a_hand_edited_actions_file_with_bad_steps_does_not_stop_the_window_from_opening(sandbox):
    sandbox.config.mkdir(parents=True)
    (sandbox.config / 'acciones.json').write_text('[{"id": "a1", "nombre": "Rota", "pasos": null}]', encoding='utf-8')
    proc = launch_gui(sandbox)
    try:
        assert wait_for_window(sandbox.env, 'Mi Lanzador', proc), 'main window never appeared'
    finally:
        code = stop_gui(proc, sandbox.env)
    output = proc.stdout.read()
    assert 'Traceback' not in output and code == 0, (code, output)


def test_first_run_installs_itself_launcher_and_icon_and_the_window_uses_that_icon(sandbox):
    proc = launch_gui(sandbox)
    try:
        assert wait_for_window(sandbox.env, 'Mi Lanzador', proc)
        props = subprocess.run(['xprop', '-name', 'Mi Lanzador', '_NET_WM_ICON'], env=sandbox.env,
                               capture_output=True, text=True).stdout
    finally:
        stop_gui(proc, sandbox.env)
    assert (sandbox.app_dir / 'mi-lanzador.sh').is_file()
    assert (sandbox.applications / 'mi-lanzador.desktop').is_file()
    assert (sandbox.desktop / 'Mi Lanzador.desktop').is_file()
    assert (sandbox.icons / 'mi-lanzador.svg').is_file()
    assert 'not found' not in props, 'the main window did not pick up the installed icon (needs librsvg2-common)'


def test_every_place_that_names_the_application_icon_agrees():
    """bash (.desktop, installed file) and Python (window, notifications) must name the same theme icon."""
    bash = bash_part()
    names = set(re.findall(r'^Icon=(.+)$', bash, re.M)) | set(re.findall(r'/([\w-]+)\.svg"', bash))
    for node in ast.walk(ast.parse(embedded_python())):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
            if node.func.attr == 'set_icon_name':
                names.add(node.args[0].value)
            elif node.func.attr == 'new' and len(node.args) == 3:      # Notify.Notification.new(title, text, icon)
                names.add(node.args[2].value)
        elif isinstance(node, ast.List) and node.elts and getattr(node.elts[0], 'value', None) == 'notify-send':
            args = [getattr(e, 'value', None) for e in node.elts]
            names.add(args[args.index('-i') + 1] if '-i' in args else None)
    assert names == {'mi-lanzador'}, names


def test_headless_run_of_unknown_action_does_not_crash(sandbox):
    result = subprocess.run(['bash', str(SCRIPT), '--ejecutar', 'does-not-exist'], env=sandbox.env,
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr
    assert 'Traceback' not in result.stderr


def _loaded_names(node):
    """Names read when `node` is EXECUTED. Function bodies run later (skipped);
    decorators and default values run at definition time (kept)."""
    stack = [node]
    while stack:
        cur = stack.pop()
        if isinstance(cur, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
            stack.extend(getattr(cur, 'decorator_list', []))
            stack.extend(d for d in cur.args.defaults + cur.args.kw_defaults if d)
            continue
        if isinstance(cur, ast.Name) and isinstance(cur.ctx, ast.Load):
            yield cur.id, cur.lineno
        stack.extend(ast.iter_child_nodes(cur))


def _bound_names(node):
    for cur in ast.walk(node):
        if isinstance(cur, ast.Name) and isinstance(cur.ctx, (ast.Store, ast.Del)):
            yield cur.id
        elif isinstance(cur, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            yield cur.name
        elif isinstance(cur, (ast.Import, ast.ImportFrom)):
            for alias in cur.names:
                yield (alias.asname or alias.name).split('.')[0]
        elif isinstance(cur, ast.ExceptHandler) and cur.name:
            yield cur.name


def test_module_level_code_never_reads_a_name_before_it_is_defined():
    """Catches the whole class of bug behind the CONFIG_DIR crash."""
    defined = set(dir(builtins)) | {'__name__', '__file__'}
    problems = []
    for stmt in ast.parse(embedded_python()).body:
        for name, line in _loaded_names(stmt):
            if name not in defined and name not in set(_bound_names(stmt)):
                problems.append(f'line {line}: {name!r} used before being defined')
        defined.update(_bound_names(stmt) if not isinstance(stmt, (ast.FunctionDef, ast.ClassDef)) else [stmt.name])
    assert not problems, problems


def test_every_gtk_gdk_glib_name_the_program_uses_exists_in_the_real_library():
    """A name that GTK3 lacks (e.g. Gdk.ModifierType.ALT_MASK, which only GTK4 has) raises AttributeError on first use.
    Stub-based tests cannot see it, and it only surfaced when someone pressed a key in the real window."""
    import gi
    gi.require_version('Gtk', '3.0')
    gi.require_version('Gdk', '3.0')
    gi.require_version('GdkPixbuf', '2.0')
    from gi.repository import Gdk, GdkPixbuf, GLib, Gtk
    roots = {'Gtk': Gtk, 'Gdk': Gdk, 'GLib': GLib, 'GdkPixbuf': GdkPixbuf}   # Notify is optional in the program
    missing = []
    for node in ast.walk(ast.parse(embedded_python())):
        if not isinstance(node, ast.Attribute):
            continue
        parts, base = [], node
        while isinstance(base, ast.Attribute):
            parts.append(base.attr)
            base = base.value
        if isinstance(base, ast.Name) and base.id in roots:
            target = roots[base.id]
            for part in reversed(parts):
                target = getattr(target, part, None)
                if target is None:
                    missing.append(f'line {node.lineno}: {base.id}.{".".join(reversed(parts))}')
                    break
    assert not missing, sorted(set(missing))


# A stand-in for PyGObject, found first through PYTHONPATH: `require_version` fails for the namespace named in
# FAKE_GI_WITHOUT (as with a missing typelib), importing it fails when FAKE_GI_ABSENT is set (python3-gi not installed),
# and loading the library itself (`gi.repository`) leaves a marker file.
FAKE_GI = '''
import os
if os.environ.get('FAKE_GI_ABSENT'):
    raise ImportError("No module named 'gi'")

def require_version(namespace, version):
    if namespace == os.environ.get('FAKE_GI_WITHOUT'):
        raise ValueError('Namespace %s not available for version %s' % (namespace, version))
'''


@pytest.fixture
def fake_gi(tmp_path):
    package = tmp_path / 'fake' / 'gi'
    (package / 'repository').mkdir(parents=True)
    (package / '__init__.py').write_text(FAKE_GI, encoding='utf-8')
    (package / 'repository' / '__init__.py').write_text(
        "import pathlib\npathlib.Path(__file__).parent.parent.joinpath('library_loaded').touch()\n", encoding='utf-8')
    return package


@pytest.mark.parametrize('missing, available', [
    ({}, True),
    ({'FAKE_GI_WITHOUT': 'Gtk'}, False),
    ({'FAKE_GI_WITHOUT': 'GdkPixbuf'}, False),
    ({'FAKE_GI_ABSENT': '1'}, False),
])
def test_start_up_gtk_check_looks_for_the_typelibs_without_loading_the_library(fake_gi, missing, available):
    function = re.search(r'^python_gtk_disponible\(\) \{\n.*?^\}\n', bash_part(), re.M | re.S).group(0)
    result = subprocess.run(['bash', '-c', function + 'python_gtk_disponible'], capture_output=True, text=True,
                            env={**os.environ, 'PYTHONPATH': str(fake_gi.parent), **missing}, timeout=30)
    assert (result.returncode == 0) is available, result
    assert not (fake_gi / 'library_loaded').exists(), 'the check loaded the whole GTK library'


def test_without_the_gtk_typelib_the_program_stops_at_start_up_and_says_how_to_install_it(sandbox, fake_gi):
    result = subprocess.run(['bash', str(SCRIPT)], capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL,
                            env={**sandbox.env, 'PYTHONPATH': str(fake_gi.parent), 'FAKE_GI_WITHOUT': 'Gtk'})
    assert result.returncode == 1, result
    assert 'Python GTK dependencies are missing' in result.stderr and 'sudo apt install python3-gi' in result.stderr, result
    assert 'Traceback' not in result.stderr, result
