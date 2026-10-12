"""The bash script generated for each action: terminal step epilogue and the runtime message table."""
import os
import pathlib
import re
import shutil
import subprocess
import sys
import time

import pytest

from conftest import COMANDO_HOSTIL, SALIDA_HOSTIL, TERMINALES, embedded_python, require_tools, wait_until, window_titles

TOOLBOX = ['bash', 'sh', 'sort', 'comm', 'tail', 'head', 'sleep', 'cat', 'awk', 'grep', 'sed', 'env', 'setsid',
           'nohup', 'date', 'mkdir', 'dirname', 'cut', 'tr', 'rm', 'mktemp', 'base64', 'timeout']
FAKE_TERMINAL = '#!/bin/bash\nshift   # drop -e\nprintf "\\n" | "$@" > "$FAKE_TERM_OUT" 2>&1   # what the user would see; Enter is pressed\n'

# How each terminal must be told to run a command. tilix does NOT take "--": it opens an empty shell and drops the
# command (tilix 1.9.6, checked by hand). Its -e takes ONE argument that it splits with g_shell_parse_argv; with several
# it re-quotes them in double quotes and a doubled backslash in the user's command arrives as a single one.
# Third value: the terminal replaces $NAME with the variable's value in its arguments, even inside single quotes
# (konsole 23.08.5, checked by hand: '$HOME' arrives as the home path and $PWD as konsole's own directory; `\$` blocks
# the replacement but keeps the backslash, and `$(`, `${..}` and `$$` are left alone). x-terminal-emulator may be konsole.
CONVENCION_TERMINAL = {'gnome-terminal': ('--', False, False), 'mate-terminal': ('-x', False, False),
                       'xfce4-terminal': ('-x', False, False), 'tilix': ('-e', True, False),
                       'terminator': ('-x', False, False), 'konsole': ('-e', False, True),
                       'xterm': ('-e', False, False), 'x-terminal-emulator': ('-e', False, True)}
# Stands in for a real terminal: runs the command only when called the way that terminal needs, with Enter pressed.
FAKE_TERMINAL_PY = '''#!{python}
import os, subprocess, sys
flag, one_string, expands_env = {flag!r}, {one_string!r}, {expands_env!r}
args = sys.argv[1:]
if not args or args[0] != flag:
    sys.exit(2)   # the real terminal would open an empty shell and the command would never run
command = args[1:]
if one_string:
    if len(command) != 1:
        sys.exit(3)   # the real one would re-quote several arguments and mangle the backslashes
    from gi.repository import GLib
    command = GLib.shell_parse_argv(command[0])[1]
if expands_env:
    import re
    command = [re.sub(r'\\$([A-Za-z0-9_]+)', lambda m: os.environ.get(m.group(1)) or m.group(0), arg) for arg in command]
with open(os.environ['FAKE_TERM_OUT'], 'wb') as out:
    subprocess.run(command, input=b'\\n', stdout=out, stderr=subprocess.STDOUT)
'''


def isolated_path(tmp_path, terminal=None):
    """A PATH holding only coreutils plus a fake `xterm` (or the fake `terminal` given), so no real terminal can ever open."""
    bin_dir = tmp_path / 'bin'
    bin_dir.mkdir()
    for tool in TOOLBOX:
        if shutil.which(tool):
            (bin_dir / tool).symlink_to(shutil.which(tool))
    if terminal is None:
        (bin_dir / 'xterm').write_text(FAKE_TERMINAL, encoding='utf-8')
        (bin_dir / 'xterm').chmod(0o755)
    else:
        flag, one_string, expands_env = CONVENCION_TERMINAL[terminal]
        (bin_dir / terminal).write_text(FAKE_TERMINAL_PY.format(python=sys.executable, flag=flag, one_string=one_string,
                                                                expands_env=expands_env), encoding='utf-8')
        (bin_dir / terminal).chmod(0o755)
    return bin_dir


def run_generated(app, tmp_path, steps, lang, name='demo', terminal=None):
    script = tmp_path / 'accion.sh'
    script.write_text(app.generar_script_bash(steps, name), encoding='utf-8')
    out = tmp_path / 'term.out'
    env = {'PATH': str(isolated_path(tmp_path, terminal)), 'HOME': str(tmp_path), 'MI_LANZADOR_IDIOMA': lang, 'FAKE_TERM_OUT': str(out)}
    result = subprocess.run(['bash', str(script)], env=env, capture_output=True, text=True, timeout=30)
    deadline = time.time() + 10
    while time.time() < deadline and not (out.exists() and '[Mi Lanzador]' in out.read_text(encoding='utf-8')):
        time.sleep(0.1)
    return result, (out.read_text(encoding='utf-8') if out.exists() else '')


@pytest.mark.parametrize('lang, expected', [
    ('en', 'The command finished (exit code 0). Press Enter to close this terminal'),
    ('es', 'El comando terminó (código 0). Pulsa Intro para cerrar esta terminal')])
def test_terminal_step_shows_the_closing_notice_in_the_terminal(app, tmp_path, lang, expected):
    _, terminal = run_generated(app, tmp_path, [{'tipo': 'comando', 'comando': 'echo hola-desde-terminal', 'espera': 0.2}], lang)
    assert 'hola-desde-terminal' in terminal
    assert expected in terminal
    assert 'command not found' not in terminal   # the new bash does not inherit _ml_msg


def test_terminal_epilogue_survives_trailing_comment_quotes_and_reports_the_exit_code(app, tmp_path):
    command = "echo 'with \"quotes\" and $HOME'; (exit 3) # trailing comment"
    _, terminal = run_generated(app, tmp_path, [{'tipo': 'comando', 'comando': command, 'espera': 0.2}], 'en')
    assert 'with "quotes" and $HOME' in terminal
    assert 'exit code 3' in terminal


def test_terminal_epilogue_works_when_the_user_command_ends_in_an_ampersand(app, tmp_path):
    _, terminal = run_generated(app, tmp_path, [{'tipo': 'comando', 'comando': 'sleep 0.1 &', 'espera': 0.2}], 'en')
    assert 'exit code 0' in terminal


def test_missing_terminal_is_reported_in_the_selected_language(app, tmp_path):
    steps = [{'tipo': 'comando', 'comando': 'echo x', 'espera': 0.2}]
    script = tmp_path / 'accion.sh'
    script.write_text(app.generar_script_bash(steps, 'demo'), encoding='utf-8')
    empty = tmp_path / 'empty'
    empty.mkdir()
    for tool in TOOLBOX:
        if shutil.which(tool):
            (empty / tool).symlink_to(shutil.which(tool))
    for lang, expected in (('en', 'no installed terminal was found'), ('es', 'no se encontró ninguna terminal')):
        result = subprocess.run(['bash', str(script)], env={'PATH': str(empty), 'HOME': str(tmp_path), 'MI_LANZADOR_IDIOMA': lang},
                                capture_output=True, text=True, timeout=30)
        assert expected in result.stderr


@pytest.mark.parametrize('terminal', list(CONVENCION_TERMINAL))
def test_the_command_step_reaches_each_terminal_intact_the_way_that_terminal_takes_it(app, tmp_path, terminal):
    _, terminal_out = run_generated(app, tmp_path, [{'tipo': 'comando', 'comando': COMANDO_HOSTIL, 'espera': 0.2}], 'en',
                                    terminal=terminal)
    assert SALIDA_HOSTIL in terminal_out
    assert 'exit code 3' in terminal_out


