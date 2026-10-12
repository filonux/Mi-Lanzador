#!/usr/bin/env python3
import ast
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = pathlib.Path(os.environ.get('MI_LANZADOR_TEST_SCRIPT') or ROOT / 'script' / 'mi-lanzador.sh')


@pytest.fixture(autouse=True)
def _restore_environment_after_test():
    original, gi = os.environ.copy(), {k: sys.modules.get(k) for k in ('gi', 'gi.repository')}
    yield
    for key in set(os.environ) - set(original):
        os.environ.pop(key, None)
    os.environ.update(original)
    for name, module in gi.items():  # load_module() las sustituye por stubs; sin restaurarlas, el resto de la suite cargaría el script sin GTK
        if module is None:
            sys.modules.pop(name, None)
        else:
            sys.modules[name] = module


def embedded_python():
    text = SCRIPT.read_text(encoding='utf-8')
    return text.split("exec python3 - \"$@\" <<'PYEOF'\n", 1)[1].split('\nPYEOF', 1)[0]


def load_module(language='en'):
    src = embedded_python()
    import types

    class Dummy:
        def __call__(self, *args, **kwargs): return Dummy()
        def __getattr__(self, name): return Dummy()
        def __iter__(self): return iter(())
        def __bool__(self): return False

    class DummyWidget:
        def __init__(self, *args, **kwargs): pass

    repo = types.ModuleType('gi.repository')
    gtk = Dummy(); gtk.Dialog = DummyWidget; gtk.Window = DummyWidget
    repo.Gtk, repo.Gdk, repo.GLib, repo.GdkPixbuf, repo.Notify = gtk, Dummy(), Dummy(), Dummy(), Dummy()
    gi = types.ModuleType('gi')
    gi.require_version = lambda *args: None
    gi.repository = repo
    sys.modules['gi'] = gi
    sys.modules['gi.repository'] = repo

    td = tempfile.TemporaryDirectory()
    os.environ['MI_LANZADOR_CONFIG_DIR'] = td.name
    os.environ['HOME'] = td.name
    os.environ['MI_LANZADOR_IDIOMA'] = language
    ns = {'__name__': 'filonux_test', '__file__': str(SCRIPT)}  # no pre-seeded names
    exec(compile(src, '<embedded>', 'exec'), ns)
    ns['_test_tmpdir'] = td
    return ns


def ast_tree():
    return ast.parse(embedded_python())


def assignment(tree, name):
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in node.targets):
            return ast.literal_eval(node.value)
    raise AssertionError(name)


def test_syntax_and_embedded_import():
    subprocess.run(['bash', '-n', str(SCRIPT)], check=True)
    compile(embedded_python(), '<embedded>', 'exec')
    ns = load_module('en')
    assert len(ns['TR_EN']) > 200
    ns['_test_tmpdir'].cleanup()


def test_locale_precedence_and_default():
    cases = [
        ({'LANG': 'es_ES.UTF-8'}, 'es'),
        ({'LANG': 'es.UTF-8'}, 'es'),
        ({'LANG': 'es_ES.UTF-8@traditional'}, 'es'),
        ({'LANG': 'es-ES.UTF-8'}, 'es'),
        ({'LANG': 'en_US.UTF-8'}, 'en'),
        ({'LANG': 'en.UTF-8'}, 'en'),
        ({'LANG': 'en_US.UTF-8', 'LC_MESSAGES': 'es_ES.UTF-8'}, 'es'),
        ({'LANG': 'es_ES.UTF-8', 'LC_ALL': 'en_US.UTF-8'}, 'en'),
        ({'LANGUAGE': 'es:en', 'LANG': 'en_US.UTF-8'}, 'en'),
        ({'LANG': 'ca_ES.UTF-8'}, 'en'),
        ({'LANG': 'C.UTF-8'}, 'en'),
        ({}, 'en'),
    ]
    for locale_env, expected in cases:
        with tempfile.TemporaryDirectory() as home:
            env = os.environ.copy()
            env['HOME'] = home
            env['MI_LANZADOR_CONFIG_DIR'] = str(pathlib.Path(home) / '.config' / 'mi-lanzador')
            env.pop('MI_LANZADOR_LANG', None)
            for key in ('LC_ALL', 'LC_MESSAGES', 'LANGUAGE', 'LANG'):
                env.pop(key, None)
            env.update(locale_env)
            r = subprocess.run(['bash', str(SCRIPT), '--print-language'], env=env, capture_output=True, text=True, check=True)
            assert r.stdout.strip() == expected, (locale_env, r.stdout, r.stderr)


