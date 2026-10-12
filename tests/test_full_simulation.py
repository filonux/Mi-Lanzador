#!/usr/bin/env python3
import ast
import contextlib
import importlib.util
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import textwrap
import time
import types

from gi.repository import GLib as GLibReal

from conftest import TERMINALES, path_without, require_tools, x_session

ORIG_TRACEBACK_PRINT = __import__('traceback').print_exception

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = pathlib.Path(os.environ.get('MI_LANZADOR_TEST_SCRIPT') or ROOT / 'script' / 'mi-lanzador.sh')
I18N = ROOT / 'tests' / 'test_i18n.py'


def load_i18n():
    spec = importlib.util.spec_from_file_location('ti_full', I18N)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


base = load_i18n()


class W:
    def __init__(self, initial_text='', active=False, active_id=None, value=0, filename=None, *args, **kwargs):
        self.text = kwargs.pop('text', initial_text)
        self.active = active
        self.active_id = active_id
        self.value = value
        self.filename = filename
        self.visible_child = None
        self.sensitive = True
        self.label = ''
        self.visible = True
        self.current_page = 0
        self._selection = (None, None)
        self.rows = []
        self.buffer = self
        self.handlers = {}
        self.props = types.SimpleNamespace()
        self.iconified = False

    _NOOP_METHODS = {
        'set_border_width', 'set_default_size', 'set_icon_name', 'set_title', 'set_titlebar',
        'set_transient_for', 'get_transient_for', 'set_can_focus', 'set_justify', 'set_line_wrap',
        'set_margin_top', 'set_margin_bottom', 'set_margin_start', 'set_margin_end', 'override_background_color',
        'override_color', 'set_accept_focus', 'set_skip_taskbar_hint', 'set_skip_pager_hint',
        'set_vexpand', 'set_halign', 'set_no_show_all', 'set_active_id', 'set_active', 'set_sensitive',
        'set_visible', 'set_opacity', 'move', 'show_all', 'present', 'deiconify', 'hide', 'add_events',
        'pack_start', 'pack_end', 'attach', 'add', 'set_policy', 'set_min_content_height',
        'set_transition_type', 'add_titled', 'append_column', 'set_headers_visible',
        'get_style_context', 'add_class', 'set_size_request', 'set_editable', 'set_monospace',
        'set_completion', 'set_inline_selection', 'set_minimum_key_length', 'set_match_func',
        'set_line_wrap', 'set_selectable', 'set_content_width', 'set_content_height', 'set_text_column', 'set_spacing', 'set_placeholder_text', 'set_current_folder', 'set_name', 'add_pattern', 'add_filter', 'set_digits', 'set_tooltip_text', 'set_tab_pos', 'append_page', 'destroy', 'load_from_data', 'add_button', 'set_expand', 'set_markup', 'set_filter', 'set_show_close_button',
    }

    def __getattr__(self, name):
        if name in self._NOOP_METHODS:
            return lambda *args, **kwargs: self
        raise AttributeError(f'Strict GTK stub: unsupported attribute {name!r}')

    def connect(self, signal, callback, *args): self.handlers[signal] = (callback, args); return 1
    def emit(self, signal, *args):
        entry = self.handlers.get(signal)
        if entry:
            cb, extra = entry
            return cb(self, *args, *extra)
        return None
    def set_match_func(self, callback, *args): self.handlers['match-func'] = (callback, args)
    def set_completion(self, completion): self.completion = completion
    def get_text(self): return self.text
    def set_text(self, value): self.text = value
    def get_active(self): return self.active
    def set_active(self, value): self.active = value
    def get_active_id(self): return self.active_id
    def set_active_id(self, value): self.active_id = value
    def set_stack(self, value): self.stack = value
    def get_selection(self): return self
    def set_model(self, value): self.model = value
    def get_content_area(self): return self
    def add_buttons(self, *args): self.button_args = args
    def get_value(self): return self.value
    def get_value_as_int(self): return int(self.value)
    def set_value(self, value): self.value = value
    def get_filename(self): return self.filename
    def set_filename(self, value): self.filename = value
    def set_visible_child_name(self, value): self.visible_child = value
    def get_visible_child_name(self): return self.visible_child
    def get_focus(self): return self._focus if hasattr(self, '_focus') else None
    def set_label(self, value): self.label = value
    def get_label(self): return self.label
    def set_sensitive(self, value): self.sensitive = value
    def get_sensitive(self): return self.sensitive
    def set_visible(self, value): self.visible = value
    def get_visible(self): return self.visible
    def unselect_all(self): self.filename = None
    def select_path(self, path): self._selection = (self, path)
    def get_selected(self): return self._selection
    def get_model(self): return self
    def get_path(self, it): return types.SimpleNamespace(get_indices=lambda: (it if isinstance(it, int) else 0,))
    def __getitem__(self, key): return self.rows[key]
    def __iter__(self): return iter(self.rows)
    def append(self, *row): self.rows.append(row[0] if len(row)==1 else list(row)); return len(self.rows) - 1
    def clear(self): self.rows.clear()
    def get_buffer(self): return self
    def set_editable(self, value): pass
    def set_monospace(self, value): pass
    def set_current_page(self, value): self.current_page = value
    def get_current_page(self): return self.current_page
    def iconify(self): self.iconified = True


class Dialog(W):
    next_responses = []

    def response(self, value): self.response_value = value
    def run(self):
        if hasattr(self, '_run_hook'):
            self._run_hook()
        return self.__dict__.get('response_value') if self.__dict__.get('response_value') is not None else (self.next_responses.pop(0) if self.next_responses else 0)

    def destroy(self): self.destroyed = True


class MessageDialog(Dialog):
    pass


class GtkStub(types.SimpleNamespace):
    pass


Gtk = GtkStub(
    Dialog=Dialog,
    Window=type('Window', (W,), {}), StackSwitcher=type('StackSwitcher', (W,), {}), EntryCompletion=type('EntryCompletion', (W,), {}),
    Entry=type('Entry', (W,), {}), TextView=type('TextView', (W,), {}),
    SearchEntry=type('SearchEntry', (W,), {}), SpinButton=type('SpinButton', (W,), {'new_with_range': classmethod(lambda cls,*a: cls())}),
    CheckButton=type('CheckButton', (W,), {}), ComboBoxText=type('ComboBoxText', (W,), {}),
    Button=type('Button', (W,), {}), Label=type('Label', (W,), {}), Grid=type('Grid', (W,), {}),
    Box=type('Box', (W,), {}), Frame=type('Frame', (W,), {}), Image=type('Image', (W,), {'new_from_icon_name': classmethod(lambda cls,*a,**k: cls())}),
    Notebook=type('Notebook', (W,), {}), TreeView=type('TreeView', (W,), {}),
    TreeViewColumn=type('TreeViewColumn', (W,), {}), CellRendererText=type('CellRendererText', (W,), {}),
    CellRendererPixbuf=type('CellRendererPixbuf', (W,), {}), ScrolledWindow=type('ScrolledWindow', (W,), {}),
    FileChooserButton=type('FileChooserButton', (W,), {}), FileFilter=type('FileFilter', (W,), {}), EventBox=type('EventBox', (W,), {}),
    HeaderBar=type('HeaderBar', (W,), {}), MessageDialog=MessageDialog, CssProvider=type('CssProvider', (W,), {}), StyleContext=types.SimpleNamespace(add_provider_for_screen=lambda *a, **k: None), Separator=type('Separator', (W,), {}),
    Stack=type('Stack', (W,), {}), Adjustment=type('Adjustment', (W,), {}),
    ListStore=type('ListStore', (W,), {}), IconTheme=type('IconTheme', (W,), {'get_default': classmethod(lambda cls: cls())}),
    Orientation=types.SimpleNamespace(VERTICAL=1, HORIZONTAL=2), Align=types.SimpleNamespace(START=1, END=2, FILL=3),
    WindowType=types.SimpleNamespace(POPUP=1), StateFlags=types.SimpleNamespace(NORMAL=0), EventMask=types.SimpleNamespace(KEY_RELEASE_MASK=1), SeatCapabilities=types.SimpleNamespace(KEYBOARD=1),
    Justification=types.SimpleNamespace(CENTER=0), MessageType=types.SimpleNamespace(ERROR=1, INFO=2, QUESTION=3, WARNING=4),
    ButtonsType=types.SimpleNamespace(OK=1, YES_NO=2), ResponseType=types.SimpleNamespace(YES=1, NO=2, OK=0, CANCEL=-1, CLOSE=3),
    IconSize=types.SimpleNamespace(BUTTON=1), PolicyType=types.SimpleNamespace(AUTOMATIC=1, NEVER=2),
    FileChooserAction=types.SimpleNamespace(OPEN=1), PositionType=types.SimpleNamespace(TOP=1),
    StackTransitionType=types.SimpleNamespace(NONE=0), STYLE_PROVIDER_PRIORITY_USER=800,
    main_quit=lambda: None, main=lambda: None, events_pending=lambda: False, main_iteration=lambda: None,
)

