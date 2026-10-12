"""Real-GTK checks of dialog and main-window behaviours that only break under unusual interaction or timing
(double clicks, failures, a click as the first step)."""
import ast
import json

import pytest

from conftest import embedded_python, run_gui

PREPARE = '''
mod.herramientas_x11_disponibles = lambda: {'xdotool': True, 'wmctrl': True}
mod._resolver_ventana_bajo_punto = lambda x, y: (0, 0, '')
main = mod.VentanaPrincipal(); main.show_all()
dialog = mod.DialogoPaso(main, []); dialog.show_all(); pump(500)
'''


def test_double_press_on_pick_point_captures_once_and_restores_the_dialog(sandbox):
    result = run_gui(sandbox, PREPARE, '''
        calls = []
        mod._capturar_punto_pantalla = lambda: calls.append(1) or (123, 45)
        before = dialog.get_position()
        dialog._on_elegir_punto_clic(None); dialog._on_elegir_punto_clic(None)
        pump(2500)
        result = {'calls': len(calls), 'before': list(before), 'after': list(dialog.get_position()),
                  'opacity': dialog.get_opacity(), 'x': dialog.spin_x_clic.get_value()}
    ''')
    assert result['calls'] == 1 and result['x'] == 123, result
    assert result['after'] == result['before'] and result['opacity'] == 1, result


FAKE_POPEN = '''
opened = []
def failing_popen(*args, **kwargs):
    opened.append(kwargs.get('stderr') or kwargs.get('stdout'))
    raise OSError('boom')
mod.subprocess.Popen = failing_popen
'''


def test_log_file_is_closed_when_popen_fails_in_both_runners(sandbox):
    result = run_gui(sandbox, PREPARE, FAKE_POPEN, '''
        shown = []
        dialog._mostrar_info_prueba = lambda texto, es_error=False: shown.append(texto)
        dialog.validar_y_construir = lambda: ({'tipo': 'esperar', 'segundos': 0}, None)
        dialog._on_probar_paso(Gtk.Button(label='Test'))
        errors = []
        parent = type('P', (), {'mostrar_dialogo_error': lambda self, text: errors.append(text)})()
        mod.ejecutar_accion({'nombre': 'x', 'pasos': [{'tipo': 'esperar', 'segundos': 0}]}, parent)
        result = {'handles': len(opened), 'closed': [getattr(f, 'closed', None) for f in opened],
                  'shown': len(shown), 'errors': len(errors)}
    ''')
    assert result == {'handles': 2, 'closed': [True, True], 'shown': 1, 'errors': 1}, result


def test_empty_step_test_log_uses_the_translated_placeholder(sandbox):
    result = run_gui(sandbox, PREPARE, '''
        shown = []
        dialog._mostrar_info_prueba = lambda texto, es_error=False: shown.append(texto)
        dialog.validar_y_construir = lambda: ({'tipo': 'esperar', 'segundos': 0}, None)
        mod.generar_script_bash = lambda pasos, nombre='': '#!/bin/bash\\ntrue\\n'
        dialog._on_probar_paso(Gtk.Button(label='Test')); pump(1500)
        result = {'shown': shown}
    ''')
    assert len(result['shown']) == 1 and '(no messages;' in result['shown'][0], result


def test_step_test_log_names_the_run_in_the_selected_language(sandbox):
    # El nombre de la ejecución de prueba iba sin tr(): en inglés el registro decía «running Prueba de paso».
    result = run_gui(sandbox, PREPARE, '''
        shown = []
        dialog._mostrar_info_prueba = lambda texto, es_error=False: shown.append(texto)
        dialog.validar_y_construir = lambda: ({'tipo': 'esperar', 'segundos': 0}, None)
        dialog._on_probar_paso(Gtk.Button(label='Test')); pump(1500)
        result = {'shown': shown}
    ''')
    assert len(result['shown']) == 1 and 'running Step test' in result['shown'][0], result
    assert 'Prueba de paso' not in result['shown'][0], result


def test_validation_errors_are_translated_where_they_are_created():
    method = next(n for n in ast.walk(ast.parse(embedded_python()))
                  if isinstance(n, ast.FunctionDef) and n.name == 'validar_y_construir')
    bare = [n.lineno for n in ast.walk(method) if isinstance(n, ast.Return) and isinstance(n.value, ast.Tuple)
            and isinstance(n.value.elts[1], ast.Constant) and isinstance(n.value.elts[1].value, str)]
    assert not bare, f'string literals returned without tr() at embedded lines {bare}'


def test_error_dialog_and_missing_app_message_are_shown_in_english(sandbox):
    result = run_gui(sandbox, PREPARE, '''
        shown = []
        class FakeDialog:
            def __init__(self, **kw): shown.append(kw['text'])
            def run(self): pass
            def destroy(self): pass
        mod.Gtk.MessageDialog = FakeDialog
        dialog.combo_tipo.set_active_id('programa'); dialog.stack_programa.set_visible_child_name('instalado')
        _, error = dialog.validar_y_construir()
        main.mostrar_dialogo_error('Selecciona primero un paso de la lista.')
        result = {'error': error, 'shown': shown, 'expected': mod.TR_EN['Selecciona primero un paso de la lista.']}
    ''')
    assert result['error'].startswith('Choose an application'), result
    assert result['shown'] == [result['expected']], result


def test_keyboard_grab_is_released_even_if_the_capture_dialog_fails(sandbox):
    result = run_gui(sandbox, PREPARE, '''
        events = []
        class Seat:
            def ungrab(self): events.append('ungrab')
        Base = Gtk.Dialog
        class Broken(Base):
            def run(self): raise RuntimeError('boom')
            def destroy(self): events.append('destroy'); Base.destroy(self)
        mod.Gtk.Dialog = Broken
        mod._agarrar_dispositivo = lambda window, caps: Seat()
        try:
            mod._capturar_combinacion_teclado(main)
        except RuntimeError as error:
            events.append(str(error))
        result = {'events': events}
    ''')
    assert sorted(result['events']) == ['boom', 'destroy', 'ungrab'], result


