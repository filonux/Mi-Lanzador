"""Persistence guarantees: atomic writes, damaged data set aside (never lost), safe re-installation."""
import json
import os
import pathlib
import shlex
import shutil
import subprocess
import sys
import time

import pytest

from conftest import ROOT, SCRIPT, bash_part, path_without, require_tools, wait_until


def leftovers(folder) -> list[str]:
    """Temporary files an interrupted atomic write would leave behind."""
    return sorted(p.name for p in pathlib.Path(folder).iterdir() if p.name.startswith('.') and '.tmp' in p.name
                  or p.name.startswith('.') and p.suffix not in ('', '.desktop') and len(p.suffixes) > 1)


def run_headless(sandbox, script=SCRIPT, **extra_env):
    return subprocess.run(['bash', str(script), '--ejecutar', 'does-not-exist'], env={**sandbox.env, **extra_env},
                          capture_output=True, text=True, timeout=60)


# --------------------------------------------------------------------------- Python: JSON files
def test_json_roundtrip_keeps_unicode_and_leaves_no_temporary_file(app):
    data = [{'id': 'a1', 'nombre': 'Ñandú ✔', 'pasos': []}]
    app.guardar_acciones(data)
    assert json.loads(pathlib.Path(app.ACCIONES_FILE).read_text(encoding='utf-8')) == data
    assert leftovers(app.CONFIG_DIR) == []


def test_unserialisable_data_never_touches_the_previous_file(app):
    app.guardar_acciones([{'id': 'previa', 'pasos': []}])
    with pytest.raises(TypeError):
        app.guardar_acciones([{'id': object()}])
    assert [a['id'] for a in app.cargar_acciones()] == ['previa']


def test_crash_while_renaming_keeps_previous_file_and_removes_the_temporary(app, monkeypatch):
    app.guardar_acciones([{'id': 'previa', 'pasos': []}])
    with monkeypatch.context() as m:
        m.setattr(app.os, 'replace', lambda *a, **k: (_ for _ in ()).throw(OSError('disk gone')))
        with pytest.raises(OSError):
            app.guardar_acciones([{'id': 'nueva', 'pasos': []}])
    assert [a['id'] for a in app.cargar_acciones()] == ['previa']
    assert leftovers(app.CONFIG_DIR) == []


DAMAGED = [b'[{"id": "a1", "nom', b'', b'not json at all', b'\xff\xfe\x00garbage', b'{"a": 1}', b'"just a string"']


@pytest.mark.parametrize('content', DAMAGED)
def test_damaged_actions_file_is_set_aside_and_survives_the_next_save(app, content):
    path = pathlib.Path(app.ACCIONES_FILE)
    path.write_bytes(content)
    assert app.cargar_acciones() == []
    kept = list(path.parent.glob('acciones.json.corrupt-*'))
    assert len(kept) == 1 and kept[0].read_bytes() == content
    assert not path.exists()
    assert len(app.AVISOS_DATOS) == 1 and 'acciones.json' in app.AVISOS_DATOS[0]
    assert 'archivo dañado' in (path.parent / 'error.log').read_text(encoding='utf-8')
    app.guardar_acciones([{'id': 'nueva', 'pasos': []}])  # the user keeps working...
    assert kept[0].read_bytes() == content                 # ...and the damaged copy is still there


def test_two_damaged_files_in_one_second_do_not_overwrite_each_other(app):
    path = pathlib.Path(app.ACCIONES_FILE)
    for text in ('[1', '[2'):
        path.write_text(text, encoding='utf-8')
        app.cargar_acciones()
    assert sorted(p.read_text(encoding='utf-8') for p in path.parent.glob('acciones.json.corrupt-*')) == ['[1', '[2']


def test_damaged_settings_fall_back_to_defaults_and_are_kept(app):
    path = pathlib.Path(app.AJUSTES_FILE)
    path.write_text('[1, 2]', encoding='utf-8')  # valid JSON, wrong type
    assert app.cargar_ajustes() == app.AJUSTES_POR_DEFECTO
    assert len(list(path.parent.glob('ajustes.json.corrupt-*'))) == 1


@pytest.mark.parametrize('nombre', ['ACCIONES_FILE', 'AJUSTES_FILE'])
def test_json_nested_beyond_the_recursion_limit_is_set_aside_instead_of_breaking_startup(app, nombre):
    ruta = pathlib.Path(getattr(app, nombre))
    ruta.write_bytes(b'[' * 100_000)  # RecursionError, que no es un ValueError: tumbaba el arranque en cada inicio
    app.cargar_acciones() if nombre == 'ACCIONES_FILE' else app.cargar_ajustes()
    assert not ruta.exists() and len(list(ruta.parent.glob(f'{ruta.name}.corrupt-*'))) == 1
    assert len(app.AVISOS_DATOS) == 1


def test_a_utf8_bom_in_a_hand_edited_json_file_is_accepted_instead_of_setting_the_file_aside(app):
    bom = b'\xef\xbb\xbf'
    pathlib.Path(app.ACCIONES_FILE).write_bytes(bom + json.dumps([{'id': 'a1', 'nombre': 'N', 'pasos': []}]).encode('utf-8'))
    pathlib.Path(app.AJUSTES_FILE).write_bytes(bom + b'{"navegador_predeterminado": "firefox"}')
    assert [a['id'] for a in app.cargar_acciones()] == ['a1']
    assert app.cargar_ajustes()['navegador_predeterminado'] == 'firefox'
    assert not list(pathlib.Path(app.ACCIONES_FILE).parent.glob('*.corrupt-*')) and app.AVISOS_DATOS == []


@pytest.mark.parametrize('contenido, clave, esperado', [
    ({'navegador_predeterminado': 5}, 'navegador_predeterminado', 'sistema'),
    ({'navegador_predeterminado': ['firefox']}, 'navegador_predeterminado', 'sistema'),
    ({'navegador_predeterminado': None}, 'navegador_predeterminado', 'sistema'),
    ({'navegador_predeterminado': True}, 'navegador_predeterminado', 'sistema'),
    ({'navegador_predeterminado': 'firefox'}, 'navegador_predeterminado', 'firefox'),
    ({'notificaciones': 'no'}, 'notificaciones', True), ({'notificaciones': 0}, 'notificaciones', False),
    ({'notificaciones': False}, 'notificaciones', False),
    ({'crear_acceso_automatico': None}, 'crear_acceso_automatico', False),
    ({'crear_acceso_automatico': 1}, 'crear_acceso_automatico', True),
    ({'crear_acceso_automatico': 1.5}, 'crear_acceso_automatico', False),
    ({'otra_clave': [1]}, 'otra_clave', [1])])