Gdk = types.SimpleNamespace(
    ModifierType=types.SimpleNamespace(CONTROL_MASK=1, MOD1_MASK=2, ALT_MASK=2, SHIFT_MASK=4, SUPER_MASK=8, MOD4_MASK=16, MOD5_MASK=32),
    KEY_Control_L=10, KEY_Control_R=11, KEY_Alt_L=12, KEY_Alt_R=13, KEY_Shift_L=14, KEY_Shift_R=15,
    KEY_Super_L=16, KEY_Super_R=17, KEY_Meta_L=18, KEY_Meta_R=19, KEY_ISO_Level3_Shift=20,
    KEY_ISO_Level5_Shift=21, KEY_Caps_Lock=22, KEY_Num_Lock=23, KEY_l=108, KEY_L=76,
    RGBA=lambda *a: W(), GrabStatus=types.SimpleNamespace(SUCCESS=0), InputCapability=types.SimpleNamespace(KEYBOARD=1),
    SeatCapabilities=types.SimpleNamespace(KEYBOARD=1), EventMask=types.SimpleNamespace(KEY_RELEASE_MASK=1),
    InputMode=types.SimpleNamespace(SCREEN=1), keyval_name=lambda k: {108:'l',76:'L',10:'Control_L',12:'Alt_L',14:'Shift_L',16:'Super_L'}.get(k, 'a'),
    Screen=types.SimpleNamespace(get_default=lambda: W()), Display=types.SimpleNamespace(get_default=lambda: W()),
)
GLib = types.SimpleNamespace(
    UserDirectory=types.SimpleNamespace(DIRECTORY_DESKTOP=0), get_user_special_dir=lambda *a: None,
    timeout_add=lambda *a: 0, timeout_add_seconds=lambda *a: 0, idle_add=lambda *a: 0,
    shell_parse_argv=GLibReal.shell_parse_argv, Error=GLibReal.Error,   # _id_de_acceso lee el Exec= con el analizador real
)
GdkPixbuf = types.SimpleNamespace(Pixbuf=types.SimpleNamespace(new_from_file_at_size=lambda *a: W()))
Notify = types.SimpleNamespace(init=lambda *a: None, is_initted=lambda: True, Notification=types.SimpleNamespace(new=lambda *a, **k: W()))


def load(language='en'):
    src = base.embedded_python()
    import sys
    gi = types.ModuleType('gi'); gi.require_version = lambda *a: None
    repo = types.ModuleType('gi.repository')
    repo.Gtk, repo.Gdk, repo.GLib, repo.GdkPixbuf, repo.Notify = Gtk, Gdk, GLib, GdkPixbuf, Notify
    gi.repository = repo
    oldmods = {k: sys.modules.get(k) for k in ('gi', 'gi.repository')}
    sys.modules['gi'] = gi; sys.modules['gi.repository'] = repo
    td = tempfile.TemporaryDirectory()
    oldenv = os.environ.copy()
    os.environ['HOME'] = td.name
    os.environ['MI_LANZADOR_CONFIG_DIR'] = str(pathlib.Path(td.name) / 'config')
    os.environ['MI_LANZADOR_IDIOMA'] = language
    os.environ['MI_LANZADOR_SESION_TIPO'] = 'x11'
    ns = {'__name__': 'filonux_full', '__file__': str(SCRIPT)}  # no pre-seeded names: definition order must hold on its own
    exec(compile(src, '<embedded-full>', 'exec'), ns)
    ns['_td'] = td; ns['_oldenv'] = oldenv; ns['_oldmods'] = oldmods
    return ns


def unload(ns):
    import sys
    for k, v in ns.pop('_oldmods').items():
        if v is None: sys.modules.pop(k, None)
        else: sys.modules[k] = v
    old = ns.pop('_oldenv')
    for k in set(os.environ) - set(old): os.environ.pop(k, None)
    os.environ.update(old)
    ns['_td'].cleanup()


def exercise_data_and_serialization():
    ns = load('en')
    try:
        root = pathlib.Path(ns['_td'].name)
        doc = root / 'doc ñ.txt'; doc.write_text('contenido', encoding='utf-8')
        desktop = root / 'Demo.desktop'; desktop.write_text('[Desktop Entry]\nType=Application\nName=Demo\nName[es]=Demostración\nExec=/usr/bin/xmessage %U\nStartupWMClass=xmessage\n', encoding='utf-8')
        assert ns['_parsear_desktop_entry'](str(desktop))['nombre'] == 'Demo'
        assert ns['id_desktop_de_ruta']('/x/Demo.desktop') == 'Demo'
        assert ns['_normalizar_exec_para_dedup']('/usr/bin/xmessage %U') == '/usr/bin/xmessage'
        p = root / 'data.json'; ns['guardar_json'](str(p), {'ñ': 'á'}); assert ns['cargar_json'](str(p), {}) == {'ñ':'á'}
        p.write_text('{bad', encoding='utf-8'); assert ns['cargar_json'](str(p), {'d':1}) == {'d':1}
        old = {'id':'abc','nombre':'A','tipo':'web','valor':'https://example.com','navegador':'firefox'}
        a = ns['_migrar_accion_antigua'](old); assert a['pasos'][0]['url'] == 'https://example.com'
        c = ns['_migrar_paso_clic_antiguo']({'tipo':'clic','x':2,'y':3}); assert c['activar_ventana'] and not c['coords_absolutas']
        ns['ACCIONES_FILE'] = str(root / 'acciones.json')
        ns['guardar_json'](ns['ACCIONES_FILE'], [{'id':'a','nombre':'A','tipo':'web','valor':'example.com'}])
        assert ns['cargar_acciones']()[0]['pasos'][0]['tipo'] == 'web'
        ns['AJUSTES_FILE'] = str(root / 'ajustes.json'); ns['guardar_ajustes']({'notificaciones':False}); assert ns['cargar_ajustes']()['notificaciones'] is False
        assert ns['sugerir_alias']([], 'web', 'example.com') == 'example_com'
        assert ns['sugerir_alias']([{'tipo':'web','alias':'example_com'}], 'web', 'example.com') == 'example_com_2'
        for t in ns['ORDEN_TIPOS_PASO']:
            assert ns['icono_por_tipo_paso'](t)
        assert ns['sanear_nombre_archivo']('A:/?') == 'A___'
        assert ns['_validar_rango_personalizada']({'personalizada_x':80,'personalizada_w':30})
        assert ns['_validar_rango_personalizada']({'personalizada_x':10,'personalizada_w':30}) is None
    finally: unload(ns)


def exercise_desktop_catalogue():
    ns = load('en')
    try:
        root = pathlib.Path(ns['_td'].name)
        d1, d2 = root/'a', root/'b'; d1.mkdir(); d2.mkdir()
        (d1/'same.desktop').write_text('[Desktop Entry]\nType=Application\nName=Same\nExec=/bin/echo %U\n', encoding='utf-8')
        (d2/'same.desktop').write_text('[Desktop Entry]\nType=Application\nName=Same\nExec=/bin/echo %U\n', encoding='utf-8')
        (d2/'other.desktop').write_text('[Desktop Entry]\nType=Application\nName=Other\nExec=/bin/printf %U\n', encoding='utf-8')
        (d2/'hidden.desktop').write_text('[Desktop Entry]\nType=Application\nName=Hidden\nExec=/bin/true\nHidden=true\n', encoding='utf-8')
        ns['_directorios_aplicaciones'] = lambda: [str(d1), str(d2)]
        apps = ns['listar_aplicaciones_instaladas']()
        assert [a['nombre'] for a in apps] == ['Other', 'Same']
        ns['APP_SCRIPT_PATH'] = '/opt/launcher'
        (d1/'self.desktop').write_text('[Desktop Entry]\nType=Application\nName=Self\nExec=bash /opt/launcher --ejecutar x\n', encoding='utf-8')
        apps = ns['listar_aplicaciones_instaladas'](); assert all(a['nombre'] != 'Self' for a in apps)
        assert ns['_pista_clase_para_paso']({'tipo':'programa','modo':'manual','ruta':'/usr/bin/xmessage'}) == 'xmessage'
        assert ns['_pista_clase_para_paso']({'tipo':'web','navegador':'firefox'}) == 'firefox'
    finally: unload(ns)