@pytest.mark.parametrize('terminal', ['konsole', 'x-terminal-emulator'])
def test_a_variable_the_command_sets_itself_is_not_replaced_by_a_terminal_that_expands_them(app, tmp_path, terminal):
    """The everyday case behind the quoted '$HOME': `cd dir; echo $PWD` or `HOME=/x; ...` must see the command's own value."""
    command = 'HOME=/elsewhere; echo "now:$HOME"'
    _, terminal_out = run_generated(app, tmp_path, [{'tipo': 'comando', 'comando': command, 'espera': 0.2}], 'en',
                                    terminal=terminal)
    assert 'now:/elsewhere' in terminal_out


def test_the_terminals_tried_by_the_script_are_exactly_the_ones_the_tests_know(app):
    """A terminal added to the script without its convention here would go unchecked, and the sandbox tests would not hide it."""
    tried = re.search(r'for term in ([a-z0-9 -]+); do', app.generar_script_bash([{'tipo': 'comando', 'comando': 'x'}], 'd')).group(1)
    assert tuple(tried.split()) == TERMINALES
    assert set(CONVENCION_TERMINAL) == set(TERMINALES)


# --------------------------------------------------------------------------- message table
def test_every_message_key_used_by_the_generator_exists_and_every_key_is_used(app):
    used = set(re.findall(r'_ml_msg (\w+)', embedded_python()))
    assert used == set(app.MENSAJES_SCRIPT), (used ^ set(app.MENSAJES_SCRIPT))


def test_each_message_has_both_languages_and_the_same_placeholders(app):
    for key, (es, en) in app.MENSAJES_SCRIPT.items():
        assert es.strip() and en.strip(), key
        assert es.count('%s') == en.count('%s'), key
        assert es.replace('%s', '').count('%') == 0 and en.replace('%s', '').count('%') == 0, key
        assert es != en or key == 'command_finished', key


def message_preamble(app, tmp_path):
    """The language detection plus the `_ml_msg` function, exactly as shipped in a generated script."""
    text = app.generar_script_bash([{'tipo': 'esperar', 'segundos': 0}], 'demo')
    start = text.index('_ML_LANG="${MI_LANZADOR_IDIOMA:-}"')
    end = text.index('_snapshot() {')
    return text[start:end]


@pytest.mark.parametrize('lang', ['en', 'es'])
def test_every_message_prints_one_clean_line_with_its_arguments(app, tmp_path, lang):
    lines = [message_preamble(app, tmp_path)]
    for key, (es, _) in app.MENSAJES_SCRIPT.items():
        lines.append(f'_ml_msg {key} ' + ' '.join(f'ARG{i}' for i in range(es.count('%s'))))
    result = subprocess.run(['bash', '-c', '\n'.join(lines)], env={'PATH': os.environ['PATH'], 'MI_LANZADOR_IDIOMA': lang},
                            capture_output=True, text=True, timeout=30)
    printed = result.stdout.splitlines()
    assert len(printed) == len(app.MENSAJES_SCRIPT), result.stdout       # one line each: no format re-use
    assert '%s' not in result.stdout and 'command not found' not in result.stderr
    for line, (key, (es, en)) in zip(printed, app.MENSAJES_SCRIPT.items()):
        for i in range(es.count('%s')):
            assert f'ARG{i}' in line, (key, line)


@pytest.mark.parametrize('lang, header, step', [('en', '=== Mi Lanzador: running demo ===', '  Step 1: '),
                                                ('es', '=== Mi Lanzador: ejecutando demo ===', '  Paso 1: ')])
def test_header_and_step_lines_follow_the_runtime_language(app, tmp_path, lang, header, step):
    result, _ = run_generated(app, tmp_path, [{'tipo': 'esperar', 'segundos': 0}], lang)
    assert header in result.stderr and step in result.stderr


def test_newlines_in_user_text_cannot_inject_a_command_or_fake_a_log_warning(app, tmp_path, monkeypatch):
    marker = tmp_path / 'injected'
    monkeypatch.setattr(app, 'resumen_paso', lambda paso: 'step text\nWarning: fake (step)')
    result, _ = run_generated(app, tmp_path, [{'tipo': 'esperar', 'segundos': 0}], 'en',
                              name=f'name\ntouch {marker}\nAviso: fake (name)')
    assert result.returncode == 0 and not marker.exists()
    assert 'name' in result.stderr and 'step text' in result.stderr
    assert not app.RE_AVISO_LOG.search(result.stderr), result.stderr


CARGAS_HOSTILES = {'plain': 'plain', 'quotes': "it's \"q\" $HOME `id` \\n %s ; | & < > * ?",
                   'newline': 'línea1\nlínea2 $(touch /tmp/pwn) ñ 日本', 'closer': "}\n'; rm -rf / #"}


def pasos_de_todos_los_tipos(h):
    """One or more steps of every step type, with the text `h` in every field the user can type."""
    return [
        {'tipo': 'programa', 'modo': 'manual', 'ruta': '/usr/bin/' + h, 'argumentos': h, 'alias': h, 'colocar_ventana': True,
         'accion_ventana': 'personalizada', 'personalizada_x': 10, 'personalizada_y': 10, 'personalizada_w': 50, 'personalizada_h': 50},
        {'tipo': 'documento', 'ruta': '/tmp/' + h, 'abrir_con': 'predeterminada'},
        {'tipo': 'documento', 'ruta': '/tmp/' + h, 'abrir_con': 'app', 'ruta_desktop': '/usr/share/applications/' + h + '.desktop',
         'nombre_detectado': h, 'colocar_ventana': True, 'accion_ventana': 'mitad_izq'},
        {'tipo': 'web', 'url': 'https://example.com/?q=' + h, 'navegador': 'firefox', 'nueva_ventana': True},
        {'tipo': 'web', 'url': 'https://example.com/' + h, 'navegador': 'chrome', 'modo_app': True, 'colocar_ventana': True,
         'accion_ventana': 'cuarto_si'},
        {'tipo': 'comando', 'comando': h, 'colocar_ventana': True, 'accion_ventana': 'maximizar'},
        {'tipo': 'esperar', 'segundos': 1.5},
        {'tipo': 'ventana', 'objetivo_modo': '_alias', 'objetivo_alias': h, 'accion_ventana': 'maximizar'},
        {'tipo': 'ventana', 'objetivo_modo': '_buscar', 'objetivo_buscar': h, 'accion_ventana': 'cerrar'},
        {'tipo': 'clic', 'x': 100, 'y': 200, 'boton': '1', 'coords_absolutas': True, 'activar_ventana': False},
        {'tipo': 'clic', 'x': 5, 'y': 6, 'boton': '3', 'doble': True, 'coords_absolutas': False, 'activar_ventana': True,
         'objetivo_modo': '_alias', 'objetivo_alias': h},
        {'tipo': 'clic', 'x': 5, 'y': 6, 'boton': '2', 'coords_absolutas': True, 'activar_ventana': True,
         'objetivo_modo': '_buscar', 'objetivo_buscar': h},
        {'tipo': 'tecla', 'combinacion': 'ctrl+' + h, 'objetivo_modo': '_ultima'},
        {'tipo': 'tecla', 'combinacion': 'Return', 'objetivo_modo': '_buscar', 'objetivo_buscar': h},
        {'tipo': 'texto', 'texto': h, 'objetivo_modo': '_alias', 'objetivo_alias': h},
        {'tipo': 'texto', 'texto': h, 'objetivo_modo': '_ultima'},
    ]