def test_language_switch_does_not_restart_when_the_choice_cannot_be_saved(sandbox):
    result = run_gui(sandbox, PREPARE, '''
        restarts, errors = [], []
        mod.os.execv = lambda *args: restarts.append(args)
        mod._escribir_atomico = lambda *args, **kwargs: (_ for _ in ()).throw(OSError('read-only'))
        main.mostrar_dialogo_error = errors.append
        main._on_cambiar_idioma(None)
        result = {'restarts': len(restarts), 'errors': len(errors), 'text': errors[0] if errors else ''}
    ''')
    assert result['restarts'] == 0 and result['errors'] == 1 and 'could not be saved' in result['text'], result


def test_language_switch_overrides_a_forced_launch_language(sandbox):
    result = run_gui(sandbox, PREPARE, '''
        restarts = []
        mod.os.execv = lambda *args: restarts.append(args)
        mod.os.environ['MI_LANZADOR_LANG'] = 'en'
        main._on_cambiar_idioma(None)
        result = {'restarts': len(restarts), 'forced': mod.os.environ.get('MI_LANZADOR_LANG'),
                  'saved': open(mod.IDIOMA_FILE, encoding='utf-8').read().strip()}
    ''')
    assert result == {'restarts': 1, 'forced': None, 'saved': 'es'}, result


def test_web_step_keeps_any_url_scheme_and_prefixes_only_bare_hosts(sandbox):
    result = run_gui(sandbox, PREPARE, '''
        dialog.combo_tipo.set_active_id('web')
        def build(text):
            dialog.entry_url.set_text(text)
            step, error = dialog.validar_y_construir()
            return step['url'] if step else error
        samples = ['example.com', 'localhost:8080/a', 'http://a.b', 'HTTPS://A.B', 'file:///tmp/x.html', 'chrome://settings']
        result = {s: build(s) for s in samples}
    ''')
    assert result == {
        'example.com': 'https://example.com', 'localhost:8080/a': 'https://localhost:8080/a',
        'http://a.b': 'http://a.b', 'HTTPS://A.B': 'HTTPS://A.B',
        'file:///tmp/x.html': 'file:///tmp/x.html', 'chrome://settings': 'chrome://settings'}, result


def test_web_step_with_an_unparseable_url_is_rejected_with_a_message_and_not_an_exception(sandbox):
    # urlparse lanza ValueError con corchetes sueltos; el diálogo se cerraba con un error y se perdía lo escrito.
    result = run_gui(sandbox, PREPARE, '''
        dialog.combo_tipo.set_active_id('web')
        result = {}
        for text in ['[Google](https://google.com)', 'https://[x', 'a]b.com', 'http://[::1]:8080/x']:
            dialog.entry_url.set_text(text)
            try:
                step, error = dialog.validar_y_construir()
            except ValueError as exc:          # sin captura, el gancho del programa abriría un diálogo y la prueba se colgaría
                step, error = None, f'ValueError: {exc}'
            result[text] = [step and step['url'], error]
    ''')
    assert result == {
        '[Google](https://google.com)': [None, 'The URL is not valid:\nhttps://[Google](https://google.com)'],
        'https://[x': [None, 'The URL is not valid:\nhttps://[x'],
        'a]b.com': [None, 'The URL is not valid:\nhttps://a]b.com'],
        'http://[::1]:8080/x': ['http://[::1]:8080/x', None]}, result


def test_saving_an_edit_of_an_action_missing_from_disk_keeps_it(sandbox):
    result = run_gui(sandbox, PREPARE, '''
        mod.notificar = lambda *args, **kwargs: None
        main.editando_id = 'gone'
        main.entry_nombre.set_text('Edited')
        main.pasos_actual = [{'tipo': 'esperar', 'segundos': 1}]
        main._on_guardar_accion(None)
        result = {'saved': [(a['id'], a['nombre']) for a in mod.cargar_acciones()]}
    ''')
    assert result == {'saved': [['gone', 'Edited']]}, result


def test_x11_install_does_not_freeze_the_window_while_apt_runs(sandbox):
    result = run_gui(sandbox, PREPARE, '''
        import threading, time, types
        started, release = threading.Event(), threading.Event()
        def slow_apt(*args, **kwargs):
            started.set(); release.wait(5)
            return types.SimpleNamespace(stdout='installed', stderr='', returncode=0)
        mod.subprocess.run = slow_apt
        mod.shutil.which = lambda name: '/usr/bin/pkexec'
        Gtk.MessageDialog.run = lambda self: Gtk.ResponseType.YES
        button = main.btn_instalar_x11; button.set_visible(True)
        t0 = time.monotonic(); main._on_instalar_x11(button); elapsed = time.monotonic() - t0
        pump(200)
        busy = (started.is_set(), button.get_sensitive(), main.etiqueta_estado_x11.get_text())
        release.set(); pump(600)
        result = {'elapsed': elapsed, 'busy': busy, 'sensitive': button.get_sensitive(),
                  'visible': button.get_visible(), 'status': main.etiqueta_estado_x11.get_text(),
                  'log': open(mod.CONFIG_DIR + '/instalacion_dependencias_x11.log').read()}
    ''')
    assert result['elapsed'] < 2, result  # el manejador devuelve el control mientras apt sigue ejecutándose
    assert result['busy'] == [True, False, '⏳ Installing… answer the password dialog if it appears'], result
    assert (result['sensitive'], result['visible'], result['status'], result['log']) == (True, False, '✅ Available', 'installed'), result