def exercise_command_generation():
    ns = load('en')
    try:
        root = pathlib.Path(ns['_td'].name)
        doc = root/'f.txt'; doc.write_text('x', encoding='utf-8')
        de = root/'app.desktop'; de.write_text('[Desktop Entry]\nType=Application\nName=App\nExec=/usr/bin/xmessage %U\n', encoding='utf-8')
        steps = [
            {'tipo':'programa','modo':'manual','ruta':'/usr/bin/xmessage','argumentos':'-title "Manual" hello','alias':'manual'},
            {'tipo':'programa','modo':'desktop','ruta_desktop':str(de),'alias':'desktop'},
            {'tipo':'programa','modo':'instalado','ruta_desktop':str(de),'alias':'installed'},
            {'tipo':'documento','ruta':str(doc),'abrir_con':'sistema'},
            {'tipo':'documento','ruta':str(doc),'abrir_con':'app','ruta_desktop':str(de)},
            {'tipo':'web','url':'https://example.test','navegador':'firefox','nueva_ventana':False,'modo_app':False},
            {'tipo':'web','url':'https://example.test','navegador':'firefox','nueva_ventana':True,'modo_app':False},
            {'tipo':'web','url':'https://example.test','navegador':'chrome','nueva_ventana':False,'modo_app':True},
            {'tipo':'web','url':'https://example.test','navegador':'chromium','nueva_ventana':False,'modo_app':True},
            {'tipo':'web','url':'https://example.test','navegador':'brave','nueva_ventana':False,'modo_app':True},
            {'tipo':'comando','comando':'printf "%s\\n" ok'},
            {'tipo':'esperar','segundos':0},
            {'tipo':'ventana','objetivo_modo':'_ultima','accion_ventana':'centrada'},
            {'tipo':'clic','x':10,'y':20,'coords_absolutas':True,'activar_ventana':False,'boton':'1','doble':False},
            {'tipo':'clic','x':5,'y':6,'coords_absolutas':False,'activar_ventana':True,'objetivo_modo':'_alias','objetivo_alias':'manual','boton':'2','doble':True},
            {'tipo':'tecla','objetivo_modo':'_alias','objetivo_alias':'manual','combinacion':'ctrl+shift+t'},
            {'tipo':'texto','objetivo_modo':'_alias','objetivo_alias':'manual','texto':'Hola + ñ'},
        ]
        script = ns['generar_script_bash'](steps, 'Completa')
        subprocess.run(['bash','-n'], input=script, text=True, check=True)
        for pos in ns['ORDEN_POSICIONES']:
            p={'tipo':'ventana','objetivo_modo':'_ultima','accion_ventana':pos}
            if pos == 'personalizada': p.update(personalizada_x=10, personalizada_y=10, personalizada_w=40, personalizada_h=40)
            assert pos in ns['_lineas_posicionar_ventana'](p)[0]
        assert ns['_comando_shell_programa']({'modo':'manual','ruta':'/bin/echo','argumentos':'hola'}) == '/bin/echo hola'
        assert ns['_comando_shell_programa']({'modo':'desktop','ruta_desktop':str(de)}).startswith('gio launch ')
        assert ns['_comando_shell_documento']({'ruta':str(doc),'abrir_con':'sistema'}) == f'xdg-open {shutil.quote(str(doc)) if False else str(doc)}'
        assert ns['_comando_shell_web']({'url':'https://x','navegador':'firefox','nueva_ventana':True,'modo_app':False}).startswith('firefox --new-window') or 'xdg-open' in ns['_comando_shell_web']({'url':'https://x','navegador':'firefox','nueva_ventana':True,'modo_app':False})
        old_which = ns['shutil'].which
        try:
            ns['shutil'].which = lambda x: x == 'chromium-browser'
            assert ns['_resolver_binario_navegador']({'bin':'chromium','bin_alt':['chromium-browser']}) == 'chromium-browser'
        finally: ns['shutil'].which = old_which
        old_run = ns['subprocess'].run
        class R:
            stdout='firefox.desktop\n'
        ns['subprocess'].run = lambda *a, **k: R()
        try: assert ns['_detectar_navegador_predeterminado']() == 'firefox'
        finally: ns['subprocess'].run = old_run
    finally: unload(ns)


def exercise_desktop_access_and_cleanup():
    ns = load('en')
    try:
        root = pathlib.Path(ns['_td'].name); desktop_dir=root/'Desktop'; apps=root/'.local/share/applications'; desktop_dir.mkdir(parents=True); apps.mkdir(parents=True); ns['GLib'].get_user_special_dir=lambda *a: str(desktop_dir)
        icon=root/'old.png'; icon.write_bytes(b'old')
        action={'id':'abc123','nombre':'My Action / Test','pasos':[{'tipo':'web','url':'https://example.com'}]}
        paths=ns['crear_acceso_directo'](action,[str(desktop_dir),str(apps)])
        assert len(paths)==2 and all(pathlib.Path(x).is_file() for x in paths)
        text=pathlib.Path(paths[0]).read_text(encoding='utf-8')
        assert 'Name=My Action / Test' in text and '\nComment=Shortcut' in text and 'Comment[es]=' in text and 'Comment[en]' not in text
        assert ns['sanear_nombre_archivo']('My Action / Test') == 'My Action _ Test'
        assert ns['generar_desktop_entry'](action,'web-browser').startswith('[Desktop Entry]')
        ns['eliminar_accesos_directos']('abc123')
        assert all(not pathlib.Path(x).exists() for x in paths), (paths, list(desktop_dir.iterdir()), list(apps.iterdir()))
        oldf=root/'stale.tmp'; oldf.write_text('x'); os.utime(oldf,(time.time()-90000,time.time()-90000)); ns['TMP_DIR']=str(root); ns['_limpiar_temporales_antiguos'](); assert not oldf.exists()
    finally: unload(ns)


def fake_tools(tmp):
    bindir=pathlib.Path(tmp)/'bin'; bindir.mkdir()
    log=pathlib.Path(tmp)/'tools.log'
    xdotool=bindir/'xdotool'
    xdotool.write_text(textwrap.dedent(f'''\
        #!/bin/sh
        printf 'xdotool %s\\n' "$*" >> "{log}"
        case "$1" in
          search)
            if [ "$2" = "--name" ]; then
              pat="$4"; wmctrl -l | grep -iF -- "$pat" | awk '{{print $1}}'
            else
              wmctrl -l | awk '{{print $1}}'
            fi ;;
          getdisplaygeometry) echo "1200 800" ;;
          getactivewindow) wmctrl -l | tail -n1 | awk '{{print $1}}' ;;
          getwindowgeometry)
            id="${{3:-$2}}"
            wmctrl -lG | awk -v id="$id" '$1==id{{printf "WINDOW=%s\\nX=%s\\nY=%s\\nWIDTH=%s\\nHEIGHT=%s\\nSCREEN=0\\n",$1,$3,$4,$5,$6}}' ;;
          windowactivate|windowfocus) id="$(printf '%s' "$*" | awk '{{print $NF}}')"; wmctrl -ia "$id" 2>/dev/null || true ;;
          windowminimize) id="$(printf '%s' "$*" | awk '{{print $NF}}')"; wmctrl -ir "$id" -b add,hidden 2>/dev/null || true ;;
          windowclose) id="$(printf '%s' "$*" | awk '{{print $NF}}')"; wmctrl -ic "$id" 2>/dev/null || true ;;
          *) : ;;
        esac
        exit 0
    '''), encoding='utf-8'); xdotool.chmod(0o755)
    for name in ('firefox','google-chrome','chromium','chromium-browser','brave-browser','xterm','xdg-open','gio','gtk-launch'):
        p=bindir/name
        p.write_text(textwrap.dedent(f'''\
            #!/bin/sh
            printf '{name} %s\\n' "$*" >> "{log}"
            title="SIM-{name}"
            /usr/bin/xmessage -title "$title" -timeout 20 "Mi Lanzador simulation" >/dev/null 2>&1 &
            exit 0
        '''), encoding='utf-8'); p.chmod(0o755)
    return bindir,log


def run_x11_script(ns, step_list, env, workdir, timeout=8):
    script=ns['generar_script_bash'](step_list,'X11 integration')
    p=pathlib.Path(workdir)/f'run-{time.time_ns()}.sh'; p.write_text(script,encoding='utf-8'); p.chmod(0o755)
    return subprocess.run([str(p)], env=env, text=True, capture_output=True, timeout=timeout)


def window_info(title, env):
    out=subprocess.check_output(['wmctrl','-lG'],env=env,text=True)
    for line in out.splitlines():
        if title not in line:
            continue
        parts=line.split(); wid=parts[0]
        detail=subprocess.check_output(['xwininfo','-id',wid],env=env,text=True)
        nums={}
        for raw in detail.splitlines():
            line2=raw.strip()
            if ':' in line2:
                key,val=line2.split(':',1)
                m=re.match(r'(-?\d+)',val.strip())
                if m: nums[key.strip()] = int(m.group(1))
        return wid, [nums.get('Absolute upper-left X',0), nums.get('Absolute upper-left Y',0), nums.get('Width',0), nums.get('Height',0)]
    return None, None

def frame_extents(wid, env):
    raw=subprocess.check_output(['xprop','-id',wid,'_NET_FRAME_EXTENTS'],env=env,text=True)
    vals=raw.split('=',1)[1].replace(',',' ').split()
    return tuple(map(int,vals[:4])) if len(vals) >= 4 else (0,0,0,0)