def test_settings_of_the_wrong_type_are_ignored_in_memory_only(app, contenido, clave, esperado):
    ruta = pathlib.Path(app.AJUSTES_FILE)
    ruta.write_text(json.dumps(contenido), encoding='utf-8')
    original = ruta.read_text(encoding='utf-8')
    valor = app.cargar_ajustes()[clave]
    assert valor == esperado and type(valor) is type(esperado)
    assert ruta.read_text(encoding='utf-8') == original and app.AVISOS_DATOS == []  # leer no reescribe ni aparta


def test_entries_that_are_not_actions_are_skipped_instead_of_crashing(app):
    pathlib.Path(app.ACCIONES_FILE).write_text(json.dumps(['text', 5, {'id': 'ok', 'nombre': 'N', 'pasos': []}]), encoding='utf-8')
    assert [a['id'] for a in app.cargar_acciones()] == ['ok']


PASO = {'tipo': 'esperar', 'segundos': 1}


@pytest.mark.parametrize('pasos, quedan', [(None, []), ('abrir firefox', []), (5, []), ({'tipo': 'web'}, []),
                                           ([None, 'x', 5, ['y']], []), ([None, PASO, 'x'], [PASO]), ([], [])])
def test_steps_that_are_not_a_list_of_steps_are_skipped_instead_of_crashing(app, pasos, quedan):
    ruta = pathlib.Path(app.ACCIONES_FILE)
    ruta.write_text(json.dumps([{'id': 'a1', 'nombre': 'Rota', 'pasos': pasos}, {'id': 'a2', 'nombre': 'Sana', 'pasos': [PASO]}]), encoding='utf-8')
    original = ruta.read_text(encoding='utf-8')
    acciones = app.cargar_acciones()
    assert [(a['id'], a['pasos']) for a in acciones] == [('a1', quedan), ('a2', [PASO])]
    assert ruta.read_text(encoding='utf-8') == original          # leer no reescribe lo que el usuario editó
    log = pathlib.Path(app.ERROR_LOG_FILE)
    assert (log.is_file() and 'pasos no válidos' in log.read_text(encoding='utf-8')) == (pasos != quedan)


@pytest.mark.parametrize('campo, valor, esperado', [
    ('id', 7, '7'), ('id', 1.5, '1.5'), ('nombre', 123, '123'), ('nombre', None, ''), ('nombre', ['a'], "['a']"),
    ('icono', 5, None), ('icono', ['x'], None), ('icono', None, None), ('icono', '/ruta/ok.png', '/ruta/ok.png'),
    ('id', 'a1', 'a1'), ('nombre', 'Normal', 'Normal')])
def test_id_name_and_icon_of_the_wrong_type_are_fixed_in_memory_only(app, campo, valor, esperado):
    ruta = pathlib.Path(app.ACCIONES_FILE)
    accion = {'id': 'a1', 'nombre': 'N', 'icono': None, 'pasos': [PASO], campo: valor}
    ruta.write_text(json.dumps([accion]), encoding='utf-8')
    original = ruta.read_text(encoding='utf-8')
    assert app.cargar_acciones()[0][campo] == esperado
    assert ruta.read_text(encoding='utf-8') == original          # leer no reescribe lo que el usuario editó


def test_an_action_without_id_gets_a_stable_saved_one_so_it_can_be_selected(app):
    ruta = pathlib.Path(app.ACCIONES_FILE)
    ruta.write_text(json.dumps([{'nombre': 'A', 'pasos': []}, {'id': None, 'nombre': 'B', 'pasos': []},
                                {'id': '', 'nombre': 'C', 'pasos': []}, {'id': 'ok', 'nombre': 'D', 'pasos': []}]), encoding='utf-8')
    ids = [a['id'] for a in app.cargar_acciones()]
    assert ids[3] == 'ok' and all(i and isinstance(i, str) for i in ids) and len(set(ids)) == 4, ids
    assert [a['id'] for a in json.loads(ruta.read_text(encoding='utf-8'))] == ids          # quedó guardado...
    assert [a['id'] for a in app.cargar_acciones()] == ids                                  # ...y no cambia entre lecturas
    assert app._accion_por_id(ids[0])['nombre'] == 'A'


@pytest.mark.parametrize('ids', [['dup', 'dup'], ['dup', 'x', 'dup', 'dup'], [7, '7'], [7, '7', 7]],
                         ids=['two', 'three-of-four', 'int-and-text', 'int-text-int'])
def test_actions_sharing_an_id_get_distinct_saved_ids_and_keep_their_data(app, ids):
    # Con el mismo id, «Editar» sobrescribía todas las copias y «Eliminar» las borraba todas.
    ruta = pathlib.Path(app.ACCIONES_FILE)
    ruta.write_text(json.dumps([{'id': i, 'nombre': f'A{n}', 'pasos': [{'tipo': 'esperar', 'segundos': n}]}
                                for n, i in enumerate(ids)]), encoding='utf-8')
    acciones = app.cargar_acciones()
    nuevos = [a['id'] for a in acciones]
    assert len(set(nuevos)) == len(ids) and all(isinstance(i, str) and i for i in nuevos), nuevos
    assert nuevos[0] == str(ids[0])                                                       # la primera conserva su id
    assert [(a['nombre'], a['pasos'][0]['segundos']) for a in acciones] == [(f'A{n}', n) for n in range(len(ids))]
    assert [a['id'] for a in json.loads(ruta.read_text(encoding='utf-8'))][1:] == nuevos[1:]   # quedó guardado...
    assert [a['id'] for a in app.cargar_acciones()] == nuevos                                  # ...y es estable
    assert 'id repetido' in pathlib.Path(app.ERROR_LOG_FILE).read_text(encoding='utf-8')