def test_desktop_folder_that_resolves_to_home_falls_back_to_desktop_subfolder(sandbox):
    (sandbox.home / '.config').mkdir(exist_ok=True)
    (sandbox.home / '.config' / 'user-dirs.dirs').write_text('XDG_DESKTOP_DIR="$HOME/"\n', encoding='utf-8')
    result = run_gui(sandbox, PREPARE, '''
        result = {'window': main.obtener_dir_escritorio(), 'scanned': mod._directorios_aplicaciones()[-1]}
    ''')
    expected = str(sandbox.home / 'Desktop')
    assert result == {'window': expected, 'scanned': expected}, result


def test_shortcut_launch_failure_without_a_window_is_logged_and_notified(sandbox):
    result = run_gui(sandbox, PREPARE, FAKE_POPEN, '''
        sent = []
        mod.notificar = lambda texto, titulo='Mi Lanzador': sent.append(texto)
        outcome = mod.ejecutar_accion({'nombre': 'x', 'pasos': [{'tipo': 'esperar', 'segundos': 0}]}, None)
        log = open(mod.ERROR_LOG_FILE, encoding='utf-8').read() if mod.os.path.exists(mod.ERROR_LOG_FILE) else ''
        result = {'outcome': outcome, 'sent': sent, 'logged': 'boom' in log}
    ''')
    assert result['outcome'] is None and result['logged'], result
    assert len(result['sent']) == 1 and 'boom' in result['sent'][0], result


def test_shortcut_of_a_deleted_action_notifies_instead_of_only_writing_to_stderr(sandbox):
    result = run_gui(sandbox, '''
        sent, ran = [], []
        mod.notificar = lambda texto, titulo='Mi Lanzador': sent.append(texto)
        mod.ejecutar_accion = lambda accion, *args: ran.append(accion['id'])
        mod.guardar_acciones([{'id': 'vivo', 'nombre': 'V', 'pasos': []}])
        mod.ejecutar_accion_por_id('vivo')                       # control: una acción que existe no avisa de nada
        result = {'control': [list(ran), list(sent)]}
        result['gone'] = [mod.ejecutar_accion_por_id('borrada'), sent]
    ''')
    assert result['control'] == [['vivo'], []], result
    assert result['gone'] == [None, ['No action was found with id "borrada"']], result


def test_window_title_label_is_shown_only_together_with_its_search_field(sandbox):
    result = run_gui(sandbox, '''
        dialog = mod.DialogoPaso(None, []); dialog.show_all(); pump(200)
        def walk(w, cls, out):
            if isinstance(w, cls): out.append(w)
            for child in (w.get_children() if hasattr(w, 'get_children') else []): walk(child, cls, out)
            return out
        result = {}
        for kind in ('ventana', 'clic', 'tecla', 'texto'):
            dialog.combo_tipo.set_active_id(kind); pump(50)
            page = dialog.stack.get_visible_child()
            label = [l for l in walk(page, Gtk.Label, []) if l.get_text() == 'Window title:'][0]
            entry = [e for e in walk(page, Gtk.Entry, []) if e.get_placeholder_text() == 'Text that appears in the window title'][0]
            combo = [c for c in walk(page, Gtk.ComboBoxText, []) if c.get_active_id() == '_ultima'][0]
            states = [(label.get_mapped(), entry.get_mapped())]
            combo.set_active_id('_buscar'); pump(50); states.append((label.get_mapped(), entry.get_mapped()))
            combo.set_active_id('_ultima'); pump(50); states.append((label.get_mapped(), entry.get_mapped()))
            result[kind] = states
    ''')
    assert result == {kind: [[False, False], [True, True], [False, False]] for kind in ('ventana', 'clic', 'tecla', 'texto')}, result


def test_saved_title_search_shows_label_and_field_together_when_editing_any_step_type(sandbox):
    result = run_gui(sandbox, PREPARE, '''
        entries = {'ventana': 'entry_buscar_ventana', 'clic': 'entry_buscar_clic',
                   'tecla': 'entry_buscar_tecla', 'texto': 'entry_buscar_texto'}
        result = {}
        for kind, attribute in entries.items():
            step = {'tipo': kind, 'objetivo_modo': '_buscar', 'objetivo_buscar': 'Firefox'}
            editor = mod.DialogoPaso(main, [], step); editor.show_all(); pump(200)
            entry = getattr(editor, attribute)
            label = entry.get_parent().get_child_at(0, 1)
            result[kind] = [label.get_text(), label.get_mapped(), entry.get_mapped(), entry.get_text()]
            editor.destroy()
    ''')
    assert result == {kind: ['Window title:', True, True, 'Firefox'] for kind in ('ventana', 'clic', 'tecla', 'texto')}, result


def test_script_generation_failure_is_reported_as_an_action_failure_with_and_without_a_window(sandbox):
    result = run_gui(sandbox, PREPARE, '''
        def broken(pasos, nombre=''):
            raise ValueError('bad step')
        mod.generar_script_bash = broken
        sent, errors = [], []
        mod.notificar = lambda texto, titulo='Mi Lanzador': sent.append(texto)
        parent = type('P', (), {'mostrar_dialogo_error': lambda self, text: errors.append(text)})()
        action = {'nombre': 'x', 'pasos': [{'tipo': 'esperar', 'segundos': 0}]}
        outcomes = [mod.ejecutar_accion(action, parent), mod.ejecutar_accion(action, None)]
        log = open(mod.ERROR_LOG_FILE, encoding='utf-8').read()
        result = {'outcomes': outcomes, 'errors': errors, 'sent': sent, 'logged': log.count('bad step') >= 2}
    ''')
    assert result['outcomes'] == [None, None] and result['logged'], result
    assert len(result['errors']) == 1 and 'bad step' in result['errors'][0], result
    assert len(result['sent']) == 1 and 'bad step' in result['sent'][0], result