def exercise_x11_runtime():
    require_tools('xmessage', 'xprop', 'xwininfo')
    cleanup, old_path, ns = contextlib.ExitStack(), os.environ.get('PATH', ''), None
    try:
        display = cleanup.enter_context(x_session('1200x800x24'))
        env = {**os.environ, 'DISPLAY': display, 'HOME': cleanup.enter_context(tempfile.TemporaryDirectory()), 'XAUTHORITY': '/dev/null'}
        tmp = tempfile.TemporaryDirectory(); cleanup.callback(tmp.cleanup)
        bindir, log = fake_tools(tmp.name)
        # Without the real terminals: the script takes the first installed one, and a real tilix or gnome-terminal beats the fake xterm.
        env['PATH'] = f"{bindir}:{path_without(pathlib.Path(tmp.name) / 'path', *TERMINALES)}"
        os.environ['PATH'] = env['PATH']
        ns = load('en')
        manual_title='SIM-MANUAL'
        r=run_x11_script(ns,[{'tipo':'programa','modo':'manual','ruta':'/usr/bin/xmessage','argumentos':f'-title "{manual_title}" hello'}],env,tmp.name)
        time.sleep(.5); assert window_info(manual_title,env)[0], r.stderr
        wid,_=window_info(manual_title,env)
        positions={
            'mitad_izq':(0,0,600,800), 'mitad_der':(600,0,600,800),
            'mitad_arriba':(0,0,1200,400), 'mitad_abajo':(0,400,1200,400),
            'cuarto_si':(0,0,600,400), 'cuarto_sd':(600,0,600,400),
            'cuarto_ii':(0,400,600,400), 'cuarto_id':(600,400,600,400),
            'centrada':(120,80,960,640),
            'personalizada':(120,80,480,320),
        }
        for pos, expected in positions.items():
            step={'tipo':'ventana','objetivo_modo':'_buscar','objetivo_buscar':manual_title,'accion_ventana':pos}
            if pos=='personalizada': step.update(personalizada_x=10,personalizada_y=10,personalizada_w=40,personalizada_h=40)
            r=run_x11_script(ns,[step],env,tmp.name); assert r.returncode==0, (pos,r.stderr)
            time.sleep(.15); _,geo=window_info(manual_title,env); assert geo, pos
            x,y,w,h=geo; ex,ey,ew,eh=expected
            fl,fr,ft,fb=frame_extents(wid, env)
            assert abs(x-(ex+fl))<=3 and abs(y-(ey+ft))<=3 and abs(w-ew)<=3 and abs(h-eh)<=3, (pos,geo,expected,(fl,fr,ft,fb))
        run_x11_script(ns,[{'tipo':'ventana','objetivo_modo':'_buscar','objetivo_buscar':manual_title,'accion_ventana':'mitad_arriba'}],env,tmp.name,timeout=4)
        run_x11_script(ns,[{'tipo':'ventana','objetivo_modo':'_buscar','objetivo_buscar':manual_title,'accion_ventana':'mitad_abajo'}],env,tmp.name,timeout=4)
        time.sleep(0.9); _,geo=window_info(manual_title,env); fl,fr,ft,fb=frame_extents(wid, env); assert geo and abs(geo[1]-(400+ft))<=3 and abs(geo[3]-400)<=3
        r=run_x11_script(ns,[{'tipo':'ventana','objetivo_modo':'_buscar','objetivo_buscar':manual_title,'accion_ventana':'maximizar'}],env,tmp.name); assert r.returncode==0
        state=subprocess.check_output(['xprop','-id',wid,'_NET_WM_STATE'],env=env,text=True); assert 'MAXIMIZED' in state
        run_x11_script(ns,[{'tipo':'ventana','objetivo_modo':'_buscar','objetivo_buscar':manual_title,'accion_ventana':'minimizar'}],env,tmp.name); time.sleep(.2)
        state=subprocess.check_output(['xprop','-id',wid,'_NET_WM_STATE'],env=env,text=True); assert '_NET_WM_STATE_HIDDEN' in state
        run_x11_script(ns,[{'tipo':'ventana','objetivo_modo':'_buscar','objetivo_buscar':manual_title,'accion_ventana':'restaurar'}],env,tmp.name); time.sleep(.2)
        # A newer geometry operation must cancel stale maximize retries.
        run_x11_script(ns,[{'tipo':'ventana','objetivo_modo':'_buscar','objetivo_buscar':manual_title,'accion_ventana':'maximizar'}],env,tmp.name)
        run_x11_script(ns,[{'tipo':'ventana','objetivo_modo':'_buscar','objetivo_buscar':manual_title,'accion_ventana':'personalizada','personalizada_x':5,'personalizada_y':5,'personalizada_w':30,'personalizada_h':30}],env,tmp.name)
        time.sleep(1.0); _,geo=window_info(manual_title,env); fl,fr,ft,fb=frame_extents(wid, env); assert geo and abs(geo[0]-(60+fl))<=3 and abs(geo[1]-(40+ft))<=3 and abs(geo[2]-360)<=3 and abs(geo[3]-240)<=3
        t0=time.monotonic(); r=run_x11_script(ns,[{'tipo':'esperar','segundos':0.20}],env,tmp.name,timeout=3); assert r.returncode==0 and time.monotonic()-t0 >= 0.16
        r=run_x11_script(ns,[{'tipo':'clic','x':20,'y':30,'coords_absolutas':True,'activar_ventana':False,'boton':'1','doble':False},{'tipo':'clic','x':5,'y':6,'coords_absolutas':False,'activar_ventana':True,'objetivo_modo':'_buscar','objetivo_buscar':manual_title,'boton':'2','doble':True},{'tipo':'tecla','objetivo_modo':'_buscar','objetivo_buscar':manual_title,'combinacion':'ctrl+t'},{'tipo':'texto','objetivo_modo':'_buscar','objetivo_buscar':manual_title,'texto':'Prueba ñ'}],env,tmp.name); assert r.returncode==0
        logtxt=pathlib.Path(log).read_text(encoding='utf-8'); assert 'mousemove' in logtxt and 'click' in logtxt and 'key -- ctrl+t' in logtxt and 'type --clearmodifiers' in logtxt
        run_x11_script(ns,[{'tipo':'ventana','objetivo_modo':'_buscar','objetivo_buscar':manual_title,'accion_ventana':'cerrar'}],env,tmp.name); time.sleep(.4); assert not window_info(manual_title,env)[0]
        # Web, document, desktop-app and terminal command launch paths.
        doc=pathlib.Path(tmp.name)/'doc.txt'; doc.write_text('x',encoding='utf-8')
        steps=[
            {'tipo':'web','url':'https://example.test','navegador':'firefox','nueva_ventana':True,'modo_app':False},
            {'tipo':'documento','ruta':str(doc),'abrir_con':'sistema'},
            {'tipo':'documento','ruta':str(doc),'abrir_con':'app','ruta_desktop':str(pathlib.Path(tmp.name)/'app.desktop')},
            {'tipo':'programa','modo':'desktop','ruta_desktop':str(pathlib.Path(tmp.name)/'app.desktop')},
            {'tipo':'programa','modo':'instalado','ruta_desktop':str(pathlib.Path(tmp.name)/'app.desktop'),'nombre_detectado':'App'},
            {'tipo':'comando','comando':'printf ok'},
        ]
        (pathlib.Path(tmp.name)/'app.desktop').write_text('[Desktop Entry]\nType=Application\nName=App\nExec=/usr/bin/xmessage %U\n',encoding='utf-8')
        for st in steps:
            r=run_x11_script(ns,[st],env,tmp.name); assert r.returncode==0
        logtxt=pathlib.Path(log).read_text(encoding='utf-8');
        for token in ('firefox','xdg-open','gio launch','xterm'):
            assert token in logtxt, token
    finally:
        if ns is not None:
            unload(ns)
        os.environ['PATH'] = old_path
        cleanup.close()


def exercise_dialog_validation_all_types():
    ns=load('en')
    try:
        root=pathlib.Path(ns['_td'].name); doc=root/'doc.txt'; doc.write_text('x',encoding='utf-8'); de=root/'app.desktop'; de.write_text('[Desktop Entry]\nType=Application\nName=App\nExec=/usr/bin/xmessage %U\n',encoding='utf-8')
        d=object.__new__(ns['DialogoPaso']); d.pasos_previos=[]; d.alias_prohibidos=set(); d._coords_absolutas_actual=True
        d._leer_colocar_ventana=lambda *a: None
        d._resolver_ruta_app_seleccionada=lambda: str(de)
        d._buscar_app_por_nombre=lambda texto: str(de) if texto == 'App' else None
        d._ruta_app_documento_seleccionada=str(de); d.store_apps=W(); d.store_apps.rows=[['App',str(de),'/usr/bin/xmessage']]
        d._leer_objetivo=lambda combo,entry,p: p.update({'objetivo_modo':'_ultima'})
        def setup(**kw):
            for k,v in kw.items(): setattr(d,k,v)
        setup(combo_tipo=W(active_id='programa'), stack_programa=W(), chooser_programa=W(filename='/usr/bin/xmessage'), entry_argumentos=W(), entry_alias_programa=W(), spin_espera_programa=W(value=0))
        d.stack_programa.get_visible_child_name=lambda:'manual'; step,err=d.validar_y_construir(); assert step['modo']=='manual' and not err
        setup(combo_tipo=W(active_id='programa'), stack_programa=W(), chooser_programa=W(filename=str(de)), entry_argumentos=W(), entry_alias_programa=W(), spin_espera_programa=W(value=0)); d.stack_programa.get_visible_child_name=lambda:'manual'; step,err=d.validar_y_construir(); assert step['modo']=='desktop' and not err
        setup(combo_tipo=W(active_id='documento'), chooser_documento=W(filename=str(doc)), check_abrir_con_app=W(active=False), entry_app_documento=W(), entry_alias_documento=W(), spin_espera_documento=W(value=0)); step,err=d.validar_y_construir(); assert step['abrir_con']=='sistema' and not err
        setup(combo_tipo=W(active_id='documento'), chooser_documento=W(filename=str(doc)), check_abrir_con_app=W(active=True), entry_app_documento=W(text='App'), entry_alias_documento=W(), spin_espera_documento=W(value=0)); step,err=d.validar_y_construir(); assert step['abrir_con']=='app' and not err
        setup(combo_tipo=W(active_id='web'), entry_url=W(text='example.com'), combo_navegador=W(active_id='firefox'), check_nueva_ventana=W(active=True), check_modo_app=W(active=False), entry_alias_web=W(), spin_espera_web=W(value=0)); step,err=d.validar_y_construir(); assert step['url']=='https://example.com' and not err
        setup(combo_tipo=W(active_id='comando'), entry_comando=W(text='echo ok'), entry_alias_comando=W(), spin_espera_comando=W(value=0)); step,err=d.validar_y_construir(); assert step['comando']=='echo ok' and not err
        setup(combo_tipo=W(active_id='esperar'), spin_segundos_esperar=W(value=1.5)); step,err=d.validar_y_construir(); assert step['segundos']==1.5 and not err
        setup(combo_tipo=W(active_id='ventana'), combo_objetivo_ventana=W(), entry_buscar_ventana=W(), combo_posicion=W(active_id='personalizada'), spin_pers_x=W(value=10), spin_pers_y=W(value=10), spin_pers_w=W(value=40), spin_pers_h=W(value=40)); step,err=d.validar_y_construir(); assert step['accion_ventana']=='personalizada' and not err
        setup(combo_tipo=W(active_id='clic'), check_activar_ventana_clic=W(active=False), spin_x_clic=W(value=10), spin_y_clic=W(value=20), combo_boton=W(active_id='3'), check_doble_clic=W(active=True)); step,err=d.validar_y_construir(); assert step['boton']=='3' and step['doble'] and not err
        setup(combo_tipo=W(active_id='tecla'), combo_objetivo_tecla=W(), entry_buscar_tecla=W(), entry_combinacion=W(text='ctrl+t')); step,err=d.validar_y_construir(); assert step['combinacion']=='ctrl+t' and not err
        setup(combo_tipo=W(active_id='texto'), combo_objetivo_texto=W(), entry_buscar_texto=W(), entry_texto=W(text='Hola')); step,err=d.validar_y_construir(); assert step['texto']=='Hola' and not err
        # GUI page builders and low-level capture helpers are exercised with the same deterministic widget surface.
        d.stack=W()
        for method in ('_crear_pagina_programa','_crear_pagina_documento','_crear_pagina_web','_crear_pagina_comando','_crear_pagina_esperar','_crear_pagina_ventana','_crear_pagina_clic','_crear_pagina_tecla','_crear_pagina_texto'):
            getattr(d,method)()
        assert ns['_nombre_modificador_solo'](Gdk.KEY_Control_L) == 'ctrl'
        assert ns['_combinacion_desde_evento_tecla'](types.SimpleNamespace(state=0,keyval=ord('a'))) == 'a'
    finally: unload(ns)