def test_actions_with_distinct_ids_are_not_rewritten_on_read(app):
    ruta = pathlib.Path(app.ACCIONES_FILE)
    ruta.write_text(json.dumps([{'id': 'a', 'nombre': 'A', 'pasos': []}, {'id': 'b', 'nombre': 'B', 'pasos': []}], indent=1),
                    encoding='utf-8')
    original = ruta.read_text(encoding='utf-8')
    assert [a['id'] for a in app.cargar_acciones()] == ['a', 'b'] and ruta.read_text(encoding='utf-8') == original


@pytest.mark.parametrize('id_malo', ['../x', 'a/b', '/etc/cron.d/x', 'x\nExec=evil', 'x\x00y', 'a\tb', 'ñ' * 51],
                         ids=['dotdot', 'slash', 'absolute', 'newline', 'nul', 'tab', 'over-100-bytes'])
def test_an_id_that_cannot_be_part_of_a_file_name_is_replaced_and_saved(app, id_malo):
    # El id va en «<nombre>-<id>.desktop», en el nombre del icono propio y en la línea Exec= del acceso directo.
    ruta = pathlib.Path(app.ACCIONES_FILE)
    ruta.write_text(json.dumps([{'id': id_malo, 'nombre': 'A', 'pasos': [PASO]}]), encoding='utf-8')
    nuevo = app.cargar_acciones()[0]['id']
    assert len(nuevo) == 8 and set(nuevo) <= set('0123456789abcdef'), nuevo
    assert json.loads(ruta.read_text(encoding='utf-8'))[0]['id'] == nuevo          # quedó guardado...
    assert app.cargar_acciones()[0]['id'] == nuevo                                 # ...y es estable
    assert os.path.dirname(os.path.join(app.ICONOS_DIR, nuevo + '.png')) == app.ICONOS_DIR   # el icono no sale de iconos/
    assert 'id no utilizable' in pathlib.Path(app.ERROR_LOG_FILE).read_text(encoding='utf-8')


@pytest.mark.parametrize('id_bueno', ['abcd1234', 'mi-accion_2', 'Mi Acción', 'a.b', '日本', 'x' * 100, 'ñ' * 50])
def test_ids_that_work_as_a_file_name_are_kept_and_not_rewritten_on_read(app, id_bueno):
    ruta = pathlib.Path(app.ACCIONES_FILE)
    ruta.write_text(json.dumps([{'id': id_bueno, 'nombre': 'A', 'pasos': [PASO]}], indent=1), encoding='utf-8')
    original = ruta.read_text(encoding='utf-8')
    assert app.cargar_acciones()[0]['id'] == id_bueno and ruta.read_text(encoding='utf-8') == original


def test_the_shortcut_of_an_action_whose_id_had_a_newline_has_a_single_exec_line(app, tmp_path):
    # Sin el cambio, el salto de línea del id partía «Exec=» en dos y la segunda línea mandaba.
    ruta = pathlib.Path(app.ACCIONES_FILE)
    ruta.write_text(json.dumps([{'id': 'x\nExec=evil', 'nombre': 'A', 'pasos': [PASO]}]), encoding='utf-8')
    [creado] = app.crear_acceso_directo(app.cargar_acciones()[0], [str(tmp_path / 'desk')])
    texto = pathlib.Path(creado).read_text(encoding='utf-8')
    assert texto.count('Exec=') == 1 and 'evil' not in texto


@pytest.mark.parametrize('paso, esperado', [
    ({'tipo': 'comando', 'comando': 5}, {'tipo': 'comando', 'comando': '5'}),
    ({'tipo': 5, 'texto': 7.5}, {'tipo': '5', 'texto': '7.5'}),
    ({'tipo': 'programa', 'modo': 'manual', 'ruta': None}, {'tipo': 'programa', 'modo': 'manual'}),
    ({'tipo': 'web', 'url': ['x'], 'alias': {'a': 1}, 'navegador': True}, {'tipo': 'web'}),
    ({'tipo': 'esperar', 'segundos': 'abc'}, {'tipo': 'esperar'}),
    ({'tipo': 'esperar', 'segundos': '2.5'}, {'tipo': 'esperar', 'segundos': 2.5}),
    ({'tipo': 'esperar', 'segundos': True}, {'tipo': 'esperar'}),
    ({'tipo': 'esperar', 'segundos': float('nan')}, {'tipo': 'esperar'}),
    ({'tipo': 'esperar', 'segundos': 1e999}, {'tipo': 'esperar'}),
    ({'tipo': 'clic', 'activar_ventana': False, 'x': None, 'y': '7'}, {'tipo': 'clic', 'activar_ventana': False, 'y': 7.0}),
    # controles: lo válido no se toca
    ({'tipo': 'web', 'url': 'https://a.b', 'espera': 3.0, 'nueva_ventana': True, 'alias': 'a'},
     {'tipo': 'web', 'url': 'https://a.b', 'espera': 3.0, 'nueva_ventana': True, 'alias': 'a'}),
    ({'tipo': 'clic', 'activar_ventana': True, 'coords_absolutas': True, 'x': 10, 'y': 20, 'boton': '1'},
     {'tipo': 'clic', 'activar_ventana': True, 'coords_absolutas': True, 'x': 10, 'y': 20, 'boton': '1'})])
def test_step_fields_of_the_wrong_type_are_fixed_in_memory_only(app, paso, esperado):
    ruta = pathlib.Path(app.ACCIONES_FILE)
    ruta.write_text(json.dumps([{'id': 'a1', 'nombre': 'N', 'pasos': [paso]}]), encoding='utf-8')
    original = ruta.read_text(encoding='utf-8')
    assert app.cargar_acciones()[0]['pasos'] == [esperado]
    assert ruta.read_text(encoding='utf-8') == original          # leer no reescribe lo que el usuario editó


@pytest.mark.parametrize('antigua, campo, esperado', [
    ({'tipo': 'comando', 'valor': None}, 'comando', ''), ({'tipo': 'comando', 'valor': 5}, 'comando', '5'),
    ({'tipo': 'comando', 'valor': ['ls']}, 'comando', ''), ({'tipo': 'comando', 'valor': True}, 'comando', ''),
    ({'tipo': 'programa', 'valor': None}, 'ruta', ''), ({'tipo': 'programa', 'valor': 7}, 'ruta', '7'),
    ({'tipo': 'web', 'valor': 5}, 'url', '5'), ({'tipo': 'web', 'valor': {'a': 1}}, 'url', ''),
    ({'tipo': 'web', 'valor': 'https://x.org'}, 'url', 'https://x.org')])
