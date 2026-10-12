#!/usr/bin/env python3
import ast
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import types

import pytest

from conftest import run_gui

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = pathlib.Path(os.environ.get('MI_LANZADOR_TEST_SCRIPT') or ROOT / 'script' / 'mi-lanzador.sh')
PY = SCRIPT.read_text(encoding='utf-8').split("exec python3 - \"$@\" <<'PYEOF'\n", 1)[1].split('\nPYEOF', 1)[0]
TREE = ast.parse(PY)


def translations():
    for node in TREE.body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'TR_EN' for t in node.targets):
            return ast.literal_eval(node.value)
    raise AssertionError('TR_EN not found')


def text_width(text, pointsize=14):
    magick = shutil.which('magick') or shutil.which('convert')
    if not magick:
        return len(text) * 8
    cmd = [magick, '-background', 'none', '-fill', 'black', '-font', 'DejaVu-Sans', '-pointsize', str(pointsize),
           'label:' + text.replace('\n', ' '), '-format', '%w', 'info:']
    return int(subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True).strip())


def test_toolbar_fits_default_window_in_both_languages():
    d = translations()
    labels = {
        'es': ['Ejecutar', 'Crear acceso directo', 'Editar', 'Ver script generado', 'Eliminar'],
        'en': [d['Ejecutar'], d['Crear acceso directo'], d['Editar'], d['Ver script generado'], d['Eliminar']],
    }
    for lang, values in labels.items():
        total = sum(text_width(v) + 48 for v in values) + 4 * 8
        assert total < 948, (lang, total)


def test_language_button_and_header_text_remain_compact():
    d = translations()
    assert text_width('Mi Lanzador') < 180
    assert text_width(d['Automatiza tus accesos directos']) < 300
    assert 'self.btn_idioma.set_size_request(34, -1)' in SCRIPT.read_text(encoding='utf-8')


def test_long_help_texts_are_wrapped():
    src = SCRIPT.read_text(encoding='utf-8')
    for var in ('ayuda_catalogo', 'ayuda_manual', 'ayuda_doc', 'ayuda_nueva_ventana',
                'ayuda_comando', 'aviso_avanzado', 'ayuda', 'ayuda_activar'):
        assert f'{var}.set_line_wrap(True)' in src, var
    assert 'self.label_punto_detectado.set_line_wrap(True)' in src
    assert 'self.label_tecla_capturada.set_line_wrap(True)' in src


def test_single_line_toggle_labels_fit_the_main_window():
    d = translations()
    labels = [
        d['Colocar / organizar esta ventana justo después de abrirla'],
        d['Abrir con una aplicación instalada concreta (opcional)'],
        d['Abrir en una ventana nueva (si no, se abre como pestaña)'],
        d['Abrir como app (sin barra de direcciones; solo Chrome/Chromium/Brave)'],
        d['Activar/enfocar una ventana justo antes de hacer el clic'],
        d['Crear automáticamente un acceso directo en el Escritorio al guardar una acción nueva'],
        d['Mostrar notificaciones al ejecutar una acción'],
    ]
    for text in labels:
        assert text_width(text) < 900, (len(text), text_width(text), text)


def test_css_is_balanced_and_contains_the_existing_ui_classes():
    css_match = re.search(r'CSS = b"""(.*?)"""', PY, re.S)
    assert css_match
    css = css_match.group(1)
    assert css.count('{') == css.count('}')
    for selector in ('.titulo-form', 'button.suggested-action', 'headerbar', 'notebook > header.top'):
        assert selector in css


def test_window_shadow_keeps_its_geometry_when_the_window_loses_focus():
    """GTK sizes a client-decorated window's invisible frame from the shadow's offsets, blur and spread. If
    `:backdrop` changes them, the window is resized and moved on every minimize/restore (a visible shake): only
    the colour may differ. Openbox draws no client shadows, so this is checked on the CSS itself."""
    css = re.sub(r'/\*.*?\*/', '', re.search(r'CSS = b"""(.*?)"""', PY, re.S).group(1), flags=re.S)

    def geometry(selector):
        rule = re.search(r'(?m)^' + re.escape(selector) + r'\s*\{(.*?)\}', css, re.S).group(1)
        shadow = re.search(r'box-shadow:\s*([^;]+);', rule).group(1)
        return re.sub(r'rgba?\([^)]*\)', '', shadow).split()

    assert geometry('decoration:backdrop') == geometry('decoration')