def exercise_main_window_callbacks():
    ns=load('es')
    try:
        root=pathlib.Path(ns['_td'].name)
        actions=[{'id':'a1','nombre':'Uno','pasos':[{'tipo':'esperar','segundos':1}]}]
        ns['cargar_acciones']=lambda: list(actions)
        ns['guardar_acciones']=lambda x: actions.__setitem__(slice(None), list(x))
        ns['obtener_pixbuf']=lambda *a: None
        ns['resumen_pasos']=lambda p: 'RES'
        ns['notificar']=lambda *a: None
        ns['crear_acceso_directo']=lambda *a: [str(root/'x.desktop')]
        ns['eliminar_accesos_directos']=lambda *a: None
        ns['cargar_ajustes']=lambda: {'crear_acceso_automatico':False,'notificaciones':True}
        o=object.__new__(ns['VentanaPrincipal'])
        o.store=W(); o.tree=W(); o.store_pasos=W(); o.tree_pasos=W(); o.pasos_actual=[{'id':1},{'id':2},{'id':3}]; o.editando_id='a1'; o.entry_nombre=W(text='Uno'); o.chooser_icono=W(filename=None); o.btn_guardar=W(); o.notebook=W(); o.cargar_lista=lambda: None; o.refrescar_store_pasos=lambda: None; o.limpiar_formulario=lambda: setattr(o,'pasos_actual',[]); o.obtener_dir_escritorio=lambda: str(root)
        errors=[]; o.mostrar_dialogo_error=lambda x: errors.append(x); o.mostrar_dialogo_info=lambda x: None
        o.tree_pasos._selection=(o.tree_pasos,1)
        assert o.obtener_indice_paso_seleccionado()==1
        o._on_subir_paso(None); assert [x['id'] for x in o.pasos_actual]==[2,1,3]
        o._on_bajar_paso(None); assert [x['id'] for x in o.pasos_actual]==[1,2,3]
        o._on_quitar_paso(None); assert len(o.pasos_actual)==2
        o.pasos_actual=[]; o.tree_pasos._selection=(None,None); o._on_quitar_paso(None); assert errors
        # Selection resolution, edit, save, settings, view, delete, execute, shortcut and double-click paths.
        model=W(); model.rows=[['a1',None,'Uno','1','RES']]; o.tree.get_model=lambda:model; o.tree.get_selection=lambda: types.SimpleNamespace(get_selected=lambda:(model,0)); assert o.obtener_seleccion()['id']=='a1'
        o.entry_nombre=W(text='Nuevo'); o.pasos_actual=[{'tipo':'esperar','segundos':1}]; o.editando_id=None; o._on_guardar_accion(None); assert any(a['nombre']=='Nuevo' for a in actions)
        o.pasos_actual=[{'tipo':'esperar','segundos':2}]; o.editando_id='a1'; o.entry_nombre=W(text='Editado'); o._on_guardar_accion(None); assert actions[0]['nombre']=='Editado'
        o.combo_navegador_defecto=W(active_id='firefox'); o.check_auto_acceso=W(active=True); o.check_notificaciones=W(active=False); o._on_guardar_ajustes(None)
        captured=[]; ns['generar_script_bash']=lambda p,n: 'SCRIPT'; o.mostrar_dialogo_texto_largo=lambda t,s: captured.append((t,s)); o._on_ver_script(None); assert captured and captured[0][1]=='SCRIPT'
        ns['ejecutar_accion']=lambda *a: captured.append(('exec',a)); o._on_ejecutar(None); assert any(x[0]=='exec' for x in captured if isinstance(x,tuple))
        o.crear_acceso_para=lambda a: captured.append(('shortcut',a)); o._on_crear_acceso(None); assert any(x[0]=='shortcut' for x in captured if isinstance(x,tuple))
        # El formulario tiene el nombre «Editado»: cargar otra acción pregunta antes de descartarlo.
        o.editando_id=None; Dialog.next_responses=[Gtk.ResponseType.NO]; o._on_editar(None); assert o.editando_id is None
        Dialog.next_responses=[Gtk.ResponseType.YES]; o._on_editar(None); assert o.editando_id=='a1'
        # Delete YES.
        old_msg=Gtk.MessageDialog; Dialog.next_responses=[Gtk.ResponseType.YES]; Gtk.MessageDialog=MessageDialog
        try: o._on_eliminar(None)
        finally: Gtk.MessageDialog=old_msg
        assert all(a['id']!='a1' for a in actions)
        # Double click executes selected row directly.
        actions.append({'id':'a2','nombre':'Dos','pasos':[{'tipo':'esperar','segundos':1}]}); model.rows=[['a2']]; o._on_fila_doble_clic(o.tree,0,None); assert any(x[0]=='exec' for x in captured if isinstance(x,tuple))
        # Language key, capture helpers and X11 dependency callback.
        o._on_cambiar_idioma=lambda w: captured.append(('lang',None)); o.get_focus=lambda: None; o.btn_idioma=W(); event=types.SimpleNamespace(state=0,keyval=Gdk.KEY_l); o._on_tecla_idioma(None,event); assert any(x[0]=='lang' for x in captured if isinstance(x,tuple))
    finally: unload(ns)


def exercise_top_level_cli_and_zip_integrity():
    required = {
        'script/mi-lanzador.sh', 'README.md', 'README.es.md', 'LICENSE.txt',
        'tests/test_i18n.py', 'tests/test_full_simulation.py', 'tests/test_aesthetic.py',
    }
    for rel in required:
        assert (ROOT / rel).is_file(), rel
    with tempfile.TemporaryDirectory() as home:
        env=os.environ.copy(); env.update(HOME=home, MI_LANZADOR_CONFIG_DIR=str(pathlib.Path(home)/'.config'/'mi-lanzador'), MI_LANZADOR_LANG='en', PATH='/usr/bin:/bin')
        r=subprocess.run(['bash',str(SCRIPT),'--print-language'],env=env,capture_output=True,text=True,check=True)
        assert r.stdout.strip()=='en'
        r=subprocess.run(['bash',str(SCRIPT),'--print-language'],env={**env,'MI_LANZADOR_LANG':'es'},capture_output=True,text=True,check=True)
        assert r.stdout.strip()=='es'
    subprocess.run(['bash','-n',str(SCRIPT)],check=True)
    src=base.embedded_python(); compile(src,'<embedded>','exec')
    ast.parse(src)


