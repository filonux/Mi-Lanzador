"""Walks the REAL widget tree (PyGObject + Xvfb, in a fresh interpreter) and checks the language of every visible text.

The static AST checks in test_i18n.py only see calls such as set_text(); a literal handed to a helper that builds
the widget (e.g. the buttons of the first tab) slips through them, so the tree itself is inspected here."""
import json
import re
import subprocess
import sys

import pytest

from conftest import SCRIPT, HEREDOC_OPEN, embedded_python, run_gui

WALKER = r'''
import json, pathlib, sys, types
script = pathlib.Path(sys.argv[1])
src = script.read_text(encoding='utf-8').split(sys.argv[2], 1)[1].split('\nPYEOF', 1)[0]
mod = types.ModuleType('m'); mod.__file__ = str(script)
exec(compile(src, str(script), 'exec'), mod.__dict__)
Gtk = mod.Gtk
texts = set()
def walk(w):
    if isinstance(w, Gtk.Label): texts.add(w.get_label())
    if isinstance(w, Gtk.Entry): texts.add(w.get_placeholder_text() or '')
    if isinstance(w, Gtk.Frame): texts.add(w.get_label() or '')
    if isinstance(w, Gtk.ComboBoxText): texts.update(row[0] for row in w.get_model())
    if isinstance(w, Gtk.TreeView): texts.update(c.get_title() for c in w.get_columns())
    texts.add(w.get_tooltip_text() or '')
    if isinstance(w, Gtk.Container):
        for child in w.get_children(): walk(child)
main = mod.VentanaPrincipal()
dialog = mod.DialogoPaso(main, [])
texts.update((main.get_title(), dialog.get_title()))
for window in (main, main.get_titlebar(), dialog): walk(window)
print(json.dumps({'texts': sorted(texts - {''}), 'tr': mod.TR_EN}))
'''


@pytest.mark.parametrize('lang', ['en', 'es'])
def test_no_visible_text_is_left_in_the_wrong_language(sandbox, lang):
    env = {**sandbox.env, 'MI_LANZADOR_IDIOMA': lang, 'MI_LANZADOR_CONFIG_DIR': str(sandbox.config)}
    out = subprocess.run([sys.executable, '-c', WALKER, str(SCRIPT), HEREDOC_OPEN], env=env,
                         capture_output=True, text=True, timeout=60)
    assert out.returncode == 0, out.stderr[-2000:]
    data = json.loads(out.stdout.strip().splitlines()[-1])
    pairs = {source: english for source, english in data['tr'].items() if source != english}
    wrong = sorted(set(data['texts']) & (set(pairs) if lang == 'en' else set(pairs.values())))
    assert len(data['texts']) > 100 and not wrong, wrong


@pytest.mark.parametrize('lang, own, other', [('es', 'Español', 'English'), ('en', 'English', 'Español')])
def test_settings_show_the_name_of_the_selected_language(sandbox, lang, own, other):
    result = run_gui(sandbox, '''
        main = mod.VentanaPrincipal(); main.show_all(); pump(300)
        labels = []
        def walk(w):
            if isinstance(w, Gtk.Label): labels.append(w.get_label())
            if isinstance(w, Gtk.Container):
                for child in w.get_children(): walk(child)
        walk(main); walk(main.get_titlebar())
        result = {'labels': labels}
    ''', lang=lang)
    assert own in result['labels'] and other not in result['labels'], result


@pytest.mark.parametrize('lang', ['es', 'en'])
def test_settings_about_text_starts_with_the_program_version(sandbox, lang):
    result = run_gui(sandbox, '''
        main = mod.VentanaPrincipal(); main.show_all(); pump(300)
        labels = []
        def walk(w):
            if isinstance(w, Gtk.Label): labels.append(w.get_text())
            if isinstance(w, Gtk.Container):
                for child in w.get_children(): walk(child)
        walk(main)
        result = {'version': mod.VERSION, 'labels': labels}
    ''', lang=lang)
    version = result['version']
    about = [text for text in result['labels'] if 'Filonux' in text]
    assert re.fullmatch(r'\d+\.\d+\.\d+', version), version
    assert len(about) == 1 and about[0].startswith(f'Mi Lanzador {version} · '), result
    assert '{' not in about[0], about


def test_the_script_header_names_the_same_version_as_the_version_constant():
    version = re.search(r"^VERSION = '([^']+)'", embedded_python(), re.M).group(1)
    header = SCRIPT.read_text(encoding='utf-8').splitlines()[:40]
    assert any(line.startswith(f'#  MI LANZADOR {version} ') for line in header), (version, header[:5])