def test_an_old_format_action_with_a_non_text_value_is_migrated_instead_of_breaking_startup(app, antigua, campo, esperado):
    ruta = pathlib.Path(app.ACCIONES_FILE)
    ruta.write_text(json.dumps([{'id': 'old', 'nombre': 'Vieja', **antigua}]), encoding='utf-8')
    (accion,) = app.cargar_acciones()
    (paso,) = accion['pasos']
    assert paso['tipo'] == antigua['tipo'] and paso[campo] == esperado and paso['alias']
    assert 'pasos' in json.loads(ruta.read_text(encoding='utf-8'))[0]  # migrada y guardada, como cualquier formato antiguo


def test_an_old_format_web_action_with_an_unparseable_url_is_migrated_instead_of_breaking_startup(app):
    ruta = pathlib.Path(app.ACCIONES_FILE)
    ruta.write_text(json.dumps([{'id': 'old', 'nombre': 'Vieja', 'tipo': 'web', 'valor': 'https://[x'}]), encoding='utf-8')
    (accion,) = app.cargar_acciones()
    assert accion['id'] == 'old' and [(p['tipo'], p['url'], p['alias']) for p in accion['pasos']] == [('web', 'https://[x', 'web')]


def test_language_file_is_written_atomically_and_failures_do_not_raise(app, monkeypatch):
    app.guardar_idioma('es')
    assert pathlib.Path(app.IDIOMA_FILE).read_text(encoding='utf-8') == 'es\n'
    app.guardar_idioma('fr')  # unsupported: ignored
    assert pathlib.Path(app.IDIOMA_FILE).read_text(encoding='utf-8') == 'es\n'
    assert leftovers(app.CONFIG_DIR) == []
    monkeypatch.setattr(app, '_escribir_atomico', lambda *a, **k: (_ for _ in ()).throw(OSError('read-only')))
    app.guardar_idioma('en')  # must not raise
    assert 'guardar idioma' in (pathlib.Path(app.CONFIG_DIR) / 'error.log').read_text(encoding='utf-8')


def test_error_log_is_rotated_once_it_passes_the_size_limit(app, monkeypatch):
    log = pathlib.Path(app.ERROR_LOG_FILE)
    monkeypatch.setattr(app, 'LIMITE_ERROR_LOG', 200)
    log.write_text('x' * 500, encoding='utf-8')
    app._registrar_error('nuevo', ValueError('boom'))
    assert (log.parent / 'error.log.1').read_text(encoding='utf-8') == 'x' * 500
    assert 'nuevo' in log.read_text(encoding='utf-8') and 'xxx' not in log.read_text(encoding='utf-8')


def test_unhandled_exception_is_written_to_the_log_only_once(app, monkeypatch):
    class Dialogo:
        def __init__(self, **kwargs): pass
        def run(self): return 0
        def destroy(self): pass
    monkeypatch.setattr(app.Gtk, 'MessageDialog', Dialogo)
    try:
        raise ValueError('boom')
    except ValueError as exc:
        app._excepthook_global(ValueError, exc, exc.__traceback__)
    assert pathlib.Path(app.ERROR_LOG_FILE).read_text(encoding='utf-8').count('ValueError: boom') == 1


def test_custom_icon_copy_is_atomic_and_same_file_is_not_an_error(app, tmp_path):
    source = tmp_path / 'icon.png'
    source.write_bytes(b'png-bytes')
    target = pathlib.Path(app.ICONOS_DIR) / 'abc.png'
    app._copiar_atomico(str(source), str(target))
    assert target.read_bytes() == b'png-bytes' and leftovers(app.ICONOS_DIR) == []
    with pytest.raises(FileNotFoundError):
        app._copiar_atomico(str(tmp_path / 'missing.png'), str(target))
    assert target.read_bytes() == b'png-bytes' and leftovers(app.ICONOS_DIR) == []


def test_action_shortcuts_are_written_atomically_and_executable(app, tmp_path):
    folder = tmp_path / 'apps'
    paths = app.crear_acceso_directo({'id': 'abc', 'nombre': 'Demo\nInjected=1', 'pasos': []}, [str(folder)])
    assert len(paths) == 1 and os.access(paths[0], os.X_OK) and leftovers(folder) == []
    assert 'Name=Demo Injected=1\n' in pathlib.Path(paths[0]).read_text(encoding='utf-8')  # no extra key injected


@pytest.mark.parametrize('nombre', ['a' * 300, '日' * 100, 'é' * 200, 'a' * 119 + 'éé', 'Nombre normal'],
                         ids=['ascii-300', 'cjk-100', 'accents-200', 'cut-inside-a-character', 'short'])
def test_shortcut_is_created_even_when_the_action_name_is_very_long(app, tmp_path, nombre):
    # Con ~230 caracteres ASCII u ~80 CJK el nombre del archivo superaba los 255 bytes y no se creaba nada.
    carpeta = tmp_path / 'apps'
    rutas = app.crear_acceso_directo({'id': 'abcd1234', 'nombre': nombre, 'pasos': []}, [str(carpeta)])
    assert len(rutas) == 1 and os.path.isfile(rutas[0]) and leftovers(carpeta) == []
    assert rutas[0].endswith('-abcd1234.desktop') and len(os.path.basename(rutas[0]).encode()) <= 140
    assert f'Name={nombre}\n' in pathlib.Path(rutas[0]).read_text(encoding='utf-8')     # el nombre mostrado no se recorta


def test_recreating_the_shortcut_after_a_rename_replaces_the_old_file_instead_of_adding_a_second_icon(app, tmp_path):
    # El nombre del archivo lleva el nombre de la acción: al renombrarla, el acceso directo nuevo se sumaba al viejo.
    escritorio, menu = tmp_path / 'desk', tmp_path / 'menu'
    for carpeta in (escritorio, menu):
        carpeta.mkdir()
        (carpeta / 'Otra-zzzz9999.desktop').write_text('otra acción', encoding='utf-8')   # no es de esta acción
        (carpeta / 'notas-abcd1234.txt').write_text('no es un .desktop', encoding='utf-8')
    app.crear_acceso_directo({'id': 'abcd1234', 'nombre': 'Viejo', 'pasos': []}, [str(escritorio), str(menu)])
    rutas = app.crear_acceso_directo({'id': 'abcd1234', 'nombre': 'Nuevo', 'pasos': []}, [str(escritorio)])
    assert sorted(p.name for p in escritorio.iterdir()) == ['Nuevo-abcd1234.desktop', 'Otra-zzzz9999.desktop', 'notas-abcd1234.txt']
    assert 'Name=Nuevo\n' in pathlib.Path(rutas[0]).read_text(encoding='utf-8')
    # Solo se limpian las carpetas donde se crea: lo que el usuario no eligió esta vez no se toca.
    assert sorted(p.name for p in menu.iterdir()) == ['Otra-zzzz9999.desktop', 'Viejo-abcd1234.desktop', 'notas-abcd1234.txt']