@pytest.mark.parametrize('carga', list(CARGAS_HOSTILES.values()), ids=list(CARGAS_HOSTILES))
def test_generated_script_with_every_step_type_and_hostile_text_passes_shellcheck(app, tmp_path, carga):
    # SC2016 (el «$» entre comillas simples va a un `bash -c` hijo) y SC2015 («A && B || C» con la rama de error
    # buscada) son intencionados: sin ellos shellcheck da 0 hallazgos en cualquier nivel con las 4 cargas.
    if shutil.which('shellcheck') is None:
        pytest.skip('shellcheck is not installed (sudo apt install shellcheck)')
    pasos = pasos_de_todos_los_tipos(carga)
    assert {p['tipo'] for p in pasos} == set(app.ORDEN_TIPOS_PASO)   # a new step type must be added here too
    ruta = tmp_path / 'accion.sh'
    ruta.write_text(app.generar_script_bash(pasos, 'Acción ' + carga), encoding='utf-8')
    comprobado = subprocess.run(['shellcheck', '-s', 'bash', '-e', 'SC2015,SC2016', str(ruta)], capture_output=True, text=True)
    assert comprobado.returncode == 0, comprobado.stdout


@pytest.mark.parametrize('lang, expected', [('en', 'the target window of the key step was not found'),
                                            ('es', 'no se encontró la ventana objetivo del paso de tecla')])
def test_window_target_warning_names_the_step_and_shows_no_raw_placeholder(app, tmp_path, lang, expected):
    steps = [{'tipo': 'tecla', 'combinacion': 'a', 'objetivo_modo': '_alias', 'objetivo_alias': 'nope'}]
    result, _ = run_generated(app, tmp_path, steps, lang)   # isolated PATH: no xdotool, so no window can be resolved
    assert expected in result.stderr
    assert '%s' not in result.stderr and 'window step' not in result.stderr


def run_action_and_collect(app, tmp_path, monkeypatch, lang, steps):
    """Run an action through ejecutar_accion with no xdotool on PATH; return (log text, notifications)."""
    monkeypatch.setenv('PATH', str(isolated_path(tmp_path)))
    monkeypatch.setenv('MI_LANZADOR_IDIOMA', lang)
    app.IDIOMA = lang
    sent = []
    monkeypatch.setattr(app, 'notificar', lambda *args: sent.append(args[0]))
    watcher = app.ejecutar_accion({'id': 'w1', 'nombre': 'Demo', 'pasos': steps})
    watcher.join(timeout=15)
    return (pathlib.Path(app.CONFIG_DIR) / 'ultima_ejecucion.log').read_text(encoding='utf-8'), sent


@pytest.mark.parametrize('lang, marker, notice', [('en', 'Warning:', 'finished with warnings'), ('es', 'Aviso:', 'terminó con avisos')])
def test_a_warning_in_the_log_triggers_the_warnings_notification_in_both_languages(app, tmp_path, monkeypatch, lang, marker, notice):
    log, sent = run_action_and_collect(app, tmp_path, monkeypatch, lang, [{'tipo': 'tecla', 'combinacion': 'ctrl+l'}])
    assert marker in log
    assert any(notice in text for text in sent), sent


@pytest.mark.parametrize('lang', ['en', 'es'])
def test_a_clean_run_sends_no_warnings_notification(app, tmp_path, monkeypatch, lang):
    log, sent = run_action_and_collect(app, tmp_path, monkeypatch, lang, [{'tipo': 'esperar', 'segundos': 0}])
    assert not app.RE_AVISO_LOG.search(log)
    assert len(sent) == 1, sent   # only the "running" notice


def test_an_action_started_while_another_runs_does_not_erase_its_log_or_its_warnings(app, tmp_path, monkeypatch):
    # Las dos escribían en ultima_ejecucion.log: la segunda lo truncaba y la primera perdía su aviso.
    monkeypatch.setenv('PATH', str(isolated_path(tmp_path)))
    monkeypatch.setenv('MI_LANZADOR_IDIOMA', 'en')
    app.IDIOMA = 'en'
    sent = []
    monkeypatch.setattr(app, 'notificar', lambda *args: sent.append(args[0]))
    log = pathlib.Path(app.CONFIG_DIR) / 'ultima_ejecucion.log'
    larga = app.ejecutar_accion({'id': 'a1', 'nombre': 'Alpha',
                                 'pasos': [{'tipo': 'tecla', 'combinacion': 'ctrl+l'}, {'tipo': 'esperar', 'segundos': 2}]})
    assert wait_until(lambda: log.exists() and 'Warning:' in log.read_text(encoding='utf-8'), timeout=10)
    corta = app.ejecutar_accion({'id': 'b1', 'nombre': 'Beta', 'pasos': [{'tipo': 'esperar', 'segundos': 0}]})
    larga.join(timeout=15)
    corta.join(timeout=15)
    avisos = [texto for texto in sent if 'finished with warnings' in texto]
    assert len(avisos) == 1 and 'Alpha' in avisos[0], sent                                     # el de Alpha, y solo ese
    assert 'Warning:' in pathlib.Path(avisos[0].splitlines()[-1]).read_text(encoding='utf-8')  # la ruta que da lo lleva
    ultimo = log.read_text(encoding='utf-8')
    assert 'Beta' in ultimo and 'Alpha' not in ultimo and '\x00' not in ultimo                 # la última que empezó, entera


def test_the_warnings_notification_names_the_fixed_log_while_it_is_still_the_runs_own(app, tmp_path, monkeypatch):
    _, sent = run_action_and_collect(app, tmp_path, monkeypatch, 'en', [{'tipo': 'tecla', 'combinacion': 'ctrl+l'}])
    avisos = [texto for texto in sent if 'finished with warnings' in texto]
    assert [a.splitlines()[-1] for a in avisos] == [str(pathlib.Path(app.CONFIG_DIR) / 'ultima_ejecucion.log')]
    assert not list(pathlib.Path(app.TMP_DIR).glob('*.enlace'))                                  # sin temporales de enlace


def test_without_hard_links_the_log_is_still_written_and_the_warning_still_sent(app, tmp_path, monkeypatch):
    monkeypatch.setattr(app.os, 'link', lambda *a, **k: (_ for _ in ()).throw(OSError('no hard links here')))
    log, sent = run_action_and_collect(app, tmp_path, monkeypatch, 'en', [{'tipo': 'tecla', 'combinacion': 'ctrl+l'}])
    assert 'Warning:' in log
    assert any('finished with warnings' in texto and texto.endswith('ultima_ejecucion.log') for texto in sent), sent
    assert not [p for p in pathlib.Path(app.TMP_DIR).iterdir() if p.name.startswith('ejecucion_')]


def test_every_warning_in_the_message_table_is_recognised_in_both_languages(app):
    not_warnings = {'command_finished', 'running', 'step_line', 'action_finished'}
    for key, texts in app.MENSAJES_SCRIPT.items():
        for text in texts:
            assert bool(app.RE_AVISO_LOG.search(text + '\n')) == (key not in not_warnings), (key, text)


@pytest.mark.parametrize('stored, expected', [(2, 'sleep 2'), (1.5, 'sleep 1.5'), (0, 'sleep 0'), ('1; touch pwn', 'sleep 1'),
                                              (None, 'sleep 1'), (-3, 'sleep 1'), (float('nan'), 'sleep 1'), (float('inf'), 'sleep 1')])
def test_wait_step_only_ever_emits_a_plain_number(app, stored, expected):
    lines = app.generar_script_bash([{'tipo': 'esperar', 'segundos': stored}], 'demo').splitlines()
    assert [l for l in lines if l.startswith('sleep ')] == [expected]