def exercise_all_feature_paths():
    ns = load('en')
    try:
        root = pathlib.Path(ns['_td'].name)
        ns['ERROR_LOG_FILE'] = str(root / 'error.log')
        ns['ACCIONES_FILE'] = str(root / 'acciones.json')
        ns['AJUSTES_FILE'] = str(root / 'ajustes.json')
        ns['ICONOS_DIR'] = str(root / 'iconos'); pathlib.Path(ns['ICONOS_DIR']).mkdir()
        ns['TMP_DIR'] = str(root / 'tmp'); pathlib.Path(ns['TMP_DIR']).mkdir()

        assert ns['herramientas_x11_disponibles']()['xdotool'] in (True, False)
        assert ns['_detectar_idioma_sistema']() in ('es', 'en')
        ns['guardar_idioma']('es'); assert pathlib.Path(ns['IDIOMA_FILE']).read_text() == 'es\n'; assert ns['_cargar_idioma_guardado']() == 'es'
        ns['guardar_idioma']('en'); assert ns['_cargar_idioma_guardado']() == 'en'; ns['guardar_idioma']('xx'); assert ns['_cargar_idioma_guardado']() == 'en'
        for bad in ({'personalizada_x':90,'personalizada_w':20},{'personalizada_y':90,'personalizada_h':20}): assert ns['_validar_rango_personalizada'](bad)

        try:
            raise ValueError('boom')
        except ValueError as exc:
            detail = ns['_registrar_error']('coverage', exc); assert 'ValueError' in detail and 'coverage' in pathlib.Path(ns['ERROR_LOG_FILE']).read_text()
            ns['Gtk'].MessageDialog.next_responses = [ns['Gtk'].ResponseType.OK]
            ns['_mostrar_error_excepcion'](None, 'context', exc)
            ns['traceback'].print_exception = lambda *a, **k: None
            tb = exc.__traceback__
            ns['_excepthook_global'](ValueError, exc, tb)

        # Real helper execution rather than test doubles.
        de = root/'app.desktop'; de.write_text('[Desktop Entry]\nType=Application\nName=Coverage\nExec=/usr/bin/xmessage %U\nStartupWMClass=xmessage\n', encoding='utf-8')
        doc = root/'file.txt'; doc.write_text('x', encoding='utf-8')
        assert ns['_comando_shell_programa']({'modo':'manual','ruta':'/bin/echo','argumentos':'hello'}) == '/bin/echo hello'
        assert ns['_comando_shell_programa']({'modo':'desktop','ruta_desktop':str(de)}).startswith('gio launch')
        assert ns['_comando_shell_programa']({'modo':'instalado','ruta_desktop':str(de)}).startswith('gio launch')
        assert 'xdg-open' in ns['_comando_shell_documento']({'ruta':str(doc),'abrir_con':'sistema'})
        assert 'gio launch' in ns['_comando_shell_documento']({'ruta':str(doc),'abrir_con':'app','ruta_desktop':str(de)})
        for nav in ('firefox','chrome','chromium','brave','sistema'):
            assert isinstance(ns['_comando_shell_web']({'url':'https://example.test','navegador':nav,'nueva_ventana':False,'modo_app':False}), str)
        assert ns['_resolver_binario_navegador']({'bin':'not-real','bin_alt':['also-not-real']}) == 'not-real'
        assert ns['_pista_clase_para_paso']({'tipo':'programa','modo':'desktop','ruta_desktop':str(de)}) == 'xmessage'
        assert ns['_pista_clase_para_paso']({'tipo':'programa','modo':'manual','ruta':'/usr/bin/xmessage'}) == 'xmessage'
        assert ns['_pista_clase_para_paso']({'tipo':'web','navegador':'firefox'}) == 'firefox'
        assert ns['_pista_clase_para_paso']({'tipo':'documento','abrir_con':'app','ruta_desktop':str(de)}) == 'xmessage'
        assert ns['_pista_clase_para_paso']({'tipo':'documento','abrir_con':'sistema'}) == ''
        assert '_resolver_ventana' in ns['_bloque_resolver_objetivo']({'objetivo_modo':'_buscar','objetivo_buscar':'xmessage'})
        assert ns['_q']("a b'")
        assert 'mitad_izq' in ns['_lineas_posicionar_ventana']({'accion_ventana':'mitad_izq'})[0]

        # Dialog page behavior and field round-tripping.
        ns['listar_aplicaciones_instaladas'] = lambda: []
        d = ns['DialogoPaso'](None, [])
        d._fijar_objetivo(d.combo_objetivo_ventana, d.entry_buscar_ventana, {'objetivo_modo':'_buscar','objetivo_buscar':'My title'})
        p={}; d._leer_objetivo(d.combo_objetivo_ventana,d.entry_buscar_ventana,p); assert p['objetivo_modo']=='_buscar' and p['objetivo_buscar']=='My title'
        for pref in ('programa','documento','web','comando'):
            d._fijar_colocar_ventana(pref, {'colocar_ventana':True,'accion_ventana':'personalizada','personalizada_x':1,'personalizada_y':2,'personalizada_w':30,'personalizada_h':40})
            out={}; assert d._leer_colocar_ventana(pref,out) is None and out['accion_ventana']=='personalizada'
        d.combo_tipo.set_active_id('tecla'); d._on_cambio_tipo(d.combo_tipo)
        d.combo_posicion.set_active_id('personalizada'); d._on_cambio_posicion(d.combo_posicion)
        d._mostrar_info_prueba('Coverage info'); d._mostrar_info_prueba('Coverage error', es_error=True)
        d._resolver_ruta_app_seleccionada = lambda: str(de)
        d._buscar_app_por_nombre = lambda text: str(de) if text.lower() == 'coverage' else None
        d.entry_app_instalada.set_text('Coverage'); d._ruta_app_seleccionada = str(de); assert d._resolver_ruta_app_seleccionada()==str(de)
        d._on_recargar_apps(None)

        # Capture helper success and fallback branches.
        old_which = ns['shutil'].which; old_run = ns['subprocess'].run
        class Seat:
            def ungrab(self): self.ungrabbed=True
            def grab(self,*a): return ns['Gdk'].GrabStatus.SUCCESS
        ns['Gdk'].Display.get_default = lambda: types.SimpleNamespace(get_default_seat=lambda: Seat())
        try:
            assert ns['_agarrar_dispositivo'](object(), ns['Gdk'].SeatCapabilities.KEYBOARD).__class__ is Seat
            ns['shutil'].which = lambda x: '/fake/xdotool' if x == 'xdotool' else old_which(x)
            def fake_run(cmd,*a,**k):
                if cmd[:2] == ['xdotool','getmouselocation']:
                    return types.SimpleNamespace(stdout='X=100\nY=120\nWINDOW=123\n')
                if cmd[:2] == ['xdotool','getwindowgeometry']:
                    return types.SimpleNamespace(stdout='X=90\nY=100\nWIDTH=400\nHEIGHT=300\n')
                if cmd[:2] == ['xdotool','getwindowname']:
                    return types.SimpleNamespace(stdout='Under cursor\n')
                return old_run(cmd,*a,**k)
            ns['subprocess'].run = fake_run
            assert ns['_capturar_punto_pantalla']() == (100,120)
            assert ns['_resolver_ventana_bajo_punto'](100,120) == (10,20,'Under cursor')
        finally:
            ns['shutil'].which = old_which; ns['subprocess'].run = old_run
        assert ns['_resolver_ventana_bajo_punto'](3,4) == (3,4,'')

        class CaptureDialog(Dialog):
            def run(self):
                self.handlers['key-press-event'][0](self, types.SimpleNamespace(keyval=ord('a'), state=ns['Gdk'].ModifierType.CONTROL_MASK))
                return ns['Gtk'].ResponseType.OK
        old_dialog = ns['Gtk'].Dialog; ns['Gtk'].Dialog = CaptureDialog
        seat = Seat(); ns['_agarrar_dispositivo'] = lambda *a: seat
        try: assert ns['_capturar_combinacion_teclado'](None) == 'ctrl+a'
        finally: ns['Gtk'].Dialog = old_dialog
        assert ns['_combinacion_desde_evento_tecla'](types.SimpleNamespace(state=4+1+2, keyval=ord('a'))) == 'ctrl+alt+shift+a'
        assert ns['_nombre_modificador_solo'](ns['Gdk'].KEY_Super_L) == 'super'

        # Runtime execution API: generated shell, process/log watcher and id lookup.
        old_gen = ns['generar_script_bash']
        ns['generar_script_bash'] = old_gen
        ns['APP_SCRIPT_PATH'] = str(SCRIPT)
        action={'id':'run1','nombre':'Runtime','pasos':[{'tipo':'comando','comando':'printf runtime'}]}
        ns['cargar_acciones'] = lambda: [action]
        old_notify = ns['notificar']; notices=[]; ns['notificar']=lambda *args: notices.append(args)
        try:
            thread=ns['ejecutar_accion'](action); assert thread is not None; thread.join(timeout=5); assert pathlib.Path(ns['CONFIG_DIR'])/'ultima_ejecucion.log' in [p for p in pathlib.Path(ns['CONFIG_DIR']).glob('ultima_ejecucion.log')]; assert any('Running:' in str(x[0]) or 'Ejecutando:' in str(x[0]) for x in notices)
            assert ns['ejecutar_accion_por_id']('run1') is not None
            assert ns['ejecutar_accion_por_id']('missing') is None
        finally: ns['notificar']=old_notify

        # Shortcut dialog paths, icon loading, clean-up and all main callbacks.
        ico=root/'custom.svg'; ico.write_text('<svg/>',encoding='utf8')
        action={'id':'icon1','nombre':'Icon action','pasos':[{'tipo':'esperar','segundos':1}], 'icono':str(root/'old.svg')}
        pathlib.Path(action['icono']).write_text('<svg/>',encoding='utf8')
        o=ns['VentanaPrincipal']()
        o.chooser_icono.set_filename(str(ico)); o.entry_nombre.set_text('Icon action'); o.pasos_actual=action['pasos'][:]; o.editando_id='icon1'
        ns['cargar_acciones']=lambda:[action]; ns['guardar_acciones']=lambda a: None; o.cargar_lista=lambda:None; o.limpiar_formulario=lambda:None
        o._on_guardar_accion(None)
        # Create shortcut in both destinations through the real dialog.
        dest1=root/'Desktop'; dest2=root/'apps'; dest1.mkdir(); dest2.mkdir()
        old_home=os.environ['HOME']; os.environ['HOME']=str(root); ns['GLib'].get_user_special_dir=lambda *a:str(dest1)
        try:
            ns['Gtk'].Dialog.next_responses=[ns['Gtk'].ResponseType.OK]
            created=[]; ns['crear_acceso_directo']=lambda a,d: created.append(d) or [str(dest1/'x.desktop')]
            o.crear_acceso_para({'id':'c','nombre':'Create me','pasos':[{'tipo':'esperar','segundos':1}]}); assert created
        finally: os.environ['HOME']=old_home

        # Installation callback branches without invoking apt.
        widget=W(); o.etiqueta_estado_x11=W(); old_which=ns['shutil'].which; old_run=ns['subprocess'].run
        ns['shutil'].which=lambda x: None if x=='pkexec' else old_which(x); errs=[]; o.mostrar_dialogo_error=lambda x: errs.append(x); o._on_instalar_x11(widget); assert errs
        ns['shutil'].which=lambda x: '/bin/pkexec' if x=='pkexec' else old_which(x); ns['Gtk'].MessageDialog.next_responses=[ns['Gtk'].ResponseType.NO]; o._on_instalar_x11(widget)
        class R: stdout='ok'; stderr=''; returncode=0
        class SyncThread:  # the install runs in a worker thread and finishes through GLib.idle_add: run both inline here
            def __init__(self,target,**k): self.target=target
            def start(self): self.target()
        old_thread,old_idle=ns['threading'].Thread,ns['GLib'].idle_add
        ns['subprocess'].run=lambda *a,**k:R(); ns['herramientas_x11_disponibles']=lambda:{'xdotool':True,'wmctrl':True}; ns['Gtk'].MessageDialog.next_responses=[ns['Gtk'].ResponseType.YES]
        ns['threading'].Thread=SyncThread; ns['GLib'].idle_add=lambda fn,*a: fn(*a)
        try: o._on_instalar_x11(widget); assert widget.get_visible() is False
        finally: ns['threading'].Thread=old_thread; ns['GLib'].idle_add=old_idle; ns['shutil'].which=old_which; ns['subprocess'].run=old_run

        # Actual page handlers: add/edit validation loop, capture click/key, test step, and language restart (exec is stubbed).
        class FakeStep:
            def __init__(self,*a,**k): self.calls=0
            def run(self): self.calls+=1; return ns['Gtk'].ResponseType.OK if self.calls==1 else ns['Gtk'].ResponseType.CANCEL
            def validar_y_construir(self): return None, 'invalid' if self.calls==1 else None
            def destroy(self): pass
        old_step=ns['DialogoPaso']; ns['DialogoPaso']=FakeStep
        shown=[]; o.mostrar_dialogo_error=lambda x: shown.append(x); o.pasos_actual=[]; o._on_anadir_paso(None); assert shown==['invalid']
        ns['DialogoPaso']=old_step
        # Change/settings/reload helpers.
        o._hay_cambios_sin_guardar(); o.limpiar_formulario(); o.ir_a_tab_nueva(); o.refrescar_store_pasos(); o.obtener_dir_escritorio()
        old_exec=ns['os'].execv; restarted=[]; ns['os'].execv=lambda *a: restarted.append(a); o.pasos_actual=[]; o.editando_id=None; o.entry_nombre.set_text(''); ns['IDIOMA']='es'; o._on_cambiar_idioma(None); assert restarted
        ns['os'].execv=old_exec
    finally:
        unload(ns)