def test_title_search_without_a_title_is_rejected_in_all_four_step_types(sandbox):
    result = run_gui(sandbox, PREPARE, '''
        fields = {'ventana': ('combo_objetivo_ventana', 'entry_buscar_ventana'), 'clic': ('combo_objetivo_clic', 'entry_buscar_clic'),
                  'tecla': ('combo_objetivo_tecla', 'entry_buscar_tecla'), 'texto': ('combo_objetivo_texto', 'entry_buscar_texto')}
        dialog.entry_combinacion.set_text('ctrl+t'); dialog.entry_texto.set_text('hola')
        dialog.check_activar_ventana_clic.set_active(True)
        result = {}
        for kind, (combo_name, entry_name) in fields.items():
            dialog.combo_tipo.set_active_id(kind)
            getattr(dialog, combo_name).set_active_id('_buscar')
            outcomes = []
            for title in ('', '   ', 'Firefox'):
                getattr(dialog, entry_name).set_text(title)
                step, error = dialog.validar_y_construir()
                outcomes.append([error, (step or {}).get('objetivo_buscar')])
            result[kind] = outcomes
    ''')
    message = 'Enter the title (or part of the title) of the window to look for.'
    assert result == {kind: [[message, None], [message, None], [None, 'Firefox']]
                      for kind in ('ventana', 'clic', 'tecla', 'texto')}, result


@pytest.mark.parametrize('archivo', ['acciones.json', 'ajustes.json'])
def test_damaged_data_is_reported_once_when_the_main_window_opens(sandbox, archivo):
    sandbox.config.mkdir(parents=True)
    (sandbox.config / archivo).write_text('[{"id": "a1", "nom', encoding='utf-8')
    result = run_gui(sandbox, '''
        shown = []
        mod.VentanaPrincipal.mostrar_dialogo_error = lambda self, texto: shown.append(texto)
        main = mod.VentanaPrincipal(); main.show_all()
        main.cargar_lista()                     # two reloads queued before the first notice appears
        pump(500)
        main.cargar_lista(); pump(300)          # nothing new is damaged: the notice is not repeated
        result = {'shown': shown}
    ''')
    assert len(result['shown']) == 1, result
    assert f'{archivo}.corrupt-' in result['shown'][0], result


def test_no_data_notice_when_nothing_is_damaged(sandbox):
    result = run_gui(sandbox, '''
        shown = []
        mod.VentanaPrincipal.mostrar_dialogo_error = lambda self, texto: shown.append(texto)
        main = mod.VentanaPrincipal(); main.show_all(); pump(500)
        result = {'shown': shown}
    ''')
    assert result['shown'] == [], result


def test_failed_x11_install_shows_a_single_error_and_never_reports_success(sandbox):
    result = run_gui(sandbox, PREPARE, '''
        shown = {'exception': 0, 'error': 0, 'notice': 0}
        def count(key):
            return lambda *args, **kwargs: shown.__setitem__(key, shown[key] + 1)
        mod._mostrar_error_excepcion = count('exception')
        main.mostrar_dialogo_error = count('error')
        mod.notificar = count('notice')
        result = {}
        for failed in (True, False):
            for present in (False, True):
                for key in shown: shown[key] = 0
                mod.herramientas_x11_disponibles = lambda present=present: {'xdotool': present, 'wmctrl': present}
                main._terminar_instalacion_x11(main.btn_instalar_x11, RuntimeError('boom') if failed else None, '/tmp/x.log')
                result[f'failed={failed} present={present}'] = dict(shown)
    ''')
    assert result == {
        'failed=True present=False': {'exception': 1, 'error': 0, 'notice': 0},   # one dialog, not two
        'failed=True present=True': {'exception': 1, 'error': 0, 'notice': 0},    # no success notice after an error
        'failed=False present=False': {'exception': 0, 'error': 1, 'notice': 0},
        'failed=False present=True': {'exception': 0, 'error': 0, 'notice': 1}}, result


def test_closing_the_window_asks_before_discarding_a_half_filled_form(sandbox):
    result = run_gui(sandbox, '''
        mod.herramientas_x11_disponibles = lambda: {'xdotool': True, 'wmctrl': True}
        quits, asked, answers = [], [], [Gtk.ResponseType.NO, Gtk.ResponseType.YES]
        mod.Gtk.main_quit = lambda *args: quits.append(1)
        class FakeDialog:
            def __init__(self, **kw): asked.append(kw['text'])
            def run(self): return answers.pop(0)
            def destroy(self): pass
        mod.Gtk.MessageDialog = FakeDialog
        def close():  # what the window manager's close button does: WM_DELETE_WINDOW
            mod.subprocess.run(['wmctrl', '-c', 'Mi Lanzador']); pump(800)
        result = {}
        main = mod.VentanaPrincipal(); main.show_all(); pump(600)
        close()                                                  # nothing typed: closes without asking
        result['clean'] = [len(asked), len(quits)]
        asked.clear(); quits.clear()
        main = mod.VentanaPrincipal(); main.show_all(); pump(600)
        main.entry_nombre.set_text('Half-written')
        close()                                                  # answer «no»: the window and the form stay
        result['no'] = [len(asked), len(quits), main.get_visible(), main.entry_nombre.get_text()]
        close()                                                  # answer «yes»: it closes
        result['yes'] = [len(asked), len(quits)]
    ''')
    assert result['clean'] == [0, 1], result
    assert result['no'] == [1, 0, True, 'Half-written'], result
    assert result['yes'] == [2, 1], result