def test_open_step_wait_that_is_not_a_number_does_not_break_generation(app):
    text = app.generar_script_bash([{'tipo': 'comando', 'comando': 'true', 'espera': 'abc'}], 'demo')
    assert '_esperar_ventana_nueva "$ANTES" "$ACTIVA_ANTES" 10 ' in text  # 2 s por defecto = 10 intentos de 0.2 s


FAKE_XDOTOOL = '''#!/bin/bash
case "$1" in
    getactivewindow) echo 42 ;;
    getdisplaygeometry) echo "1920 1080" ;;
    key) case "$*" in *zzz*) echo "No such key name 'zzz'. Ignoring it." >&2 ;; esac ;;   # exit status stays 0, like xdotool
esac
exit 0
'''


@pytest.mark.parametrize('lang, combo, expected', [('en', 'zzz', 'Warning: xdotool could not send the key “zzz”'),
                                                   ('es', 'zzz', 'Aviso: xdotool no pudo enviar la tecla «zzz»'),
                                                   ('en', 'ctrl+t', None)])
def test_key_step_warns_when_xdotool_rejects_the_key(app, tmp_path, lang, combo, expected):
    bin_dir = isolated_path(tmp_path)
    (bin_dir / 'xdotool').write_text(FAKE_XDOTOOL, encoding='utf-8')
    (bin_dir / 'xdotool').chmod(0o755)
    script = tmp_path / 'accion.sh'
    script.write_text(app.generar_script_bash([{'tipo': 'tecla', 'combinacion': combo}], 'demo'), encoding='utf-8')
    result = subprocess.run(['bash', str(script)], env={'PATH': str(bin_dir), 'HOME': str(tmp_path), 'MI_LANZADOR_IDIOMA': lang},
                            capture_output=True, text=True, timeout=30)
    if expected:
        assert expected in result.stderr, result.stderr
    else:
        assert not app.RE_AVISO_LOG.search(result.stderr), result.stderr


FAKE_XDOTOOL_LOGGING = '''#!/bin/bash
echo "$*" >> "$XDO_LOG"
case "$1" in
    search) echo 999 ;;
    getactivewindow) echo 42 ;;
    getdisplaygeometry) echo "1920 1080" ;;
esac
exit 0
'''


@pytest.mark.parametrize('title, searched', [('', False), ('Firefox', True)])
def test_empty_title_search_is_never_sent_to_xdotool_and_falls_back_to_the_active_window(app, tmp_path, title, searched):
    bin_dir = isolated_path(tmp_path)
    (bin_dir / 'xdotool').write_text(FAKE_XDOTOOL_LOGGING, encoding='utf-8')
    (bin_dir / 'xdotool').chmod(0o755)
    log, script = tmp_path / 'xdo.log', tmp_path / 'accion.sh'
    steps = [{'tipo': 'tecla', 'combinacion': 'ctrl+t', 'objetivo_modo': '_buscar', 'objetivo_buscar': title}]
    script.write_text(app.generar_script_bash(steps, 'demo'), encoding='utf-8')
    subprocess.run(['bash', str(script)], capture_output=True, text=True, timeout=30,
                   env={'PATH': str(bin_dir), 'HOME': str(tmp_path), 'MI_LANZADOR_IDIOMA': 'en', 'XDO_LOG': str(log)})
    calls = log.read_text(encoding='utf-8').splitlines()
    assert any(call.startswith('search --name') for call in calls) == searched, calls
    assert any(call.startswith('windowactivate') and call.endswith(' 999' if searched else ' 42') for call in calls), calls


# --------------------------------------------------------------------------- objetivo por alias
FAKE_XDOTOOL_VENTANAS = '''#!/bin/bash
echo "$*" >> "$XDO_LOG"
case "$1" in
    getactivewindow)   # 42: ventana ajena con foco. 555: la que abre el programa; pierde el foco nada más detectarla
        if [ -e "$FLAG" ] && [ ! -e "$FLAG.visto" ]; then : > "$FLAG.visto"; echo 555; else echo 42; fi ;;
    getdisplaygeometry) echo "1920 1080" ;;
    getmouselocation) [ -z "$PUNTERO" ] || printf 'X=%s\\nY=%s\\nSCREEN=0\\nWINDOW=1\\n' "${PUNTERO%,*}" "${PUNTERO#*,}" ;;
    mousemove) [ -z "$MOVER_TARDA" ] || [ "$2" != --sync ] || exec sleep 30 ;;   # como xdotool con el puntero quieto
    getwindowgeometry) [ -n "$SIN_GEOMETRIA" ] || printf 'X=0\\nY=0\\nWIDTH=800\\nHEIGHT=600\\n' ;;
    getwindowname)   # con CERRADA, la 555 ya no existe tras detectarla: xdotool real falla (BadWindow, código 1);
        # igual cuando el wmctrl falso recibió «-ic» (marca FLAG.cerrada, que él crea con retraso)
        [ "$2" = 555 ] || exit 0
        [ -n "$CERRADA" ] && [ -e "$FLAG.visto" ] && exit 1
        [ -e "$FLAG.cerrada" ] && exit 1 ;;
esac
exit 0
'''
CONSULTAS = {'getactivewindow', 'getdisplaygeometry', 'getmouselocation', 'getwindowgeometry', 'getwindowname', 'search'}


# wmctrl falso: anota sus llamadas en el mismo registro (con el prefijo «wmctrl ») y, con «-ic», la ventana 555 desaparece
# 0,3 s después, como un cierre real (asíncrono).
FAKE_WMCTRL = '''#!/bin/bash
echo "wmctrl $*" >> "$XDO_LOG"
case "$1" in -ic) ( sleep 0.3; : > "$FLAG.cerrada" ) >/dev/null 2>&1 & ;; esac
exit 0
'''


def xdotool_calls(app, tmp_path, steps, flag=None, con_wmctrl=False, sin_timeout=False, **extra_env):
    """Ejecuta la acción con un xdotool falso (y un wmctrl falso con `con_wmctrl`, sin `timeout` en el PATH con `sin_timeout`):
    devuelve (sus llamadas, stderr). `flag` es el fichero que crea el programa abierto; CERRADA=1 hace que esa ventana ya no
    exista al usarla, SIN_GEOMETRIA=1 que no se pueda leer su geometría, PUNTERO="x,y" fija dónde está el puntero y
    MOVER_TARDA=1 que «mousemove --sync» no vuelva."""
    bin_dir = isolated_path(tmp_path)
    if sin_timeout:
        (bin_dir / 'timeout').unlink()
    (bin_dir / 'xdotool').write_text(FAKE_XDOTOOL_VENTANAS, encoding='utf-8')
    (bin_dir / 'xdotool').chmod(0o755)
    if con_wmctrl:
        (bin_dir / 'wmctrl').write_text(FAKE_WMCTRL, encoding='utf-8')
        (bin_dir / 'wmctrl').chmod(0o755)
    script, log = tmp_path / 'accion.sh', tmp_path / 'xdo.log'
    script.write_text(app.generar_script_bash(steps, 'demo'), encoding='utf-8')
    env = {'PATH': str(bin_dir), 'HOME': str(tmp_path), 'MI_LANZADOR_IDIOMA': 'en', 'XDO_LOG': str(log), 'FLAG': str(flag), **extra_env}
    result = subprocess.run(['bash', str(script)], env=env, capture_output=True, text=True, timeout=30)
    return log.read_text(encoding='utf-8').splitlines(), result.stderr