def test_translation_growth_does_not_change_window_dimensions():
    src = SCRIPT.read_text(encoding='utf-8')
    assert 'self.set_default_size(980, 680)' in src
    assert 'self.set_default_size(640, 560)' in src
    assert 'dialogo.set_default_size(720, 520)' in src


# Draws the program's own CSS on a HeaderBar with the two buttons the window puts there and measures, on the
# rendered pixels, the contrast between the button's background and its text (the CSS makes the text white).
HEADERBAR_PROBE = r"""
import json, sys, time
import gi
gi.require_version('Gtk', '3.0'); gi.require_version('Gdk', '3.0')
from gi.repository import Gdk, Gtk

settings = Gtk.Settings.get_default()
settings.set_property('gtk-theme-name', sys.argv[2])
settings.set_property('gtk-application-prefer-dark-theme', sys.argv[1] == 'dark')
provider = Gtk.CssProvider()
provider.load_from_data(sys.stdin.read().encode())
Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_USER)

win = Gtk.OffscreenWindow()
bar = Gtk.HeaderBar()
bar.set_show_close_button(True)
bar.props.title = 'Mi Lanzador'
buttons = {'L': Gtk.Button(label='L'), '+': Gtk.Button()}
buttons['L'].set_size_request(34, -1)
buttons['+'].add(Gtk.Image.new_from_icon_name('list-add-symbolic', Gtk.IconSize.BUTTON))
for button in buttons.values():
    bar.pack_end(button)
win.add(bar)
win.set_default_size(600, 60)
win.show_all()


def settle():
    for _ in range(2):  # the frame clock redraws on its own schedule: give it time, then force one more pass
        for _ in range(30):
            while Gtk.events_pending():
                Gtk.main_iteration()
            time.sleep(0.02)
        win.queue_draw()


def luminance(rgb):
    lin = [(v / 255 / 12.92) if v / 255 <= 0.03928 else ((v / 255 + 0.055) / 1.055) ** 2.4 for v in rgb]
    return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]


result = {}
for state, flag in (('normal', Gtk.StateFlags.NORMAL), ('hover', Gtk.StateFlags.PRELIGHT)):
    for button in buttons.values():
        button.set_state_flags(flag, True)
    settle()
    pixbuf = win.get_pixbuf()
    for name, button in buttons.items():
        box = button.get_allocation()  # a few pixels inside its left edge: past the border, clear of the icon
        offset = (box.y + box.height // 2) * pixbuf.get_rowstride() + (box.x + 5) * pixbuf.get_n_channels()
        background = list(pixbuf.get_pixels()[offset:offset + 3])
        color = button.get_style_context().get_color(button.get_state_flags())
        text = [round(color.red * 255), round(color.green * 255), round(color.blue * 255)]
        light, dark = sorted((luminance(background), luminance(text)), reverse=True)
        result[name + '/' + state] = round((light + 0.05) / (dark + 0.05), 2)
print(json.dumps(result))
"""


def installed_theme(name):
    if name == 'Adwaita':   # built into GTK: it has no folder
        return True
    folders = ('/usr/share/themes', os.path.expanduser('~/.themes'), os.path.expanduser('~/.local/share/themes'))
    return any((pathlib.Path(folder) / name / 'gtk-3.0').is_dir() for folder in folders)


# GTK theme and light/dark preference of the tests that depend on the theme. Mint-Y is Cinnamon's default; its tests skip
# when it is not installed.
THEMES = [('Adwaita', 'light'), ('Adwaita', 'dark'), ('Mint-Y', 'light'), ('Mint-Y-Dark', 'dark')]