def test_python_locale_detection_matches_shell_contract():
    ns = load_module('en')
    try:
        original = {k: os.environ.get(k) for k in ('LC_ALL', 'LC_MESSAGES', 'LANGUAGE', 'LANG')}
        cases = [
            ({'LC_ALL': 'en_US.UTF-8', 'LC_MESSAGES': 'es_ES.UTF-8', 'LANG': 'es_ES.UTF-8'}, 'en'),
            ({'LC_MESSAGES': 'es_ES.UTF-8', 'LANG': 'en_US.UTF-8'}, 'es'),
            ({'LANGUAGE': 'es:en', 'LANG': 'en_US.UTF-8'}, 'en'),
            ({'LANG': 'de_DE.UTF-8'}, 'en'),
            ({}, 'en'),
        ]
        for locale_env, expected in cases:
            for key in ('LC_ALL', 'LC_MESSAGES', 'LANGUAGE', 'LANG'):
                os.environ.pop(key, None)
            os.environ.update(locale_env)
            assert ns['_detectar_idioma_sistema']() == expected, (locale_env, expected)
        for key, value in original.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
    finally:
        ns['_test_tmpdir'].cleanup()


def test_saved_language_and_one_launch_override():
    with tempfile.TemporaryDirectory() as home:
        cfg = pathlib.Path(home) / '.config' / 'mi-lanzador'
        cfg.mkdir(parents=True)
        (cfg / 'idioma').write_text('es\n', encoding='utf-8')
        env = os.environ.copy(); env.update(HOME=home, MI_LANZADOR_CONFIG_DIR=str(cfg), LANG='en_US.UTF-8')
        for k in ('LC_ALL', 'LC_MESSAGES', 'LANGUAGE'):
            env.pop(k, None)
        assert subprocess.run(['bash', str(SCRIPT), '--print-language'], env=env, capture_output=True, text=True, check=True).stdout.strip() == 'es'
        env['MI_LANZADOR_LANG'] = 'en'
        assert subprocess.run(['bash', str(SCRIPT), '--print-language'], env=env, capture_output=True, text=True, check=True).stdout.strip() == 'en'
        assert (cfg / 'idioma').read_text(encoding='utf-8') == 'es\n'
        env.pop('MI_LANZADOR_LANG')
        (cfg / 'idioma').write_text('fr\n', encoding='utf-8')
        assert subprocess.run(['bash', str(SCRIPT), '--print-language'], env=env, capture_output=True, text=True, check=True).stdout.strip() == 'en'