def exercise_remaining_ui_functions():
    """Exercise the UI builders, editing helpers and capture/test callbacks not covered by the end-to-end flow."""
    ns = load('en')
    try:
        root = pathlib.Path(ns['_td'].name)
        d = ns['DialogoPaso'](None, [{'tipo':'programa','alias':'editor','nombre_detectado':'Editor'}])

        # Shared target and placement widgets, including read/write round-trips.
        selector, combo, entry = d._crear_selector_objetivo(1)
        assert selector is not None and combo.get_active_id() == '_ultima'
        combo.set_active_id('_buscar'); entry.set_text('Terminal'); paso={}; d._leer_objetivo(combo, entry, paso)
        assert paso == {'objetivo_modo':'_buscar','objetivo_buscar':'Terminal'}
        d._fijar_objetivo(combo, entry, {'objetivo_modo':'_alias','objetivo_alias':'editor'})
        assert combo.get_active_id() == '_alias:editor'
        assert d._crear_seccion_colocar_ventana('prueba') is not None and 'check' in d.colocar_prueba
        d.colocar_prueba['check'].set_active(True); d.colocar_prueba['combo'].set_active_id('personalizada')
        d.colocar_prueba['spin_w'].set_value(40); d.colocar_prueba['spin_h'].set_value(50)
        out={}; assert d._leer_colocar_ventana('prueba', out) is None and out['colocar_ventana'] is True
        d._fijar_colocar_ventana('prueba', {'colocar_ventana':True,'accion_ventana':'maximizar','personalizada_x':1,'personalizada_y':2,'personalizada_w':30,'personalizada_h':40})
        assert d.colocar_prueba['check'].get_active() is True

        # Installed-app route resolver: selected route first, then name lookup.
        d.store_apps = [['Editor', '/opt/editor.desktop']]
        old_lookup=d._buscar_app_por_nombre; d._buscar_app_por_nombre = lambda text: '/fallback.desktop' if text == 'Fallback' else None
        entry_app=W(text='Editor'); assert d._resolver_ruta_app_desde(entry_app, '/opt/editor.desktop') == '/opt/editor.desktop'
        entry_app.set_text('Fallback'); assert d._resolver_ruta_app_desde(entry_app, '/different.desktop') == '/fallback.desktop'; d._buscar_app_por_nombre=old_lookup

        # Click capture entry points: unavailable-tool branch and hidden-dialog/restoration path.
        d.label_punto_detectado=W(); old_tools=ns['herramientas_x11_disponibles']; ns['herramientas_x11_disponibles']=lambda:{'xdotool':False,'wmctrl':True}
        d._on_elegir_punto_clic(None); assert 'xdotool' in d.label_punto_detectado.get_text()
        ns['herramientas_x11_disponibles']=lambda:{'xdotool':True,'wmctrl':True}
        scheduled=[]; old_timeout=ns['GLib'].timeout_add; ns['GLib'].timeout_add=lambda ms, cb: scheduled.append((ms,cb)) or 1
        d._on_elegir_punto_clic(None); assert scheduled and scheduled[-1][0] == 900
        d.get_transient_for=lambda: W(); d.get_position=lambda:(12,34); hidden=[]
        d.set_opacity=lambda value:hidden.append(('opacity',value)); d.move=lambda x,y:hidden.append(('move',x,y))
        d._ocultar_para_capturar(); assert any(x == ('opacity',0) for x in hidden); assert hidden[-1][0] == 'move'
        vp=d.get_transient_for(); vp.set_skip_taskbar_hint=lambda v:setattr(vp,'skip_taskbar',v); vp.set_skip_pager_hint=lambda v:setattr(vp,'skip_pager',v)
        # Re-run with stable parent object so restoration can be asserted.
        d.get_transient_for=lambda: vp; d._posicion_previa_captura=(12,34); d._ventana_principal_para_captura=vp
        ns['_capturar_punto_pantalla']=lambda:(321,654); ns['_resolver_ventana_bajo_punto']=lambda x,y:('id', 'pid', 'Window Under Cursor'); d.label_punto_detectado=W(); d.spin_x_clic=W(); d.spin_y_clic=W(); d.entry_buscar_clic=W();
        d._restaurar_captura = getattr(d, '_restaurar_captura', None)
        d.set_opacity=lambda value:hidden.append(('restore_opacity',value)); d.move=lambda x,y:hidden.append(('restore_move',x,y)); d.present=lambda: hidden.append(('present',))
        assert d._lanzar_captura_punto() is False
        assert d.spin_x_clic.get_value_as_int() == 321 and d.spin_y_clic.get_value_as_int() == 654
        assert d.entry_buscar_clic.get_text() == 'Window Under Cursor'

        # Keyboard capture: success, cancellation and exception paths.
        d.entry_combinacion=W(); d.label_tecla_capturada=W(); old_cap=ns['_capturar_combinacion_teclado']
        ns['_capturar_combinacion_teclado']=lambda parent:'Ctrl+Shift+T'; d._on_capturar_tecla(None); assert d.entry_combinacion.get_text() == 'Ctrl+Shift+T'
        ns['_capturar_combinacion_teclado']=lambda parent:None; d._on_capturar_tecla(None); assert 'cancel' in d.label_tecla_capturada.get_text().lower()
        ns['_capturar_combinacion_teclado']=lambda parent: (_ for _ in ()).throw(RuntimeError('capture'))
        d._on_capturar_tecla(None); assert 'capture' in d.label_tecla_capturada.get_text()
        ns['_capturar_combinacion_teclado']=old_cap

        # Load every persisted step type through the real editor.
        samples=[
            {'tipo':'programa','modo':'manual','ruta':'/bin/echo','argumentos':'hi','alias':'p','espera':1},
            {'tipo':'documento','ruta':str(root/'a.txt'),'abrir_con':'sistema','alias':'d','espera':1},
            {'tipo':'web','url':'https://example.test','navegador':'firefox','nueva_ventana':True,'modo_app':False,'alias':'w','espera':1},
            {'tipo':'comando','comando':'echo ok','alias':'c','espera':1},
            {'tipo':'esperar','segundos':1},
            {'tipo':'ventana','objetivo_modo':'_ultima','accion_ventana':'centrada'},
            {'tipo':'clic','x':10,'y':20,'coords_absolutas':True,'activar_ventana':False,'boton':'1','doble':False},
            {'tipo':'tecla','objetivo_modo':'_ultima','combinacion':'ctrl+a'},
            {'tipo':'texto','objetivo_modo':'_ultima','texto':'hello'},
        ]
        for sample in samples:
            d._cargar_paso(sample); assert d.combo_tipo.get_active_id() == sample['tipo']

        # Page-change visibility, help, styles and all three main tabs.
        d._on_cambio_posicion(W(active_id='personalizada')); assert d.caja_personalizada.get_visible() is True
        d._on_cambio_tipo(W(active_id='clic')); assert d.btn_probar_paso.get_visible() is True
        ns['Gtk'].CssProvider().load_from_data(b'')
        vp_main=ns['VentanaPrincipal'].__new__(ns['VentanaPrincipal'])
        vp_main._aplicar_estilos()
        ns['VentanaPrincipal']._crear_tab_lista(vp_main); ns['VentanaPrincipal']._crear_tab_nueva(vp_main); ns['VentanaPrincipal']._crear_tab_ajustes(vp_main)
        assert hasattr(vp_main,'entry_nombre') and hasattr(vp_main,'combo_navegador_defecto')

        # Edit-step callback: no selection, then successful replacement through the real dialog contract.
        o=ns['VentanaPrincipal'](); errors=[]; o.mostrar_dialogo_error=lambda x: errors.append(x); o.obtener_indice_paso_seleccionado=lambda:None; o._on_editar_paso(None); assert errors
        o.obtener_indice_paso_seleccionado=lambda:0; o.pasos_actual=[{'tipo':'esperar','segundos':1}]
        class EditDialog:
            def __init__(self,*a,**k): self.called=False
            def run(self): self.called=True; return ns['Gtk'].ResponseType.OK
            def validar_y_construir(self): return {'tipo':'esperar','segundos':2}, None
            def destroy(self): pass
        old_dialog=ns['DialogoPaso']; ns['DialogoPaso']=EditDialog; o.refrescar_store_pasos=lambda:None; o._on_editar_paso(None)
        assert o.pasos_actual[0]['segundos'] == 2
        ns['DialogoPaso']=old_dialog

        # Single-step test callback: validation failure, preparation failure and successful process completion.
        d2=ns['DialogoPaso'](None, [])
        test_btn=W(); errors=[]; d2._mostrar_info_prueba=lambda text, es_error=False: errors.append((text,es_error))
        d2.validar_y_construir=lambda: (None,'bad step'); d2._on_probar_paso(test_btn); assert errors and errors[-1][1] is True
        d2.validar_y_construir=lambda: ({'tipo':'esperar','segundos':0},None)
        old_tmpdir=ns['TMP_DIR']; ns['TMP_DIR']=str(root)
        class FakePopen:
            def __init__(self,*a,**k): self.done=False
            def poll(self): return 0
        old_popen=ns['subprocess'].Popen; ns['subprocess'].Popen=FakePopen; scheduled=[]; old_timeout2=ns['GLib'].timeout_add; ns['GLib'].timeout_add=lambda ms,cb: scheduled.append(cb) or 1
        try:
            d2._on_probar_paso(test_btn); assert scheduled; scheduled[-1](); assert test_btn.get_sensitive() is True
        finally:
            ns['subprocess'].Popen=old_popen; ns['GLib'].timeout_add=old_timeout2; ns['TMP_DIR']=old_tmpdir
        d2.destroy()

        # Both main() modes: direct execution and normal GUI startup.
        old_argv=ns['sys'].argv[:]; old_exec_action=ns['ejecutar_accion_por_id']; joined=[]
        class Thread:
            def join(self): joined.append(True)
        ns['ejecutar_accion_por_id']=lambda ident: Thread()
        ns['sys'].argv=['mi-lanzador.sh','--ejecutar','abc']; ns['main'](); assert joined
        started=[]
        class MainWindow(W):
            def __init__(self): super().__init__(); started.append(True)
        old_vp=ns['VentanaPrincipal']; ns['VentanaPrincipal']=MainWindow; old_gtk_main=ns['Gtk'].main; ns['Gtk'].main=lambda: started.append('gtk-main'); ns['sys'].argv=['mi-lanzador.sh']; ns['main'](); assert started[-2:] == [True,'gtk-main']
        ns['VentanaPrincipal']=old_vp; ns['Gtk'].main=old_gtk_main; ns['ejecutar_accion_por_id']=old_exec_action; ns['sys'].argv=old_argv

        # Direct execution of data writer and concrete widget helpers (not monkeypatched).
        ns['guardar_acciones']([{'id':'direct','nombre':'Direct','pasos':[]}])
        assert ns['cargar_acciones']()[0]['id'] == 'direct'
        d.store_apps=[['Editor','/opt/editor.desktop','/usr/bin/editor']]
        d.entry_app_instalada=W(text='Editor'); d._ruta_app_seleccionada='/opt/editor.desktop'
        assert d._buscar_app_por_nombre(' editor ') == '/opt/editor.desktop'
        assert d._resolver_ruta_app_seleccionada() == '/opt/editor.desktop'
        d.refrescar_store_pasos=lambda:None; d.entry_nombre=W(text='x'); d.chooser_icono=W(filename=str(root/'icon.svg')); d.pasos_actual=[{'tipo':'esperar','segundos':1}]; d.editando_id='id'; d.btn_guardar=W(label='x')
        # VentanaPrincipal helpers are run with the real dialog implementation and a deterministic stub.
        vp2=ns['VentanaPrincipal']()
        vp2.entry_nombre=W(text='x'); vp2.chooser_icono=W(filename=None); vp2.pasos_actual=[{'tipo':'esperar','segundos':1}]; vp2.editando_id='id'; vp2.btn_guardar=W(label='Guardar cambios'); vp2.refrescar_store_pasos=lambda:None
        ns['VentanaPrincipal'].limpiar_formulario(vp2); assert vp2.pasos_actual == [] and vp2.editando_id is None
        Dialog.next_responses=[ns['Gtk'].ResponseType.OK]; ns['VentanaPrincipal'].mostrar_dialogo_error(vp2,'error')
        Dialog.next_responses=[ns['Gtk'].ResponseType.CLOSE]; ns['VentanaPrincipal'].mostrar_dialogo_texto_largo(vp2,'Title','Body')

        # Low-level text/summary helpers and grid helper are all invoked directly.
        assert ns['_texto_posicion']('centrada') and ns['_texto_tipo']('web')
        assert ns['describir_objetivo']({'objetivo_modo':'_ultima'})
        assert ns['alias_disponibles_antes_de'](samples, 8)
        assert ns['_fila_grid'](W(), 0, 'Label', W()) == 1
    finally:
        ns['herramientas_x11_disponibles']=old_tools if 'old_tools' in locals() else ns['herramientas_x11_disponibles']
        unload(ns)