def test_selecting_or_double_clicking_an_action_deleted_from_disk_refreshes_the_list(sandbox):
    result = run_gui(sandbox, '''
        mod.herramientas_x11_disponibles = lambda: {'xdotool': True, 'wmctrl': True}
        shown, ran = [], []
        mod.VentanaPrincipal.mostrar_dialogo_error = lambda self, texto: shown.append(texto)
        mod.ejecutar_accion = lambda *args: ran.append(1)
        action = {'id': 'a1', 'nombre': 'One', 'pasos': []}
        mod.guardar_acciones([action])
        main = mod.VentanaPrincipal(); main.show_all(); pump(300)
        first = Gtk.TreePath.new_first()
        main.tree.get_selection().select_path(first)
        result = {'present': [(main.obtener_seleccion() or {}).get('id'), len(main.store)]}   # control: still on disk
        mod.guardar_acciones([])
        result['select'] = [main.obtener_seleccion(), len(main.store)]
        mod.guardar_acciones([action]); main.cargar_lista()
        mod.guardar_acciones([])
        main._on_fila_doble_clic(main.tree, first, None)
        result['double'] = [len(ran), len(main.store)]
        result['dialogs'] = shown
    ''')
    assert result == {'present': ['a1', 1], 'select': [None, 0], 'double': [0, 0], 'dialogs': []}, result


def test_actions_with_a_numeric_id_a_null_name_or_no_id_open_edit_and_run(sandbox):
    result = run_gui(sandbox, '''
        mod.herramientas_x11_disponibles = lambda: {'xdotool': True, 'wmctrl': True}
        ran = []
        mod.ejecutar_accion = lambda accion, *args: ran.append(accion['id'])
        mod.os.makedirs(mod.CONFIG_DIR, exist_ok=True)
        open(mod.ACCIONES_FILE, 'w', encoding='utf-8').write(
            '[{"id": 7, "nombre": 123, "pasos": []}, {"id": "b", "nombre": null, "pasos": []}, {"nombre": "Sin id", "pasos": []}]')
        main = mod.VentanaPrincipal(); main.show_all(); pump(300)
        result = {'rows': [row[2] for row in main.store], 'edit': []}
        for n in range(3):
            path = Gtk.TreePath.new_from_indices([n])
            main.tree.get_selection().select_path(path)
            main.editando_id = None; main.entry_nombre.set_text('')
            main._on_editar(None)
            result['edit'].append([bool(main.editando_id), main.entry_nombre.get_text()])
            main._on_fila_doble_clic(main.tree, path, None)
        result['ran'] = [i if i in ('7', 'b') else 'new-id' for i in ran]
    ''')
    assert result['rows'] == ['123', '', 'Sin id'], result
    assert result['edit'] == [[True, '123'], [True, ''], [True, 'Sin id']], result
    assert result['ran'] == ['7', 'b', 'new-id'], result

WRONG_TYPE_STEPS = [
    {'tipo': 'programa', 'modo': 'manual', 'ruta': None}, {'tipo': 'comando', 'comando': 5},
    {'tipo': 'texto', 'texto': 7}, {'tipo': 'esperar', 'segundos': 'abc'}, {'tipo': 'tecla', 'combinacion': None},
    {'tipo': 'web', 'url': None, 'espera': 'x', 'alias': 5},
    {'tipo': 'comando', 'comando': 'echo hi', 'alias': None, 'colocar_ventana': True,
     'accion_ventana': 'personalizada', 'personalizada_x': 'a'},
    {'tipo': 'clic', 'activar_ventana': False, 'x': 'a', 'y': None}, {'tipo': 'nope'}, {'tipo': None}]


def test_steps_with_fields_of_the_wrong_type_let_the_window_open_and_the_step_be_edited_and_generated(sandbox):
    # Un JSON válido con ruta null, comando 5 o texto 7 en un paso impedía abrir la ventana en cada arranque.
    result = run_gui(sandbox, f'''
        import json
        mod.herramientas_x11_disponibles = lambda: {{'xdotool': True, 'wmctrl': True}}
        mod.os.makedirs(mod.CONFIG_DIR, exist_ok=True)
        steps = json.loads({json.dumps(json.dumps(WRONG_TYPE_STEPS))})
        json.dump([{{'id': 'a%d' % i, 'nombre': 'N', 'pasos': [s]}} for i, s in enumerate(steps)],
                  open(mod.ACCIONES_FILE, 'w', encoding='utf-8'))
        result = {{'window': 'ok', 'rows': 0, 'steps': []}}
        try:       # sin captura, el gancho del programa abriría un diálogo y la prueba se colgaría
            main = mod.VentanaPrincipal(); main.show_all(); pump(300)
        except Exception as exc:
            result['window'] = repr(exc)
        else:
            result['rows'] = len(main.store)
            for accion in mod.cargar_acciones():
                paso = accion['pasos'][0]
                try:
                    dialog = mod.DialogoPaso(main, [], paso_inicial=paso); dialog.show_all()
                    built, error = dialog.validar_y_construir()
                    dialog.destroy()
                    mod.generar_script_bash([paso], 'x')
                    result['steps'].append(error is not None or built['tipo'] in mod.ORDEN_TIPOS_PASO)
                except Exception as exc:
                    result['steps'].append(repr(exc))
    ''')
    assert result['window'] == 'ok' and result['rows'] == len(WRONG_TYPE_STEPS), result
    assert result['steps'] == [True] * len(WRONG_TYPE_STEPS), result   # sin excepción y nunca un paso sin tipo guardado como si nada


def test_settings_of_the_wrong_type_let_the_window_open_with_the_default_values(sandbox):
    sandbox.config.mkdir(parents=True)
    result = run_gui(sandbox, '''
        filas = []
        for navegador in (5, ['firefox'], {}, True, None):  # un TypeError al construir las pestañas impedía abrir la ventana
            pathlib.Path(mod.AJUSTES_FILE).write_text(json.dumps(
                {'navegador_predeterminado': navegador, 'notificaciones': 'no', 'crear_acceso_automatico': None}))
            main = mod.VentanaPrincipal(); main.show_all(); pump(100)
            filas.append([main.combo_navegador_defecto.get_active_id(), main.check_notificaciones.get_active(),
                          main.check_auto_acceso.get_active()])
            main.destroy()
        result = {'filas': filas}
    ''')
    assert result['filas'] == [['sistema', True, False]] * 5, result