def test_recreating_the_shortcut_keeps_the_old_one_when_the_new_one_cannot_be_written(app, tmp_path, monkeypatch):
    carpeta = tmp_path / 'apps'
    app.crear_acceso_directo({'id': 'abcd1234', 'nombre': 'Viejo', 'pasos': []}, [str(carpeta)])
    monkeypatch.setattr(app, '_escribir_atomico', lambda *a, **k: (_ for _ in ()).throw(OSError('disco lleno')))
    assert app.crear_acceso_directo({'id': 'abcd1234', 'nombre': 'Nuevo', 'pasos': []}, [str(carpeta)]) == []
    assert [p.name for p in carpeta.iterdir()] == ['Viejo-abcd1234.desktop']


def test_recreating_the_shortcut_without_renaming_leaves_exactly_one_file(app, tmp_path):
    carpeta = tmp_path / 'apps'
    for _ in range(2):
        rutas = app.crear_acceso_directo({'id': 'abcd1234', 'nombre': 'Igual', 'pasos': []}, [str(carpeta)])
    assert [p.name for p in carpeta.iterdir()] == ['Igual-abcd1234.desktop'] and len(rutas) == 1


@pytest.fixture
def carpetas_de_accesos(app, tmp_path, monkeypatch):
    """Escritorio y menú de aplicaciones aislados (sin crear): lo que `actualizar_accesos_directos` mira."""
    monkeypatch.setenv('HOME', str(tmp_path / 'home'))
    escritorio = tmp_path / 'desk'
    monkeypatch.setattr(app, '_dir_escritorio', lambda: str(escritorio))
    return escritorio, tmp_path / 'home' / '.local' / 'share' / 'applications'


def test_saving_a_renamed_action_refreshes_the_shortcuts_it_already_has(app, carpetas_de_accesos):
    escritorio, menu = carpetas_de_accesos
    app.crear_acceso_directo({'id': 'abcd1234', 'nombre': 'Viejo', 'pasos': [{'tipo': 'esperar'}]}, [str(escritorio), str(menu)])
    (escritorio / 'Otra-zzzz9999.desktop').write_text('otra acción', encoding='utf-8')
    app.actualizar_accesos_directos({'id': 'abcd1234', 'nombre': 'Nuevo', 'pasos': [{'tipo': 'esperar'}] * 3})
    for carpeta in (escritorio, menu):
        assert 'Nuevo-abcd1234.desktop' in [p.name for p in carpeta.iterdir()]
        assert not (carpeta / 'Viejo-abcd1234.desktop').exists()
        texto = (carpeta / 'Nuevo-abcd1234.desktop').read_text(encoding='utf-8')
        assert 'Name=Nuevo\n' in texto and '(3 steps)' in texto
    assert (escritorio / 'Otra-zzzz9999.desktop').read_text(encoding='utf-8') == 'otra acción'


def test_refreshing_shortcuts_creates_none_where_the_action_had_none(app, carpetas_de_accesos):
    escritorio, menu = carpetas_de_accesos
    app.crear_acceso_directo({'id': 'abcd1234', 'nombre': 'Viejo', 'pasos': []}, [str(escritorio)])
    carpetas = app.actualizar_accesos_directos({'id': 'abcd1234', 'nombre': 'Nuevo', 'pasos': []})
    assert carpetas == [str(escritorio)] and [p.name for p in escritorio.iterdir()] == ['Nuevo-abcd1234.desktop']
    assert not menu.exists()   # ni se crea la carpeta


def test_refreshing_shortcuts_of_an_action_without_any_does_nothing(app, carpetas_de_accesos):
    escritorio, menu = carpetas_de_accesos
    assert app.actualizar_accesos_directos({'id': 'abcd1234', 'nombre': 'Nueva', 'pasos': []}) == []
    assert not escritorio.exists() and not menu.exists()


@pytest.mark.parametrize('nombre, icono', [
    ('dir\\temp', 'x'), ('a\\sb', 'x'), ('Copiar a D:\\', 'x'), ('x\\\\y', 'x'), ('Tab\there', 'x'),
    ('Normal', '/home/a\\b/icono.png'), ('Normal', '/home/ana/icono.png')],
    ids=['tab-lookalike', 'space-lookalike', 'trailing-backslash', 'double-backslash', 'real-tab', 'icon-backslash', 'plain'])
def test_shortcut_name_and_icon_with_backslashes_are_read_back_unchanged_by_glib(app, tmp_path, nombre, icono):
    # «\t» y «\s» se leían como tabulador y espacio, y un nombre que acababa en «\» dejaba la clave Name ilegible.
    ruta = tmp_path / 'x.desktop'
    ruta.write_text(app.generar_desktop_entry({'id': 'abc', 'nombre': nombre, 'pasos': []}, icono), encoding='utf-8')
    claves = app.GLib.KeyFile()
    claves.load_from_file(str(ruta), app.GLib.KeyFileFlags.NONE)
    assert claves.get_string('Desktop Entry', 'Name') == nombre.replace('\t', ' ')
    assert claves.get_string('Desktop Entry', 'Icon') == icono


HOMES_RAROS = ['/home/ana', '/home/josé', '/home/ana maria', "/home/o'brien", '/home/a$b', '/home/a"b', '/home/a`b',
               '/home/a%b', '/home/a\\sb', '/home/a\\\\b', '/home/a;b&c|d', '/home/a(b)*?#~<>']


