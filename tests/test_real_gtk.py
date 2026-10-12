#!/usr/bin/env python3
"""Real GTK3 smoke tests without PyGObject.

The application uses PyGObject, which is unavailable in the audit image.
These tests therefore exercise the *real GTK3 shared library* through ctypes
under a private Xvfb display. They deliberately do not pretend to execute the
Python/GTK application itself; they validate the toolkit contract used by the
translated UI: UTF-8 labels, buttons, combo-box IDs/text, markup and real text
layout/size negotiation.
"""
from __future__ import annotations

import ast
import ctypes
from ctypes import POINTER, c_bool, c_char_p, c_int, c_void_p
import os
from pathlib import Path
import shutil
import subprocess
import time

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path(os.environ.get('MI_LANZADOR_TEST_SCRIPT') or ROOT / 'script' / 'mi-lanzador.sh')


def embedded_python() -> str:
    text = SCRIPT.read_text(encoding="utf-8")
    return text.split('exec python3 - "$@" <<\'PYEOF\'\n', 1)[1].split("\nPYEOF", 1)[0]


def literal_assignment(name: str):
    tree = ast.parse(embedded_python())
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(
            isinstance(target, ast.Name) and target.id == name for target in node.targets
        ):
            return ast.literal_eval(node.value)
    raise AssertionError(f"Missing literal assignment: {name}")


@pytest.fixture(scope="module")
def real_gtk():
    if shutil.which("Xvfb") is None:
        pytest.fail("Xvfb is required for real GTK tests")
    try:
        gtk = ctypes.CDLL("libgtk-3.so.0")
        gobject = ctypes.CDLL("libgobject-2.0.so.0")
        glib = ctypes.CDLL("libglib-2.0.so.0")
    except OSError as exc:
        pytest.fail(f"GTK3 runtime is unavailable: {exc}")

    display_num = 126
    while Path(f"/tmp/.X11-unix/X{display_num}").exists():
        display_num += 1
    display = f":{display_num}"
    proc = subprocess.Popen(
        ["Xvfb", display, "-screen", "0", "1280x800x24", "-nolisten", "tcp"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env={**os.environ},
    )
    try:
        for _ in range(50):
            if proc.poll() is not None:
                pytest.fail("Xvfb terminated while starting")
            if Path(f"/tmp/.X11-unix/X{display_num}").exists():
                break
            time.sleep(0.02)
        else:
            pytest.fail("Xvfb did not become ready")

        os.environ["DISPLAY"] = display

        gtk.gtk_init_check.argtypes = [POINTER(c_int), POINTER(c_void_p)]
        gtk.gtk_init_check.restype = c_bool
        argc = c_int(0)
        argv = c_void_p()
        assert gtk.gtk_init_check(ctypes.byref(argc), ctypes.byref(argv))

        # Minimal real GTK3 ABI used below. No PyGObject shim is involved.
        gtk.gtk_window_new.argtypes = [c_int]
        gtk.gtk_window_new.restype = c_void_p
        gtk.gtk_window_set_default_size.argtypes = [c_void_p, c_int, c_int]
        gtk.gtk_window_get_default_size.argtypes = [c_void_p, POINTER(c_int), POINTER(c_int)]
        gtk.gtk_label_new.argtypes = [c_char_p]
        gtk.gtk_label_new.restype = c_void_p
        gtk.gtk_label_get_label.argtypes = [c_void_p]
        gtk.gtk_label_get_label.restype = c_char_p
        gtk.gtk_label_set_markup.argtypes = [c_void_p, c_char_p]
        gtk.gtk_button_new_with_label.argtypes = [c_char_p]
        gtk.gtk_button_new_with_label.restype = c_void_p
        gtk.gtk_button_get_label.argtypes = [c_void_p]
        gtk.gtk_button_get_label.restype = c_char_p
        gtk.gtk_combo_box_text_new.restype = c_void_p
        gtk.gtk_combo_box_text_append.argtypes = [c_void_p, c_char_p, c_char_p]
        gtk.gtk_combo_box_set_active_id.argtypes = [c_void_p, c_char_p]
        gtk.gtk_combo_box_get_active_id.argtypes = [c_void_p]
        gtk.gtk_combo_box_get_active_id.restype = c_char_p
        gtk.gtk_combo_box_text_get_active_text.argtypes = [c_void_p]
        gtk.gtk_combo_box_text_get_active_text.restype = c_void_p
        gtk.gtk_widget_get_preferred_width.argtypes = [c_void_p, POINTER(c_int), POINTER(c_int)]
        gtk.gtk_widget_show_all.argtypes = [c_void_p]
        gtk.gtk_widget_destroy.argtypes = [c_void_p]
        gtk.gtk_container_add.argtypes = [c_void_p, c_void_p]
        gtk.gtk_widget_get_visible.argtypes = [c_void_p]
        gtk.gtk_widget_get_visible.restype = c_bool
        gtk.gtk_main_iteration_do.argtypes = [c_bool]
        gtk.gtk_main_iteration_do.restype = c_bool
        glib.g_free.argtypes = [c_void_p]
        gobject.g_object_unref.argtypes = [c_void_p]

        yield gtk, glib, gobject
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=2)
        os.environ.pop("DISPLAY", None)