def test_closing_the_dialog_during_the_pick_point_notice_cancels_the_capture(sandbox):
    # Cerrar el diálogo en el primer segundo no cancelaba nada: se ocultaba la ventana principal y empezaba la cuenta atrás.
    result = run_gui(sandbox, PREPARE, '''
        calls = []
        mod._capturar_punto_pantalla = lambda: calls.append(1) or (123, 45)
        dialog._on_elegir_punto_clic(None); pump(150)
        dialog.destroy(); pump(2000)
        result = {'calls': len(calls), 'flag': dialog._captura_en_curso, 'skip_taskbar': main.get_skip_taskbar_hint()}
    ''')
    assert result == {'calls': 0, 'flag': False, 'skip_taskbar': False}, result


def test_create_shortcut_button_is_disabled_while_no_destination_is_ticked(sandbox):
    # Con «Escritorio» y «Menú» desmarcados, «Crear» cerraba el diálogo sin crear nada ni avisar.
    result = run_gui(sandbox, PREPARE, '''
        seen = []
        def inspect():
            dialog = next(w for w in Gtk.Window.list_toplevels()
                          if isinstance(w, Gtk.Dialog) and w.get_title() == mod.tr('Crear acceso directo'))
            ok = dialog.get_widget_for_response(Gtk.ResponseType.OK)
            checks = [c for c in dialog.get_content_area().get_children() if isinstance(c, Gtk.CheckButton)]
            seen.append(ok.get_sensitive())                    # arranca con «Escritorio» marcado
            checks[0].set_active(False); seen.append(ok.get_sensitive())
            checks[1].set_active(True); seen.append(ok.get_sensitive())
            checks[1].set_active(False); seen.append(ok.get_sensitive())
            checks[0].set_active(True); seen.append(ok.get_sensitive())
            dialog.response(Gtk.ResponseType.CANCEL)
        GLib.timeout_add(300, inspect)
        main.crear_acceso_para({'id': 'abc', 'nombre': 'Demo', 'pasos': []})
        result = {'sensitive': seen}
    ''')
    assert result['sensitive'] == [True, False, True, False, True], result


def test_editing_a_step_whose_target_window_is_gone_keeps_the_reference_instead_of_switching_to_last_window(sandbox):
    # Si ningún paso anterior abre ya el alias, el selector caía en silencio a «Última ventana» y Aceptar cambiaba el destino.
    result = run_gui(sandbox, PREPARE, '''
        base = {'ventana': {'tipo': 'ventana', 'accion_ventana': 'maximizar'},
                'clic': {'tipo': 'clic', 'activar_ventana': True, 'x': 1, 'y': 2, 'boton': '1', 'doble': False},
                'tecla': {'tipo': 'tecla', 'combinacion': 'ctrl+s'}, 'texto': {'tipo': 'texto', 'texto': 'hola'}}
        previos = [{'tipo': 'web', 'url': 'https://example.org', 'alias': 'viva'}]
        result = {}
        for tipo, paso in base.items():
            for alias in ('gone', 'viva'):
                d = mod.DialogoPaso(main, previos, paso_inicial={**paso, 'objetivo_modo': '_alias', 'objetivo_alias': alias})
                combo = getattr(d, 'combo_objetivo_' + tipo)
                construido, error = d.validar_y_construir()
                result[f'{tipo}/{alias}'] = [combo.get_active_id(), combo.get_active_text(), len(combo.get_model()),
                                            construido.get('objetivo_modo'), construido.get('objetivo_alias'), error]
                d.destroy()
    ''')
    for tipo in ('ventana', 'clic', 'tecla', 'texto'):
        gone, viva = result[f'{tipo}/gone'], result[f'{tipo}/viva']
        assert gone[0] == '_alias:gone' and gone[3:] == ['_alias', 'gone', None], (tipo, gone)   # la referencia sigue ahí
        assert gone[1].startswith('⚠') and 'gone' in gone[1] and gone[2] == viva[2] + 1, (tipo, gone, viva)
        assert viva[0] == '_alias:viva' and not viva[1].startswith('⚠') and viva[3:] == ['_alias', 'viva', None], (tipo, viva)