# Pytest entry points: keep the detailed exercise functions reusable while making
# the complete integration suite visible to standard CI/test discovery.
def test_full_data_and_serialization(): exercise_data_and_serialization()
def test_full_desktop_catalogue(): exercise_desktop_catalogue()
def test_full_command_generation(): exercise_command_generation()
def test_full_desktop_access_and_cleanup(): exercise_desktop_access_and_cleanup()
def test_full_x11_runtime(): exercise_x11_runtime()
def test_full_dialog_validation_all_types(): exercise_dialog_validation_all_types()
def test_full_main_window_callbacks(): exercise_main_window_callbacks()
def test_full_top_level_cli_and_zip_integrity(): exercise_top_level_cli_and_zip_integrity()
def test_full_all_feature_paths(): exercise_all_feature_paths()
def test_full_remaining_ui_functions(): exercise_remaining_ui_functions()


def x_servers_of_the_exercise():
    """PIDs of the Xvfb 1200x800x24 alive now. `pgrep -f` reads whole command lines, so callers compare before and after:
    a parent shell that mentions the pattern, or an unrelated server of that size, would otherwise look like a leak."""
    return set(subprocess.run(['pgrep', '-f', 'Xvfb.*1200x800x24'], capture_output=True, text=True).stdout.split())


def test_x11_runtime_setup_failure_leaves_no_server_behind(monkeypatch):
    def broken_fake_tools(_tmp):
        raise RuntimeError('setup failed')
    monkeypatch.setitem(globals(), 'fake_tools', broken_fake_tools)
    before = x_servers_of_the_exercise()
    try:
        exercise_x11_runtime()
    except RuntimeError as error:
        assert str(error) == 'setup failed'
        # Checked inside the `except`: the traceback (and with it the frame of exercise_x11_runtime) is still alive, as
        # pytest keeps it for a failing test. Once it is released, the garbage collector closes the `x_session` generator
        # on its own and a missing cleanup.close() goes unnoticed.
        assert x_servers_of_the_exercise() <= before, 'an Xvfb 1200x800x24 was left running'
    else:
        raise AssertionError('the setup failure was swallowed')