@pytest.mark.parametrize('absolutas', [True, False])
def test_a_step_aimed_at_an_alias_that_never_opened_a_window_does_nothing_and_warns(app, tmp_path, absolutas):
    objetivo = {'objetivo_modo': '_alias', 'objetivo_alias': 'nunca_abierta'}
    steps = [{'tipo': 'tecla', 'combinacion': 'ctrl+s', **objetivo},
             {'tipo': 'texto', 'texto': 'hola', **objetivo},
             {'tipo': 'ventana', 'accion_ventana': 'maximizar', **objetivo},
             {'tipo': 'clic', 'x': 10, 'y': 20, 'coords_absolutas': absolutas, 'activar_ventana': True, **objetivo}]
    calls, stderr = xdotool_calls(app, tmp_path, steps)
    assert [c for c in calls if c.split()[0] not in CONSULTAS] == [], calls   # ni activar, ni teclear, ni clicar
    for aviso in ('the target window of the key step was not found', 'the target window of the text step was not found',
                  'the target window of the window step was not found', 'the window to activate before clicking was not found'):
        assert aviso in stderr, stderr
    assert stderr.count('the window to activate before clicking was not found') == 1
    assert 'the click coordinates could not be determined' not in stderr   # un solo aviso por el clic, no dos


@pytest.mark.parametrize('alias, objetivo', [('editor', 'editor'), (None, '__paso0')])
def test_a_step_aimed_at_a_window_opened_earlier_acts_on_it_even_if_the_focus_moved(app, tmp_path, alias, objetivo):
    flag = tmp_path / 'ventana.flag'
    apertura = {'tipo': 'programa', 'modo': 'manual', 'ruta': '/usr/bin/touch', 'argumentos': str(flag), 'espera': 3}
    apertura.update({'alias': alias} if alias else {})   # sin alias, la ventana se llama por su posición
    steps = [apertura] + [{**paso, 'objetivo_modo': '_alias', 'objetivo_alias': objetivo} for paso in (
        {'tipo': 'tecla', 'combinacion': 'ctrl+s'}, {'tipo': 'texto', 'texto': 'hola'},
        {'tipo': 'clic', 'x': 10, 'y': 20, 'coords_absolutas': True, 'activar_ventana': True})]
    calls, stderr = xdotool_calls(app, tmp_path, steps, flag)
    for esperada in ('windowactivate --sync 555', 'windowfocus --sync 555', 'key -- ctrl+s', 'windowactivate 555',
                     'type --clearmodifiers --delay 30 -- hola', 'mousemove --sync -- 10 20', 'click --clearmodifiers 1'):
        assert esperada in calls, calls
    assert not [c for c in calls if c.startswith('window') and c.endswith(' 42')], calls   # la ventana ajena, intacta
    assert not app.RE_AVISO_LOG.search(stderr), stderr


def test_first_step_without_a_previous_window_still_acts_on_the_active_window(app, tmp_path):
    calls, stderr = xdotool_calls(app, tmp_path, [{'tipo': 'tecla', 'combinacion': 'ctrl+s'}])
    assert 'windowactivate --sync 42' in calls and 'key -- ctrl+s' in calls
    assert not app.RE_AVISO_LOG.search(stderr), stderr


@pytest.mark.parametrize('objetivo', [{'objetivo_alias': ''}, {}])
def test_an_empty_alias_is_reported_without_a_bash_subscript_error(app, tmp_path, objetivo):
    steps = [{'tipo': 'tecla', 'combinacion': 'ctrl+s', 'objetivo_modo': '_alias', **objetivo}]
    calls, stderr = xdotool_calls(app, tmp_path, steps)
    assert 'bad array subscript' not in stderr and 'the target window of the key step was not found' in stderr
    assert not [c for c in calls if c.split()[0] not in CONSULTAS], calls


# --------------------------------------------------------------------------- clic: mover el puntero
# xdotool 3.20160805: «mousemove --sync X Y» con el puntero ya en X Y espera ~15 s a un movimiento que no llega.
PASO_CLIC = {'tipo': 'clic', 'x': 10, 'y': 20, 'coords_absolutas': True, 'activar_ventana': False}
MOVER_Y_CLICAR = ['mousemove --sync -- 10 20', 'click --clearmodifiers 1']


def acciones(calls):
    return [c for c in calls if c.split()[0] not in CONSULTAS]


def test_a_click_moves_the_pointer_and_then_clicks(app, tmp_path):
    calls, stderr = xdotool_calls(app, tmp_path, [PASO_CLIC])
    assert acciones(calls) == MOVER_Y_CLICAR, calls
    assert not app.RE_AVISO_LOG.search(stderr), stderr


def test_a_pointer_already_on_the_click_point_is_not_moved(app, tmp_path):
    calls, stderr = xdotool_calls(app, tmp_path, [PASO_CLIC], PUNTERO='10,20')
    assert acciones(calls) == ['click --clearmodifiers 1'], calls
    assert not app.RE_AVISO_LOG.search(stderr), stderr


@pytest.mark.parametrize('puntero', ['11,20', '10,21', '20,10'])
def test_a_pointer_off_the_click_point_in_either_coordinate_is_moved(app, tmp_path, puntero):
    calls, _ = xdotool_calls(app, tmp_path, [PASO_CLIC], PUNTERO=puntero)
    assert acciones(calls) == MOVER_Y_CLICAR, calls


def test_a_pointer_that_never_arrives_delays_the_click_by_2_seconds_at_most(app, tmp_path):
    inicio = time.monotonic()
    calls, _ = xdotool_calls(app, tmp_path, [PASO_CLIC], MOVER_TARDA='1')   # el «mousemove --sync» falso no vuelve en 30 s
    assert acciones(calls) == MOVER_Y_CLICAR, calls
    assert time.monotonic() - inicio < 10


def test_without_timeout_the_pointer_is_moved_without_waiting_for_it(app, tmp_path):
    calls, _ = xdotool_calls(app, tmp_path, [PASO_CLIC], sin_timeout=True, MOVER_TARDA='1')
    assert acciones(calls) == ['mousemove -- 10 20', 'click --clearmodifiers 1'], calls


# --------------------------------------------------------------------------- ventana cerrada a mano
def abre_ventana(tmp_path, **extra):
    """Paso que abre la ventana 555 del xdotool falso (el programa crea el fichero que activa su detección)."""
    flag = tmp_path / 'ventana.flag'
    return flag, {'tipo': 'programa', 'modo': 'manual', 'ruta': '/usr/bin/touch', 'argumentos': str(flag), 'espera': 3, **extra}


def test_a_click_whose_window_exists_but_has_no_readable_geometry_warns_about_the_coordinates_only(app, tmp_path):
    flag, apertura = abre_ventana(tmp_path, alias='editor')
    clic = {'tipo': 'clic', 'x': 10, 'y': 20, 'coords_absolutas': False, 'activar_ventana': True,
            'objetivo_modo': '_alias', 'objetivo_alias': 'editor'}
    calls, stderr = xdotool_calls(app, tmp_path, [apertura, clic], flag, SIN_GEOMETRIA='1')
    assert 'windowactivate 555' in calls and not [c for c in calls if c.startswith(('mousemove', 'click'))], calls
    assert 'the click coordinates could not be determined' in stderr
    assert 'the window to activate before clicking was not found' not in stderr, stderr