def test_editing_a_step_with_an_unknown_browser_or_mouse_button_keeps_it_instead_of_switching_to_another_value(sandbox):
    # Con un id que el combo no conoce (JSON a mano), `set_active_id` no cambia nada: el combo se quedaba en su valor inicial
    # (el navegador de Ajustes, «Izquierdo») y Aceptar guardaba ese otro valor sin avisar; el resumen decía «Izquierdo».
    result = run_gui(sandbox, PREPARE, '''
        mod.guardar_ajustes({**mod.cargar_ajustes(), 'navegador_predeterminado': 'brave'})  # ni el probado ni 'sistema'
        base = {'navegador': {'tipo': 'web', 'url': 'https://example.org'},
                'boton': {'tipo': 'clic', 'activar_ventana': False, 'x': 1, 'y': 2, 'doble': False}}
        combos = {'navegador': 'combo_navegador', 'boton': 'combo_boton'}
        result = {}
        for campo, valores in {'navegador': ('opera', 'chromium', ''), 'boton': ('4', '3')}.items():
            for valor in valores:
                d = mod.DialogoPaso(main, [], paso_inicial={**base[campo], campo: valor})
                combo = getattr(d, combos[campo])
                construido, error = d.validar_y_construir()
                result[f'{campo}/{valor}'] = [combo.get_active_id(), combo.get_active_text(), len(combo.get_model()),
                                             construido.get(campo), error, mod.resumen_paso(construido)]
                d.destroy()
        result['filas'] = {'navegador': len(mod.NAVEGADORES), 'boton': len(mod.BOTONES_RATON)}
        result['textos'] = {'chromium': mod.tr('Chromium'), 'derecho': mod.tr('Derecho'), 'izquierdo': mod.tr('Izquierdo'),
                            'sistema': mod.tr(mod.NAVEGADORES['sistema']['nombre']),
                            'clic_4': mod.tr('Clic ({button})').format(button='4')}
    ''')
    filas, textos = result['filas'], result['textos']
    for campo, raro, conocido, texto_conocido in (('navegador', 'opera', 'chromium', textos['chromium']),
                                                  ('boton', '4', '3', textos['derecho'])):
        desconocido, normal = result[f'{campo}/{raro}'], result[f'{campo}/{conocido}']
        assert desconocido[:5] == [raro, raro, filas[campo] + 1, raro, None], (campo, desconocido)   # su id, como una fila más
        assert normal[:5] == [conocido, texto_conocido, filas[campo], conocido, None], (campo, normal)
    assert result['navegador/'][:5] == ['sistema', textos['sistema'], filas['navegador'], 'sistema', None], result['navegador/']  # vacío = ausente
    assert textos['clic_4'] in result['boton/4'][5] and textos['izquierdo'] not in result['boton/4'][5], result['boton/4']
    assert textos['derecho'] in result['boton/3'][5], result['boton/3']


def test_an_unknown_default_browser_is_shown_in_settings_and_in_a_new_web_step_and_saving_settings_keeps_it(sandbox):
    # El combo de Ajustes quedaba vacío y «Guardar ajustes» guardaba «sistema»; el paso web nuevo, que parte del navegador
    # de Ajustes, también salía con el combo vacío.
    sandbox.config.mkdir(parents=True)
    result = run_gui(sandbox, '''
        mod.notificar = lambda *args, **kwargs: None
        pathlib.Path(mod.AJUSTES_FILE).write_text(json.dumps({'navegador_predeterminado': 'opera'}))
    ''', PREPARE, '''
        combo = main.combo_navegador_defecto
        en_ajustes = [combo.get_active_id(), combo.get_active_text(), len(combo.get_model())]
        main._on_guardar_ajustes(None)
        result = {'en_ajustes': en_ajustes, 'guardado': mod.cargar_ajustes()['navegador_predeterminado'],
                  'paso_nuevo': [dialog.combo_navegador.get_active_id(), dialog.combo_navegador.get_active_text()],
                  'filas': len(mod.NAVEGADORES)}
    ''')
    assert result['en_ajustes'] == ['opera', 'opera', result['filas'] + 1], result
    assert result['guardado'] == 'opera', result
    assert result['paso_nuevo'] == ['opera', 'opera'], result


def test_deleting_or_editing_one_of_two_actions_that_shared_an_id_leaves_the_other_untouched(sandbox):
    result = run_gui(sandbox, '''
        mod.herramientas_x11_disponibles = lambda: {'xdotool': True, 'wmctrl': True}
        mod.os.makedirs(mod.CONFIG_DIR, exist_ok=True)
        open(mod.ACCIONES_FILE, 'w', encoding='utf-8').write(json.dumps([
            {'id': 'dup', 'nombre': 'Primera', 'pasos': [{'tipo': 'esperar', 'segundos': 1}]},
            {'id': 'dup', 'nombre': 'Segunda', 'pasos': [{'tipo': 'esperar', 'segundos': 2}]}]))
        main = mod.VentanaPrincipal(); main.show_all(); pump(300)
        main.tree.get_selection().select_path(Gtk.TreePath.new_from_indices([1]))
        main._on_editar(None)
        result = {'editing': main.entry_nombre.get_text()}
        main.entry_nombre.set_text('Segunda editada')
        mod.Gtk.MessageDialog.run = lambda self: Gtk.ResponseType.NO       # «¿crear también un acceso directo?»
        main._on_guardar_accion(None)
        result['after_edit'] = [a['nombre'] for a in mod.cargar_acciones()]
        main.tree.get_selection().select_path(Gtk.TreePath.new_from_indices([1]))
        mod.Gtk.MessageDialog.run = lambda self: Gtk.ResponseType.YES
        main._on_eliminar(None)
        result['after_delete'] = [a['nombre'] for a in mod.cargar_acciones()]
    ''')
    assert result == {'editing': 'Segunda', 'after_edit': ['Primera', 'Segunda editada'],
                      'after_delete': ['Primera']}, result


L_KEY_SETUP = '''
mod.herramientas_x11_disponibles = lambda: {'xdotool': True, 'wmctrl': True}
mod.guardar_acciones([{'id': 'a1', 'nombre': 'Lanzar copia', 'pasos': [{'tipo': 'esperar', 'segundos': 1}]}])
main = mod.VentanaPrincipal(); main.show_all(); pump(300)
switched = []
main._on_cambiar_idioma = lambda widget: switched.append(1)
Gdk = mod.Gdk
def press(keyval, state=0):
    event = Gdk.Event.new(Gdk.EventType.KEY_PRESS)
    event.keyval, event.state = keyval, Gdk.ModifierType(state)
    try:
        return main._on_tecla_idioma(main, event)
    except Exception as error:      # in the real window this opens the modal «unexpected error» dialog
        return type(error).__name__
'''