def test_translation_quality_and_placeholders():
    t = ast_tree(); d = assignment(t, 'TR_EN')
    keys = [n.value for n in next(n for n in t.body if isinstance(n, ast.Assign) and any(isinstance(x, ast.Name) and x.id == 'TR_EN' for x in n.targets)).value.keys if isinstance(n, ast.Constant)]
    assert len(keys) == len(set(keys)), 'duplicate translation keys'
    direct = {n.args[0].value for n in ast.walk(t) if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == 'tr' and n.args and isinstance(n.args[0], ast.Constant) and isinstance(n.args[0].value, str)}
    assert direct <= set(d), sorted(direct - set(d))
    for source, english in d.items():
        assert isinstance(english, str)
        assert source != english or source in {'Mi Lanzador', 'English', 'URL:'}
        assert sorted(re.findall(r'\{[A-Za-z_][A-Za-z0-9_]*\}', source)) == sorted(re.findall(r'\{[A-Za-z_][A-Za-z0-9_]*\}', english)), source
    en = load_module('en'); es = load_module('es')
    try:
        checks = [
            ('Abrir programa', 'Open program'),
            ('Abrir documento / archivo', 'Open document / file'),
            ('Abrir sitio web', 'Open website'),
            ('Ejecutar comando', 'Run command'),
            ('Buscar título:', 'Window title:'),
            ('Central (rueda)', 'Middle (mouse wheel)'),
            ('Doble clic', 'Double-click'),
            ('Cancelar', 'Cancel'),
            ('Aceptar', 'OK'),
            ('Crear', 'Create'),
        ]
        for source, expected in checks:
            assert es['tr'](source) == source
            assert en['tr'](source) == expected
        assert en['tr']('Cadena no catalogada') == 'Cadena no catalogada'
        assert en['tr']('Ventana de: {value}').format(value='Firefox') == 'Window: Firefox'
        assert en['tr']('No se encuentra el archivo:\n{path}\n\n¿Se ha movido o borrado?').format(path='/tmp/a') == 'File not found:\n/tmp/a\n\nWas it moved or deleted?'
    finally:
        en['_test_tmpdir'].cleanup(); es['_test_tmpdir'].cleanup()


def test_translation_preserves_formatting_and_markup_contracts():
    tree = ast_tree(); d = assignment(tree, 'TR_EN')
    def markup_tokens(text):
        return [re.sub(r'\s+', ' ', token).strip() for token in re.findall(r'</?[A-Za-z][^>]*>', text)]
    for source, english in d.items():
        assert source.count('\n') == english.count('\n'), source
        assert source.count('\t') == english.count('\t'), source
        assert markup_tokens(source) == markup_tokens(english), source
        assert source[:1].isspace() == english[:1].isspace()
        assert source[-1:].isspace() == english[-1:].isspace()
        assert '«' not in english and '»' not in english, source  # en inglés se usan “ ”


def test_all_visible_ui_literals_are_localized():
    tree = ast_tree()
    ui_calls = {'_fila_grid', 'set_text', 'set_title', 'set_placeholder_text', 'set_markup', 'set_label', 'set_tooltip_text', 'set_secondary_text', 'set_name'}
    suspicious = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        fn = node.func.attr if isinstance(node.func, ast.Attribute) else node.func.id if isinstance(node.func, ast.Name) else ''
        if fn not in ui_calls:
            continue
        for value_node in list(node.args) + [k.value for k in node.keywords if k.arg in {'label', 'title', 'text', 'markup', 'message'}]:
            if isinstance(value_node, ast.Constant) and isinstance(value_node.value, str) and re.search(r'[A-Za-zÁÉÍÓÚÜÑáéíóúüñ]', value_node.value):
                if value_node.value not in {'https://...'} and not value_node.value.startswith(('sudo ', 'xdg-', 'notify-send')):
                    suspicious.append((node.lineno, fn, value_node.value))
    assert not suspicious, suspicious


def test_user_facing_error_calls_use_translation_layer():
    tree = ast_tree()
    bad = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == 'mostrar_dialogo_error':
            if node.args and isinstance(node.args[0], ast.Constant) and isinstance(node.args[0].value, str):
                bad.append((node.lineno, node.args[0].value))
    assert not bad, bad


def test_exception_contexts_are_translated():
    tree = ast_tree()
    contexts = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == '_mostrar_error_excepcion':
            if len(node.args) > 1 and isinstance(node.args[1], ast.Constant) and isinstance(node.args[1].value, str):
                contexts.append((node.lineno, node.args[1].value))
    assert not contexts, contexts


