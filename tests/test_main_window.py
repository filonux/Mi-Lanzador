"""Lógica de VentanaPrincipal probada sin pantalla: sus métodos se prestan a un objeto con marcadores mínimos
(instanciar la clase real de GTK exigiría una pantalla)."""
import pathlib
import types

import pytest

METODOS = ('_on_guardar_accion', 'limpiar_formulario', '_on_editar', 'ir_a_tab_nueva',
           '_confirmar_descartar', '_hay_cambios_sin_guardar')
GUARDADA = {'id': 'a1', 'nombre': 'Guardada', 'pasos': [{'tipo': 'esperar', 'segundos': 1}]}


class Marcador:
    """Sustituye al widget GTK con lo único que usan los manejadores probados."""

    def __init__(self, text='', filename=None):
        self.text, self.filename, self.label, self.page = text, filename, '', None

    def get_text(self): return self.text
    def set_text(self, value): self.text = value
    def get_filename(self): return self.filename
    def unselect_all(self): self.filename = None
    def set_label(self, value): self.label = value
    def set_current_page(self, page): self.page = page


@pytest.fixture
def window(app, tmp_path, monkeypatch):
    win = type('FalsaVentana', (), {m: getattr(app.VentanaPrincipal, m) for m in METODOS})()
    win.entry_nombre, win.chooser_icono = Marcador('Demo'), Marcador()
    win.btn_guardar, win.notebook = Marcador(), Marcador()
    win.pasos_actual, win.editando_id = [{'tipo': 'esperar', 'segundos': 1}], None
    win.cargar_lista = win.refrescar_store_pasos = lambda: None
    win.obtener_dir_escritorio = lambda: str(tmp_path / 'Desktop')
    win.errors, win.avisos = [], []
    win.mostrar_dialogo_error = win.errors.append
    monkeypatch.setattr(app, 'notificar', lambda texto, *a: win.avisos.append(texto))
    monkeypatch.setattr(app, 'cargar_ajustes', lambda: {'crear_acceso_automatico': True})
    return win


def test_shortcut_failure_goes_to_the_error_log(app, tmp_path):
    ocupado = tmp_path / 'es-un-archivo'
    ocupado.write_text('x')  # makedirs sobre un archivo falla
    assert app.crear_acceso_directo({'id': 'a1', 'nombre': 'N', 'pasos': []}, [str(ocupado)]) == []
    assert 'crear acceso directo en' in (tmp_path / 'config' / 'error.log').read_text()


def test_automatic_shortcut_failure_is_reported_instead_of_announced_as_created(app, window, monkeypatch):
    monkeypatch.setattr(app, 'crear_acceso_directo', lambda accion, destinos: [])
    window._on_guardar_accion(None)
    assert len(window.errors) == 1 and 'could not be created on the Desktop' in window.errors[0]
    assert not any('created automatically' in aviso for aviso in window.avisos)


def test_automatic_shortcut_success_is_still_announced(app, window, monkeypatch):
    monkeypatch.setattr(app, 'crear_acceso_directo', lambda accion, destinos: ['/x.desktop'])
    window._on_guardar_accion(None)
    assert not window.errors and any('created automatically' in aviso for aviso in window.avisos)


@pytest.fixture
def pregunta(app, monkeypatch):
    """Sustituye el diálogo de confirmación: anota los textos y responde lo que valga `pregunta.respuesta`."""
    class Falsa:
        respuesta, textos = None, []

        def __init__(self, **kwargs): Falsa.textos.append(kwargs['text'])
        def run(self): return Falsa.respuesta
        def destroy(self): pass

    monkeypatch.setattr(app.Gtk, 'MessageDialog', Falsa)
    return Falsa


def test_editing_another_action_asks_before_replacing_a_form_with_changes(app, window, pregunta):
    window.obtener_seleccion = lambda: GUARDADA
    pregunta.respuesta = app.Gtk.ResponseType.NO
    window._on_editar(None)
    assert window.editando_id is None and window.entry_nombre.text == 'Demo' and len(pregunta.textos) == 1
    pregunta.respuesta = app.Gtk.ResponseType.YES
    window._on_editar(None)
    assert window.editando_id == 'a1' and window.entry_nombre.text == 'Guardada'


def test_editing_with_an_empty_form_does_not_ask(window, pregunta):
    window.entry_nombre.text, window.pasos_actual = '', []
    window.obtener_seleccion = lambda: GUARDADA
    window._on_editar(None)
    assert not pregunta.textos and window.editando_id == 'a1'