def test_pressing_keys_in_the_main_window_raises_no_error_and_l_switches_language_only_where_it_cannot_be_typing(sandbox):
    result = run_gui(sandbox, L_KEY_SETUP, '''
        Gdk = mod.Gdk
        outcome = {}
        for name, widget in (('entry', main.entry_nombre), ('list', main.tree), ('steps', main.tree_pasos),
                             ('button', main.btn_guardar), ('notebook', main.notebook)):
            main.set_focus(widget); before = len(switched)
            outcome[name] = [press(Gdk.KEY_l), len(switched) - before]
        main.set_focus(main.btn_guardar); before = len(switched)
        outcome['other_key'] = [press(Gdk.KEY_a), len(switched) - before]
        outcome['ctrl_l'] = [press(Gdk.KEY_l, int(Gdk.ModifierType.CONTROL_MASK)), len(switched) - before]
        outcome['alt_l'] = [press(Gdk.KEY_l, int(Gdk.ModifierType.MOD1_MASK)), len(switched) - before]
        result = outcome
    ''')
    assert result == {'entry': [False, 0], 'list': [False, 0], 'steps': [False, 0], 'button': [True, 1],
                      'notebook': [True, 1], 'other_key': [False, 0], 'ctrl_l': [False, 0], 'alt_l': [False, 0]}, result


def test_the_program_and_document_app_entries_complete_from_the_same_catalog_and_remember_the_chosen_desktop(sandbox):
    result = run_gui(sandbox, '''
        funciones = []
        original = Gtk.EntryCompletion.set_match_func
        Gtk.EntryCompletion.set_match_func = lambda self, func, *data: (funciones.append(func), original(self, func, *data))[1]
        dialog = mod.DialogoPaso(None, []); dialog.show_all(); pump(200)
        store = dialog.store_apps
        store.clear()
        store.append(['Editor de texto', '/apps/editor.desktop', 'editor %U'])
        store.append(['Navegador', '/apps/nav.desktop', 'nav'])
        result = {'funciones': len(funciones)}
        for clave, entrada, atributo in (('programa', dialog.entry_app_instalada, '_ruta_app_seleccionada'),
                                         ('documento', dialog.entry_app_documento, '_ruta_app_documento_seleccionada')):
            completado = entrada.get_completion()
            modelo = completado.get_model()
            devuelto = completado.emit('match-selected', modelo, modelo.get_iter_from_string('1'))
            result[clave] = [modelo.iter_n_children(None), entrada.get_text(), entrada.get_position(), getattr(dialog, atributo), devuelto]
        fila = store.get_iter_first()
        result['coincide'] = [[f(None, texto, fila) for texto in ('editor', 'TEXTO', 'zzz', '')] for f in funciones]
    ''')
    elegido = [2, 'Navegador', 9, '/apps/nav.desktop', True]
    assert result == {'funciones': 2, 'programa': elegido, 'documento': elegido,
                      'coincide': [[True, True, False, True]] * 2}, result


def test_step_test_still_runs_after_the_temp_folder_was_deleted_while_the_dialog_was_open(sandbox):
    result = run_gui(sandbox, PREPARE, '''
        import shutil
        shown = []
        dialog._mostrar_info_prueba = lambda texto, es_error=False: shown.append([texto, es_error])
        dialog.validar_y_construir = lambda: ({'tipo': 'esperar', 'segundos': 0}, None)
        shutil.rmtree(mod.TMP_DIR)
        dialog._on_probar_paso(Gtk.Button(label='Test')); pump(1500)
        result = {'shown': shown}
    ''')
    assert len(result['shown']) == 1 and result['shown'][0][1] is False and 'running Step test' in result['shown'][0][0], result


def test_a_click_as_first_step_waits_for_the_main_window_to_be_minimised_but_other_first_steps_start_at_once(sandbox):
    # The click used to fire before the window manager had minimised the window, which was still in view (opening a
    # program or a web page takes longer and never had the problem). With a manager that never minimises, the action
    # still starts, after about a second. The waits poll the real state, with a cap, instead of pausing for a fixed
    # time: a loaded machine makes the test slower, not wrong. Each restore waits for the previous minimise to have
    # happened first; otherwise the manager could still be minimising when the next scenario starts.
    result = run_gui(sandbox, '''
        import time
        def pump_until(condition, seconds=20):
            end = time.monotonic() + seconds
            while not condition() and time.monotonic() < end:
                pump(20)
            return condition()
        main = mod.VentanaPrincipal(); main.show_all(); pump_until(main.is_active)
        minimised = lambda: bool(main.get_window().get_state() & mod.Gdk.WindowState.ICONIFIED)
        seen = []
        mod.ejecutar_accion = lambda accion, ventana: seen.append((accion['nombre'], minimised()))
        action = lambda tipo: {'nombre': tipo, 'pasos': [{'tipo': tipo}, {'tipo': 'esperar', 'segundos': 0}]}
        main._lanzar_accion(action('clic')); pump_until(lambda: seen)
        click = list(seen)
        main.deiconify(); pump_until(lambda: not minimised()); del seen[:]
        others = [tipo for tipo in mod.ORDEN_TIPOS_PASO if tipo != 'clic']
        for tipo in others: main._lanzar_accion(action(tipo))
        at_once = [name for name, _ in seen]
        pump_until(minimised)   # the manager has not yet processed the requests above: wait for them before restoring
        main.deiconify(); pump_until(lambda: not minimised()); del seen[:]
        main.iconify = lambda: None
        started = time.monotonic()
        main._lanzar_accion(action('clic')); pump_until(lambda: seen)
        result = {'click': click, 'others': others, 'at_once': at_once, 'never_minimised': list(seen),
                  'waited': time.monotonic() - started}
    ''')
    assert result['click'] == [['clic', True]], result
    assert len(result['others']) == 8 and result['at_once'] == result['others'], result
    assert result['never_minimised'] == [['clic', False]] and result['waited'] >= 0.9, result   # cap: 40 x 25 ms