def test_summary_outputs_are_native_in_both_languages():
    ns = load_module('en')
    try:
        samples = [
            {'tipo':'programa','modo':'manual','ruta':'/usr/bin/echo','argumentos':'hello'},
            {'tipo':'documento','ruta':'/tmp/report.pdf'},
            {'tipo':'web','url':'https://example.test','nueva_ventana':True},
            {'tipo':'comando','comando':'notify-send hello'},
            {'tipo':'esperar','segundos':2.5},
            {'tipo':'ventana','objetivo_modo':'_ultima','accion_ventana':'mitad_izq'},
            {'tipo':'clic','x':10,'y':20,'boton':'1','doble':True,'activar_ventana':True,'objetivo_modo':'_ultima'},
            {'tipo':'tecla','combinacion':'ctrl+shift+t','objetivo_modo':'_ultima'},
            {'tipo':'texto','texto':'Hello + chars','objetivo_modo':'_ultima'},
        ]
        for lang in ('es','en'):
            ns['IDIOMA'] = lang
            out = '\n'.join(ns['resumen_paso'](p) for p in samples)
            if lang == 'en':
                assert 'Open website:' in out
                assert 'Double-click (Left)' in out
                assert 'Send "ctrl+shift+t"' in out
                assert 'Window: ' not in out
                assert 'ventana' not in out.lower()
            else:
                assert 'Abrir sitio web:' in out
                assert 'Clic doble (Izquierdo)' in out
                assert 'Tecla "ctrl+shift+t"' in out
        assert ns['_validar_rango_personalizada']({'personalizada_x': 80, 'personalizada_w': 30}).startswith('X position')
        ns['IDIOMA'] = 'es'
        assert ns['_validar_rango_personalizada']({'personalizada_y': 80, 'personalizada_h': 30}).startswith('La posición Y')
    finally:
        ns['_test_tmpdir'].cleanup()


def test_generated_script_is_language_invariant_and_desktop_entry_localized():
    ns = load_module('es')
    try:
        steps = [
            {'tipo':'programa','modo':'manual','ruta':'/usr/bin/echo','argumentos':'hello'},
            {'tipo':'documento','ruta':'/tmp/file.pdf'},
            {'tipo':'web','url':'https://example.test','nueva_ventana':True},
            {'tipo':'comando','comando':'printf %s hello'},
            {'tipo':'esperar','segundos':1},
            {'tipo':'clic','x':10,'y':20,'boton':'1'},
            {'tipo':'tecla','combinacion':'ctrl+t'},
            {'tipo':'texto','texto':'abc'},
        ]
        ns['IDIOMA'] = 'es'; es_script = ns['generar_script_bash'](steps, 'Test')
        ns['IDIOMA'] = 'en'; en_script = ns['generar_script_bash'](steps, 'Test')
        def functional_lines(text):
            return '\n'.join(line for line in text.splitlines() if not line.startswith(('_ml_msg step_line', '_ml_msg running')))
        assert functional_lines(es_script) == functional_lines(en_script)
        entry = ns['generar_desktop_entry']({'nombre':'Demo','id':'abc','pasos':steps}, 'system-run')
        assert 'Name=Demo\n' in entry
        assert 'Comment[es]=Acceso directo creado con Mi Lanzador' in entry
        assert 'Comment=Shortcut created with Mi Lanzador' in entry  # unsuffixed = English fallback
        assert 'Comment[en]' not in entry
        assert 'Exec=' in entry and '--ejecutar abc' in entry
    finally:
        ns['_test_tmpdir'].cleanup()