def argv_de_exec(GLib, ruta):
    """Los argumentos que GLib saca del Exec= de un .desktop: GKeyFile deshace el escape de cadena, shell_parse_argv el
    entrecomillado y «%%» pasa a «%» (único código de campo que lleva nuestro Exec=)."""
    claves = GLib.KeyFile()
    claves.load_from_file(str(ruta), GLib.KeyFileFlags.NONE)
    return [a.replace('%%', '%') for a in GLib.shell_parse_argv(claves.get_string('Desktop Entry', 'Exec'))[1]]


@pytest.mark.parametrize('home', HOMES_RAROS)
def test_shortcut_exec_line_splits_into_the_right_arguments_for_unusual_home_paths(app, tmp_path, monkeypatch, home):
    ruta = f'{home}/.local/share/mi-lanzador/mi-lanzador.sh'
    monkeypatch.setattr(app, 'APP_SCRIPT_PATH', ruta)
    desktop = tmp_path / 'x.desktop'
    desktop.write_text(app.generar_desktop_entry({'id': 'abc', 'nombre': 'N', 'pasos': []}, 'x'), encoding='utf-8')
    assert argv_de_exec(app.GLib, desktop) == ['bash', ruta, '--ejecutar', 'abc']


@pytest.mark.parametrize('home', HOMES_RAROS)
@pytest.mark.parametrize('id_accion', ['abcd1234', "it's a $b%c\\d", 'a"b`c', ''], ids=['plain', 'odd', 'quotes', 'empty'])
def test_shortcut_passes_desktop_file_validate_whatever_the_home_and_the_id(app, tmp_path, monkeypatch, home, id_accion):
    # `desktop-file-validate` rechazaba las comillas simples de Exec= (GLib las entiende, la especificación no las define).
    if shutil.which('desktop-file-validate') is None:
        pytest.skip('desktop-file-validate is not installed (sudo apt install desktop-file-utils)')
    monkeypatch.setattr(app, 'APP_SCRIPT_PATH', f'{home}/.local/share/mi-lanzador/mi-lanzador.sh')
    ruta = tmp_path / 'x.desktop'
    ruta.write_text(app.generar_desktop_entry({'id': id_accion, 'nombre': 'N', 'pasos': []}, '/usr/share/pixmaps/x.png'),
                    encoding='utf-8')
    comprobado = subprocess.run(['desktop-file-validate', str(ruta)], capture_output=True, text=True)
    assert comprobado.returncode == 0, comprobado.stdout + comprobado.stderr


@pytest.mark.parametrize('directorio, id_accion', [
    ('ana', 'a%b'), ('ana', 'a%%b'), ('ana', '%f'), ('ana', 'a\\b'), ('ana', 'a\\sb'), ('ana', 'a\\\\b'),
    ('ana', 'a b'), ('ana', "a'b"), ('ana', 'a$b'), ('ana', 'ñandú'), ('ana', 'a"b'), ('ana', 'a`b'), ('ana', '$HOME'),
    ('ana', '"'), ('ana', '\\'),
    ('a%b', 'abcd1234'), ('a\\sb', 'abcd1234'), ('a b', 'abcd1234'), ('a$b', 'abcd1234'), ('a"b', 'abcd1234'),
    ('a`b', 'abcd1234'), ("a'b", 'abcd1234'), ('a;b&c|d', 'abcd1234')])
def test_launching_the_shortcut_through_gio_runs_the_action_with_exactly_its_id(app, tmp_path, monkeypatch, directorio, id_accion):
    # Exec= sin escapar «%» ni «\»: «a%b» llegaba como «a», «a\sb» como «a b» (otra acción) y «a\b» ni se cargaba.
    from gi.repository import Gio
    falso = tmp_path / directorio / 'mi-lanzador.sh'
    falso.parent.mkdir()
    salida = tmp_path / 'id-recibido.txt'
    falso.write_text(f'#!/bin/bash\nprintf %s "$2" > {shlex.quote(str(salida))}\n', encoding='utf-8')
    falso.chmod(0o755)
    monkeypatch.setattr(app, 'APP_SCRIPT_PATH', str(falso))
    ruta = app.crear_acceso_directo({'id': id_accion, 'nombre': 'T', 'pasos': []}, [str(tmp_path / 'apps')])[0]
    info = Gio.DesktopAppInfo.new_from_filename(ruta)
    assert info is not None
    info.launch([], None)
    assert wait_until(lambda: salida.exists() and salida.read_text(encoding='utf-8') == id_accion, timeout=5)


def test_shortcuts_of_an_id_that_ends_another_id_are_not_taken_as_its_own(app, tmp_path):
    # El sufijo del nombre no basta: «Acc-x-5.desktop» acaba en «-5.desktop» y renombrar o borrar la acción «5» lo borraba.
    carpeta = tmp_path / 'apps'
    for id_accion in ('5', 'x-5', 'y-z-5'):
        app.crear_acceso_directo({'id': id_accion, 'nombre': 'Acc', 'pasos': []}, [str(carpeta)])
    (carpeta / 'Ajeno-5.desktop').write_text('[Desktop Entry]\nExec=firefox\n', encoding='utf-8')   # no es de Mi Lanzador
    assert app._accesos_en(str(carpeta), '5') == ['Acc-5.desktop']
    app.crear_acceso_directo({'id': '5', 'nombre': 'Renombrada', 'pasos': []}, [str(carpeta)])
    assert sorted(p.name for p in carpeta.iterdir()) == ['Acc-x-5.desktop', 'Acc-y-z-5.desktop', 'Ajeno-5.desktop', 'Renombrada-5.desktop']
    app._borrar_accesos_en(str(carpeta), '5')
    assert sorted(p.name for p in carpeta.iterdir()) == ['Acc-x-5.desktop', 'Acc-y-z-5.desktop', 'Ajeno-5.desktop']


@pytest.mark.parametrize('id_accion', ['abcd1234', 'a b', "a'b", 'a$b', 'a%b', 'a%%b', 'a\\b', 'a\\\\b', 'ñandú', 'x-5',
                                        'a"b', 'a`b', '$HOME', '"', '\\'])
def test_a_shortcut_is_recognised_as_its_own_whatever_characters_its_id_has(app, tmp_path, id_accion):
    carpeta = tmp_path / 'apps'
    ruta = app.crear_acceso_directo({'id': id_accion, 'nombre': 'N', 'pasos': []}, [str(carpeta)])[0]
    assert app._id_de_acceso(ruta) == id_accion
    assert app._accesos_en(str(carpeta), id_accion) == [os.path.basename(ruta)]