@pytest.mark.parametrize('absolutas', [True, False])
def test_a_step_aimed_at_an_alias_whose_window_was_closed_is_skipped_with_a_warning(app, tmp_path, absolutas):
    flag, apertura = abre_ventana(tmp_path, alias='editor')
    objetivo = {'objetivo_modo': '_alias', 'objetivo_alias': 'editor'}
    steps = [apertura, {'tipo': 'tecla', 'combinacion': 'ctrl+s', **objetivo}, {'tipo': 'texto', 'texto': 'hola', **objetivo},
             {'tipo': 'clic', 'x': 10, 'y': 20, 'coords_absolutas': absolutas, 'activar_ventana': True, **objetivo}]
    calls, stderr = xdotool_calls(app, tmp_path, steps, flag, CERRADA='1')
    assert 'getwindowname 555' in calls and [c for c in calls if c.split()[0] not in CONSULTAS] == [], calls   # sin teclear, activar ni clicar
    for aviso in ('the target window of the key step was not found', 'the target window of the text step was not found'):
        assert aviso in stderr, stderr
    assert stderr.count('the window to activate before clicking was not found') == 1 and 'could not be determined' not in stderr


def test_a_step_aimed_at_the_last_window_falls_back_to_the_focused_one_when_that_window_was_closed(app, tmp_path):
    flag, apertura = abre_ventana(tmp_path)
    calls, stderr = xdotool_calls(app, tmp_path, [apertura, {'tipo': 'tecla', 'combinacion': 'ctrl+s'}], flag, CERRADA='1')
    assert 'getwindowname 555' in calls
    assert 'windowactivate --sync 42' in calls and 'key -- ctrl+s' in calls, calls
    assert not [c for c in calls if c.startswith('window') and c.endswith(' 555')], calls
    assert not app.RE_AVISO_LOG.search(stderr), stderr


def test_a_window_closed_for_real_is_never_replaced_by_the_focused_one_for_an_alias(app, tmp_path, x11):
    """De extremo a extremo (X, xdotool y xmessage reales): tras cerrar la ventana, la tecla no va al foco real."""
    for tool in ('xdotool', 'xmessage', 'wmctrl'):
        require_tools(tool)
    bin_dir = isolated_path(tmp_path)
    (bin_dir / 'xmessage').symlink_to(shutil.which('xmessage'))
    log = tmp_path / 'xdo.log'
    for tool, prefijo in (('xdotool', ''), ('wmctrl', 'wmctrl ')):   # anotan la llamada y ejecutan la herramienta real
        (bin_dir / tool).write_text(f'#!/bin/bash\necho "{prefijo}$*" >> {log}\nexec {shutil.which(tool)} "$@"\n', encoding='utf-8')
        (bin_dir / tool).chmod(0o755)
    objetivo = {'objetivo_modo': '_alias', 'objetivo_alias': 'aviso'}
    steps = [{'tipo': 'programa', 'modo': 'manual', 'ruta': shutil.which('xmessage'), 'argumentos': '-timeout 20 -title ML-VENTANA-CERRADA hola',
              'espera': 8, 'alias': 'aviso'},
             {'tipo': 'ventana', 'accion_ventana': 'cerrar', **objetivo},
             {'tipo': 'tecla', 'combinacion': 'ctrl+s', **objetivo}]
    script = tmp_path / 'accion.sh'
    script.write_text(app.generar_script_bash(steps, 'demo'), encoding='utf-8')
    result = subprocess.run(['bash', str(script)], capture_output=True, text=True, timeout=60,
                            env={'PATH': str(bin_dir), 'HOME': str(tmp_path), 'MI_LANZADOR_IDIOMA': 'en', 'DISPLAY': x11})
    calls = log.read_text(encoding='utf-8').splitlines()
    assert any(c.startswith('wmctrl -ic') for c in calls), (calls, result.stderr)   # la ventana se detectó y se pidió su cierre
    assert 'the target window of the key step was not found' in result.stderr, result.stderr
    assert not [c for c in calls if c.startswith('key ')], calls


def test_the_close_step_asks_the_application_to_close_and_waits_until_the_window_is_gone(app, tmp_path):
    """`xdotool windowclose` destruía la ventana sin dejar que la aplicación preguntara «¿guardar cambios?». Ahora se pide el cierre
    con `wmctrl -ic`; como es asíncrono, el paso siguiente no debe encontrar viva la ventana que se estaba cerrando."""
    flag, apertura = abre_ventana(tmp_path, alias='editor')
    objetivo = {'objetivo_modo': '_alias', 'objetivo_alias': 'editor'}
    steps = [apertura, {'tipo': 'ventana', 'accion_ventana': 'cerrar', **objetivo},
             {'tipo': 'tecla', 'combinacion': 'ctrl+s', **objetivo}]
    calls, stderr = xdotool_calls(app, tmp_path, steps, flag, con_wmctrl=True)
    assert 'wmctrl -ic 555' in calls, calls
    assert not [c for c in calls if c.startswith(('windowclose', 'windowkill'))], calls
    assert not [c for c in calls if c.startswith('key ')], calls   # la tecla no llega a la ventana que se estaba cerrando
    assert 'the target window of the key step was not found' in stderr, stderr


# Una ventana que pregunta antes de cerrar (como un editor con cambios sin guardar): anota la petición y se queda abierta.
VENTANA_QUE_PREGUNTA = '''
import sys
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk


def al_cerrar(*_):
    with open(sys.argv[1], 'a') as registro:
        registro.write('petición de cierre\\n')
    return True


ventana = Gtk.Window(title='ML-CIERRE-PREGUNTA')
ventana.connect('delete-event', al_cerrar)
ventana.show_all()
Gtk.main()
'''