@pytest.mark.parametrize('start, expected', [('es', 'en'), ('en', 'es')])
def test_language_toggle_restarts_and_the_launcher_reads_back_the_saved_language(start, expected):
    ns = load_module(start)
    try:
        obj = object.__new__(ns['VentanaPrincipal'])
        obj.pasos_actual = []
        obj.editando_id = None
        obj.entry_nombre = type('Field', (), {'get_text': lambda self: ''})()
        obj._hay_cambios_sin_guardar = lambda: False
        obj.btn_idioma = object()
        captured = []
        old_execv = ns['os'].execv
        ns['os'].execv = lambda *args: captured.append(args)
        try:
            obj._on_cambiar_idioma(obj.btn_idioma)
        finally:
            ns['os'].execv = old_execv
        assert pathlib.Path(ns['IDIOMA_FILE']).read_text(encoding='utf-8').strip() == expected
        assert captured == [('/bin/bash', ['/bin/bash', ns['APP_SCRIPT_PATH']])]
        with tempfile.TemporaryDirectory() as home:  # the restarted launcher must pick up the saved choice, not the locale
            cfg = pathlib.Path(home) / '.config' / 'mi-lanzador'
            cfg.mkdir(parents=True)
            shutil.copy(ns['IDIOMA_FILE'], cfg / 'idioma')
            env = {k: v for k, v in os.environ.items() if k not in ('LC_ALL', 'LC_MESSAGES', 'LANGUAGE', 'MI_LANZADOR_LANG', 'MI_LANZADOR_CONFIG_DIR')}
            env.update(HOME=home, LANG='es_ES.UTF-8' if expected == 'en' else 'en_US.UTF-8')
            out = subprocess.run(['bash', str(SCRIPT), '--print-language'], env=env, capture_output=True, text=True, check=True)
            assert out.stdout.strip() == expected
    finally:
        ns['_test_tmpdir'].cleanup()


def test_generated_script_locale_detection_handles_encoding():
    ns = load_module('en')
    try:
        script = ns['generar_script_bash']([{'tipo': 'comando', 'comando': 'true'}], 'Locale test')
        with tempfile.TemporaryDirectory() as td:
            path = pathlib.Path(td) / 'generated.sh'
            path.write_text(script, encoding='utf-8')
            path.chmod(0o755)
            env = os.environ.copy()
            env['HOME'] = td
            env.pop('MI_LANZADOR_IDIOMA', None)
            env['LANG'] = 'es_ES.UTF-8@traditional'
            env.pop('LC_ALL', None); env.pop('LC_MESSAGES', None); env.pop('LANGUAGE', None)
            env['PATH'] = str(pathlib.Path(td) / 'empty-bin')
            pathlib.Path(env['PATH']).mkdir()
            r_es = subprocess.run(['/bin/bash', str(path)], env=env, capture_output=True, text=True)
            assert 'Aviso: no se encontró ninguna terminal instalada' in r_es.stderr
            env['LANG'] = 'en-US.UTF-8'
            r_en = subprocess.run(['/bin/bash', str(path)], env=env, capture_output=True, text=True)
            assert 'Warning: no installed terminal was found' in r_en.stderr
    finally:
        ns['_test_tmpdir'].cleanup()


def test_desktop_catalogue_follows_ui_language_and_dedup_is_language_independent():
    for language, expected in (('es', 'Editor ES'), ('en', 'Editor EN')):
        ns = load_module(language)
        try:
            root = pathlib.Path(ns['_test_tmpdir'].name)
            d1 = root / 'apps-a'; d2 = root / 'apps-b'
            d1.mkdir(); d2.mkdir()
            (d1 / 'editor.desktop').write_text(
                '[Desktop Entry]\nType=Application\nName=Editor EN\nName[es]=Editor ES\nName[en]=Editor EN\nExec=/usr/bin/editor %U\n',
                encoding='utf-8')
            (d2 / 'editor-copy.desktop').write_text(
                '[Desktop Entry]\nType=Application\nName=Editor EN\nName[es]=Editor ES alternativo\nName[en]=Editor EN alternativo\nExec=/usr/bin/editor %U\n',
                encoding='utf-8')
            ns['_directorios_aplicaciones'] = lambda: [str(d1), str(d2)]
            apps = ns['listar_aplicaciones_instaladas']()
            assert len(apps) == 1
            assert apps[0]['nombre'] in {expected, expected + ' alternativo'}
            assert apps[0]['nombre_base'] == 'Editor EN'
        finally:
            ns['_test_tmpdir'].cleanup()