def test_plus_button_keeps_a_new_action_in_progress(window, pregunta):
    window.ir_a_tab_nueva()
    assert window.pasos_actual and window.entry_nombre.text == 'Demo' and window.notebook.page == 1
    assert not pregunta.textos


def test_plus_button_while_editing_asks_and_only_clears_when_confirmed(app, window, pregunta):
    window.editando_id = 'a1'
    pregunta.respuesta = app.Gtk.ResponseType.NO
    window.ir_a_tab_nueva()
    assert window.editando_id == 'a1' and window.pasos_actual and window.notebook.page is None
    pregunta.respuesta = app.Gtk.ResponseType.YES
    window.ir_a_tab_nueva()
    assert window.editando_id is None and window.pasos_actual == [] and window.notebook.page == 1


def con_referencia(abre, apunta):
    return [{'tipo': 'comando', 'comando': 'x', 'alias': abre},
            {'tipo': 'tecla', 'combinacion': 'a', 'objetivo_modo': '_alias', 'objetivo_alias': apunta}]


def test_window_references_that_no_earlier_step_opens_are_found(app):
    valido = con_referencia('a', 'a')
    assert app.referencias_rotas(valido) == []
    assert app.referencias_rotas(con_referencia('a', 'borrada')) == [(2, 'borrada')]
    assert app.referencias_rotas(valido[::-1]) == [(1, 'a')]  # el paso que abre la ventana quedó después
    sin_activar = [{'tipo': 'clic', 'activar_ventana': False, 'objetivo_modo': '_alias', 'objetivo_alias': 'x'}]
    assert app.referencias_rotas(sin_activar) == []  # el generador ignora el objetivo de un clic sin activar


def test_a_window_opened_without_alias_is_offered_and_accepted_under_its_position(app):
    pasos = con_referencia(None, '__paso0')
    assert [i for i, _ in app.alias_disponibles_antes_de(pasos, 1)] == ['__paso0']
    assert app.referencias_rotas(pasos) == []


def test_saving_refuses_a_step_aimed_at_a_window_that_no_longer_exists(app, window):
    window.pasos_actual = con_referencia('a', 'borrada')
    window._on_guardar_accion(None)
    assert len(window.errors) == 1 and 'Step 2' in window.errors[0] and 'borrada' in window.errors[0]
    assert 'skipped' in window.errors[0] and 'active' not in window.errors[0]
    assert app.cargar_acciones() == [] and window.pasos_actual and not window.avisos


def test_saving_accepts_a_step_aimed_at_an_earlier_window(app, window, monkeypatch):
    monkeypatch.setattr(app, 'crear_acceso_directo', lambda accion, destinos: ['/x.desktop'])
    window.pasos_actual = con_referencia('a', 'a')
    window._on_guardar_accion(None)
    assert not window.errors and len(app.cargar_acciones()) == 1


def test_saving_an_edited_action_replaces_it_instead_of_adding_another(app, window, monkeypatch):
    monkeypatch.setattr(app, 'crear_acceso_directo', lambda accion, destinos: ['/x.desktop'])
    window._on_guardar_accion(None)
    window.editando_id, window.entry_nombre.text = app.cargar_acciones()[0]['id'], 'Renombrada'
    window.pasos_actual = [{'tipo': 'esperar', 'segundos': 2}]  # guardar vació el formulario
    window._on_guardar_accion(None)
    assert [a['nombre'] for a in app.cargar_acciones()] == ['Renombrada'] and window.editando_id is None


def test_saving_refreshes_the_shortcuts_only_when_an_existing_action_is_edited(app, window, monkeypatch):
    monkeypatch.setattr(app, 'crear_acceso_directo', lambda accion, destinos: ['/x.desktop'])
    refrescadas = []
    monkeypatch.setattr(app, 'actualizar_accesos_directos', lambda accion: refrescadas.append(accion['nombre']))
    window._on_guardar_accion(None)
    assert refrescadas == []   # una acción nueva no tiene accesos que rehacer
    window.editando_id, window.entry_nombre.text = app.cargar_acciones()[0]['id'], 'Renombrada'
    window.pasos_actual = [{'tipo': 'esperar', 'segundos': 2}]
    window._on_guardar_accion(None)
    assert refrescadas == ['Renombrada']


class VentanaDeEjecucion:
    """Lo mínimo que usa `_lanzar_accion`: minimizar y mostrar un error."""

    def __init__(self, app):
        self.minimizada, self.errors = False, []
        self._lanzar_accion = lambda accion: app.VentanaPrincipal._lanzar_accion(self, accion)

    def iconify(self): self.minimizada = True
    def mostrar_dialogo_error(self, texto): self.errors.append(texto)