@pytest.mark.parametrize('theme, variant', THEMES)
def test_headerbar_buttons_stay_readable_on_each_theme(x11, theme, variant):
    """The CSS paints the title-bar text white; with no background of its own, Adwaita light draws light-grey
    buttons under it (contrast 1.1). 4.5 is the WCAG AA minimum for normal text. Mint-Y (Cinnamon's default)
    is checked when installed and skipped otherwise."""
    if not installed_theme(theme):
        pytest.skip(f'GTK theme {theme} is not installed')
    css = re.search(r'CSS = b"""(.*?)"""', PY, re.S).group(1)
    env = {k: v for k, v in os.environ.items() if k != 'GTK_THEME'}
    env.update(DISPLAY=x11, GDK_BACKEND='x11')
    done = subprocess.run([sys.executable, '-c', HEADERBAR_PROBE, variant, theme], input=css, env=env,
                          capture_output=True, text=True, timeout=60)
    assert done.returncode == 0, done.stderr
    contrast = json.loads(done.stdout.strip().splitlines()[-1])
    assert set(contrast) == {'L/normal', 'L/hover', '+/normal', '+/hover'}
    assert {name: value for name, value in contrast.items() if value < 4.5} == {}, contrast


# The real window, the real pointer: hovering the checked tab must not paint its label in another colour than the tab
# around it, and the theme's own tab indicator (Adwaita draws a blue line) must not show above the purple one the CSS
# draws. Everything is read from the pixels of the window on screen.
TAB_PROBE = r"""
sys.excepthook = sys.__excepthook__   # the program's own hook opens a dialog that would hang this process
theme, variant = {theme!r}, {variant!r}
settings = Gtk.Settings.get_default()
settings.set_property('gtk-theme-name', theme)
settings.set_property('gtk-application-prefer-dark-theme', variant == 'dark')
main = mod.VentanaPrincipal()
main.show_all()
main.move(40, 40)
pump(1500)
label = main.notebook.get_tab_label(main.notebook.get_nth_page(0))   # «Mis accesos», the checked tab at start
lx, ly = label.translate_coordinates(main, 0, 0)
size = label.get_allocation()
window = main.get_window()
origin = window.get_origin()[-2:]


def grab():
    pump(600)
    pixbuf = mod.Gdk.pixbuf_get_from_window(window, 0, 0, window.get_width(), window.get_height())
    return pixbuf, pixbuf.get_rowstride(), pixbuf.get_n_channels(), pixbuf.get_pixels()


def pixel(shot, x, y):
    pixbuf, stride, channels, data = shot
    offset = y * stride + x * channels
    return list(data[offset:offset + 3])


result = {{}}
for state, pointer in (('rest', (origin[0] + 5, origin[1] + 5)),
                       ('hover', (origin[0] + lx + size.width // 2, origin[1] + ly + size.height // 2))):
    subprocess.run(['xdotool', 'mousemove', str(pointer[0]), str(pointer[1])], check=True)
    shot = grab()
    result[state] = {{
        'around': pixel(shot, lx - 6, ly + size.height // 2),
        'label_top_left': pixel(shot, lx + 1, ly + 1),
        'label_top_right': pixel(shot, lx + size.width - 2, ly + 1),
        'column': [pixel(shot, lx + size.width // 2, ly + size.height + dy) for dy in range(0, 24)],
    }}
main.destroy()
"""


def theme_sandbox(x11, tmp_path):
    """An isolated HOME and an environment that lets the test pick the GTK theme (no GTK_THEME)."""
    home = tmp_path / 'home'
    home.mkdir()
    return types.SimpleNamespace(
        config=home / '.config' / 'mi-lanzador',
        env={**{k: v for k, v in os.environ.items() if k != 'GTK_THEME'}, 'HOME': str(home), 'DISPLAY': x11,
             'GDK_BACKEND': 'x11'})


def tab_colours(x11, tmp_path, theme, variant):
    return run_gui(theme_sandbox(x11, tmp_path), 'import subprocess\n', TAB_PROBE.format(theme=theme, variant=variant),
                   timeout=90)