def ctext(value: str) -> bytes:
    return value.encode("utf-8")


@pytest.mark.real_gtk
def test_real_gtk_accepts_all_primary_english_labels(real_gtk):
    gtk, _, _ = real_gtk
    d = literal_assignment("TR_EN")
    selected = [
        d["Abrir programa"],
        d["Abrir documento / archivo"],
        d["Abrir sitio web"],
        d["Ejecutar comando"],
        d["Cancelar"],
        d["Aceptar"],
        d["Crear"],
        d["Cambiar idioma (L)"],
        d["Posición X (% pantalla):"],
    ]
    for value in selected:
        widget = gtk.gtk_label_new(ctext(value))
        assert gtk.gtk_label_get_label(widget).decode("utf-8") == value
        gtk.gtk_widget_destroy(widget)


@pytest.mark.parametrize('catalogue_name,active_id', [('POSICIONES', 'centrada'), ('TIPOS_PASO', 'texto')])
@pytest.mark.real_gtk
def test_real_gtk_catalogue_ids_are_independent_of_translation(real_gtk, catalogue_name, active_id):
    gtk, glib, _ = real_gtk
    translations = literal_assignment('TR_EN')
    catalogue = literal_assignment(catalogue_name)
    combo = gtk.gtk_combo_box_text_new()
    try:
        for ident, source in catalogue.items():
            gtk.gtk_combo_box_text_append(combo, ctext(ident), ctext(translations[source]))
        gtk.gtk_combo_box_set_active_id(combo, active_id.encode())
        assert gtk.gtk_combo_box_get_active_id(combo).decode() == active_id
        active = gtk.gtk_combo_box_text_get_active_text(combo)
        try:
            assert ctypes.string_at(active).decode('utf-8') == translations[catalogue[active_id]]
        finally:
            glib.g_free(active)
    finally:
        gtk.gtk_widget_destroy(combo)

@pytest.mark.real_gtk
def test_real_gtk_markup_and_window_dimensions(real_gtk):
    gtk, _, _ = real_gtk
    window = gtk.gtk_window_new(0)
    label = gtk.gtk_label_new(b"")
    gtk.gtk_label_set_markup(label, ctext("<b>Warning:</b> The action could not be executed"))
    gtk.gtk_container_add(window, label)
    gtk.gtk_window_set_default_size(window, 980, 680)
    gtk.gtk_widget_show_all(window)
    for _ in range(5):
        gtk.gtk_main_iteration_do(False)
    width = c_int(); height = c_int()
    gtk.gtk_window_get_default_size(window, ctypes.byref(width), ctypes.byref(height))
    assert (width.value, height.value) == (980, 680)
    assert gtk.gtk_widget_get_visible(label)
    gtk.gtk_widget_destroy(window)


@pytest.mark.real_gtk
def test_real_gtk_measures_long_translated_controls(real_gtk):
    gtk, _, _ = real_gtk
    translations = literal_assignment("TR_EN")
    values = [
        translations["Colocar / organizar esta ventana justo después de abrirla"],
        translations["Abrir con una aplicación instalada concreta (opcional)"],
        translations["Abrir en una ventana nueva (si no, se abre como pestaña)"],
        translations["Abrir como app (sin barra de direcciones; solo Chrome/Chromium/Brave)"],
        translations["Crear automáticamente un acceso directo en el Escritorio al guardar una acción nueva"],
        translations["Mostrar notificaciones al ejecutar una acción"],
    ]
    for value in values:
        window = gtk.gtk_window_new(0)
        widget = gtk.gtk_label_new(ctext(value))
        gtk.gtk_container_add(window, widget)
        gtk.gtk_widget_show_all(window)
        for _ in range(3):
            gtk.gtk_main_iteration_do(False)
        minimum = c_int(); natural = c_int()
        gtk.gtk_widget_get_preferred_width(widget, ctypes.byref(minimum), ctypes.byref(natural))
        assert minimum.value > 0 and natural.value >= minimum.value and natural.value < 4000
        gtk.gtk_widget_destroy(window)