def test_running_an_action_without_steps_warns_instead_of_doing_nothing(app, monkeypatch):
    # Solo con el JSON editado a mano: guardar exige al menos un paso. Antes no pasaba nada, sin mensaje.
    avisos = []
    monkeypatch.setattr(app, 'notificar', lambda texto, titulo='': avisos.append((texto, titulo)))
    ventana = VentanaDeEjecucion(app)
    assert app.ejecutar_accion({'id': 'a1', 'nombre': 'Vacía', 'pasos': []}, ventana) is None
    assert ventana.errors == ['The action "Vacía" has no steps.'] and avisos == []
    assert app.ejecutar_accion({'id': 'a1', 'nombre': 'Vacía', 'pasos': []}, None) is None   # desde un .desktop
    assert avisos == [('The action "Vacía" has no steps.', 'Mi Lanzador ⚠')]


def test_the_window_is_minimised_only_when_the_action_has_steps_to_run(app, monkeypatch):
    lanzadas = []
    monkeypatch.setattr(app, 'ejecutar_accion', lambda accion, ventana: lanzadas.append(accion['nombre']))
    vacia, con_pasos = VentanaDeEjecucion(app), VentanaDeEjecucion(app)
    vacia._lanzar_accion({'nombre': 'Vacía', 'pasos': []})
    con_pasos._lanzar_accion({'nombre': 'Normal', 'pasos': [{'tipo': 'esperar', 'segundos': 1}]})
    assert (vacia.minimizada, con_pasos.minimizada) == (False, True)
    assert lanzadas == ['Vacía', 'Normal']   # la vacía también pasa por ejecutar_accion: es quien avisa


def test_saving_the_settings_keeps_the_keys_this_tab_does_not_edit(app, monkeypatch, tmp_path):
    # Antes se escribía un diccionario nuevo con solo las tres claves de la pestaña: el resto se perdía.
    app.guardar_ajustes({'navegador_predeterminado': 'firefox', 'crear_acceso_automatico': False, 'notificaciones': True,
                         'clave_de_otra_version': {'a': 1}})
    monkeypatch.setattr(app, 'notificar', lambda *a, **k: None)
    marca = lambda **k: types.SimpleNamespace(**k)
    ventana = marca(combo_navegador_defecto=marca(get_active_id=lambda: 'chrome'),
                    check_auto_acceso=marca(get_active=lambda: True),
                    check_notificaciones=marca(get_active=lambda: False))
    app.VentanaPrincipal._on_guardar_ajustes(ventana, None)
    assert app.cargar_ajustes() == {'navegador_predeterminado': 'chrome', 'crear_acceso_automatico': True,
                                    'notificaciones': False, 'clave_de_otra_version': {'a': 1}}


def test_only_icons_copied_by_the_app_are_deleted(app, tmp_path):
    propio, ajeno = pathlib.Path(app.ICONOS_DIR) / 'a1.png', tmp_path / 'mi-foto.png'
    propio.write_text('x'), ajeno.write_text('x')
    for ruta in (str(propio), str(ajeno), None, str(propio)):  # el último ya no existe: no es un error
        app._borrar_icono_propio(ruta)
    assert not propio.exists() and ajeno.exists()


class Fijo:
    """Control GTK mínimo: solo lo que leen los pasos que abren ventana."""

    def __init__(self, text='', value=0.0, active=False):
        self.text, self.value, self.active = text, value, active

    def get_text(self): return self.text
    def get_value(self): return self.value
    def get_active(self): return self.active


def lector_de_apertura(app, alias_prohibidos=()):
    dialogo = type('FalsoDialogo', (), {m: getattr(app.DialogoPaso, m) for m in ('_leer_apertura', '_leer_colocar_ventana')})()
    dialogo.pasos_previos, dialogo.alias_prohibidos = [], set(alias_prohibidos)
    dialogo.colocar_comando = {'check': Fijo()}
    return dialogo


def test_opening_steps_reject_an_alias_another_step_already_uses(app):
    paso = {'tipo': 'comando'}
    error = lector_de_apertura(app, {'editor'})._leer_apertura(paso, Fijo('editor'), Fijo(value=2), 'ls')
    assert 'editor' in error and 'alias' not in paso and 'espera' not in paso


def test_opening_steps_suggest_a_free_alias_and_round_the_wait(app):
    paso = {'tipo': 'comando'}
    assert lector_de_apertura(app, {'ls'})._leer_apertura(paso, Fijo(), Fijo(value=2.46), 'ls') is None
    assert paso == {'tipo': 'comando', 'alias': 'ls_2', 'espera': 2.5, 'colocar_ventana': False}