def close_to(a, b, tolerance=4):
    return all(abs(x - y) <= tolerance for x, y in zip(a, b))


@pytest.mark.parametrize('theme, variant', THEMES)
def test_checked_tab_is_one_colour_with_a_single_underline_on_each_theme(x11, tmp_path, theme, variant):
    if not installed_theme(theme):
        pytest.skip(f'GTK theme {theme} is not installed')
    result = tab_colours(x11, tmp_path, theme, variant)
    purple = [0x6c, 0x5c, 0xe7]
    for state, seen in result.items():
        around = seen['around']
        assert close_to(seen['label_top_left'], around) and close_to(seen['label_top_right'], around), (state, seen)
        column = seen['column']
        first = next((i for i, colour in enumerate(column) if close_to(colour, purple, 8)), None)
        assert first is not None, (state, column)   # the CSS underline is there
        stray = [colour for colour in column[:first] if not close_to(colour, around)]
        assert stray == [], (state, 'the theme draws something above the underline', stray)


# The «Add step» dialog warns (red text) when xdotool/wmctrl are missing or the session is Wayland. The theme paints the
# dialog, so a fixed text colour is readable on one background and not on the other (2.1:1 on Adwaita dark): the warning
# carries its own background, as the form titles do. Measured on the pixels of the real dialog.
WARNING_PROBE = r"""
sys.excepthook = sys.__excepthook__   # the program's own hook opens a dialog that would hang this process
theme, variant = {theme!r}, {variant!r}
settings = Gtk.Settings.get_default()
settings.set_property('gtk-theme-name', theme)
settings.set_property('gtk-application-prefer-dark-theme', variant == 'dark')
mod.SESION_WAYLAND = True   # the dialog reads it when it is built
main = mod.VentanaPrincipal()
main.show_all()
pump(300)
dialog = mod.DialogoPaso(main, [])
dialog.show_all()
dialog.move(40, 40)
pump(1500)


def labels(widget):
    yield widget
    if isinstance(widget, Gtk.Container):
        for child in widget.get_children():
            yield from labels(child)


warning = next(w for w in labels(dialog) if isinstance(w, Gtk.Label) and w.get_style_context().has_class('aviso-x11'))
colour = warning.get_style_context().get_color(Gtk.StateFlags.NORMAL)
text = [round(colour.red * 255), round(colour.green * 255), round(colour.blue * 255)]
window = dialog.get_window()
pixbuf = mod.Gdk.pixbuf_get_from_window(window, 0, 0, window.get_width(), window.get_height())
x0, y0 = warning.translate_coordinates(dialog, 0, 0)
box = warning.get_allocation()
row = (y0 + 1) * pixbuf.get_rowstride()   # the top edge of the label: no glyph reaches it
seen = {{}}
for x in range(x0 + box.width // 4, x0 + box.width - box.width // 4, 7):   # away from the rounded corners
    offset = row + x * pixbuf.get_n_channels()
    pixel = tuple(pixbuf.get_pixels()[offset:offset + 3])
    seen[pixel] = seen.get(pixel, 0) + 1
background = list(max(seen, key=seen.get))   # the most frequent colour along an empty row is the background


def luminance(rgb):
    lin = [(v / 255 / 12.92) if v / 255 <= 0.03928 else ((v / 255 + 0.055) / 1.055) ** 2.4 for v in rgb]
    return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]


light, dark = sorted((luminance(background), luminance(text)), reverse=True)
result = {{'text': text, 'background': background, 'contrast': round((light + 0.05) / (dark + 0.05), 2)}}
dialog.destroy()
main.destroy()
"""


@pytest.mark.parametrize('theme, variant', THEMES)
def test_dialog_warning_stays_readable_on_each_theme(x11, tmp_path, theme, variant):
    if not installed_theme(theme):
        pytest.skip(f'GTK theme {theme} is not installed')
    seen = run_gui(theme_sandbox(x11, tmp_path), WARNING_PROBE.format(theme=theme, variant=variant), timeout=90)
    assert seen['contrast'] >= 4.5, seen   # WCAG AA for normal text