@pytest.mark.parametrize('id_accion', ['abcd1234', 'a b', "it's", 'a$b', 'a%b', 'a\\b'])
def test_a_shortcut_written_by_an_older_version_with_single_quotes_is_still_recognised(app, tmp_path, id_accion):
    # Hasta 1.56 el argumento llevaba comillas simples (shlex.quote): los accesos ya creados siguen siendo suyos.
    antiguo = tmp_path / 'apps' / f'Viejo-{id_accion}.desktop'
    antiguo.parent.mkdir()
    exec_line = app._exec_desktop(f"bash {shlex.quote('/home/ana maria/.local/share/mi-lanzador/mi-lanzador.sh')} "
                                  f"--ejecutar {shlex.quote(id_accion)}")
    antiguo.write_text(f'[Desktop Entry]\nType=Application\nName=Viejo\nExec={exec_line}\n', encoding='utf-8')
    assert app._id_de_acceso(str(antiguo)) == id_accion
    assert app._accesos_en(str(antiguo.parent), id_accion) == [antiguo.name]


# --------------------------------------------------------------------------- bash: installation
def make_variant(tmp_path, marker):
    """A copy of the script with a harmless trailing comment (after the heredoc that ends the program)."""
    path = tmp_path / marker / 'mi-lanzador.sh'
    path.parent.mkdir()
    path.write_text(SCRIPT.read_text(encoding='utf-8') + f'\n# {marker}\n', encoding='utf-8')
    return path


def test_reinstall_replaces_the_script_by_rename_so_running_copies_are_untouched(sandbox, tmp_path):
    v1, v2 = make_variant(tmp_path, 'marker-v1'), make_variant(tmp_path, 'marker-v2')
    assert run_headless(sandbox, v1).returncode == 0
    installed = sandbox.app_dir / 'mi-lanzador.sh'
    with open(installed, 'rb') as still_running:           # e.g. another instance reading the script
        inode = os.fstat(still_running.fileno()).st_ino
        assert run_headless(sandbox, v2).returncode == 0
        assert b'marker-v1' in still_running.read() and b'marker-v2' not in still_running.read()
    assert b'marker-v2' in installed.read_bytes() and os.stat(installed).st_ino != inode
    assert os.access(installed, os.X_OK) and leftovers(sandbox.app_dir) == []


def test_launcher_is_refreshed_when_stale_and_defaults_to_english_text(sandbox):
    assert run_headless(sandbox).returncode == 0
    launcher = sandbox.applications / 'mi-lanzador.desktop'
    launcher.write_text('[Desktop Entry]\nName=stale\n', encoding='utf-8')
    assert run_headless(sandbox).returncode == 0
    text = launcher.read_text(encoding='utf-8')
    assert 'GenericName=Automated shortcut creator' in text and 'GenericName[es]=Creador de accesos directos' in text
    assert 'Comment=Create shortcuts' in text and '[en]' not in text
    assert f'Exec=/bin/bash "{sandbox.app_dir}/mi-lanzador.sh"' in text
    assert os.access(launcher, os.X_OK) and leftovers(sandbox.applications) == []


@pytest.mark.parametrize('carpeta', ['ana maria', 'a$b', 'a"b', 'a`b', 'a%b', 'a\\sb', "a'b", 'a;b&c|d'])
def test_own_launcher_runs_the_installed_script_whatever_characters_the_home_has(sandbox, carpeta):
    # `Exec=/bin/bash "$APP_SCRIPT"` sin escapar: con «$», «"», «`» o «%» en HOME el lanzador no era válido y con «\s»
    # GLib leía un espacio (otra ruta, sin aviso).
    import gi
    gi.require_version('GLib', '2.0')
    from gi.repository import GLib
    home = sandbox.home.parent / carpeta
    (home / 'Desktop').mkdir(parents=True)
    assert run_headless(sandbox, HOME=str(home)).returncode == 0
    lanzador = home / '.local' / 'share' / 'applications' / 'mi-lanzador.desktop'
    assert argv_de_exec(GLib, lanzador) == ['/bin/bash', str(home / '.local' / 'share' / 'mi-lanzador' / 'mi-lanzador.sh')]
    if shutil.which('desktop-file-validate'):
        comprobado = subprocess.run(['desktop-file-validate', str(lanzador)], capture_output=True, text=True)
        assert comprobado.returncode == 0, comprobado.stdout + comprobado.stderr


def test_icon_is_installed_in_the_user_theme_and_the_launcher_points_to_it(sandbox):
    assert run_headless(sandbox).returncode == 0
    icon = sandbox.icons / 'mi-lanzador.svg'
    assert icon.read_bytes() == (ROOT / 'assets' / 'icon.svg').read_bytes()
    assert icon.stat().st_mode & 0o777 == 0o644 and leftovers(sandbox.icons) == []
    assert 'Icon=mi-lanzador\n' in (sandbox.applications / 'mi-lanzador.desktop').read_text(encoding='utf-8')


def test_installs_from_before_the_icon_existed_are_upgraded_and_a_damaged_icon_is_restored(sandbox):
    assert run_headless(sandbox).returncode == 0
    launcher, copy, icon = sandbox.applications / 'mi-lanzador.desktop', sandbox.desktop / 'Mi Lanzador.desktop', sandbox.icons / 'mi-lanzador.svg'
    for old in (launcher, copy):
        old.write_text(old.read_text(encoding='utf-8').replace('Icon=mi-lanzador', 'Icon=system-run'), encoding='utf-8')
    icon.unlink()
    assert run_headless(sandbox).returncode == 0
    assert 'Icon=mi-lanzador' in launcher.read_text(encoding='utf-8') and copy.read_bytes() == launcher.read_bytes()
    assert icon.is_file()
    icon.write_text('<svg/>', encoding='utf-8')
    assert run_headless(sandbox).returncode == 0 and icon.read_bytes() == (ROOT / 'assets' / 'icon.svg').read_bytes()
    inode = icon.stat().st_ino
    assert run_headless(sandbox).returncode == 0 and icon.stat().st_ino == inode  # intact icon: not rewritten