def test_desktop_catalogue_follows_the_spanish_interface_whatever_the_system_locale(monkeypatch):
    ns = load_module('es')
    try:
        data = {'Name': 'Generic', 'NameLocales': {
            'es': 'Spanish generic', 'es_es': 'Spanish Spain', 'es_es@valencia': 'Spanish Valencia', 'en_us': 'English US'}}
        cases = [({'LC_ALL': 'es_ES.UTF-8@valencia'}, 'Spanish Valencia'), ({'LC_ALL': 'es_ES.UTF-8'}, 'Spanish Spain'),
                 ({'LC_ALL': 'es_MX.UTF-8'}, 'Spanish generic'), ({'LC_ALL': 'en_US.UTF-8'}, 'Spanish generic'), ({}, 'Spanish generic')]
        for env_updates, expected in cases:
            for key in ('LC_ALL', 'LC_MESSAGES', 'LANG'):
                monkeypatch.delenv(key, raising=False)
            for key, value in env_updates.items():
                monkeypatch.setenv(key, value)
            assert ns['_nombre_localizado_desktop'](data) == expected, (env_updates, expected)
    finally:
        ns['_test_tmpdir'].cleanup()


def test_desktop_catalogue_matches_locale_hierarchy_within_selected_language():
    ns = load_module('en')
    try:
        data = {'Name': 'Generic', 'NameLocales': {
            'en': 'English generic',
            'en_us': 'English US',
            'en_us@latin': 'English US Latin',
            'en@latin': 'English Latin',
            'es_es': 'Spanish Spain',
        }}
        cases = [
            ({'LC_ALL': 'en_US.UTF-8@latin'}, 'English US Latin'),
            ({'LC_ALL': 'en_US.UTF-8'}, 'English US'),
            ({'LC_ALL': 'en_GB.UTF-8@latin'}, 'English Latin'),
            ({'LC_ALL': 'en_GB.UTF-8'}, 'English generic'),
            ({'LC_ALL': 'es_ES.UTF-8'}, 'English generic'),
            ({'LC_ALL': 'en-US.UTF-8'}, 'English US'),
        ]
        for env_updates, expected in cases:
            old = {k: os.environ.get(k) for k in ('LC_ALL', 'LC_MESSAGES', 'LANG')}
            try:
                for k in old: os.environ.pop(k, None)
                os.environ.update(env_updates)
                assert ns['_nombre_localizado_desktop'](data) == expected, (env_updates, expected)
            finally:
                for k, value in old.items():
                    if value is None: os.environ.pop(k, None)
                    else: os.environ[k] = value
    finally:
        ns['_test_tmpdir'].cleanup()


def test_dynamic_user_messages_are_localized():
    ns = load_module('en')
    try:
        assert ns['tr']('🎯 Coloca el cursor en el punto exacto\nCapturando en {seconds} s…').format(seconds=3) == '🎯 Place the cursor on the exact point\nCapturing in 3 s…'
        assert ns['tr']('🕒 Esta ventana se va a ocultar un momento: coloca el cursor donde quieras hacer clic. Tendrás {seconds} segundos en cuanto veas la cuenta atrás en la esquina.').format(seconds=3) == '🕒 This window will be hidden briefly: place the cursor where you want to click. You will have 3 seconds once you see the countdown in the corner.'
        assert ns['tr']('No se encontró ninguna acción con id "{id}"').format(id='missing') == 'No action was found with id "missing"'
    finally:
        ns['_test_tmpdir'].cleanup()