# «Settings» is a tab of the main window, not a dialog, and the theme paints its page (the notebook has its own
# background): a text colour or a page background fixed in the CSS would read on one theme and vanish on the dark one.
# Every label of the real tab, and the text of its browser combo, is measured against the pixels behind it.
SETTINGS_PROBE = r"""
sys.excepthook = sys.__excepthook__   # the program's own hook opens a dialog that would hang this process
theme, variant = {theme!r}, {variant!r}
settings = Gtk.Settings.get_default()
settings.set_property('gtk-theme-name', theme)
settings.set_property('gtk-application-prefer-dark-theme', variant == 'dark')
main = mod.VentanaPrincipal()
main.show_all()
main.move(40, 40)
main.notebook.set_current_page(2)   # «Settings»
pump(1500)
window = main.get_window()
pixbuf = mod.Gdk.pixbuf_get_from_window(window, 0, 0, window.get_width(), window.get_height())
pixels, stride, channels = pixbuf.get_pixels(), pixbuf.get_rowstride(), pixbuf.get_n_channels()


def texts(widget):   # forall, not get_children(): only forall reaches the cell view inside a combo
    if isinstance(widget, Gtk.CellView) or (isinstance(widget, Gtk.Label) and widget.get_text()):
        if widget.get_mapped():
            yield widget
    if isinstance(widget, Gtk.Container):
        children = []
        widget.forall(children.append)
        for child in children:
            yield from texts(child)


def luminance(rgb):
    lin = [(v / 255 / 12.92) if v / 255 <= 0.03928 else ((v / 255 + 0.055) / 1.055) ** 2.4 for v in rgb]
    return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]


def behind(widget):
    # The colour behind the text, read on the top and on the bottom row of the widget's box: a glyph rarely reaches them,
    # and a button's gradient is not the same on both. (The most frequent colour of the whole box is wrong on a small
    # label over a gradient: the letters win.)
    x0, y0 = widget.translate_coordinates(main, 0, 0)
    box = widget.get_allocation()
    colours = []
    for y in (y0 + 1, y0 + box.height - 2):
        seen = {{}}
        for x in range(max(x0, 0), min(x0 + box.width, pixbuf.get_width()), 2):
            offset = y * stride + x * channels
            pixel = tuple(pixels[offset:offset + 3])
            seen[pixel] = seen.get(pixel, 0) + 1
        colours.append(max(seen, key=seen.get))
    return colours


rows = []
for widget in texts(main.notebook.get_nth_page(2)):
    colour = widget.get_style_context().get_color(widget.get_state_flags())
    worst = 21.0
    for shade in behind(widget):
        text = [c * 255 * colour.alpha + b * (1 - colour.alpha)   # a translucent text colour blends with what is behind
                for c, b in zip((colour.red, colour.green, colour.blue), shade)]
        light, dark = sorted((luminance(shade), luminance(text)), reverse=True)
        worst = min(worst, (light + 0.05) / (dark + 0.05))
    rows.append({{'kind': type(widget).__name__, 'text': widget.get_text() if isinstance(widget, Gtk.Label) else '',
                  'contrast': round(worst, 2)}})
result = {{'rows': rows}}
main.destroy()
"""


@pytest.mark.parametrize('theme, variant', THEMES)
def test_settings_tab_text_stays_readable_on_each_theme(x11, tmp_path, theme, variant):
    if not installed_theme(theme):
        pytest.skip(f'GTK theme {theme} is not installed')
    rows = run_gui(theme_sandbox(x11, tmp_path), SETTINGS_PROBE.format(theme=theme, variant=variant),
                   timeout=90)['rows']
    # The walk went all the way down: the combo's own text and the button inside the grid were measured.
    assert any(row['kind'] == 'CellView' for row in rows) and any('Save settings' in row['text'] for row in rows), rows
    assert {row['text'] or row['kind']: row['contrast'] for row in rows if row['contrast'] < 4.5} == {}, rows   # WCAG AA