def test_a_stale_icon_cache_does_not_hide_the_new_icon_from_gtk(sandbox):
    require_tools('gtk-update-icon-cache')
    sandbox.icons.mkdir(parents=True)
    (sandbox.icons / 'other.svg').write_bytes((ROOT / 'assets' / 'icon.svg').read_bytes())
    subprocess.run(['gtk-update-icon-cache', '-qtf', str(sandbox.icons.parents[1])], check=True)  # cache that predates our icon
    assert run_headless(sandbox).returncode == 0
    probe = ("import gi; gi.require_version('Gtk', '3.0'); from gi.repository import Gtk; "
             "print(Gtk.IconTheme.get_default().has_icon('mi-lanzador'))")
    seen = subprocess.run([sys.executable, '-c', probe], env=sandbox.env, capture_output=True, text=True, timeout=60)
    assert seen.stdout.strip() == 'True', seen


def test_desktop_copy_is_kept_current_but_never_recreated_after_the_user_deletes_it(sandbox):
    assert run_headless(sandbox).returncode == 0
    copy = sandbox.desktop / 'Mi Lanzador.desktop'
    launcher = sandbox.applications / 'mi-lanzador.desktop'
    assert copy.read_bytes() == launcher.read_bytes()
    copy.write_text('[Desktop Entry]\nName=stale\n', encoding='utf-8')
    assert run_headless(sandbox).returncode == 0
    assert copy.read_bytes() == launcher.read_bytes() and leftovers(sandbox.desktop) == []
    copy.unlink()
    assert run_headless(sandbox).returncode == 0
    assert not copy.exists()


def test_the_sandbox_hides_zenity_and_yad_but_keeps_every_other_tool(sandbox):
    path = sandbox.env['PATH']
    assert [shutil.which(name, path=path) for name in ('zenity', 'yad')] == [None, None]
    assert all(shutil.which(name, path=path) for name in ('bash', 'python3', 'xdotool', 'wmctrl'))


def test_daily_warning_timestamp_is_numeric_atomic_and_throttles_the_warning(sandbox):
    first = run_headless(sandbox, XDG_SESSION_TYPE='wayland', MI_LANZADOR_LANG='en')
    stamp = sandbox.config / '.aviso_wayland'
    assert 'native Cinnamon Wayland session' in first.stderr
    assert stamp.read_text(encoding='utf-8').strip().isdigit() and leftovers(sandbox.config) == []
    second = run_headless(sandbox, XDG_SESSION_TYPE='wayland', MI_LANZADOR_LANG='en')
    assert 'Wayland session' not in second.stderr


def test_daily_warning_stamp_in_the_future_does_not_silence_the_warning(sandbox):
    # Con el reloj adelantado la marca quedaba en el futuro y el aviso no volvía a salir hasta esa fecha.
    run_headless(sandbox, XDG_SESSION_TYPE='wayland', MI_LANZADOR_LANG='en')
    stamp = sandbox.config / '.aviso_wayland'
    stamp.write_text(f'{int(time.time()) + 400 * 86400}\n', encoding='utf-8')
    again = run_headless(sandbox, XDG_SESSION_TYPE='wayland', MI_LANZADOR_LANG='en')
    assert 'native Cinnamon Wayland session' in again.stderr
    assert int(stamp.read_text(encoding='utf-8')) <= time.time() + 5
    assert 'Wayland session' not in run_headless(sandbox, XDG_SESSION_TYPE='wayland', MI_LANZADOR_LANG='en').stderr


@pytest.mark.parametrize('lang, expected, foreign', [('en', 'xdotool and wmctrl', 'xdotool y wmctrl'),
                                                      ('es', 'xdotool y wmctrl', 'xdotool and wmctrl')])
def test_missing_x11_tools_warning_joins_the_names_in_the_selected_language(sandbox, tmp_path, lang, expected, foreign):
    # Sin pkexec no hay diálogo de instalación: sale directamente el aviso de que siguen faltando.
    path = path_without(tmp_path / 'sin_x11', 'zenity', 'yad', 'xdotool', 'wmctrl', 'pkexec')
    out = run_headless(sandbox, PATH=path, MI_LANZADOR_LANG=lang)
    assert expected in out.stderr and foreign not in out.stderr


def test_bash_messages_follow_the_selected_language_and_leave_no_hardcoded_button_text():
    text = bash_part()
    assert '--button=Cerrar' not in text
    assert "MSG_CLOSE='Cerrar'" in text and "MSG_CLOSE='Close'" in text
    assert text.count('Estás en una sesión Wayland') == 1  # one copy of each message, not two


def test_no_desktop_copy_is_dropped_into_home_when_the_desktop_folder_is_unset(sandbox):
    require_tools('xdg-user-dir')
    sandbox.desktop.rmdir()
    (sandbox.home / '.config').mkdir(exist_ok=True)
    (sandbox.home / '.config' / 'user-dirs.dirs').write_text('XDG_DESKTOP_DIR="$HOME/"\n', encoding='utf-8')
    run_headless(sandbox, XDG_CONFIG_HOME=str(sandbox.home / '.config'))
    assert not (sandbox.home / 'Mi Lanzador.desktop').exists()
    assert (sandbox.applications / 'mi-lanzador.desktop').is_file()  # the menu launcher is still installed


def test_desktop_copy_goes_to_home_desktop_when_the_desktop_folder_is_unset_but_that_folder_exists(sandbox):
    # xdg-user-dir da $HOME/ si no hay Escritorio configurado; la parte de Python ya usa entonces ~/Desktop.
    require_tools('xdg-user-dir')
    (sandbox.home / '.config').mkdir(exist_ok=True)
    (sandbox.home / '.config' / 'user-dirs.dirs').write_text('XDG_DESKTOP_DIR="$HOME/"\n', encoding='utf-8')
    run_headless(sandbox, XDG_CONFIG_HOME=str(sandbox.home / '.config'))
    assert (sandbox.desktop / 'Mi Lanzador.desktop').is_file()
    assert not (sandbox.home / 'Mi Lanzador.desktop').exists()


def test_desktop_copy_goes_to_home_desktop_when_xdg_user_dir_is_not_installed(sandbox, tmp_path):
    run_headless(sandbox, PATH=path_without(tmp_path / 'sin_xdg', 'zenity', 'yad', 'xdg-user-dir'))
    assert (sandbox.desktop / 'Mi Lanzador.desktop').is_file()