def test_language_layer_does_not_touch_core_generation():
    tree = ast_tree()
    core = {'_q', '_comando_shell_programa', '_comando_shell_documento',
            '_comando_shell_web', '_bloque_resolver_objetivo', '_lineas_posicionar_ventana',
            'generar_script_bash', '_pista_clase_para_paso'}
    funcs = {n.name: n for n in tree.body if isinstance(n, ast.FunctionDef)}
    for name in core:
        assert name in funcs
        assert not any(isinstance(n, ast.Name) and n.id in {'IDIOMA', 'TR_EN', 'tr'}
                       for n in ast.walk(funcs[name])), name


def _normalizar_script_para_comparar_idiomas(script):
    """Elimina únicamente la capa de presentación/locale para comparar conducta.

    La comparación conserva comandos, argumentos, resoluciones, sleeps,
    comprobaciones, control de ventanas y el flujo del script generado.
    """
    lines = script.splitlines()
    out = []
    in_ml_msg = False
    for line in lines:
        stripped = line.strip()
        if stripped == '_ml_msg() {':
            in_ml_msg = True
            continue
        if in_ml_msg:
            if stripped == '}':
                in_ml_msg = False
            continue
        if line.startswith('# Script generado por Mi Lanzador para la acción: '):
            continue
        if '_ML_LANG_FILE=' in line:
            continue
        if '_ML_LANG=' in line and ('MI_LANZADOR_IDIOMA' in line or '_ML_LOCALE' in line or '"$_ML_LANG"' in line):
            continue
        if '_ml_msg ' in line:
            continue
        if re.match(r"\s*printf '%s\\n' '  Paso [0-9]+: .*' >&2$", line):
            continue
        if re.match(r"\s*printf '%s\\n' '=== Mi Lanzador: ejecutando .* ===' >&2$", line):
            continue
        out.append(line)
    return '\n'.join(out)


def test_language_changes_presentation_but_not_generated_execution_flow():
    en = load_module('en')
    es = load_module('es')
    try:
        tmp = pathlib.Path(en['_test_tmpdir'].name)
        desktop = tmp / 'app.desktop'
        desktop.write_text(
            '[Desktop Entry]\nType=Application\nName=Demo\nExec=/usr/bin/xmessage %U\n',
            encoding='utf-8')
        steps = [
            {'tipo': 'programa', 'modo': 'manual', 'ruta': '/usr/bin/xmessage', 'argumentos': '--name "Demo" hola', 'alias': 'demo'},
            {'tipo': 'programa', 'modo': 'desktop', 'ruta_desktop': str(desktop), 'alias': 'desktop'},
            {'tipo': 'documento', 'ruta': '/tmp/example file.txt', 'abrir_con': 'sistema'},
            {'tipo': 'web', 'url': 'https://example.test', 'navegador': 'firefox', 'nueva_ventana': True, 'modo_app': False},
            {'tipo': 'web', 'url': 'https://example.test', 'navegador': 'chrome', 'nueva_ventana': False, 'modo_app': True},
            {'tipo': 'comando', 'comando': 'printf "%s\\n" ok'},
            {'tipo': 'esperar', 'segundos': 2},
            {'tipo': 'ventana', 'objetivo_modo': '_ultima', 'accion_ventana': 'centrada'},
            {'tipo': 'clic', 'x': 10, 'y': 20, 'coords_absolutas': True, 'activar_ventana': False, 'boton': '1', 'doble': False},
            {'tipo': 'clic', 'x': 5, 'y': 6, 'coords_absolutas': False, 'activar_ventana': True, 'objetivo_modo': '_alias', 'objetivo_alias': 'demo', 'boton': '2', 'doble': True},
            {'tipo': 'tecla', 'objetivo_modo': '_alias', 'objetivo_alias': 'demo', 'combinacion': 'ctrl+shift+t'},
            {'tipo': 'texto', 'objetivo_modo': '_alias', 'objetivo_alias': 'demo', 'texto': 'Hola + ñ'},
        ]
        es['TMP_DIR'] = en['TMP_DIR']  # el script lleva esa ruta (1.19) y cada módulo trae su carpeta temporal: solo debe diferir el idioma
        script_en = en['generar_script_bash'](steps, 'Action test')
        script_es = es['generar_script_bash'](steps, 'Prueba acción')
        subprocess.run(['bash', '-n'], input=script_en, text=True, check=True)
        subprocess.run(['bash', '-n'], input=script_es, text=True, check=True)
        assert _normalizar_script_para_comparar_idiomas(script_en) == _normalizar_script_para_comparar_idiomas(script_es)
    finally:
        en['_test_tmpdir'].cleanup(); es['_test_tmpdir'].cleanup()