def test_the_close_step_lets_the_application_refuse_instead_of_destroying_its_window(app, tmp_path, x11):
    """De extremo a extremo (X, wmctrl y xdotool reales): una ventana que pregunta antes de cerrar recibe la petición y sigue
    abierta; con `xdotool windowclose` desaparecía sin enterarse."""
    for tool in ('xdotool', 'wmctrl'):
        require_tools(tool)
    bin_dir = isolated_path(tmp_path)
    for tool in ('xdotool', 'wmctrl'):
        (bin_dir / tool).symlink_to(shutil.which(tool))
    env = {'PATH': str(bin_dir), 'HOME': str(tmp_path), 'MI_LANZADOR_IDIOMA': 'en', 'DISPLAY': x11}
    registro = tmp_path / 'peticiones.log'
    ventana = subprocess.Popen([sys.executable, '-c', VENTANA_QUE_PREGUNTA, str(registro)], env={**os.environ, **env, 'NO_AT_BRIDGE': '1'},
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        assert wait_until(lambda: 'ML-CIERRE-PREGUNTA' in window_titles(env), 15), window_titles(env)
        steps = [{'tipo': 'ventana', 'accion_ventana': 'cerrar', 'objetivo_modo': '_buscar', 'objetivo_buscar': 'ML-CIERRE-PREGUNTA'}]
        script = tmp_path / 'accion.sh'
        script.write_text(app.generar_script_bash(steps, 'demo'), encoding='utf-8')
        subprocess.run(['bash', str(script)], env=env, capture_output=True, text=True, timeout=60)
        assert wait_until(registro.exists, 5), 'la aplicación no recibió la petición de cierre'
        assert ventana.poll() is None and 'ML-CIERRE-PREGUNTA' in window_titles(env)   # sigue abierta: nadie la destruyó
    finally:
        ventana.kill()
        ventana.wait()


def test_title_search_is_literal_even_when_the_title_has_regex_characters(app, tmp_path, x11):
    """X, xdotool y xmessage reales: `xdotool search --name` toma un regex; el título escrito debe buscarse tal cual."""
    for tool in ('xdotool', 'xmessage', 'wmctrl'):
        require_tools(tool)
    bin_dir = isolated_path(tmp_path)
    for tool in ('xdotool', 'xmessage', 'wmctrl'):
        (bin_dir / tool).symlink_to(shutil.which(tool))
    env = {'PATH': str(bin_dir), 'HOME': str(tmp_path), 'MI_LANZADOR_IDIOMA': 'en', 'DISPLAY': x11}
    titulos = ['Notes (draft)', 'Report [final]', 'C++ Primer', 'a.b|c', 'Cost $5 ^ {x}', 'What? *new*', 'dir\\sub']
    ventanas = [subprocess.Popen(['xmessage', '-timeout', '60', '-title', t, 'hola'], env=env,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) for t in titulos + ['Keep me']]

    def titulos_abiertos():  # solo los propios: otras pruebas pueden dejar ventanas en el mismo servidor X
        salida = subprocess.run(['wmctrl', '-l'], env=env, capture_output=True, text=True).stdout
        return sorted(t for t in (l.split(None, 3)[3] for l in salida.splitlines() if len(l.split(None, 3)) == 4)
                      if t in titulos + ['Keep me'])

    try:
        assert wait_until(lambda: titulos_abiertos() == sorted(titulos + ['Keep me']), 15), titulos_abiertos()
        steps = [{'tipo': 'ventana', 'accion_ventana': 'cerrar', 'objetivo_modo': '_buscar', 'objetivo_buscar': t} for t in titulos]
        script = tmp_path / 'accion.sh'
        script.write_text(app.generar_script_bash(steps, 'demo'), encoding='utf-8')
        subprocess.run(['bash', str(script)], env=env, capture_output=True, text=True, timeout=90)
        assert wait_until(lambda: titulos_abiertos() == ['Keep me'], 5), titulos_abiertos()   # cada título cerró SU ventana
    finally:
        for ventana in ventanas:
            ventana.kill()


@pytest.mark.parametrize('carpeta', ['tmp', "mi carpeta 'con' $comillas"])
def test_placement_tokens_go_to_the_cleaned_temp_folder_not_to_the_cache(app, tmp_path, monkeypatch, carpeta):
    """TMP_DIR es una variable de Python: sin pasarla al script, los .token caían en ~/.cache y nadie los limpiaba."""
    monkeypatch.setattr(app, 'TMP_DIR', str(tmp_path / carpeta))
    bin_dir = isolated_path(tmp_path)
    for name, body in (('xdotool', FAKE_XDOTOOL_VENTANAS), ('wmctrl', '#!/bin/bash\nexit 0\n')):
        (bin_dir / name).write_text(body, encoding='utf-8')
        (bin_dir / name).chmod(0o755)
    script = tmp_path / 'accion.sh'
    script.write_text(app.generar_script_bash([{'tipo': 'ventana', 'accion_ventana': a} for a in ('maximizar', 'centrada')], 'demo'),
                      encoding='utf-8')
    subprocess.run(['bash', str(script)], capture_output=True, text=True, timeout=30,
                   env={'PATH': str(bin_dir), 'HOME': str(tmp_path), 'MI_LANZADOR_IDIOMA': 'en',
                        'XDO_LOG': str(tmp_path / 'xdo.log'), 'FLAG': str(tmp_path / 'flag')})
    assert sorted(p.name for p in pathlib.Path(app.TMP_DIR).glob('*.token')) == ['geometria_42.token', 'ventana_42.token']
    assert not (tmp_path / '.cache').exists()


# --------------------------------------------------------------------------- detección de la ventana nueva
# xdotool falso que nunca cambia el foco (siempre la 42): la ventana nueva solo puede detectarse comparando las listas de
# «search» (ids separados por espacios). Mientras el programa no ha creado FLAG da VISIBLES_0; en el primer sondeo después,
# VISIBLES_1; en los siguientes, VISIBLES_2.
FAKE_XDOTOOL_LISTAS = '''#!/bin/bash
echo "$*" >> "$XDO_LOG"
case "$1" in
    search)
        if [ ! -e "$FLAG" ]; then lista="$VISIBLES_0"
        else
            n=$(( $(cat "$FLAG.xdo" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FLAG.xdo"
            if [ "$n" -eq 1 ]; then lista="$VISIBLES_1"; else lista="$VISIBLES_2"; fi
        fi
        for id in $lista; do echo "$id"; done ;;
    getactivewindow) echo 42 ;;
    getdisplaygeometry) echo "1920 1080" ;;
    getwindowname) [ "$2" = 555 ] && [ -e "$FLAG.cerrada" ] && exit 1 ;;
esac
exit 0
'''
# wmctrl falso: «-l» da el contenido de LISTA_GESTOR_1 la primera vez tras abrirse la ventana y el de LISTA_GESTOR_2 después
# (una ventana por línea, con el id en hexadecimal como el real); con SIN_GESTOR falla como wmctrl sin gestor de ventanas.
FAKE_WMCTRL_LISTAS = '''#!/bin/bash
echo "wmctrl $*" >> "$XDO_LOG"
case "$1" in
    -l)
        if [ -n "$SIN_GESTOR" ]; then echo "Cannot get client list properties. (_NET_CLIENT_LIST or _WIN_CLIENT_LIST)" >&2; exit 1; fi
        [ -e "$FLAG" ] || exit 0
        n=$(( $(cat "$FLAG.wm" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FLAG.wm"
        if [ "$n" -eq 1 ]; then cat "$LISTA_GESTOR_1"; else cat "$LISTA_GESTOR_2"; fi ;;
    -ic) ( sleep 0.3; : > "$FLAG.cerrada" ) >/dev/null 2>&1 & ;;
esac
exit 0
'''
VENTANA_555 = '0x0000022b  0 pc Editor\n'   # 0x22b = 555


def abre_y_cierra(app, tmp_path, visibles, gestor, espera=3, sin_gestor=False, sin_xdotool=False):
    """Abre una ventana con un programa falso y la cierra con «ventana → cerrar» (la 555, la única real): devuelve (llamadas, stderr).
    `visibles`: lo que lista «xdotool search» (antes, primer sondeo, siguientes); `gestor`: lo que lista «wmctrl -l» (primera
    vez, siguientes)."""
    bin_dir = isolated_path(tmp_path)
    for nombre, cuerpo in (('wmctrl', FAKE_WMCTRL_LISTAS),) + (() if sin_xdotool else (('xdotool', FAKE_XDOTOOL_LISTAS),)):
        (bin_dir / nombre).write_text(cuerpo, encoding='utf-8')
        (bin_dir / nombre).chmod(0o755)
    for numero, contenido in enumerate(gestor, 1):
        (tmp_path / f'gestor{numero}.txt').write_text(contenido, encoding='utf-8')
    flag, apertura = abre_ventana(tmp_path, alias='editor', espera=espera)
    cerrar = {'tipo': 'ventana', 'accion_ventana': 'cerrar', 'objetivo_modo': '_alias', 'objetivo_alias': 'editor'}
    script, log = tmp_path / 'accion.sh', tmp_path / 'xdo.log'
    script.write_text(app.generar_script_bash([apertura, cerrar], 'demo'), encoding='utf-8')
    env = {'PATH': str(bin_dir), 'HOME': str(tmp_path), 'MI_LANZADOR_IDIOMA': 'en', 'XDO_LOG': str(log), 'FLAG': str(flag),
           'LISTA_GESTOR_1': str(tmp_path / 'gestor1.txt'), 'LISTA_GESTOR_2': str(tmp_path / 'gestor2.txt'),
           **{f'VISIBLES_{n}': lista for n, lista in enumerate(visibles)}, **({'SIN_GESTOR': '1'} if sin_gestor else {})}
    result = subprocess.run(['bash', str(script)], env=env, capture_output=True, text=True, timeout=30)
    return (log.read_text(encoding='utf-8').splitlines() if log.exists() else []), result.stderr


@pytest.mark.parametrize('visibles, gestor', [
    # el gestor ya lista la 555 pero aún no es visible (la está enmarcando): solo se ven trozos de su marco (701, 702)
    (('10 20', '10 20 701 702', '10 20 555 701 702'), (VENTANA_555, VENTANA_555)),
    # la 555 es visible antes de constar en la lista del gestor: la 701, también visible y nueva, no es una ventana suya
    (('10 20', '10 20 555 701', '10 20 555 701'), ('', VENTANA_555))],
    ids=['listada_antes_de_ser_visible', 'visible_antes_de_estar_listada'])
def test_a_new_window_is_only_taken_from_the_managers_list_and_the_poll_is_retried_until_it_matches(app, tmp_path, visibles, gestor):
    """Elegir «la última de la lista» cuando ninguna nueva coincidía con wmctrl devolvía un trozo del marco: `wmctrl -ic`, la colocación y las
    teclas actuaban sobre una ventana inválida, sin avisar (fallaba una de cada seis ejecuciones del paso «cerrar» con X real)."""
    calls, stderr = abre_y_cierra(app, tmp_path, visibles, gestor)
    assert 'wmctrl -ic 555' in calls, calls
    assert not [c for c in calls if c.endswith((' 701', ' 702'))], calls
    assert not app.RE_AVISO_LOG.search(stderr), stderr


def test_a_window_the_manager_never_lists_is_not_replaced_by_another_one_from_the_visible_list(app, tmp_path):
    calls, stderr = abre_y_cierra(app, tmp_path, ('10 20', '10 20 555 701', '10 20 555 701'), ('', ''), espera=1)
    assert not [c for c in calls if c.startswith(('wmctrl -ic', 'windowactivate'))], calls
    assert 'the target window of the window step was not found' in stderr, stderr


def test_without_a_responding_window_manager_the_last_new_visible_window_is_used(app, tmp_path):
    """Sin gestor de ventanas (o sin EWMH) `wmctrl -l` falla y no hay otra fuente: se conserva la última ventana nueva visible."""
    calls, stderr = abre_y_cierra(app, tmp_path, ('10 20', '10 20 555 701', '10 20 555 701'), ('', ''), sin_gestor=True)
    assert 'wmctrl -ic 701' in calls, calls


def test_without_xdotool_the_managers_window_list_is_the_snapshot_and_gives_decimal_ids(app, tmp_path):
    """`wmctrl -l` da los ids en hexadecimal (0x0000022b); xdotool y las comparaciones del script usan decimales."""
    calls, stderr = abre_y_cierra(app, tmp_path, ('', '', ''), ('', VENTANA_555), sin_xdotool=True)
    assert 'wmctrl -ic 555' in calls, calls
    assert not [c for c in calls if '0x' in c and c.startswith('wmctrl -ic')], calls
    assert not app.RE_AVISO_LOG.search(stderr), stderr


@pytest.mark.parametrize('paso', [{'tipo': 'programa', 'modo': 'desktop'}, {'tipo': 'programa', 'modo': 'instalado'},
                                  {'tipo': 'documento', 'abrir_con': 'app'}])
@pytest.mark.parametrize('lineas, esperado', [
    ('StartupWMClass=Clase\nExec=/usr/bin/otro %U', 'Clase'),
    ('Exec=/opt/app/bin/mi-app --flag %U', 'mi-app'),
    ('Exec=   ', ''),
])
def test_the_window_class_hint_of_a_desktop_step_is_its_wm_class_or_else_the_binary_of_exec(app, tmp_path, paso, lineas, esperado):
    """Programa (instalado/desktop) y documento «con aplicación» comparten la regla: StartupWMClass y, sin ella, el binario de Exec."""
    desktop = tmp_path / 'app.desktop'
    desktop.write_text(f'[Desktop Entry]\nType=Application\nName=X\n{lineas}\n', encoding='utf-8')
    assert app._pista_clase_para_paso({**paso, 'ruta_desktop': str(desktop)}) == esperado


def test_the_window_class_hint_is_empty_for_a_desktop_that_is_missing_or_not_launchable(app, tmp_path):
    sin_exec = tmp_path / 'sin_exec.desktop'
    sin_exec.write_text('[Desktop Entry]\nType=Application\nName=X\n', encoding='utf-8')
    for ruta in (tmp_path / 'no_existe.desktop', sin_exec):
        assert app._pista_clase_para_paso({'tipo': 'programa', 'modo': 'desktop', 'ruta_desktop': str(ruta)}) == ''
        assert app._pista_clase_para_paso({'tipo': 'documento', 'abrir_con': 'app', 'ruta_desktop': str(ruta)}) == ''


def test_an_action_still_runs_after_the_temp_folder_was_deleted_while_the_program_was_open(app, tmp_path, monkeypatch):
    """TMP_DIR solo se creaba al arrancar: borrarla con la ventana abierta hacía fallar «Ejecutar» hasta reiniciar."""
    shutil.rmtree(app.TMP_DIR)
    log, sent = run_action_and_collect(app, tmp_path, monkeypatch, 'en', [{'tipo': 'esperar', 'segundos': 0}])
    assert not app.RE_AVISO_LOG.search(log) and len(sent) == 1, (log, sent)   # solo el aviso «Running»
    assert pathlib.Path(app.TMP_DIR).is_dir()


def test_the_system_browser_is_looked_up_once_per_generated_script_and_again_for_the_next_one(app, monkeypatch):
    # Cada paso web con navegador «sistema» lanzaba xdg-settings una o dos veces (unos 80 ms cada una) al generar el script.
    # La detección se hace una vez por script y se descarta: si el usuario cambia de navegador, el siguiente script lo nota.
    consultas = []

    def xdg_settings_falso(orden, *args, **kwargs):
        consultas.append(orden[0])
        return subprocess.CompletedProcess(orden, 0, stdout='firefox.desktop\n', stderr='')

    cual = shutil.which
    monkeypatch.setattr(app.subprocess, 'run', xdg_settings_falso)
    monkeypatch.setattr(app.shutil, 'which', lambda nombre, *a, **k: '/usr/bin/firefox' if nombre == 'firefox' else cual(nombre, *a, **k))
    web = {'tipo': 'web', 'url': 'https://example.test', 'navegador': 'sistema'}
    pasos = [web, {**web, 'nueva_ventana': True}, {**web, 'modo_app': True}, {'tipo': 'esperar', 'segundos': 0}]

    script = app.generar_script_bash(pasos, 'demo')
    assert consultas == ['xdg-settings'], consultas
    # El resultado de esa única consulta lo ven el comando y la pista de ventana de cada paso, como antes.
    assert script.count('firefox --new-window https://example.test') == 1, script
    assert script.count(' firefox)"') == 3, script   # pista de clase de los tres pasos web

    app.generar_script_bash(pasos, 'demo')
    assert consultas == ['xdg-settings'] * 2, consultas
    app.generar_script_bash([{'tipo': 'esperar', 'segundos': 0}], 'demo')
    assert consultas == ['xdg-settings'] * 2, consultas   # sin pasos web no se consulta nada