def test_generated_runtime_messages_follow_language():
    ns = load_module('en')
    try:
        action = {'tipo': 'comando', 'comando': 'printf %s hello'}
        script = ns['generar_script_bash']([action], 'Runtime test')
        with tempfile.TemporaryDirectory() as td:
            path = pathlib.Path(td) / 'generated.sh'
            path.write_text(script, encoding='utf-8')
            os.chmod(path, 0o755)
            env = os.environ.copy(); env['HOME'] = td; env['MI_LANZADOR_IDIOMA'] = 'en'; env['PATH'] = str(pathlib.Path(td) / 'bin')
            r_en = subprocess.run(['/bin/bash', str(path)], env=env, capture_output=True, text=True, check=True)
            env['MI_LANZADOR_IDIOMA'] = 'es'
            r_es = subprocess.run(['/bin/bash', str(path)], env=env, capture_output=True, text=True, check=True)
        assert 'Warning: no installed terminal was found' in r_en.stderr
        assert 'Aviso: no se encontró ninguna terminal instalada' in r_es.stderr
        assert 'action finished' in r_en.stderr
        assert 'acción finalizada' in r_es.stderr

        # Static contract: all shipped runtime diagnostics must be translated through
        # the generated helper rather than being hard-coded as Spanish echoes.
        assert 'echo \"  Aviso:' not in script
        assert 'echo \"=== Mi Lanzador: acción finalizada ===\"' not in script
        assert '_ml_msg ' in script
        helper_start = script.index('_ml_msg() {')
        helper_end = script.index('\n}\n', helper_start) + 3
        helper = script[helper_start:helper_end]
        for text in (
            'Aviso: no se encontró ninguna terminal instalada',
            'Mi Lanzador: acción finalizada',
            'Aviso: falta wmctrl',
            'Aviso: no se pudo colocar la ventana',
            'Aviso: no se encontró la ventana objetivo',
            'Aviso: no se pudo determinar la coordenada del clic',
            'Aviso: xdotool no pudo simular el clic',
        ):
            assert text in helper
    finally:
        ns['_test_tmpdir'].cleanup()


def test_documentation_localization_and_links():
    en = (ROOT / 'README.md').read_text(encoding='utf-8')
    es = (ROOT / 'README.es.md').read_text(encoding='utf-8')
    assert '[🇪🇸 Leer en español](README.es.md)' in en
    assert '[🇬🇧 Read this README in English](README.md)' in es
    assert 'assets/demo-thumbnail.png' not in en + es
    assert len([l for l in en.splitlines() if l.startswith('## ')]) == len([l for l in es.splitlines() if l.startswith('## ')])
    assert '`L`' in en and '`L`' in es
    for filename in ('README.md', 'README.es.md'):
        text = (ROOT / filename).read_text(encoding='utf-8')
        for target in re.findall(r'\[[^]]+\]\(([^)]+)\)', text):
            if re.match(r'^[A-Za-z][A-Za-z0-9+.-]*:', target) or target.startswith('#'):
                continue
            clean = target.split('#', 1)[0].split('?', 1)[0]
            assert clean
            assert (ROOT / clean).resolve().is_file(), (filename, target)
