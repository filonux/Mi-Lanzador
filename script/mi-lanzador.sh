#!/bin/bash
# ============================================================================
#  MI LANZADOR 2.1.0 — Automated shortcut creator
#  For Linux Mint 22.3 (Cinnamon) — X11 session
#
#  Copyright (C) 2026 Filonux (developer and author)
#  Free software under the GNU General Public License version 3 (GPLv3);
#  the full text is in LICENSE.txt.
#
#  Opens a graphical interface where you create "actions" made of SEVERAL CHAINED STEPS:
#   · Open a program (catalogue of detected applications and shortcuts, or a manual
#     path/command), a document or a web page (in a tab or in a new window).
#   · Run a command in a terminal; wait a few seconds.
#   · Place the window that was just opened (maximize, halves, quarters, custom size/position,
#     minimize, close), built into the step itself. The separate "window" step is for a
#     window that was already open.
#   · Clicks at absolute screen coordinates (picked with a 3 s countdown or typed in), optionally
#     activating a specific window first.
#   · Send keys or key combinations; type text.
#  Like an AutoHotkey macro, using xdotool and wmctrl (the equivalent tools on X11).
#
#  From the list of actions you can generate a shortcut (.desktop) for the Desktop and/or the
#  menu that runs all the steps, in order, without opening this window.
#  It installs itself on first run: it copies itself to ~/.local/share/mi-lanzador/ and creates
#  its launcher in the applications menu (and a copy on the Desktop).
#
#  Usage:  chmod +x mi-lanzador.sh  then  ./mi-lanzador.sh  (or double-click once executable).
#  Everything (interface, logic and data handling) lives in this file; actions are saved in
#  ~/.config/mi-lanzador/acciones.json
#
#  Windows, clicks and keys (X11) need xdotool and wmctrl (sudo apt install xdotool
#  wmctrl). The script offers to install them, always asking for confirmation first.
# ============================================================================

# The messages use typographic quotes on purpose (SC1111).
# shellcheck disable=SC1111
set -u -o pipefail

APP_DIR="$HOME/.local/share/mi-lanzador"
APP_SCRIPT="$APP_DIR/mi-lanzador.sh"
CONFIG_DIR="$HOME/.config/mi-lanzador"
DESKTOP_APPS_DIR="$HOME/.local/share/applications"
DESKTOP_LAUNCHER="$DESKTOP_APPS_DIR/mi-lanzador.desktop"
FIRST_RUN_FLAG="$CONFIG_DIR/.instalado"

IDIOMA_FILE="$CONFIG_DIR/idioma"

_detectar_idioma() {
    local guardado locale
    if [[ -r "$IDIOMA_FILE" ]]; then
        read -r guardado < "$IDIOMA_FILE" || true
        case "$guardado" in
            es|en) printf '%s\n' "$guardado"; return 0 ;;
        esac
    fi
    for locale in "${LC_ALL:-}" "${LC_MESSAGES:-}" "${LANG:-}"; do
        [[ -n "$locale" ]] || continue
        locale="${locale%%:*}"
        locale="${locale%%_*}"
        locale="${locale%%-*}"
        locale="${locale%%.*}"
        locale="${locale%%@*}"
        locale="${locale,,}"
        [[ "$locale" == "es" ]] && printf '%s\n' es || printf '%s\n' en
        return 0
    done
    printf '%s\n' en
}

APP_LANG="${MI_LANZADOR_LANG:-$(_detectar_idioma)}"
case "$APP_LANG" in es|en) ;; *) APP_LANG=en ;; esac
export MI_LANZADOR_IDIOMA="$APP_LANG"

case "$APP_LANG" in
    es)
        MSG_CLOSE='Cerrar'
        MSG_DIR_ERROR='Mi Lanzador: no se pudieron crear los directorios de datos (revisa permisos y espacio en disco).'
        MSG_PYTHON_MISSING=$'Falta Python 3. Instálalo con:\nsudo apt install python3'
        MSG_GTK_MISSING=$'Faltan dependencias de GTK para Python. Instálalas con:\nsudo apt install python3-gi gir1.2-gtk-3.0 python3-gi-cairo gir1.2-notify-0.7'
        MSG_INSTALL_GTK=$'Mi Lanzador necesita instalar unos paquetes del sistema para poder mostrar su interfaz:\n\n  python3-gi, gir1.2-gtk-3.0, python3-gi-cairo, gir1.2-notify-0.7\n\n¿Instalarlos ahora? Se te pedirá tu contraseña de administrador.'
        MSG_WAYLAND=$'Estás en una sesión Wayland nativa de Cinnamon.\nxdotool y wmctrl (colocar ventana, clic, tecla) SOLO funcionan en X11 y no van a funcionar aquí, aunque los instales.\n\nAbrir programas, páginas web y comandos SÍ seguirá funcionando con normalidad.\n\nSi necesitas los demás pasos, cierra la sesión y elige "Cinnamon" (la sesión X11, no la que dice "Wayland") en la pantalla de inicio de sesión.'
        ;;
    *)
        MSG_CLOSE='Close'
        MSG_DIR_ERROR='Mi Lanzador: could not create its data directories (check permissions and available disk space).'
        MSG_PYTHON_MISSING=$'Python 3 is missing. Install it with:\nsudo apt install python3'
        MSG_GTK_MISSING=$'Python GTK dependencies are missing. Install them with:\nsudo apt install python3-gi gir1.2-gtk-3.0 python3-gi-cairo gir1.2-notify-0.7'
        MSG_INSTALL_GTK=$'Mi Lanzador needs to install a few system packages to show its interface:\n\n  python3-gi, gir1.2-gtk-3.0, python3-gi-cairo, gir1.2-notify-0.7\n\nInstall them now? You will be asked for your administrator password.'
        MSG_WAYLAND=$'You are in a native Cinnamon Wayland session.\nxdotool and wmctrl (window placement, clicks, keyboard) ONLY work on X11 and will not work here, even if installed.\n\nOpening programs, websites and commands will still work normally.\n\nFor the other steps, log out and choose “Cinnamon” (the X11 session, not the one labelled “Wayland”) on the login screen.'
        ;;
esac

if ! mkdir -p "$APP_DIR" "$CONFIG_DIR" "$DESKTOP_APPS_DIR" "$CONFIG_DIR/tmp"; then
    printf '%s\n' "$MSG_DIR_ERROR" >&2
    exit 1
fi

if [[ "${1:-}" == "--print-language" ]]; then
    printf '%s\n' "$APP_LANG"
    exit 0
fi

# ---------------------------------------------------------------------------
# Escritura atómica: el contenido (stdin) va a un temporal del mismo directorio y se renombra.
# Un corte a mitad de copia no deja archivos a medias ni modifica un script en ejecución.
# ---------------------------------------------------------------------------
escribir_atomico() {
    local destino="$1" modo="${2:-644}" tmp
    tmp="$(mktemp "${destino%/*}/.${destino##*/}.XXXXXX" 2>/dev/null)" || return 1
    if cat > "$tmp" && chmod "$modo" "$tmp" && mv -f "$tmp" "$destino"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# --- 1) Auto-instalación: copiar este script a una ubicación estable ---
SELF_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
if [[ "$SELF_PATH" != "$APP_SCRIPT" ]] && ! cmp -s "$SELF_PATH" "$APP_SCRIPT" 2>/dev/null; then
    escribir_atomico "$APP_SCRIPT" 755 < "$SELF_PATH" 2>/dev/null || true
fi
[[ -x "$APP_SCRIPT" ]] || chmod +x "$APP_SCRIPT" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2) Icono y lanzador .desktop propios (menú de aplicaciones); se regeneran si su contenido cambia.
#    Los textos sin sufijo van en inglés (idioma de reserva); [es] cubre el español.
# ---------------------------------------------------------------------------
ICON_ROOT="$HOME/.local/share/icons/hicolor"
ICON_FILE="$ICON_ROOT/scalable/apps/mi-lanzador.svg"

contenido_icono() {
    cat <<'SVG'
<svg viewBox="0 0 512 512" xmlns="http://www.w3.org/2000/svg">
<defs>
<linearGradient id="a" x1="8%" y1="2%" x2="96%" y2="100%"><stop offset="0" stop-color="#6c5ce7"/><stop offset="1" stop-color="#8e7cff"/></linearGradient>
<radialGradient id="b" cx="72%" cy="24%" r="55%"><stop offset="0" stop-color="#fff" stop-opacity=".22"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
</defs>
<rect x="16" y="16" width="480" height="480" rx="108" fill="url(#a)"/>
<rect x="16" y="16" width="480" height="480" rx="108" fill="url(#b)"/>
<g transform="translate(256 268) scale(1.18) rotate(35) translate(-256 -268)">
<circle cx="256" cy="452" r="11" fill="#fff" opacity=".85"/>
<circle cx="242" cy="480" r="7.5" fill="#fff" opacity=".55"/>
<circle cx="233" cy="502" r="4.5" fill="#fff" opacity=".32"/>
<path d="M224 330C206 366 214 400 256 436 298 400 306 366 288 330Z" fill="#FFA726"/>
<path d="M238 330C228 356 232 380 256 406 280 380 284 356 274 330Z" fill="#FFDE7A"/>
<path d="M208 296 148 384 208 340Z" fill="#E3DDFF"/>
<path d="M304 296 364 384 304 340Z" fill="#E3DDFF"/>
<path d="M256 88Q303 152 305 192V334H207V192Q209 152 256 88Z" fill="#fff"/>
<circle cx="256" cy="246" r="24" fill="#4C3FBF"/>
<circle cx="256" cy="246" r="17" fill="#C7D2FE"/>
</g>
</svg>
SVG
}

if ! contenido_icono | cmp -s - "$ICON_FILE" 2>/dev/null; then
    mkdir -p "${ICON_FILE%/*}" && contenido_icono | escribir_atomico "$ICON_FILE" 644 2>/dev/null
    # Un icon-theme.cache previo ocultaría el icono nuevo a GTK hasta regenerarlo.
    [[ -f "$ICON_ROOT/icon-theme.cache" ]] && command -v gtk-update-icon-cache >/dev/null 2>&1 \
        && gtk-update-icon-cache -qtf "$ICON_ROOT" >/dev/null 2>&1
fi

# Argumento de Exec= según la especificación Desktop Entry: entre comillas dobles, con «\», «"», «`» y «$» precedidos de
# una barra; después se duplica cada barra (escape de cadena de GKeyFile) y «%» pasa a «%%». Equivale a _arg_exec +
# _exec_desktop (Python) salvo que entrecomilla siempre: una ruta normal sale "<ruta>" y Python la deja sin comillas.
exec_arg() {
    local s=$1
    s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//\`/\\\`}; s=${s//\$/\\\$}
    s=${s//\\/\\\\}; s=${s//%/%%}
    printf '"%s"' "$s"
}

contenido_desktop() {
    cat <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Mi Lanzador
GenericName=Automated shortcut creator
GenericName[es]=Creador de accesos directos
Comment=Create shortcuts that chain programs, websites, windows, clicks and keystrokes · by Filonux
Comment[es]=Crea accesos directos que encadenan programas, webs, ventanas, clics y teclas · por Filonux
Exec=/bin/bash $(exec_arg "$APP_SCRIPT")
Icon=mi-lanzador
Terminal=false
Categories=Utility;
StartupNotify=true
EOF
}

if ! contenido_desktop | cmp -s - "$DESKTOP_LAUNCHER" 2>/dev/null; then
    contenido_desktop | escribir_atomico "$DESKTOP_LAUNCHER" 755
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$DESKTOP_APPS_DIR" >/dev/null 2>&1
    command -v gio >/dev/null 2>&1 && gio set "$DESKTOP_LAUNCHER" metadata::trusted true >/dev/null 2>&1
fi

# --- 3) Copia en el Escritorio: se crea solo en la primera ejecución; si existe, se mantiene al día ---
DESK_DIR="$(xdg-user-dir DESKTOP 2>/dev/null)"
# Sin Escritorio configurado xdg-user-dir da $HOME: igual que _dir_escritorio (Python), se usa ~/Desktop.
if [[ -z "$DESK_DIR" || "$DESK_DIR" -ef "$HOME" ]]; then DESK_DIR="$HOME/Desktop"; fi
DESK_COPY="$DESK_DIR/Mi Lanzador.desktop"
if [[ -d "$DESK_DIR" ]] && { [[ ! -f "$FIRST_RUN_FLAG" ]] \
    || { [[ -f "$DESK_COPY" ]] && ! cmp -s "$DESKTOP_LAUNCHER" "$DESK_COPY"; }; }; then
    escribir_atomico "$DESK_COPY" 755 < "$DESKTOP_LAUNCHER" 2>/dev/null || true
    command -v gio >/dev/null 2>&1 && gio set "$DESK_COPY" metadata::trusted true >/dev/null 2>&1
fi
[[ -f "$FIRST_RUN_FLAG" ]] || touch "$FIRST_RUN_FLAG"

# --- 4) Comprobar dependencias (Python 3 + GTK3 vía PyGObject, y xdotool/wmctrl) ---
# Basta con que existan los typelibs que exige el programa (Gtk 3.0 y GdkPixbuf 2.0): `from gi.repository import Gtk` cargaría
# además la biblioteca entera en cada arranque (~50 ms) para saber lo mismo, porque gir1.2-gtk-3.0 depende de libgtk-3-0t64.
python_gtk_disponible() {
    python3 -c "import gi; gi.require_version('Gtk','3.0'); gi.require_version('GdkPixbuf','2.0')" >/dev/null 2>&1
}

mostrar_error_dependencias() {
    local msg="$1"
    if command -v zenity >/dev/null 2>&1; then
        zenity --error --title="Mi Lanzador" --text="$msg" 2>/dev/null
    elif command -v yad >/dev/null 2>&1; then
        yad --title="Mi Lanzador" --text="$msg" --button="$MSG_CLOSE:0" 2>/dev/null
    else
        echo "$msg" >&2
    fi
}

# Pide confirmación antes de instalar nada: con zenity, si no con un diálogo GTK, si no por terminal.
# Sin ninguna forma de preguntar, responde que no.
confirmar_instalacion() {
    local mensaje="$1"
    if command -v zenity >/dev/null 2>&1; then
        zenity --question --title="Mi Lanzador" --width=440 --text="$mensaje" 2>/dev/null
        return $?
    fi
    if python_gtk_disponible; then
        python3 - "$mensaje" <<'PYCONFIRM'
import sys
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk
dialogo = Gtk.MessageDialog(transient_for=None, flags=0, message_type=Gtk.MessageType.QUESTION,
                             buttons=Gtk.ButtonsType.YES_NO, text=sys.argv[1] if len(sys.argv) > 1 else '')
dialogo.set_title('Mi Lanzador')
dialogo.set_keep_above(True)
respuesta = dialogo.run()
dialogo.destroy()
sys.exit(0 if respuesta == Gtk.ResponseType.YES else 1)
PYCONFIRM
        return $?
    fi
    if [[ -t 0 && -t 1 ]]; then
        printf '%s\n' "$mensaje" >&2
        read -r -p "$([[ "$APP_LANG" == es ]] && printf '%s' '¿Instalar ahora? [s/N] ' || printf '%s' 'Install now? [y/N] ')" respuesta
        case "$respuesta" in
            [sS]|[sS][iI]|[yY]|[yY][eE][sS]) return 0 ;;
            *) return 1 ;;
        esac
    fi
    return 1
}

if ! command -v python3 >/dev/null 2>&1; then
    mostrar_error_dependencias "$MSG_PYTHON_MISSING"
    exit 1
fi

if ! python_gtk_disponible; then
    if command -v pkexec >/dev/null 2>&1 && confirmar_instalacion "$MSG_INSTALL_GTK"; then
        pkexec apt-get install -y python3-gi gir1.2-gtk-3.0 python3-gi-cairo gir1.2-notify-0.7 \
            > "$CONFIG_DIR/instalacion_dependencias.log" 2>&1
    fi
    if ! python_gtk_disponible; then
        mostrar_error_dependencias "$MSG_GTK_MISSING"
        exit 1
    fi
fi

# Límite de «una vez al día» para reintentos y avisos: si han pasado 24 h desde la marca guardada en $1,
# la actualiza y devuelve éxito.
ha_pasado_un_dia() {
    local archivo="$1" ahora ultimo
    ahora="$(date +%s 2>/dev/null || echo 0)"
    ultimo="$(cat "$archivo" 2>/dev/null || echo 0)"
    case "$ultimo" in ''|*[!0-9]*) ultimo=0 ;; esac
    # Una marca en el futuro (el reloj estuvo adelantado) no vale: bloquearía el aviso hasta esa fecha.
    if (( ahora - ultimo >= 86400 || ultimo > ahora )); then
        printf '%s\n' "$ahora" | escribir_atomico "$archivo" 600 2>/dev/null || true
        return 0
    fi
    return 1
}

# xdotool y wmctrl no hacen falta para abrir programas, webs o comandos, pero sí para colocar ventanas,
# clics y teclas. Se ofrece instalarlos (con confirmación) como mucho una vez al día mientras falten;
# también se puede hacer desde Ajustes → «Instalar ahora».
X11_INTENTO_TS="$CONFIG_DIR/.intento_instalacion_x11"
if { ! command -v xdotool >/dev/null 2>&1 || ! command -v wmctrl >/dev/null 2>&1; } \
    && ha_pasado_un_dia "$X11_INTENTO_TS"; then
    FALTAN_LISTA=""
    CONJUNCION="$([[ "$APP_LANG" == es ]] && printf '%s' y || printf '%s' and)"
    command -v xdotool >/dev/null 2>&1 || FALTAN_LISTA="xdotool"
    command -v wmctrl >/dev/null 2>&1 || FALTAN_LISTA="${FALTAN_LISTA:+$FALTAN_LISTA $CONJUNCION }wmctrl"

    if [[ "$APP_LANG" == es ]]; then
        MSG_INSTALL_X11="Mi Lanzador necesita $FALTAN_LISTA para poder colocar ventanas, simular clics y enviar teclas."$'\n\n'"¿Instalarlo(s) ahora? Se te pedirá tu contraseña de administrador."$'\n\n'"(Si dices que no, se te volverá a preguntar como mucho una vez al día. También puedes instalarlo cuando quieras desde Ajustes → «Instalar ahora».)"
    else
        MSG_INSTALL_X11="Mi Lanzador needs $FALTAN_LISTA to place windows, simulate clicks and send keys."$'\n\n'"Install them now? You will be asked for your administrator password."$'\n\n'"(If you say no, you will be asked again at most once a day. You can also install them later from Settings → “Install now”.)"
    fi
    if command -v pkexec >/dev/null 2>&1 && confirmar_instalacion "$MSG_INSTALL_X11"; then
        pkexec apt-get install -y xdotool wmctrl \
            > "$CONFIG_DIR/instalacion_dependencias_x11.log" 2>&1 || true
    fi

    # Si siguen faltando (sin pkexec, el usuario dijo que no o la instalación falló), se avisa.
    if ! command -v xdotool >/dev/null 2>&1 || ! command -v wmctrl >/dev/null 2>&1; then
        if [[ "$APP_LANG" == es ]]; then
            MSG_X11_FAIL="Mi Lanzador funcionará, pero sin $FALTAN_LISTA no podrás colocar ventanas, simular clics ni enviar teclas."$'\n\n'"Instálalo cuando quieras con:"$'\n'"sudo apt install xdotool wmctrl"$'\n\n'"(o desde Ajustes → «Instalar ahora» dentro de la aplicación)."
        else
            MSG_X11_FAIL="Mi Lanzador will work, but without $FALTAN_LISTA you will not be able to place windows, simulate clicks or send keys."$'\n\n'"Install them whenever you like with:"$'\n'"sudo apt install xdotool wmctrl"$'\n\n'"(or from Settings → “Install now” inside the application)."
        fi
        mostrar_error_dependencias "$MSG_X11_FAIL"
    fi
fi

# --- 4bis) Aviso (como mucho una vez al día) si la sesión es Wayland nativo: xdotool y wmctrl solo
# funcionan en X11 o XWayland, aunque estén instalados. ---
WAYLAND_AVISO_TS="$CONFIG_DIR/.aviso_wayland"
if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]] && ha_pasado_un_dia "$WAYLAND_AVISO_TS"; then
    mostrar_error_dependencias "$MSG_WAYLAND"
fi

export MI_LANZADOR_CONFIG_DIR="$CONFIG_DIR"
export MI_LANZADOR_APP_SCRIPT="$APP_SCRIPT"
export MI_LANZADOR_SESION_TIPO="${XDG_SESSION_TYPE:-}"

# ---------------------------------------------------------------------------
# 5) Lanzar la interfaz gráfica (Python + GTK3 embebido en este mismo archivo)
#    Si se llama como:  mi-lanzador.sh --ejecutar <id_de_accion>
#    ejecuta esa acción (todos sus pasos, en orden) sin abrir ninguna ventana.
#    Así es como funcionan los accesos directos .desktop generados.
# ---------------------------------------------------------------------------
exec python3 - "$@" <<'PYEOF'
"""Mi Lanzador — graphical interface, embedded in mi-lanzador.sh to keep everything in a single file."""
import os
import re
import sys
import json
import uuid
import shutil
import shlex
import time
import math
import threading
import traceback
import tempfile
import subprocess
from urllib.parse import urlparse

import gi
gi.require_version('Gtk', '3.0')
gi.require_version('GdkPixbuf', '2.0')
try:
    gi.require_version('Notify', '0.7')
    from gi.repository import Notify
    HAY_NOTIFY = True
except Exception:
    HAY_NOTIFY = False

from gi.repository import Gtk, Gdk, GLib, GdkPixbuf

VERSION = '2.1.0'  # versión del programa: la misma que en la cabecera de este archivo (línea 3)

# --- Interfaz bilingüe ES/EN ---
CONFIG_DIR = os.environ.get('MI_LANZADOR_CONFIG_DIR', os.path.expanduser('~/.config/mi-lanzador'))
APP_SCRIPT_PATH = os.environ.get('MI_LANZADOR_APP_SCRIPT', os.path.expanduser('~/.local/share/mi-lanzador/mi-lanzador.sh'))
IDIOMA = os.environ.get('MI_LANZADOR_IDIOMA', '').strip().lower()
IDIOMA_FILE = os.path.join(CONFIG_DIR, 'idioma')
NOMBRES_IDIOMA = {'es': 'Español', 'en': 'English'}  # cada idioma, en su propia lengua

def _cargar_idioma_guardado():
    try:
        with open(IDIOMA_FILE, 'r', encoding='utf-8') as f:
            valor = f.read().strip().lower()
        return valor if valor in ('es', 'en') else None
    except Exception:
        return None

def _detectar_idioma_sistema():
    for valor in (os.environ.get('LC_ALL', ''), os.environ.get('LC_MESSAGES', ''), os.environ.get('LANG', '')):
        if not valor:
            continue
        primario = valor.split(':', 1)[0]
        primario = primario.split('_', 1)[0].split('-', 1)[0]
        primario = primario.split('.', 1)[0].split('@', 1)[0].lower()
        return 'es' if primario == 'es' else 'en'
    return 'en'

if IDIOMA not in ('es', 'en'):
    IDIOMA = _cargar_idioma_guardado() or _detectar_idioma_sistema()

def _escribir_atomico(ruta, texto, modo=None):
    """Escribe en un temporal del mismo directorio y lo renombra sobre `ruta`: un corte a mitad
    de escritura nunca deja el archivo final a medias."""
    fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(ruta) + '.', suffix='.tmp',
                               dir=os.path.dirname(os.path.abspath(ruta)))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(texto)
            f.flush()
            os.fsync(f.fileno())
        if modo is not None:
            os.chmod(tmp, modo)
        os.replace(tmp, ruta)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise

def _copiar_atomico(origen, destino):
    """Copia `origen` sobre `destino` con el mismo esquema temporal + renombrado."""
    fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(destino) + '.', suffix='.tmp',
                               dir=os.path.dirname(os.path.abspath(destino)))
    try:
        with os.fdopen(fd, 'wb') as salida, open(origen, 'rb') as entrada:
            shutil.copyfileobj(entrada, salida)
            salida.flush()
            os.fsync(salida.fileno())
        os.replace(tmp, destino)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise

def guardar_idioma(idioma):
    if idioma not in ('es', 'en'):
        return False
    try:
        _escribir_atomico(IDIOMA_FILE, idioma + '\n')
        return True
    except Exception as e:
        _registrar_error('guardar idioma', e)
        return False

TR_EN = {
 'No se pudo leer «{file}» ({error}).\n\nSe ha conservado como «{copy}» y el programa continúa con datos vacíos.': 'Could not read “{file}” ({error}).\n\nIt has been kept as “{copy}” and the program continues with empty data.',
 'Predeterminado del sistema': 'System default',
 'Abrir programa': 'Open program',
 'Abrir documento / archivo': 'Open document / file',
 'Abrir sitio web': 'Open website',
 'Ejecutar comando': 'Run command',
 'Esperar unos segundos': 'Wait a few seconds',
 'Colocar / organizar ventana ya abierta (avanzado)': 'Reposition / arrange an open window (advanced)',
 'Simular clic de ratón': 'Simulate a mouse click',
 'Enviar tecla o atajo': 'Send key or shortcut',
 'Escribir texto': 'Type text',
 'Maximizar': 'Maximize',
 'Restaurar tamaño normal': 'Restore normal size',
 'Minimizar': 'Minimize',
 'Cerrar la ventana': 'Close the window',
 'Mitad izquierda de la pantalla': 'Left half of the screen',
 'Mitad derecha de la pantalla': 'Right half of the screen',
 'Mitad superior de la pantalla': 'Top half of the screen',
 'Mitad inferior de la pantalla': 'Bottom half of the screen',
 'Cuarto superior izquierdo': 'Top-left quarter',
 'Cuarto superior derecho': 'Top-right quarter',
 'Cuarto inferior izquierdo': 'Bottom-left quarter',
 'Cuarto inferior derecho': 'Bottom-right quarter',
 'Centrada (80% del tamaño de pantalla)': 'Centered (80% of screen size)',
 'Personalizada (indicar % de posición y tamaño)': 'Custom (set position and size as percentages)',
 'Izquierdo': 'Left',
 'Central (rueda)': 'Middle (mouse wheel)',
 'Derecho': 'Right',
 'Acción': 'Action',
 'última ventana abierta': 'last window opened',
 '(sin elegir)': '(not selected)',
 '(sin ruta)': '(no path)',
 'Tus accesos configurados': 'Your shortcuts',
 'Nombre': 'Name',
 'Pasos': 'Steps',
 'Resumen': 'Summary',
 'Ejecutar': 'Run',
 'Crear acceso directo': 'Create shortcut',
 'Editar': 'Edit',
 'Ver script generado': 'View generated script',
 'Eliminar': 'Delete',
 'Crear nueva acción': 'Create new action',
 'Ej: Rutina de trabajo, Backup diario, Abrir Gmail y Slack...': 'E.g.: Work routine, Daily backup, Open Gmail and Slack...',
 'Nombre de la acción:': 'Action name:',
 'Selecciona un icono': 'Select an icon',
 'Imágenes': 'Images',
 'Icono personalizado (opcional):': 'Custom icon (optional):',
 'Pasos de esta acción (se ejecutan en el orden mostrado):': 'Steps in this action (executed in the order shown):',
 'Tipo': 'Type',
 'Detalle': 'Details',
 'Añadir paso': 'Add step',
 'Aceptar': 'OK',
 'Editar paso': 'Edit step',
 'Eliminar paso': 'Delete step',
 'Limpiar formulario': 'Clear form',
 'Ajustes generales': 'General settings',
 "Navegador predeterminado para 'Sitio web':": "Default browser for 'Website':",
 'Crear automáticamente un acceso directo en el Escritorio al guardar una acción nueva': 'Automatically create a Desktop shortcut when saving a new action',
 'Mostrar notificaciones al ejecutar una acción': 'Show notifications when running an action',
 'Carpeta de configuración:': 'Configuration folder:',
 'Abrir': 'Open',
 'Ajustes guardados correctamente.': 'Settings saved successfully.',
 'xdotool y wmctrl instalados correctamente.': 'xdotool and wmctrl installed successfully.',
 "Si al hacer doble clic te pide 'confiar' o 'permitir ejecución', acepta esa opción una sola vez (clic derecho sobre el icono → Propiedades → Permisos → 'Permitir ejecutar como programa', o 'Confiar y lanzar').": 'If double-clicking asks you to “trust” the shortcut or “allow execution”, accept it once (right-click the icon → Properties → Permissions → “Allow executing as a program”, or “Trust and launch”).',
 'Selecciona primero una acción de la lista.': 'Select an action from the list first.',
 'Selecciona primero un paso de la lista.': 'Select a step from the list first.',
 'Escribe un nombre para la acción.': 'Enter a name for the action.',
 'Añade al menos un paso a la acción.': 'Add at least one step to the action.',
 'La acción "{name}" no tiene pasos.': 'The action "{name}" has no steps.',
 'Se creó el acceso directo en el Escritorio automáticamente.': 'The Desktop shortcut was created automatically.',
 'Hay cambios sin guardar en el formulario. ¿Descartarlos y continuar?': 'The form has unsaved changes. Discard them and continue?',
 'Paso {n}: apunta a la ventana de «{alias}», que ningún paso anterior abre (se borró, se movió o cambió de nombre). Edítalo y elige otra ventana: si no, se omitirá al ejecutar la acción.': 'Step {n}: it targets the window of “{alias}”, which no earlier step opens (it was deleted, moved or renamed). Edit it and choose another window; otherwise it will be skipped when the action runs.',
 'No se pudo crear el acceso directo en el Escritorio. Detalles en:\n{log}': 'The shortcut could not be created on the Desktop. Details in:\n{log}',
 'No se pudo crear el acceso directo en todas las ubicaciones elegidas. Detalles en:\n{log}': 'The shortcut could not be created in all the chosen locations. Details in:\n{log}',
 '¿Crear también un acceso directo ahora?': 'Create a shortcut now as well?',
 'Escritorio': 'Desktop',
 'Menú de aplicaciones': 'Applications menu',
 'Cancelar': 'Cancel',
 'Crear': 'Create',
 'Cerrar': 'Close',
 'Automatiza tus accesos directos': 'Automate your shortcuts',
 '🚀 Mis accesos': '🚀 My shortcuts',
 '➕ Nueva acción': '➕ New action',
 '⚙️ Ajustes': '⚙️ Settings',
 '💾 Guardar ajustes': '💾 Save settings',
 '🎯  Elegir punto en la pantalla…': '🎯  Pick a point on the screen…',
 '⌨  Capturar pulsando…': '⌨  Capture by pressing a key…',
 '💾 Guardar acción': '💾 Save action',
 '💾 Guardar cambios': '💾 Save changes',
 '🔧 Instalar ahora': '🔧 Install now',
 '⬆ Subir': '⬆ Move up',
 '⬇ Bajar': '⬇ Move down',
 '➕ Añadir paso': '➕ Add step',
 'Aplicación / acceso directo:': 'Application / shortcut:',
 '🔄 Volver a detectar aplicaciones instaladas': '🔄 Re-detect installed applications',
 'Aplicación instalada': 'Installed application',
 'Selecciona el ejecutable o el acceso directo': 'Select the program executable or shortcut',
 'Accesos directos (.desktop)': 'Shortcuts (.desktop)',
 'Todos los archivos': 'All files',
 'Ejecutable o .desktop:': 'Executable or .desktop:',
 'Argumentos (opcional):': 'Arguments (optional):',
 'Ruta / comando manual': 'Manual path / command',
 'Alias de la ventana:': 'Window alias:',
 'Esperar como máximo tras abrir (s):': 'Maximum wait after opening (s):',
 'Selecciona el documento o archivo a abrir': 'Select the document or file to open',
 'Documento / archivo:': 'Document / file:',
 'Abrir con una aplicación instalada concreta (opcional)': 'Open with a specific installed application (optional)',
 'Escribe para buscar entre las aplicaciones instaladas…': 'Type to search installed applications…',
 'Aplicación:': 'Application:',
 'Aplicar a:': 'Apply to:',
 'Buscar título:': 'Window title:',
 'URL:': 'URL:',
 'Coordenadas absolutas de pantalla: el clic se simula siempre en ese punto exacto, sin necesidad de elegir ninguna ventana.': 'Absolute screen coordinates: the click is always simulated at that exact point, without needing to choose a window.',
 'Abrir en una ventana nueva (si no, se abre como pestaña)': 'Open in a new window (otherwise, open it as a tab)',
 'Abrir como app (sin barra de direcciones; solo Chrome/Chromium/Brave)': 'Open as an app (without an address bar; Chrome/Chromium/Brave only)',
 "Ej: notify-send 'Hola'  /  ~/scripts/backup.sh": "E.g.: notify-send 'Hello'  /  ~/scripts/backup.sh",
 'Esperar como máximo tras ejecutar (s):': 'Maximum wait after running (s):',
 'Esperar (segundos):': 'Wait (seconds):',
 'Avanzado: úsalo solo para reposicionar una ventana que ya estaba abierta de antes (buscándola por título). Para la ventana que abre un paso de programa/web/comando, activa "Colocar / organizar ventana" dentro de ese mismo paso: es más fiable.': 'Advanced: use this only to reposition a window that was already open (by searching its title). For a window opened by a program/web/command step, enable "Place / arrange window" inside that same step: it is more reliable.',
 'Coordenada X:': 'X coordinate:',
 'Coordenada Y:': 'Y coordinate:',
 'Botón del ratón:': 'Mouse button:',
 'Doble clic': 'Double-click',
 ' Activar una ventana antes de hacer clic (opcional) ': ' Activate a window before clicking (optional) ',
 'Activar/enfocar una ventana justo antes de hacer el clic': 'Activate/focus a window just before clicking',
 'Tecla / combinación:': 'Key / combination:',
 'Captura cancelada.': 'Capture cancelled.',
 'Texto que se escribirá donde esté el cursor/foco': 'Text to type at the current cursor/focus',
 'Texto a escribir:': 'Text to type:',
 'Probar este paso (validación)': 'Test this step (validation)',
 'Prueba de paso': 'Step test',
 'Probar este paso (preparación)': 'Test this step (preparation)',
 '⏳ Probando…': '⏳ Testing…',
 'Probar este paso (ejecución)': 'Test this step (execution)',
 '(sin mensajes; revisa visualmente si la ventana se colocó donde esperabas)': '(no messages; visually check whether the window was placed where expected)',
 'Probar este paso (revisión)': 'Test this step (review)',
 'Escribe la tecla o combinación a enviar (ej: ctrl+t).': 'Enter the key or shortcut to send (e.g. Ctrl+T).',
 'Escribe el texto a simular con el teclado.': 'Enter the text to type with the keyboard.',
 'Escribe el título (o parte del título) de la ventana que quieres buscar.': 'Enter the title (or part of the title) of the window to look for.',
 'Cambiar idioma (L)': 'Change language (L)',
 'Idioma de la interfaz:': 'Interface language:',
 'Cambiar el idioma reiniciará la interfaz y descartará los cambios no guardados. ¿Continuar?': 'Changing the language will restart the interface and discard unsaved changes. Continue?',
 'No se pudo guardar el idioma. Detalles en:\n{log}': 'The language could not be saved. Details in:\n{log}',
 '✅ Disponibles': '✅ Available',
 'El comando se ejecuta en una terminal visible (para poder ver su salida o cualquier error); la terminal queda abierta al terminar hasta pulsar Intro.': 'The command runs in a visible terminal (so you can see its output or any errors); the terminal stays open when it finishes until you press Enter.',
 'Escribe la URL del sitio web.': 'Enter the website URL.',
 'La URL no es válida:\n{url}': 'The URL is not valid:\n{url}',
 'Escribe el comando a ejecutar.': 'Enter the command to run.',
 'Selecciona el documento o archivo a abrir (con el explorador de archivos).': 'Select the document or file to open (using the file chooser).',
 'Elige una aplicación de la lista para abrir el documento (escribe y selecciona una sugerencia), o desmarca "Abrir con una aplicación instalada concreta" para usar la predeterminada del sistema.': 'Choose an application from the list to open the document (type and select a suggestion), or uncheck "Open with a specific installed application" to use the system default.',
 'Elige una aplicación de la lista (escribe y selecciona una sugerencia), o usa la pestaña "Ruta / comando manual".': 'Choose an application from the list (type and select a suggestion), or use the "Manual path / command" tab.',
 'Selecciona el ejecutable o el acceso directo (.desktop) del programa.': 'Select the program executable or .desktop shortcut.',
 'Con "Predeterminado del sistema" se detecta automáticamente qué navegador es (Firefox, Chrome, Chromium o Brave) para poder abrir la ventana nueva.': 'With “System default”, Mi Lanzador automatically detects which browser (Firefox, Chrome, Chromium, or Brave) is in use so it can open a new window.',
 'Instalar xdotool/wmctrl': 'Install xdotool/wmctrl',
 'Mi Lanzador': 'Mi Lanzador',
 'en': 'in',
 'Última ventana abierta por esta acción': 'Last window opened by this action',
 'Ventana de:': 'Window:',
 '⚠ Ventana de «{alias}»: ya no la abre ningún paso anterior': '⚠ Window of “{alias}”: no earlier step opens it any more',
 'Buscar por título de ventana…': 'Search by window title…',
 'Colocar / organizar esta ventana justo después de abrirla': 'Place / arrange this window immediately after opening it',
 'Posición X (% pantalla):': 'X position (% of screen):',
 'Posición Y (% pantalla):': 'Y position (% of screen):',
 'Ancho (% pantalla):': 'Width (% of screen):',
 'Alto (% pantalla):': 'Height (% of screen):',
 'Capturar tecla / combinación': 'Capture key / shortcut',
 'Busca por nombre: se detectan automáticamente los programas instalados (incluidos Snap y Flatpak) y los accesos directos de tu Escritorio. Si no encuentras algo aquí, usa la pestaña "Ruta / comando manual".': 'Search by name: installed applications (including Snap and Flatpak) and Desktop shortcuts are detected automatically. If you do not find something here, use the "Manual path / command" tab.',
 'Úsalo para binarios o scripts que no aparecen en el catálogo, o para elegir a mano un acceso directo (.desktop) guardado en otra carpeta.': 'Use this for binaries or scripts that do not appear in the catalog, or to manually choose a .desktop shortcut stored in another folder.',
 'Por defecto se abre con la aplicación predeterminada del sistema para ese tipo de archivo (xdg-open) — lo mismo que un doble clic desde el gestor de archivos. Marca la casilla de arriba solo si necesitas forzar una aplicación concreta.': 'By default, the file is opened with the system default application for that file type (xdg-open) — the same as double-clicking it in the file manager. Check the box above only if you need to force a specific application.',
 'Solo hace falta si esa ventana pudiera estar minimizada o detrás de otras (por ejemplo si no la coloca ningún paso anterior).': 'You only need this if the window might be minimized or behind other windows (for example, if no previous step places it).',
 '💡 También puedes escribirla tú mismo en el campo de arriba, sin necesidad de capturarla: por ejemplo Alt+F10, Ctrl+Shift+Esc o Super+D (Super es la tecla del logo de Windows). Varias teclas unidas con "+" forman una combinación; añade varios pasos de este tipo para enviarlas en secuencia, una detrás de otra.': '💡 You can also type it yourself in the field above, without capturing it: for example Alt+F10, Ctrl+Shift+Esc or Super+D (Super is the Windows logo key). Several keys joined with "+" form a shortcut; add several steps of this type to send them in sequence, one after another.',
 '<small>Mi Lanzador {version} · Crea accesos directos que encadenan programas, sitios web, comandos,\nesperas, posicionamiento de ventanas, clics y teclas. Todos tus datos se guardan\nlocalmente en tu carpeta de configuración.\nProgramador: Filonux</small>': '<small>Mi Lanzador {version} · Create shortcuts that chain programs, websites, commands,\nwaits, window placement, clicks and keystrokes. All your data is stored\nlocally in your configuration folder.\nDeveloper: Filonux</small>',
 '⚠ No se pudo leer la posición del ratón (¿xdotool instalado?). Vuelve a pulsar «Elegir punto en la pantalla…» para intentarlo de nuevo.': '⚠ Could not read the mouse position (is xdotool installed?). Click “Pick a point on the screen…” again to retry.',
 '⏳ Instalando… responde al diálogo de contraseña si aparece': '⏳ Installing… answer the password dialog if it appears',
 'Texto que aparece en el título de la ventana': 'Text that appears in the window title',
 'Ej: --nueva-ventana archivo.txt (se ignora si eliges un .desktop)': 'E.g.: --new-window file.txt (ignored if you choose a .desktop shortcut)',
 'Ej: Alt+F10': 'E.g.: Alt+F10',
 '(opcional) nombre para referirte a esta ventana después': '(optional) name to refer to this window later',
 'Se van a instalar los paquetes "xdotool" y "wmctrl" mediante apt.\n\nA continuación se te pedirá tu contraseña de administrador. ¿Continuar?': 'The packages "xdotool" and "wmctrl" will be installed using apt.\n\nYou will then be asked for your administrator password. Continue?',
 'Tipo de paso:': 'Step type:',
 '▶ Probar este paso ahora': '▶ Test this step now',
 'Ejecuta solo este paso tal y como está configurado ahora mismo (abre el programa/web/comando, hace el clic, envía la tecla o coloca la ventana, según el tipo), sin guardar ni tocar el resto de la acción.': 'Runs only this step exactly as currently configured (opens the program, website or command; clicks; sends a key; or places a window, depending on the type), without saving or changing the rest of the action.',
 ' Colocación de la ventana (opcional) ': ' Window placement (optional) ',
 'Acción sobre la ventana:': 'Window action:',
 '⚠ Este paso usa coordenadas de una versión antigua (relativas a la ventana activada). Vuelve a pulsar «Elegir punto en la pantalla…» para pasarlas a coordenadas absolutas, o déjalo así si prefieres mantener el comportamiento anterior.': '⚠ This step uses coordinates from an older version (relative to the activated window). Click “Pick a point on the screen…” again to convert them to absolute coordinates, or leave them as they are to keep the previous behavior.',
 '⚠ Instala xdotool para poder elegir el punto y simular el clic (sudo apt install xdotool).': '⚠ Install xdotool to pick a point and simulate the click (sudo apt install xdotool).',
 'No se pudo capturar la tecla:': 'Could not capture the key:',
 '✔ Capturado:': '✔ Captured:',
 'Comando:': 'Command:',
 'Navegador:': 'Browser:',
 'xdotool / wmctrl (ventanas, clics, teclas):': 'xdotool / wmctrl (windows, clicks, keys):',
 'la aplicación': 'the application',
 'Escribe para buscar entre {count} aplicaciones y accesos directos detectados…': 'Type to search among {count} detected applications and shortcuts…',
 '✔ Punto capturado: ({x}, {y}).': '✔ Point captured: ({x}, {y}).',
 '✔ Punto capturado: ({x}, {y}) — sobre la ventana «{window}».': '✔ Point captured: ({x}, {y}) — over window “{window}”.',
 '⚠ Sesión Wayland nativa detectada: xdotool y wmctrl NO funcionan aquí (aunque estén instalados). Los pasos de ventana, clic y tecla no van a funcionar hasta que inicies sesión en "Cinnamon" (X11) en vez de "Cinnamon (Wayland)".': '⚠ A native Wayland session was detected: xdotool and wmctrl do NOT work here (even when installed). Window, click, and keyboard steps will not work until you log in to “Cinnamon” (X11) instead of “Cinnamon (Wayland)”.',
 '⚠ Faltan {tools}. Algunos pasos de ventana, clic y tecla podrían no funcionar hasta instalarlo(s) con: sudo apt install xdotool wmctrl (también puedes hacerlo desde Ajustes → «Instalar ahora»).': '⚠ Missing {tools}. Some window, click and keyboard steps may not work until you install them with: sudo apt install xdotool wmctrl (you can also do this from Settings → “Install now”).',
 ' y ': ' and ',
 '¿Dónde quieres crear el acceso directo de "{name}"?': 'Where do you want to create the shortcut for "{name}"?',
 'Acceso directo creado para "{name}".': 'Shortcut created for "{name}".',
 'Acción "{name}" guardada correctamente.': 'Action "{name}" saved successfully.',
 'Ejecutando: {name} ({count} paso{plural})': 'Running: {name} ({count} step{plural})',
 '"{name}" terminó con avisos. Revisa el registro:\n{log}': '"{name}" finished with warnings. Check the log:\n{log}',
 'No se pudo ejecutar la acción:\n{error}': 'The action could not be executed:\n{error}',
 'No se encontró ninguna acción con id "{id}"': 'No action was found with id "{id}"',
 'Ya hay otro paso de esta acción usando el alias «{alias}». Elige un nombre distinto para poder diferenciar sus ventanas.': 'Another step in this action already uses the alias “{alias}”. Choose a different name so you can tell its windows apart.',
 'Ha ocurrido un error inesperado en «{context}»:\n\n{error}\n\nEl detalle técnico completo se ha guardado en:\n{log}': 'An unexpected error occurred in “{context}”:\n\n{error}\n\nThe complete technical details were saved to:\n{log}',
 '⚠ Faltan: {tools}': '⚠ The following tools are missing: {tools}',
 'Script de "{name}"': 'Script for "{name}"',
 '¿Eliminar la acción "{name}"?': 'Delete the action "{name}"?',
 'Acción "{name}" eliminada.': 'Action "{name}" deleted.',
 'Error al leer los datos del paso:\n{error}': 'Error reading the step data:\n{error}',
 'No se pudo preparar la prueba:\n{error}': 'The step test could not be prepared:\n{error}',
 'No se pudo ejecutar la prueba:\n{error}': 'The step test could not be executed:\n{error}',
 'Resultado de la prueba:\n\n{result}': 'Test result:\n\n{result}',
 'No se encuentra el archivo:\n{path}\n\n¿Se ha movido o borrado?': 'File not found:\n{path}\n\nWas it moved or deleted?',
 'La posición X ({x}%) más el ancho ({w}%) suman {total}%: la ventana aparecería fuera de la pantalla por la derecha. Ajusta esos valores para que sumen 100% o menos.': 'X position ({x}%) plus width ({w}%) totals {total}%: the window would extend beyond the right edge of the screen. Adjust these values so their total is 100% or less.',
 'La posición Y ({y}%) más el alto ({h}%) suman {total}%: la ventana aparecería fuera de la pantalla por abajo. Ajusta esos valores para que sumen 100% o menos.': 'Y position ({y}%) plus height ({h}%) totals {total}%: the window would extend beyond the bottom edge of the screen. Adjust these values so their total is 100% or less.',
 '⚠ No se pudo bloquear el teclado del sistema: aquí podrían no detectarse teclas reservadas.': '⚠ The system keyboard could not be grabbed; reserved keys may not be detected.',
 'No se pudo obtener el dispositivo de entrada (Gdk.Seat).': 'Could not obtain the input device (Gdk.Seat).',
 'El sistema no concedió el agarre de teclado (estado: {status}).': 'The system did not grant the keyboard grab (status: {status}).',
 'No se pudo completar la instalación automática (revisa tu conexión a internet, o si cancelaste el diálogo de contraseña). Puedes ver el detalle técnico en:\n{log}\n\nO instalarlo a mano abriendo una terminal:\nsudo apt install xdotool wmctrl': 'Automatic installation could not be completed (check your internet connection or whether you cancelled the password dialog). Technical details are available at:\n{log}\n\nOr install the tools manually by opening a terminal and running:\nsudo apt install xdotool wmctrl',
 'Ventana de: {value}': 'Window: {value}',
 'Ventana con título: {value}': 'Window titled: {value}',
 'Abrir programa: {value}': 'Open program: {value}',
 'Abrir documento: {value}': 'Open document: {value}',
 'Abrir sitio web: {value}': 'Open website: {value}',
 ' con {app}': ' with {app}',
 ' (nueva ventana)': ' (new window)',
 '  ·  colocar: {value}': '  ·  placement: {value}',
 'Comando: {value}': 'Command: {value}',
 'Esperar {seconds} s': 'Wait {seconds} s',
 'Ventana ({target}): {position}': 'Window ({target}): {position}',
 'Clic ({button})': 'Click ({button})',
 'Clic doble ({button})': 'Double-click ({button})',
 '{click} en {coords}  ·  activa {target}': '{click} at {coords}  ·  activates {target}',
 '{click} en {coords} (coordenadas de pantalla)': '{click} at {coords} (screen coordinates)',
 'Tecla "{keys}" en {target}': 'Send "{keys}" to {target}',
 'Escribir "{text}" en {target}': 'Type "{text}" in {target}',
 'paso {n}': 'step {n}',
 '🕒 Esta ventana se va a ocultar un momento: coloca el cursor donde quieras hacer clic. Tendrás {seconds} segundos en cuanto veas la cuenta atrás en la esquina.': '🕒 This window will be hidden briefly: place the cursor where you want to click. You will have {seconds} seconds once you see the countdown in the corner.',
 '🎯 Coloca el cursor en el punto exacto\nCapturando en {seconds} s…': '🎯 Place the cursor on the exact point\nCapturing in {seconds} s…',
 '⌨  <b>Pulsa ahora</b> la tecla o combinación que quieras enviar\n(incluida Esc, que también se puede capturar y usar como paso).\nSi una tecla reservada por el sistema (F1-F12, Super…) no se detecta, cierra esto y escríbela a mano en el campo, ej. <b>Alt+F10</b>.': '⌨  <b>Press now</b> the key or shortcut you want to send\n(including Esc, which can also be captured and used as a step).\nIf a system-reserved key (F1-F12, Super…) is not detected, close this dialog and type it manually in the field, e.g. <b>Alt+F10</b>.',
 'No se encontró "pkexec" en el sistema, así que no puedo abrir una ventana para pedirte la contraseña. Instálalo manualmente abriendo una terminal y escribiendo:\n\nsudo apt install xdotool wmctrl': '"pkexec" was not found on the system, so a password dialog could not be opened. Install xdotool and wmctrl manually by opening a terminal and running:\n\nsudo apt install xdotool wmctrl',
}
def tr(texto):
    if IDIOMA == 'es' or not isinstance(texto, str):
        return texto
    return TR_EN.get(texto, texto)



def _texto_posicion(clave):
    return tr(POSICIONES.get(clave, '?'))


def _texto_tipo(clave):
    return tr(TIPOS_PASO.get(clave, clave))

# --- Rutas y almacenamiento ---
os.makedirs(CONFIG_DIR, exist_ok=True)

# xdotool y wmctrl (ventanas, clics, teclas) solo funcionan en X11/XWayland,
# nunca en Wayland nativo. Se detecta la sesión para avisar en la interfaz.
TIPO_SESION = (os.environ.get('MI_LANZADOR_SESION_TIPO') or os.environ.get('XDG_SESSION_TYPE') or '').strip().lower()
SESION_WAYLAND = TIPO_SESION == 'wayland'
ACCIONES_FILE = os.path.join(CONFIG_DIR, 'acciones.json')
AJUSTES_FILE = os.path.join(CONFIG_DIR, 'ajustes.json')
ICONOS_DIR = os.path.join(CONFIG_DIR, 'iconos')
TMP_DIR = os.path.join(CONFIG_DIR, 'tmp')
os.makedirs(ICONOS_DIR, exist_ok=True)
os.makedirs(TMP_DIR, exist_ok=True)
ERROR_LOG_FILE = os.path.join(CONFIG_DIR, 'error.log')


# --- Red de seguridad ante errores inesperados ---
# Todo error inesperado se anota en error.log y se muestra en un aviso (sin terminal no habría dónde verlo).
LIMITE_ERROR_LOG = 256 * 1024


def _registrar_error(contexto, excepcion):
    detalle = ''.join(traceback.format_exception(type(excepcion), excepcion, excepcion.__traceback__))
    try:
        if os.path.getsize(ERROR_LOG_FILE) > LIMITE_ERROR_LOG:
            os.replace(ERROR_LOG_FILE, ERROR_LOG_FILE + '.1')
    except OSError:
        pass
    try:
        with open(ERROR_LOG_FILE, 'a', encoding='utf-8') as f:
            f.write(f'\n--- {contexto} ---\n{detalle}\n')
    except Exception:
        pass
    return detalle


def _mostrar_error_excepcion(ventana, contexto, excepcion):
    detalle = _registrar_error(contexto, excepcion)
    mensaje = tr('Ha ocurrido un error inesperado en «{context}»:\n\n{error}\n\nEl detalle técnico completo se ha guardado en:\n{log}').format(context=contexto, error=excepcion, log=ERROR_LOG_FILE)
    try:
        dialogo = Gtk.MessageDialog(transient_for=ventana, flags=0, message_type=Gtk.MessageType.ERROR,
                                     buttons=Gtk.ButtonsType.OK, text=mensaje)
        dialogo.run()
        dialogo.destroy()
    except Exception:
        print(mensaje, file=sys.stderr)
        print(detalle, file=sys.stderr)


def _excepthook_global(tipo, valor, tb):
    traceback.print_exception(tipo, valor, tb)
    try:
        _mostrar_error_excepcion(None, tr('la aplicación'), valor)
    except Exception:
        pass


sys.excepthook = _excepthook_global

AJUSTES_POR_DEFECTO = {
    'navegador_predeterminado': 'sistema',
    'crear_acceso_automatico': False,
    'notificaciones': True,
}

NAVEGADORES = {
    'sistema': {'nombre': 'Predeterminado del sistema', 'bin': None},
    'firefox': {'nombre': 'Firefox', 'bin': 'firefox'},
    'chrome': {'nombre': 'Google Chrome', 'bin': 'google-chrome'},
    # Mint instala el binario «chromium» (Ubuntu, «chromium-browser»): se prueba el primero que exista.
    'chromium': {'nombre': 'Chromium', 'bin': 'chromium', 'bin_alt': ['chromium-browser']},
    'brave': {'nombre': 'Brave', 'bin': 'brave-browser'},
}

TIPOS_PASO = {
    'programa': 'Abrir programa',
    'documento': 'Abrir documento / archivo',
    'web': 'Abrir sitio web',
    'comando': 'Ejecutar comando',
    'esperar': 'Esperar unos segundos',
    'ventana': 'Colocar / organizar ventana ya abierta (avanzado)',
    'clic': 'Simular clic de ratón',
    'tecla': 'Enviar tecla o atajo',
    'texto': 'Escribir texto',
}

# Pasos que abren una ventana: detectan la ventana nueva, admiten alias y colocación integrada.
TIPOS_CON_VENTANA = ('programa', 'documento', 'web', 'comando')

# El paso 'ventana' (reposicionar una ventana abierta de antes) es el caso avanzado y va al final;
# programa/documento/web/comando colocan su ventana en el propio paso ('colocar_ventana').
ORDEN_TIPOS_PASO = ['programa', 'documento', 'web', 'comando', 'esperar', 'clic', 'tecla', 'texto', 'ventana']

POSICIONES = {
    'maximizar': 'Maximizar',
    'restaurar': 'Restaurar tamaño normal',
    'minimizar': 'Minimizar',
    'cerrar': 'Cerrar la ventana',
    'mitad_izq': 'Mitad izquierda de la pantalla',
    'mitad_der': 'Mitad derecha de la pantalla',
    'mitad_arriba': 'Mitad superior de la pantalla',
    'mitad_abajo': 'Mitad inferior de la pantalla',
    'cuarto_si': 'Cuarto superior izquierdo',
    'cuarto_sd': 'Cuarto superior derecho',
    'cuarto_ii': 'Cuarto inferior izquierdo',
    'cuarto_id': 'Cuarto inferior derecho',
    'centrada': 'Centrada (80% del tamaño de pantalla)',
    'personalizada': 'Personalizada (indicar % de posición y tamaño)',
}

ORDEN_POSICIONES = ['maximizar', 'restaurar', 'minimizar', 'cerrar', 'mitad_izq', 'mitad_der',
                     'mitad_arriba', 'mitad_abajo', 'cuarto_si', 'cuarto_sd', 'cuarto_ii',
                     'cuarto_id', 'centrada', 'personalizada']

BOTONES_RATON = {'1': 'Izquierdo', '2': 'Central (rueda)', '3': 'Derecho'}


def herramientas_x11_disponibles():
    return {
        'xdotool': shutil.which('xdotool') is not None,
        'wmctrl': shutil.which('wmctrl') is not None,
    }


# --- Detección del navegador predeterminado real del sistema ---
def _detectar_navegador_predeterminado():
    """Clave de NAVEGADORES del navegador predeterminado, para poder cumplir «ventana nueva» y «modo app»,
    que xdg-open ignora. None si no se sabe o no está soportado (se seguirá usando xdg-open)."""
    desktop_id = ''
    try:
        salida = subprocess.run(['xdg-settings', 'get', 'default-web-browser'],
                                 capture_output=True, text=True, timeout=3)
        desktop_id = (salida.stdout or '').strip().lower()
    except Exception:
        desktop_id = ''
    if not desktop_id:
        try:
            salida = subprocess.run(['xdg-mime', 'query', 'default', 'x-scheme-handler/https'],
                                     capture_output=True, text=True, timeout=3)
            desktop_id = (salida.stdout or '').strip().lower()
        except Exception:
            desktop_id = ''
    for pista, clave in (('firefox', 'firefox'), ('chromium', 'chromium'),
                         ('chrome', 'chrome'), ('brave', 'brave')):
        if pista in desktop_id:
            return clave
    return None


def _una_sola_vez(funcion):
    """Devuelve una función que llama a `funcion` la primera vez y repite ese resultado. Cada generación de script
    crea la suya, así que no se recuerda nada entre una generación y la siguiente."""
    resultado = []

    def valor():
        if not resultado:
            resultado.append(funcion())
        return resultado[0]
    return valor


# --- Detección de programas instalados y accesos directos (.desktop) ---
def _dir_escritorio():
    """Carpeta Escritorio del usuario; si no está definida (XDG la deja en $HOME) se usa ~/Desktop."""
    try:
        ruta = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_DESKTOP)
    except Exception:
        ruta = None
    if not ruta or os.path.realpath(ruta) == os.path.realpath(os.path.expanduser('~')):
        return os.path.expanduser('~/Desktop')
    return ruta


def _directorios_aplicaciones():
    """Carpetas de los .desktop: sistema, usuario, Snap, Flatpak y el Escritorio del usuario."""
    dirs = [
        '/usr/share/applications',
        '/usr/local/share/applications',
        os.path.expanduser('~/.local/share/applications'),
        '/var/lib/snapd/desktop/applications',
        '/var/lib/flatpak/exports/share/applications',
        os.path.expanduser('~/.local/share/flatpak/exports/share/applications'),
    ]
    dirs.append(_dir_escritorio())
    return dirs


def _nombre_localizado_desktop(datos):
    """Nombre visible del .desktop en el idioma de la interfaz, no en el del sistema. Si el locale del sistema es de
    ese idioma se sigue la jerarquía de Desktop Entry (país+modificador, país, idioma+modificador, idioma); si no,
    solo el idioma de la interfaz. Sin traducción, el nombre base."""
    locales = datos.get('NameLocales', {}) or {}
    lang = IDIOMA if IDIOMA in ('es', 'en') else 'en'

    # Jerarquía POSIX (LC_ALL > LC_MESSAGES > LANG) para no elegir una variante regional distinta de la activa.
    raw_locale = ''
    for env_name in ('LC_ALL', 'LC_MESSAGES', 'LANG'):
        value = os.environ.get(env_name, '')
        if value:
            raw_locale = value.split(':', 1)[0]
            break
    raw_locale = raw_locale.replace('-', '_').lower()
    base_and_modifier = raw_locale.split('@', 1)
    base = base_and_modifier[0].split('.', 1)[0]
    modifier = base_and_modifier[1] if len(base_and_modifier) == 2 else ''

    if base:
        pieces = base.split('_', 1)
        locale_lang = pieces[0]
        country = pieces[1] if len(pieces) == 2 else ''
        candidatos = []
        if locale_lang == lang:
            if country and modifier:
                candidatos.extend((f'{locale_lang}_{country}@{modifier}',
                                   f'{locale_lang}_{country}',
                                   f'{locale_lang}@{modifier}',
                                   locale_lang))
            elif country:
                candidatos.extend((f'{locale_lang}_{country}', locale_lang))
            elif modifier:
                candidatos.extend((f'{locale_lang}@{modifier}', locale_lang))
            else:
                candidatos.append(locale_lang)
        # El idioma de la interfaz es siempre el último recurso, aunque el locale del sistema sea otro.
        if lang not in candidatos:
            candidatos.append(lang)
        for candidato in candidatos:
            valor = locales.get(candidato)
            if valor:
                return valor

    # Sin locale utilizable se usa igualmente el idioma de la interfaz.
    valor = locales.get(lang)
    if valor:
        return valor
    return datos.get('Name', '')


def _parsear_desktop_entry(ruta):
    """Campos básicos de un .desktop, o None si no es una aplicación lanzable (Type distinto de Application,
    NoDisplay o Hidden, sin Name o Exec, o el propio lanzador)."""
    datos = {}
    seccion = None
    try:
        with open(ruta, 'r', encoding='utf-8', errors='ignore') as f:
            for linea in f:
                linea = linea.rstrip('\n')
                if not linea or linea.startswith('#'):
                    continue
                if linea.startswith('[') and linea.endswith(']'):
                    seccion = linea
                    continue
                if seccion != '[Desktop Entry]' or '=' not in linea:
                    continue
                clave, _, valor = linea.partition('=')
                clave = clave.strip()
                valor = valor.strip()
                if clave == 'Name':
                    datos.setdefault('Name', valor)
                elif clave.startswith('Name[') and clave.endswith(']'):
                    locale_tag = clave[5:-1].strip().replace('-', '_').lower()
                    if locale_tag:
                        datos.setdefault('NameLocales', {})[locale_tag] = valor
                elif clave in ('Exec', 'Icon', 'Terminal', 'NoDisplay', 'Hidden', 'Type', 'StartupWMClass'):
                    datos[clave] = valor
    except Exception:
        return None
    if datos.get('Type', 'Application') != 'Application':
        return None
    if not datos.get('Name') or not datos.get('Exec'):
        return None
    if datos.get('NoDisplay', 'false').lower() == 'true':
        return None
    if datos.get('Hidden', 'false').lower() == 'true':
        return None
    # Se excluyen el propio lanzador y los accesos directos que genera (viven en ~/.local/share/applications
    # y ejecutan este script): evita duplicados en el catálogo.
    if APP_SCRIPT_PATH in datos.get('Exec', ''):
        return None
    return {
        'nombre': _nombre_localizado_desktop(datos),
        'nombre_base': datos.get('Name', ''),
        'ruta': ruta,
        'icono': datos.get('Icon', ''),
        'exec': datos.get('Exec', ''),
        'terminal': datos.get('Terminal', 'false').lower() == 'true',
        'startup_wm_class': datos.get('StartupWMClass', ''),
    }


def _normalizar_exec_para_dedup(exec_val):
    """Exec= sin marcadores (%f, %U, %i…), con espacios colapsados y en minúsculas, para reconocer accesos que
    lanzan lo mismo."""
    if not exec_val:
        return ''
    limpio = re.sub(r'%[fFuUdDnNickvm]', '', exec_val)
    return ' '.join(limpio.split()).strip().lower()


def listar_aplicaciones_instaladas():
    """Escanea los .desktop del sistema, del usuario, de Snap/Flatpak y del Escritorio y devuelve
    [{nombre, ruta, icono, exec, terminal}] ordenada y sin duplicados.

    Se descarta un .desktop si su «id» (nombre de fichero) ya se vio en una carpeta de mayor prioridad, o si
    otro ya visto tiene el mismo Nombre + Exec (sin %f/%U/...). Instalaciones DISTINTAS de la misma app
    (p. ej. Firefox .deb y Snap, con Exec diferente) se muestran por separado."""
    vistos_ruta = set()
    vistos_id = set()
    vistos_app = set()
    resultado = []
    for directorio in _directorios_aplicaciones():
        if not directorio or not os.path.isdir(directorio):
            continue
        try:
            archivos = os.listdir(directorio)
        except Exception:
            continue
        for nombre_archivo in sorted(archivos):
            if not nombre_archivo.endswith('.desktop'):
                continue
            ruta = os.path.join(directorio, nombre_archivo)
            ruta_real = os.path.realpath(ruta)
            if ruta_real in vistos_ruta:
                continue
            vistos_ruta.add(ruta_real)
            id_desktop = nombre_archivo.lower()
            if id_desktop in vistos_id:
                continue
            app = _parsear_desktop_entry(ruta)
            if not app:
                continue
            clave_app = (app.get('nombre_base', app['nombre']).strip().lower(),
                         _normalizar_exec_para_dedup(app.get('exec', '')))
            if clave_app in vistos_app:
                continue
            vistos_id.add(id_desktop)
            vistos_app.add(clave_app)
            resultado.append(app)
    resultado.sort(key=lambda a: a['nombre'].lower())
    return resultado


def id_desktop_de_ruta(ruta):
    base = os.path.basename(ruta)
    return base[:-len('.desktop')] if base.endswith('.desktop') else base


# Avisos sobre datos dañados; la ventana principal los muestra una vez al abrirse.
AVISOS_DATOS = []


def _apartar_archivo_danado(ruta, error):
    """Renombra un archivo ilegible a «<nombre>.corrupt-<fecha>» para que el siguiente guardado
    no lo sobrescriba, lo registra en error.log y deja un aviso para la interfaz."""
    base = f"{ruta}.corrupt-{time.strftime('%Y%m%d-%H%M%S')}"
    destino, n = base, 1
    while os.path.exists(destino):
        n += 1
        destino = f'{base}-{n}'
    try:
        os.replace(ruta, destino)
    except OSError:
        destino = ruta
    _registrar_error(f'archivo dañado: {ruta}', error)
    AVISOS_DATOS.append(tr('No se pudo leer «{file}» ({error}).\n\nSe ha conservado como «{copy}» y el programa continúa con datos vacíos.').format(
        file=os.path.basename(ruta), error=error, copy=os.path.basename(destino)))
    return destino


def cargar_json(ruta, valor_por_defecto):
    """Lee `ruta`; el tipo del valor por defecto fija el tipo esperado (lista o diccionario).
    Un archivo ilegible se aparta (nunca se pierde) y se devuelve el valor por defecto."""
    if not os.path.isfile(ruta):
        return valor_por_defecto
    try:
        with open(ruta, 'r', encoding='utf-8-sig') as f:  # «-sig»: un editor de Windows puede anteponer una marca BOM
            datos = json.load(f)
        if not isinstance(datos, type(valor_por_defecto)):
            raise ValueError(f'se esperaba {type(valor_por_defecto).__name__} y hay {type(datos).__name__}')
        return datos
    except (OSError, ValueError, RecursionError) as e:  # RecursionError (anidación absurda) no es un ValueError
        _apartar_archivo_danado(ruta, e)
        return valor_por_defecto


def guardar_json(ruta, datos):
    _escribir_atomico(ruta, json.dumps(datos, ensure_ascii=False, indent=2) + '\n')


def _host_de_url(url):
    """netloc de la URL ('' si no tiene) o None si no se puede interpretar: urlparse lanza ValueError con «https://[x»."""
    try:
        return urlparse(url).netloc
    except ValueError:
        return None


def _texto_del_archivo(valor):
    """`valor` como texto: un número pasa a texto; null, listas, diccionarios y booleanos, a ''."""
    if isinstance(valor, str):
        return valor
    return str(valor) if isinstance(valor, (int, float)) and not isinstance(valor, bool) else ''


def _migrar_accion_antigua(accion):
    """Convierte una acción del formato antiguo (un solo tipo/valor) al de 'pasos'."""
    tipo = accion.get('tipo', 'comando')
    valor = _texto_del_archivo(accion.get('valor', ''))  # un JSON válido puede traer null o un número
    paso = {'tipo': tipo if tipo in ('programa', 'web', 'comando') else 'comando',
            'espera': 3.0 if tipo == 'web' else 2.5}
    if paso['tipo'] == 'programa':
        paso['ruta'] = valor
        paso['argumentos'] = accion.get('argumentos', '')
        nombre_base = os.path.basename(paso['ruta']) or 'programa'
    elif paso['tipo'] == 'web':
        paso['url'] = valor
        paso['navegador'] = accion.get('navegador', 'sistema')
        paso['nueva_ventana'] = False
        paso['modo_app'] = accion.get('modo_app', False)
        nombre_base = _host_de_url(paso['url']) or 'web'
    else:
        paso['comando'] = valor
        nombre_base = paso['comando'].split()[0] if paso['comando'].split() else 'comando'
    # El script generado solo registra ventanas con alias no vacío: así un paso posterior puede apuntar a esta.
    paso['alias'] = sugerir_alias([], paso['tipo'], nombre_base)
    nueva = {
        'id': accion.get('id', str(uuid.uuid4())[:8]),
        'nombre': accion.get('nombre', 'Acción'),
        'icono': accion.get('icono'),
        'pasos': [paso],
    }
    return nueva


def _migrar_paso_clic_antiguo(paso):
    """Un paso de clic sin 'activar_ventana' es del formato antiguo (coordenadas relativas a una ventana
    obligatoria): se marca con 'coords_absolutas': False y 'activar_ventana': True para conservar su conducta."""
    if paso.get('tipo') == 'clic' and 'activar_ventana' not in paso:
        paso = dict(paso)
        paso['activar_ventana'] = True
        paso['coords_absolutas'] = False
    return paso


_CAMPOS_PASO_TEXTO = frozenset((
    'tipo', 'modo', 'ruta', 'ruta_desktop', 'nombre_detectado', 'argumentos', 'url', 'navegador', 'comando',
    'alias', 'combinacion', 'texto', 'abrir_con', 'accion_ventana', 'objetivo_modo', 'objetivo_alias',
    'objetivo_buscar', 'boton'))
_CAMPOS_PASO_NUMERO = frozenset((
    'espera', 'segundos', 'x', 'y', 'personalizada_x', 'personalizada_y', 'personalizada_w', 'personalizada_h'))


def _paso_con_tipos_validos(paso):
    """Copia del paso con sus textos y números del tipo que espera la interfaz. Un número en un campo de texto
    pasa a texto y un texto numérico en un campo numérico, a número; lo que no se puede convertir (null, lista,
    «abc», NaN, valores absurdos) se quita, y entonces vale el valor por defecto."""
    nuevo = {}
    for clave, valor in paso.items():
        es_numero = isinstance(valor, (int, float)) and not isinstance(valor, bool)
        if clave in _CAMPOS_PASO_TEXTO and not isinstance(valor, str):
            if not es_numero:
                continue
            valor = str(valor)
        elif clave in _CAMPOS_PASO_NUMERO:
            if isinstance(valor, str):
                try:
                    valor = float(valor)
                except ValueError:
                    continue
            elif not es_numero:
                continue
            if not abs(valor) <= 1e9:
                continue
        nuevo[clave] = valor
    return nuevo if nuevo != paso else paso


def _con_tipos_validos(accion):
    """Copia con id/nombre/icono y los campos de cada paso del tipo que espera la interfaz (un JSON válido puede
    traer números o null). Solo en memoria: el archivo se queda como lo dejó el usuario."""
    cambios = {}
    if isinstance(accion.get('pasos'), list):
        pasos = [_paso_con_tipos_validos(p) if isinstance(p, dict) else p for p in accion['pasos']]
        if pasos != accion['pasos']:
            cambios['pasos'] = pasos
    if accion.get('id') is not None and not isinstance(accion['id'], str):
        cambios['id'] = str(accion['id'])
    if 'nombre' in accion and not isinstance(accion['nombre'], str):
        cambios['nombre'] = '' if accion['nombre'] is None else str(accion['nombre'])
    if accion.get('icono') is not None and not isinstance(accion['icono'], str):
        cambios['icono'] = None
    return dict(accion, **cambios) if cambios else accion


def _id_utilizable(id_accion):
    """El id va en «<nombre>-<id>.desktop», en el nombre del icono propio y en la línea Exec= del acceso directo:
    sin «/» ni caracteres de control (un salto de línea partiría Exec=) y de ≤ 100 bytes (con el nombre recortado
    a 120, el archivo y su temporal caben en los 255 del sistema de archivos)."""
    texto = str(id_accion)
    return len(texto.encode('utf-8')) <= 100 and '/' not in texto and not any(c < ' ' or c == '\x7f' for c in texto)


def cargar_acciones():
    crudas = cargar_json(ACCIONES_FILE, [])
    acciones = [a for a in crudas if isinstance(a, dict)]
    if len(acciones) != len(crudas):
        _registrar_error('acciones.json', ValueError(f'{len(crudas) - len(acciones)} entrada(s) que no son acciones, omitidas'))
    cambiado = False
    resultado = []
    ids_vistos = set()
    for a in acciones:
        if 'pasos' not in a:
            a = _migrar_accion_antigua(a)
            cambiado = True
        sin_id = a.get('id') in (None, '')
        repetido = not sin_id and str(a['id']) in ids_vistos
        inutilizable = not sin_id and not _id_utilizable(a['id'])
        if sin_id or repetido or inutilizable:
            # Sin id la acción no se puede elegir, editar ni ejecutar; con el de otra, «Guardar» y «Eliminar» afectarían
            # a las dos; uno inutilizable (ver _id_utilizable) no vale de nombre de archivo. Se le da un id nuevo y se
            # guarda (la primera acción conserva el suyo).
            if repetido or inutilizable:
                motivo = 'repetido' if repetido else 'no utilizable'
                _registrar_error('acciones.json', ValueError(f'id {motivo} {str(a["id"])[:40]!r}: a la acción «{a.get("nombre", "")}» se le dio otro'))
            a = dict(a, id=str(uuid.uuid4())[:8])
            cambiado = True
        ids_vistos.add(str(a['id']))
        crudos = a['pasos']
        pasos = [p for p in crudos if isinstance(p, dict)] if isinstance(crudos, list) else []
        if pasos != crudos:
            _registrar_error('acciones.json', ValueError(f'acción «{a.get("nombre", "")}»: pasos no válidos, omitidos'))
        migrados = [_migrar_paso_clic_antiguo(p) for p in pasos]
        cambiado = cambiado or migrados != pasos
        resultado.append(a if migrados == crudos else dict(a, pasos=migrados))
    if cambiado:
        guardar_json(ACCIONES_FILE, resultado)
    return [_con_tipos_validos(a) for a in resultado]


def guardar_acciones(acciones):
    guardar_json(ACCIONES_FILE, acciones)


def _accion_por_id(id_accion):
    return next((a for a in cargar_acciones() if a.get('id') == id_accion), None)


def _borrar_icono_propio(ruta):
    """Borra un icono copiado por la app (solo dentro de ICONOS_DIR); un fallo al borrar se ignora."""
    if ruta and os.path.dirname(ruta) == ICONOS_DIR:
        try:
            os.remove(ruta)
        except OSError:
            pass


def cargar_ajustes():
    """Ajustes con el tipo que espera la interfaz (texto o sí/no, según el valor por defecto): un valor mal tipado
    del archivo (p. ej. un número como navegador) se ignora, y 0/1 valen como sí/no. Solo en memoria."""
    ajustes = dict(AJUSTES_POR_DEFECTO)
    for clave, valor in cargar_json(AJUSTES_FILE, {}).items():
        defecto = AJUSTES_POR_DEFECTO.get(clave)
        if defecto is None or type(valor) is type(defecto):
            ajustes[clave] = valor
        elif isinstance(defecto, bool) and isinstance(valor, int):
            ajustes[clave] = bool(valor)
    return ajustes


def guardar_ajustes(ajustes):
    guardar_json(AJUSTES_FILE, ajustes)


# --- Descripciones legibles (para la lista y para los desplegables de "objetivo") ---
def describir_objetivo(paso):
    modo = paso.get('objetivo_modo', '_ultima')
    if modo == '_alias':
        return tr('Ventana de: {value}').format(value=paso.get('objetivo_alias', '?'))
    if modo == '_buscar':
        return tr('Ventana con título: {value}').format(value=paso.get('objetivo_buscar', ''))
    return tr('última ventana abierta')


def _acortar(texto, limite):
    return texto[:limite] + ('…' if len(texto) > limite else '')


def _con_colocacion(base, paso):
    if paso.get('colocar_ventana'):
        base += tr('  ·  colocar: {value}').format(value=_texto_posicion(paso.get('accion_ventana')))
    return base


def resumen_paso(paso):
    tipo = paso.get('tipo')
    if tipo == 'programa':
        if paso.get('modo', 'manual') in ('instalado', 'desktop'):
            valor = (paso.get('nombre_detectado') or os.path.basename(paso.get('ruta_desktop', ''))
                     or tr('(sin elegir)'))
        else:
            argumentos = f' {paso["argumentos"]}' if paso.get('argumentos') else ''
            valor = (os.path.basename(paso.get('ruta', '')) or tr('(sin ruta)')) + argumentos
        return _con_colocacion(tr('Abrir programa: {value}').format(value=valor), paso)
    if tipo == 'documento':
        base = tr('Abrir documento: {value}').format(value=os.path.basename(paso.get('ruta', '')) or tr('(sin elegir)'))
        if paso.get('abrir_con') == 'app':
            base += tr(' con {app}').format(app=paso.get('nombre_detectado', ''))
        return _con_colocacion(base, paso)
    if tipo == 'web':
        base = tr('Abrir sitio web: {value}').format(value=paso.get('url', ''))
        if paso.get('nueva_ventana'):
            base += tr(' (nueva ventana)')
        return _con_colocacion(base, paso)
    if tipo == 'comando':
        return _con_colocacion(tr('Comando: {value}').format(value=_acortar(paso.get('comando', ''), 45)), paso)
    if tipo == 'esperar':
        return tr('Esperar {seconds} s').format(seconds=paso.get('segundos', 1))
    if tipo == 'ventana':
        return tr('Ventana ({target}): {position}').format(
            target=describir_objetivo(paso), position=_texto_posicion(paso.get('accion_ventana')))
    if tipo == 'clic':
        id_boton = str(paso.get('boton', '1'))
        boton = tr(BOTONES_RATON[id_boton]) if id_boton in BOTONES_RATON else id_boton  # desconocido (JSON a mano): su id
        clic = (tr('Clic doble ({button})') if paso.get('doble') else tr('Clic ({button})')).format(button=boton)
        coords = f'({paso.get("x", 0)},{paso.get("y", 0)})'
        if paso.get('activar_ventana'):
            return tr('{click} en {coords}  ·  activa {target}').format(
                click=clic, coords=coords, target=describir_objetivo(paso))
        return tr('{click} en {coords} (coordenadas de pantalla)').format(click=clic, coords=coords)
    if tipo == 'tecla':
        return tr('Tecla "{keys}" en {target}').format(
            keys=paso.get('combinacion', ''), target=describir_objetivo(paso))
    if tipo == 'texto':
        return tr('Escribir "{text}" en {target}').format(
            text=_acortar(paso.get('texto', ''), 25), target=describir_objetivo(paso))
    return tipo or '?'


def resumen_pasos(pasos, max_pasos=4):
    partes = [resumen_paso(p) for p in pasos[:max_pasos]]
    if len(pasos) > max_pasos:
        partes.append(f'… (+{len(pasos) - max_pasos})')
    return '  →  '.join(partes)


def _id_ventana(paso, i):
    """Con qué nombre se refieren otros pasos a la ventana que abre `paso` (en la posición i): su alias o, sin él, su posición."""
    return paso.get('alias') or f'__paso{i}'


def alias_disponibles_antes_de(pasos, indice):
    """[(id, etiqueta), ...] de los pasos que abren ventanas (programa/web/comando) ANTES del índice dado,
    para elegirlos como 'objetivo' en pasos posteriores."""
    disponibles = []
    for i, p in enumerate(pasos):
        if indice is not None and i >= indice:
            break
        if p.get('tipo') in TIPOS_CON_VENTANA:
            alias = p.get('alias') or tr('paso {n}').format(n=i + 1)
            disponibles.append((_id_ventana(p, i), f'{alias}  —  {resumen_paso(p)[:40]}'))
    return disponibles


def referencias_rotas(pasos):
    """[(n, alias)] de los pasos cuya ventana objetivo (por alias) no la abre ningún paso anterior:
    el script generado lo omite con un aviso."""
    abiertos, rotas = set(), []
    for n, p in enumerate(pasos, start=1):
        if (p.get('objetivo_modo') == '_alias' and (p.get('tipo') != 'clic' or p.get('activar_ventana'))
                and p.get('objetivo_alias') not in abiertos):
            rotas.append((n, p.get('objetivo_alias', '')))
        if p.get('tipo') in TIPOS_CON_VENTANA:
            abiertos.add(_id_ventana(p, n - 1))
    return rotas


def sugerir_alias(pasos, tipo, texto_base, extra_existentes=None):
    base = ''.join(c if c.isalnum() else '_' for c in texto_base.lower()).strip('_') or tipo
    base = base[:20]
    existentes = {p.get('alias', '') for p in pasos if p.get('tipo') in TIPOS_CON_VENTANA}
    existentes |= set(extra_existentes or ())
    candidato = base
    n = 2
    while candidato in existentes:
        candidato = f'{base}_{n}'
        n += 1
    return candidato


# --- Generación del script bash que ejecuta todos los pasos de una acción ---
def _q(valor):
    """Escapa un valor para insertarlo con seguridad en el script bash."""
    return shlex.quote(str(valor))


def _comando_shell_programa(paso):
    modo = paso.get('modo', 'manual')
    if modo in ('instalado', 'desktop'):
        ruta_desktop = paso.get('ruta_desktop', '')
        id_desktop = id_desktop_de_ruta(ruta_desktop)
        # gio viene en Mint (libglib2.0-bin); si faltara: gtk-launch y, por último, xdg-open sobre el .desktop.
        return (f'gio launch {_q(ruta_desktop)} 2>/dev/null '
                f'|| gtk-launch {_q(id_desktop)} 2>/dev/null '
                f'|| xdg-open {_q(ruta_desktop)}')
    ruta = paso.get('ruta', '')
    args = (paso.get('argumentos') or '').strip()
    return f'{_q(ruta)} {args}'.strip()


def _comando_shell_documento(paso):
    """Comando del paso 'documento': xdg-open o, con app elegida, 'gio launch <desktop> <archivo>' (respeta
    %f/%F/%u/%U como un doble clic en el gestor), con reserva en gtk-launch y, por último, xdg-open (que ignora
    la app elegida)."""
    ruta = paso.get('ruta', '')
    if paso.get('abrir_con') == 'app' and paso.get('ruta_desktop'):
        ruta_desktop = paso.get('ruta_desktop', '')
        id_desktop = id_desktop_de_ruta(ruta_desktop)
        return (f'gio launch {_q(ruta_desktop)} {_q(ruta)} 2>/dev/null '
                f'|| gtk-launch {_q(id_desktop)} {_q(ruta)} 2>/dev/null '
                f'|| xdg-open {_q(ruta)}')
    return f'xdg-open {_q(ruta)}'


def _resolver_binario_navegador(info):
    """Primer binario instalado entre el principal y sus alternativas (el nombre varía según la distribución,
    p. ej. chromium y chromium-browser); si no hay ninguno, el principal."""
    candidatos = [info.get('bin')] + list(info.get('bin_alt', []))
    for candidato in candidatos:
        if candidato and shutil.which(candidato):
            return candidato
    return candidatos[0]


def _comando_shell_web(paso, detectar_navegador=None):
    url = paso.get('url', '')
    nav = paso.get('navegador', 'sistema')
    nueva_ventana = paso.get('nueva_ventana', False)
    modo_app = paso.get('modo_app', False)

    if nav == 'sistema' and (nueva_ventana or modo_app):
        # xdg-open no admite «ventana nueva» ni «modo app»: hay que saber qué navegador es para usar sus parámetros.
        detectado = (detectar_navegador or _detectar_navegador_predeterminado)()
        if detectado:
            nav = detectado

    info = NAVEGADORES.get(nav, NAVEGADORES['sistema'])
    binario = _resolver_binario_navegador(info) if info.get('bin') else None

    if nav == 'sistema' or not binario or not shutil.which(binario):
        # Sin navegador concreto utilizable: el predeterminado del sistema, sin garantía de ventana nueva.
        return f'xdg-open {_q(url)}'

    if modo_app and nav in ('chrome', 'chromium', 'brave'):
        return f'{binario} --app={_q(url)}'
    if nueva_ventana:
        return f'{binario} --new-window {_q(url)}'
    return f'{binario} {_q(url)}'


# WM_CLASS habitual de cada navegador: pista para buscar una ventana ya existente (ver _pista_clase_para_paso).
_CLASE_NAVEGADOR = {
    'firefox': 'firefox',
    'chrome': 'google-chrome',
    'chromium': 'chromium',
    'brave': 'brave-browser',
}


def _clase_de_desktop(ruta_desktop):
    """Clase de ventana de un .desktop: su StartupWMClass o, si no lo tiene, el binario de Exec (sin ruta,
    argumentos ni marcadores como %U)."""
    info = _parsear_desktop_entry(ruta_desktop) or {}
    clase = info.get('startup_wm_class', '')
    if clase:
        return clase
    partes = (info.get('exec') or '').split()
    return os.path.basename(partes[0]) if partes else ''


def _pista_clase_para_paso(paso, detectar_navegador=None):
    """Texto para buscar con 'wmctrl -lx' (WM_CLASS/título) la ventana de este paso. ÚLTIMO RECURSO si no se
    detecta ventana nueva ni cambio de foco (p. ej. la app ya estaba abierta y solo se activó una ventana
    existente). Es una aproximación: si no coincide con nada, no se coloca la ventana."""
    tipo = paso.get('tipo')
    if tipo == 'programa':
        if paso.get('modo', 'manual') in ('instalado', 'desktop'):
            return _clase_de_desktop(paso.get('ruta_desktop', ''))
        return os.path.basename(paso.get('ruta', '') or '')
    if tipo == 'documento':
        if paso.get('abrir_con') == 'app' and paso.get('ruta_desktop'):
            return _clase_de_desktop(paso['ruta_desktop'])
        # Con xdg-open no se sabe qué app abrirá el documento: sin pista (rige el snapshot / cambio de foco).
        return ''
    if tipo == 'web':
        nav = paso.get('navegador', 'sistema')
        if nav == 'sistema':
            nav = (detectar_navegador or _detectar_navegador_predeterminado)() or ''
        return _CLASE_NAVEGADOR.get(nav, '')
    # 'comando': la ventana es la de la TERMINAL, que se resuelve en bash con TERM_PISTA (la rellena _abrir_en_terminal).
    return ''


def _bloque_resolver_objetivo(paso, var_win='WIN'):
    modo = paso.get('objetivo_modo', '_ultima')
    alias_ref = paso.get('objetivo_alias', '') if modo == '_alias' else ''
    # "xdotool search --name" toma un regex: el título se escapa para buscarlo tal cual.
    busqueda = re.sub(r'([\\.^$*+?()\[\]{}|])', r'\\\1', str(paso.get('objetivo_buscar') or '')) if modo == '_buscar' else ''
    return (
        f'_resolver_ventana {_q(modo)} {_q(alias_ref)} {_q(busqueda)}\n'
        f'{var_win}="$VENTANA_OBJETIVO"\n'
    )


def _validar_rango_personalizada(paso):
    """Mensaje de error si la posición + el tamaño personalizados (en % de pantalla) se salen de la pantalla; si no, None."""
    x = paso.get('personalizada_x', 0)
    y = paso.get('personalizada_y', 0)
    w = paso.get('personalizada_w', 50)
    h = paso.get('personalizada_h', 50)
    if x + w > 100:
        return tr('La posición X ({x}%) más el ancho ({w}%) suman {total}%: la ventana aparecería fuera de la pantalla por la derecha. Ajusta esos valores para que sumen 100% o menos.').format(x=x, w=w, total=x + w)
    if y + h > 100:
        return tr('La posición Y ({y}%) más el alto ({h}%) suman {total}%: la ventana aparecería fuera de la pantalla por abajo. Ajusta esos valores para que sumen 100% o menos.').format(y=y, h=h, total=y + h)
    return None


def _lineas_posicionar_ventana(paso, var_win='WIN'):
    """Lista con la línea bash que coloca la ventana de la variable `var_win` con '_colocar_ventana' (ver
    generar_script_bash). La usan el paso 'ventana' y la colocación integrada de programa/documento/web/comando."""
    accion_v = paso.get('accion_ventana', 'maximizar')
    # Una posición desconocida (JSON editado a mano) cae a 'maximizar'.
    if accion_v not in POSICIONES:
        accion_v = 'maximizar'
    if accion_v == 'personalizada':
        px = int(paso.get('personalizada_x', 0))
        py = int(paso.get('personalizada_y', 0))
        pw = int(paso.get('personalizada_w', 50))
        ph = int(paso.get('personalizada_h', 50))
    else:
        px, py, pw, ph = 0, 0, 50, 50
    return [f'_colocar_ventana "${var_win}" {_q(accion_v)} {px} {py} {pw} {ph}']


# Avisos del script generado: clave -> (español, inglés). El idioma se elige al ejecutarlo (ver _ML_LANG).
# Cada "%s" recibe un argumento de _ml_msg, en orden.
MENSAJES_SCRIPT = {
    'terminal_missing': (
        '  Aviso: no se encontró ninguna terminal instalada (gnome-terminal, xterm...); no se puede ejecutar el comando',
        '  Warning: no installed terminal was found (gnome-terminal, xterm...); the command cannot be run'),
    'command_finished': (
        '[Mi Lanzador] El comando terminó (código %s). Pulsa Intro para cerrar esta terminal…',
        '[Mi Lanzador] The command finished (exit code %s). Press Enter to close this terminal…'),
    'no_window': (
        '  Aviso: no hay ninguna ventana sobre la que aplicar «%s»',
        '  Warning: there is no window to apply “%s” to'),
    'wmctrl_missing': (
        '  Aviso: falta wmctrl (sudo apt install wmctrl); no se puede colocar la ventana',
        '  Warning: wmctrl is missing (sudo apt install wmctrl); the window cannot be positioned'),
    'place_failed': (
        '  Aviso: no se pudo colocar la ventana (no se detectó ninguna ventana nueva, ni una existente que coincidiera)',
        '  Warning: the window could not be positioned (no new or matching existing window was detected)'),
    'target_window_ventana': (
        '  Aviso: no se encontró la ventana objetivo del paso de ventana',
        '  Warning: the target window of the window step was not found'),
    'target_window_tecla': (
        '  Aviso: no se encontró la ventana objetivo del paso de tecla',
        '  Warning: the target window of the key step was not found'),
    'target_window_texto': (
        '  Aviso: no se encontró la ventana objetivo del paso de texto',
        '  Warning: the target window of the text step was not found'),
    'activate_before_click': (
        '  Aviso: no se encontró la ventana a activar antes del clic',
        '  Warning: the window to activate before clicking was not found'),
    'click_outside': (
        '  Aviso: el punto (%s,%s) cae fuera de la pantalla actual (%sx%s); revisa si cambió la resolución o los monitores',
        '  Warning: point (%s,%s) is outside the current screen (%sx%s); check whether the resolution or monitors changed'),
    'click_failed': (
        '  Aviso: xdotool no pudo simular el clic',
        '  Warning: xdotool could not simulate the click'),
    'click_coords': (
        '  Aviso: no se pudo determinar la coordenada del clic',
        '  Warning: the click coordinates could not be determined'),
    'xdotool_click_missing': (
        '  Aviso: falta xdotool (sudo apt install xdotool); no se puede simular el clic',
        '  Warning: xdotool is missing (sudo apt install xdotool); the click cannot be simulated'),
    'key_failed': (
        '  Aviso: xdotool no pudo enviar la tecla «%s»',
        '  Warning: xdotool could not send the key “%s”'),
    'xdotool_key_missing': (
        '  Aviso: falta xdotool (sudo apt install xdotool); no se puede enviar la tecla',
        '  Warning: xdotool is missing (sudo apt install xdotool); the key cannot be sent'),
    'xdotool_text_missing': (
        '  Aviso: falta xdotool (sudo apt install xdotool); no se puede escribir el texto',
        '  Warning: xdotool is missing (sudo apt install xdotool); the text cannot be typed'),
    'running': (
        '=== Mi Lanzador: ejecutando %s ===',
        '=== Mi Lanzador: running %s ==='),
    'step_line': (
        '  Paso %s: %s',
        '  Step %s: %s'),
    'action_finished': (
        '=== Mi Lanzador: acción finalizada ===',
        '=== Mi Lanzador: action finished ==='),
}


RE_ESQUEMA_URL = re.compile(r'[a-z][a-z0-9+.-]*://', re.I)  # una URL que ya trae esquema (http, file, chrome…) no se prefija
RE_AVISO_LOG = re.compile(r'^\s*(?:Aviso|Warning):', re.M)  # los avisos del script generado, en cualquiera de los dos idiomas

def _segundos(valor, defecto):
    """Número finito y no negativo; un dato editado a mano nunca llega al script como texto."""
    try:
        segundos = float(valor)
    except (TypeError, ValueError):
        return defecto
    return segundos if math.isfinite(segundos) and segundos >= 0 else defecto

def _una_linea(texto):
    # Un salto de línea partiría el comentario del script (y ejecutaría lo que siga) o imitaría un aviso del log.
    return re.sub(r'[\r\n]+', ' ', str(texto))

def generar_script_bash(pasos, nombre_accion='acción'):
    nombre_accion = _una_linea(nombre_accion)
    lineas = []
    lineas.append('#!/bin/bash')
    lineas.append(f'# Script generado por Mi Lanzador para la acción: {nombre_accion}')
    lineas.append('# No pensado para editar a mano (se regenera cada vez que se ejecuta la acción).')
    lineas.append('set +e')
    lineas.append('declare -A ALIAS_WIN')
    lineas.append('ULTIMA_WIN=""')
    lineas.append(f'TMP_DIR={_q(TMP_DIR)}')  # los .token de colocación van aquí: _limpiar_temporales_antiguos los borra
    # Sin xdotool se prueba xdpyinfo; el último recurso es 1920x1080.
    lineas.append('if command -v xdotool >/dev/null 2>&1; then')
    lineas.append('    read -r ANCHO_PANTALLA ALTO_PANTALLA < <(xdotool getdisplaygeometry 2>/dev/null)')
    lineas.append('fi')
    lineas.append('if [ -z "$ANCHO_PANTALLA" ] && command -v xdpyinfo >/dev/null 2>&1; then')
    lineas.append('    _DIM="$(xdpyinfo 2>/dev/null | awk \'/dimensions:/{print $2; exit}\')"')
    lineas.append('    ANCHO_PANTALLA="${_DIM%%x*}"')
    lineas.append('    ALTO_PANTALLA="${_DIM##*x}"')
    lineas.append('fi')
    lineas.append('ANCHO_PANTALLA=${ANCHO_PANTALLA:-1920}')
    lineas.append('ALTO_PANTALLA=${ALTO_PANTALLA:-1080}')
    lineas.append('')
    lineas.append('_ML_LANG="${MI_LANZADOR_IDIOMA:-}"')
    lineas.append('if [[ "$_ML_LANG" != es && "$_ML_LANG" != en ]]; then')
    lineas.append(f'    _ML_LANG_FILE={_q(os.path.join(CONFIG_DIR, "idioma"))}')
    lineas.append('    if [[ -r "$_ML_LANG_FILE" ]]; then read -r _ML_SAVED < "$_ML_LANG_FILE" || true; [[ "$_ML_SAVED" == es || "$_ML_SAVED" == en ]] && _ML_LANG="$_ML_SAVED"; fi')
    lineas.append('    if [[ "$_ML_LANG" != es && "$_ML_LANG" != en ]]; then')
    lineas.append('        for _ML_LOCALE in "${LC_ALL:-}" "${LC_MESSAGES:-}" "${LANG:-}"; do')
    lineas.append('            [[ -n "$_ML_LOCALE" ]] || continue')
    lineas.append('            _ML_LOCALE="${_ML_LOCALE%%:*}"; _ML_LOCALE="${_ML_LOCALE%%.*}"; _ML_LOCALE="${_ML_LOCALE%%@*}"; _ML_LOCALE="${_ML_LOCALE%%_*}"; _ML_LOCALE="${_ML_LOCALE%%-*}"; _ML_LOCALE="${_ML_LOCALE,,}"; [[ "$_ML_LOCALE" == es ]] && _ML_LANG=es || _ML_LANG=en; break')
    lineas.append('        done')
    lineas.append('    fi')
    lineas.append('fi')
    lineas.append('[[ "$_ML_LANG" == es || "$_ML_LANG" == en ]] || _ML_LANG=en')
    lineas.append('_ml_msg() {')
    lineas.append('    local clave="$1"; shift')
    lineas.append('    case "$clave" in')
    for clave, (texto_es, texto_en) in MENSAJES_SCRIPT.items():
        fmt_es, fmt_en = _q(texto_es + '\\n'), _q(texto_en + '\\n')
        args = ' "$@"' if '%s' in texto_es else ''  # sin %s, printf ignoraría los argumentos (SC2182)
        lineas.append(f'        {clave}) if [[ "$_ML_LANG" == es ]]; then printf -- {fmt_es}{args}; else printf -- {fmt_en}{args}; fi ;;')
    lineas.append('    esac')
    lineas.append('}')
    lineas.append('')
    # IDs decimales (como los da xdotool) de las ventanas que lista el gestor, una por línea. Falla (1) si wmctrl falta o no
    # responde (sin gestor de ventanas o sin EWMH); que responda y no liste ninguna no es un fallo.
    lineas.append('_ids_gestionadas() {')
    lineas.append('    local lista id')
    lineas.append('    command -v wmctrl >/dev/null 2>&1 || return 1')
    lineas.append('    lista="$(wmctrl -l 2>/dev/null)" || return 1')
    lineas.append('    while read -r id _; do')
    lineas.append('        [ -n "$id" ] && printf \'%d\\n\' "$id" 2>/dev/null')
    lineas.append('    done <<< "$lista"')
    lineas.append('    return 0')
    lineas.append('}')
    lineas.append('')
    # Ventanas visibles, para detectar la nueva; sin xdotool, las que lista el gestor.
    lineas.append('_snapshot() {')
    lineas.append('    if command -v xdotool >/dev/null 2>&1; then')
    lineas.append('        xdotool search --onlyvisible "" 2>/dev/null | sort -u')
    lineas.append('    else')
    lineas.append('        _ids_gestionadas | sort -u')
    lineas.append('    fi')
    lineas.append('}')
    lineas.append('')
    # «xdotool search» devuelve también marcos del gestor y subventanas: la última rara vez es la ventana de la app.
    # Si wmctrl responde, solo vale una nueva que él liste; si aún no coincide (el gestor la está enmarcando) no se
    # elige otra y _esperar_ventana_nueva reintenta en el siguiente sondeo. Sin wmctrl, se toma la última nueva.
    lineas.append('_detectar_nueva_ventana() {')
    lineas.append('    local antes="$1" despues nuevas gestionadas')
    lineas.append('    despues="$(_snapshot)"')
    lineas.append('    nuevas="$(comm -13 <(printf \'%s\\n\' "$antes") <(printf \'%s\\n\' "$despues"))"')
    lineas.append('    [ -n "$nuevas" ] || return 0')
    lineas.append('    if gestionadas="$(_ids_gestionadas)"; then')
    lineas.append('        printf \'%s\\n\' "$nuevas" | grep -Fxf <(printf \'%s\\n\' "$gestionadas") | sort -n | tail -n1')
    lineas.append('    else')
    lineas.append('        printf \'%s\\n\' "$nuevas" | tail -n1')
    lineas.append('    fi')
    lineas.append('}')
    lineas.append('')
    # Prioriza el cambio de ventana activa (el diff de IDs a veces detecta una ventana auxiliar); sin cambio
    # de foco, usa el diff de snapshots.
    lineas.append('_detectar_ventana_app() {')
    lineas.append('    local antes="$1" activa_antes="$2" activa_ahora=""')
    lineas.append('    if command -v xdotool >/dev/null 2>&1; then')
    lineas.append('        activa_ahora="$(xdotool getactivewindow 2>/dev/null)"')
    lineas.append('        if [ -n "$activa_ahora" ] && [ "$activa_ahora" != "$activa_antes" ]; then')
    lineas.append('            printf \'%s\\n\' "$activa_ahora"')
    lineas.append('            return')
    lineas.append('        fi')
    lineas.append('    fi')
    lineas.append('    _detectar_nueva_ventana "$antes"')
    lineas.append('}')
    lineas.append('')
    # Monitor físico que contiene la ventana → MON_X/Y/W/H (con varios monitores, getdisplaygeometry devuelve
    # la suma). Sin xrandr: pantalla virtual completa; sin xdotool: xwininfo.
    lineas.append('_actualizar_monitor() {')
    lineas.append('    local win="$1"')
    lineas.append('    MON_X=0; MON_Y=0; MON_W="$ANCHO_PANTALLA"; MON_H="$ALTO_PANTALLA"')
    lineas.append('    command -v xrandr >/dev/null 2>&1 || return 0')
    lineas.append('    local wx="" wy=""')
    lineas.append('    if command -v xdotool >/dev/null 2>&1; then')
    # "X"/"Y" locales y reiniciados antes de cada consulta: si no, una consulta fallida heredaría la ventana
    # anterior y colocaría en el monitor equivocado.
    lineas.append('        local X="" Y=""')
    lineas.append('        eval "$(xdotool getwindowgeometry --shell "$win" 2>/dev/null)"')
    lineas.append('        wx="${X:-}"; wy="${Y:-}"')
    lineas.append('    fi')
    lineas.append('    if [ -z "$wx" ] && command -v xwininfo >/dev/null 2>&1; then')
    lineas.append('        wx="$(xwininfo -id "$win" 2>/dev/null | awk -F: \'/Absolute upper-left X/{gsub(/ /,"",$2); print $2}\')"')
    lineas.append('        wy="$(xwininfo -id "$win" 2>/dev/null | awk -F: \'/Absolute upper-left Y/{gsub(/ /,"",$2); print $2}\')"')
    lineas.append('    fi')
    lineas.append('    wx="${wx:-0}"; wy="${wy:-0}"')
    lineas.append('    local geo geo_px mw mh resto mx my')
    lineas.append('    while IFS= read -r geo; do')
    lineas.append('        geo_px="$(printf \'%s\' "$geo" | sed -E \'s#/[0-9]+##g\')"')
    lineas.append('        mw="${geo_px%%x*}"')
    lineas.append('        resto="${geo_px#*x}"')
    lineas.append('        mh="${resto%%+*}"')
    lineas.append('        resto="${resto#*+}"')
    lineas.append('        mx="${resto%%+*}"')
    lineas.append('        my="${resto#*+}"')
    lineas.append('        if [ -n "$mw" ] && [ -n "$mh" ] && [ -n "$mx" ] && [ -n "$my" ] \\')
    lineas.append('           && [ "$wx" -ge "$mx" ] 2>/dev/null && [ "$wx" -lt "$((mx + mw))" ] 2>/dev/null \\')
    lineas.append('           && [ "$wy" -ge "$my" ] 2>/dev/null && [ "$wy" -lt "$((my + mh))" ] 2>/dev/null; then')
    lineas.append('            MON_X=$mx; MON_Y=$my; MON_W=$mw; MON_H=$mh')
    lineas.append('            break')
    lineas.append('        fi')
    lineas.append('    done < <(xrandr --listmonitors 2>/dev/null | tail -n +2 | awk \'{print $3}\')')
    lineas.append('}')
    lineas.append('')
    lineas.append('_resolver_ventana() {')
    lineas.append('    local modo="$1" alias_ref="$2" busqueda="$3"')
    lineas.append('    VENTANA_OBJETIVO=""')
    lineas.append('    case "$modo" in')
    lineas.append('        _alias) [ -n "$alias_ref" ] && VENTANA_OBJETIVO="${ALIAS_WIN[$alias_ref]:-}" ;;')
    lineas.append('        _buscar) [ -n "$busqueda" ] && command -v xdotool >/dev/null 2>&1 && VENTANA_OBJETIVO="$(xdotool search --name -- "$busqueda" 2>/dev/null | head -n1)" ;;')
    lineas.append('        *) VENTANA_OBJETIVO="$ULTIMA_WIN" ;;')
    lineas.append('    esac')
    # Un id guardado cuya ventana ya se cerró no vale: activarlo falla y las teclas irían al foco real.
    lineas.append('    [ -n "$VENTANA_OBJETIVO" ] && command -v xdotool >/dev/null 2>&1 \\')
    lineas.append('        && ! xdotool getwindowname "$VENTANA_OBJETIVO" >/dev/null 2>&1 && VENTANA_OBJETIVO=""')
    # Último recurso (búsqueda sin coincidencia, ventana cerrada o primer paso sin ventana previa): la ventana con
    # foco. Un alias no lo usa: si no se resolvió, el paso se omite con aviso.
    lineas.append('    if [ -z "$VENTANA_OBJETIVO" ] && [ "$modo" != _alias ] && command -v xdotool >/dev/null 2>&1; then')
    lineas.append('        VENTANA_OBJETIVO="$(xdotool getactivewindow 2>/dev/null)"')
    lineas.append('    fi')
    lineas.append('}')
    lineas.append('')
    # Plan B si el programa ya estaba abierto (ni ventana nueva ni cambio de foco): buscar por WM_CLASS o
    # título con "wmctrl -lx".
    lineas.append('_buscar_por_clase() {')
    lineas.append('    local pista="$1"')
    lineas.append('    [ -z "$pista" ] && return 0')
    lineas.append('    command -v wmctrl >/dev/null 2>&1 || return 0')
    lineas.append('    wmctrl -lx 2>/dev/null | grep -iF -- "$pista" | awk \'{print $1}\' | head -n1')
    lineas.append('}')
    lineas.append('')
    # El paso "Ejecutar comando" abre una terminal real (la primera instalada) con la
    # salida visible; al terminar muestra el código de salida y espera a Intro.
    lineas.append('_abrir_en_terminal() {')
    lineas.append('    local cmd_usuario="$1" term="" envoltura aviso comando_q _lanzador=nohup')
    lineas.append('    command -v setsid >/dev/null 2>&1 && _lanzador="setsid nohup"')
    lineas.append('    for term in gnome-terminal mate-terminal xfce4-terminal tilix terminator konsole xterm x-terminal-emulator; do')
    lineas.append('        command -v "$term" >/dev/null 2>&1 && break')
    lineas.append('        term=""')
    lineas.append('    done')
    lineas.append('    TERM_PISTA=""')
    lineas.append('    if [ -z "$term" ]; then')
    lineas.append('        _ml_msg terminal_missing >&2')
    lineas.append('        return 1')
    lineas.append('    fi')
    # Sin "local": TERM_PISTA debe sobrevivir a la función (pista de WM_CLASS de la terminal).
    lineas.append('    TERM_PISTA="$term"')
    # La terminal ejecuta un bash nuevo, sin las funciones ni variables de este script: el aviso
    # final se traduce aquí y viaja como literal ("@@" = código de salida). Un salto de línea (no
    # ";") evita que un "#" o un "&" final del comando del usuario rompan el epílogo.
    lineas.append(r'''    printf -v aviso '%q' "$(_ml_msg command_finished @@)"''')
    lineas.append(r'''    envoltura="$cmd_usuario"$'\n'"_EST=\$?; echo; _M=$aviso; printf '%s\n' \"\${_M/@@/\$_EST}\"; read -r _ignorar"''')
    lineas.append('    case "$term" in')
    lineas.append('        gnome-terminal)')
    lineas.append('            $_lanzador "$term" -- bash -c "$envoltura" </dev/null >/dev/null 2>&1 &')
    lineas.append('            ;;')
    # tilix no admite «--»: abre un bash vacío y descarta la orden (comprobado con tilix 1.9.6). Con varios argumentos tras
    # -e los reempaqueta entre comillas dobles y deforma las «\» (un «\\» llega como «\»); con UNO solo lo trocea con
    # g_shell_parse_argv. Por eso recibe «bash -c '<orden>'» como un único argumento, con cada «'» de la orden cambiada
    # por «'\''» (comillas simples POSIX).
    lineas.append('        tilix)')
    lineas.append(r'''            comando_q=${envoltura//\'/\'\\\'\'}''')
    lineas.append(r'''            $_lanzador "$term" -e "bash -c '$comando_q'" </dev/null >/dev/null 2>&1 &''')
    lineas.append('            ;;')
    # konsole sustituye $NOMBRE por su valor en los argumentos de -e, incluso entre comillas simples (comprobado con
    # konsole 23.08.5: '$HOME' llegaba como la ruta personal y $PWD como el directorio de konsole; «$(», «${» y «$$» no
    # los toca). x-terminal-emulator puede ser konsole. Por eso la orden viaja en base64, sin «$» ni «\», y la terminal
    # la decodifica y ejecuta con eval.
    lineas.append('        konsole|xterm|x-terminal-emulator)')
    lineas.append(r'''            comando_q=$(printf '%s' "$envoltura" | base64 | tr -d '\n')''')
    lineas.append(r'''            $_lanzador "$term" -e bash -c "eval \"\$(printf %s $comando_q | base64 -d)\"" </dev/null >/dev/null 2>&1 &''')
    lineas.append('            ;;')
    lineas.append('        *)')
    lineas.append('            $_lanzador "$term" -x bash -c "$envoltura" </dev/null >/dev/null 2>&1 &')
    lineas.append('            ;;')
    lineas.append('    esac')
    lineas.append('    return 0')
    lineas.append('}')
    lineas.append('')
    # Sondeo cada 0.2 s hasta detectar la ventana nueva o agotar los intentos; entonces, plan B de _buscar_por_clase.
    lineas.append('_esperar_ventana_nueva() {')
    lineas.append('    local antes="$1" activa_antes="$2" intentos_max="$3" pista="$4"')
    lineas.append('    local intento=0 encontrada=""')
    lineas.append('    while [ "$intento" -lt "$intentos_max" ]; do')
    lineas.append('        encontrada="$(_detectar_ventana_app "$antes" "$activa_antes")"')
    lineas.append('        [ -n "$encontrada" ] && break')
    lineas.append('        sleep 0.2')
    lineas.append('        intento=$((intento + 1))')
    lineas.append('    done')
    lineas.append('    if [ -z "$encontrada" ] && [ -n "$pista" ]; then')
    lineas.append('        encontrada="$(_buscar_por_clase "$pista")"')
    lineas.append('    fi')
    lineas.append('    printf \'%s\\n\' "$encontrada"')
    lineas.append('}')
    lineas.append('')
    # Colocación de ventanas: la geometría se calcula en funciones con variables "local", para que varias
    # colocaciones en una acción no se contaminen. Avisa si falta wmctrl/xdotool.
    lineas.append('_colocar_ventana() {')
    lineas.append('    local win="$1" accion="$2" p_x="${3:-0}" p_y="${4:-0}" p_w="${5:-50}" p_h="${6:-50}"')
    lineas.append('    if [ -z "$win" ]; then')
    lineas.append('        _ml_msg no_window "$accion" >&2')
    lineas.append('        return 1')
    lineas.append('    fi')
    lineas.append('    VENTANA_TOKEN_FILE="$TMP_DIR/ventana_${win}.token"')
    lineas.append('    VENTANA_TOKEN="${BASHPID:-$$}-${RANDOM}-${SECONDS}"')
    lineas.append('    mkdir -p "$TMP_DIR"')
    lineas.append("    printf '%s\\n' \"$VENTANA_TOKEN\" > \"$VENTANA_TOKEN_FILE\" 2>/dev/null || true")
    lineas.append('    if ! command -v wmctrl >/dev/null 2>&1; then')
    lineas.append('        _ml_msg wmctrl_missing >&2')
    lineas.append('        return 1')
    lineas.append('    fi')
    # Maximizar/restaurar/minimizar se refuerzan con reintentos en 2º plano (0.4/1.2/2.5/4.5 s), igual que
    # la geometría: muchas apps deshacen ese estado un instante después de abrirse.
    lineas.append('    case "$accion" in')
    lineas.append('        maximizar)')
    lineas.append('            wmctrl -ir "$win" -b add,maximized_vert,maximized_horz 2>/dev/null')
    lineas.append("            ( nohup bash -c 'sleep 0.4; [ \"$(cat \"$1\" 2>/dev/null)\" = \"$2\" ] && wmctrl -ir \"$3\" -b add,maximized_vert,maximized_horz 2>/dev/null' _ \"$VENTANA_TOKEN_FILE\" \"$VENTANA_TOKEN\" \"$win\" >/dev/null 2>&1 & )")
    lineas.append("            ( nohup bash -c 'sleep 1.2; [ \"$(cat \"$1\" 2>/dev/null)\" = \"$2\" ] && wmctrl -ir \"$3\" -b add,maximized_vert,maximized_horz 2>/dev/null' _ \"$VENTANA_TOKEN_FILE\" \"$VENTANA_TOKEN\" \"$win\" >/dev/null 2>&1 & )")
    lineas.append("            ( nohup bash -c 'sleep 2.5; [ \"$(cat \"$1\" 2>/dev/null)\" = \"$2\" ] && wmctrl -ir \"$3\" -b add,maximized_vert,maximized_horz 2>/dev/null' _ \"$VENTANA_TOKEN_FILE\" \"$VENTANA_TOKEN\" \"$win\" >/dev/null 2>&1 & )")
    lineas.append("            ( nohup bash -c 'sleep 4.5; [ \"$(cat \"$1\" 2>/dev/null)\" = \"$2\" ] && wmctrl -ir \"$3\" -b add,maximized_vert,maximized_horz 2>/dev/null' _ \"$VENTANA_TOKEN_FILE\" \"$VENTANA_TOKEN\" \"$win\" >/dev/null 2>&1 & )")
    lineas.append('            ;;')
    lineas.append('        restaurar)')
    lineas.append('            wmctrl -ir "$win" -b remove,maximized_vert,maximized_horz 2>/dev/null')
    lineas.append("            ( nohup bash -c 'sleep 0.4; [ \"$(cat \"$1\" 2>/dev/null)\" = \"$2\" ] && wmctrl -ir \"$3\" -b remove,maximized_vert,maximized_horz 2>/dev/null' _ \"$VENTANA_TOKEN_FILE\" \"$VENTANA_TOKEN\" \"$win\" >/dev/null 2>&1 & )")
    lineas.append("            ( nohup bash -c 'sleep 1.2; [ \"$(cat \"$1\" 2>/dev/null)\" = \"$2\" ] && wmctrl -ir \"$3\" -b remove,maximized_vert,maximized_horz 2>/dev/null' _ \"$VENTANA_TOKEN_FILE\" \"$VENTANA_TOKEN\" \"$win\" >/dev/null 2>&1 & )")
    lineas.append('            ;;')
    lineas.append('        minimizar)')
    lineas.append('            if command -v xdotool >/dev/null 2>&1; then')
    lineas.append('                xdotool windowminimize "$win" 2>/dev/null')
    lineas.append("                ( nohup bash -c 'sleep 0.4; [ \"$(cat \"$1\" 2>/dev/null)\" = \"$2\" ] && xdotool windowminimize \"$3\" 2>/dev/null' _ \"$VENTANA_TOKEN_FILE\" \"$VENTANA_TOKEN\" \"$win\" >/dev/null 2>&1 & )")
    lineas.append("                ( nohup bash -c 'sleep 1.2; [ \"$(cat \"$1\" 2>/dev/null)\" = \"$2\" ] && xdotool windowminimize \"$3\" 2>/dev/null' _ \"$VENTANA_TOKEN_FILE\" \"$VENTANA_TOKEN\" \"$win\" >/dev/null 2>&1 & )")
    lineas.append('            else')
    lineas.append('                wmctrl -ir "$win" -b add,hidden 2>/dev/null')
    lineas.append('            fi')
    lineas.append('            ;;')
    # «xdotool windowclose» destruye la ventana sin avisar a la aplicación (sin «¿guardar cambios?»); «wmctrl -ic» le pide
    # el cierre como el botón «×». wmctrl está disponible aquí: arriba se sale si falta. El cierre es asíncrono: se sondea
    # (máx. 1 s) hasta que la ventana desaparece, para que el paso siguiente no la vea viva. Si la aplicación pregunta
    # antes de cerrar, la ventana sigue y se continúa pasado ese tiempo.
    lineas.append('        cerrar)')
    lineas.append('            wmctrl -ic "$win" 2>/dev/null')
    lineas.append('            if command -v xdotool >/dev/null 2>&1; then')
    lineas.append('                local intentos=0')
    lineas.append('                while [ "$intentos" -lt 20 ] && xdotool getwindowname "$win" >/dev/null 2>&1; do')
    lineas.append('                    sleep 0.05')
    lineas.append('                    intentos=$((intentos + 1))')
    lineas.append('                done')
    lineas.append('            fi')
    lineas.append('            ;;')
    lineas.append('        *)')
    lineas.append('            _colocar_ventana_geo "$win" "$accion" "$p_x" "$p_y" "$p_w" "$p_h"')
    lineas.append('            ;;')
    lineas.append('    esac')
    lineas.append('}')
    lineas.append('')
    lineas.append('_colocar_ventana_geo() {')
    lineas.append('    local win="$1" accion="$2" p_x="$3" p_y="$4" p_w="$5" p_h="$6"')
    lineas.append('    local mon_x mon_y mon_w mon_h')
    lineas.append('    _actualizar_monitor "$win"')
    lineas.append('    mon_x=$MON_X; mon_y=$MON_Y; mon_w=$MON_W; mon_h=$MON_H')
    lineas.append('')
    lineas.append('    wmctrl -ir "$win" -b remove,maximized_vert,maximized_horz 2>/dev/null')
    # Se sondea con xprop (hasta 1 s) que el gestor ya quitó el estado "maximizado" antes de pedir la
    # geometría; con una espera fija Cinnamon/Muffin ignoraba la petición.
    lineas.append('    if command -v xprop >/dev/null 2>&1; then')
    lineas.append('        local intentos=0')
    lineas.append('        while [ "$intentos" -lt 20 ]; do')
    lineas.append('            xprop -id "$win" _NET_WM_STATE 2>/dev/null | grep -q \'MAXIMIZED\' || break')
    lineas.append('            sleep 0.05')
    lineas.append('            intentos=$((intentos + 1))')
    lineas.append('        done')
    lineas.append('    else')
    lineas.append('        sleep 0.15')
    lineas.append('    fi')
    lineas.append('')
    lineas.append('    local x y w h')
    lineas.append('    case "$accion" in')
    lineas.append('        mitad_izq)    x=0;            y=0;            w=$((mon_w/2)); h=$mon_h ;;')
    lineas.append('        mitad_der)    x=$((mon_w/2)); y=0;            w=$((mon_w/2)); h=$mon_h ;;')
    lineas.append('        mitad_arriba) x=0;            y=0;            w=$mon_w;       h=$((mon_h/2)) ;;')
    lineas.append('        mitad_abajo)  x=0;            y=$((mon_h/2)); w=$mon_w;       h=$((mon_h/2)) ;;')
    lineas.append('        cuarto_si)    x=0;            y=0;            w=$((mon_w/2)); h=$((mon_h/2)) ;;')
    lineas.append('        cuarto_sd)    x=$((mon_w/2)); y=0;            w=$((mon_w/2)); h=$((mon_h/2)) ;;')
    lineas.append('        cuarto_ii)    x=0;            y=$((mon_h/2)); w=$((mon_w/2)); h=$((mon_h/2)) ;;')
    lineas.append('        cuarto_id)    x=$((mon_w/2)); y=$((mon_h/2)); w=$((mon_w/2)); h=$((mon_h/2)) ;;')
    lineas.append('        centrada)')
    lineas.append('            w=$((mon_w*80/100)); h=$((mon_h*80/100))')
    lineas.append('            x=$(((mon_w-w)/2)); y=$(((mon_h-h)/2))')
    lineas.append('            ;;')
    lineas.append('        personalizada)')
    lineas.append('            x=$((mon_w*p_x/100)); y=$((mon_h*p_y/100))')
    lineas.append('            w=$((mon_w*p_w/100)); h=$((mon_h*p_h/100))')
    lineas.append('            ;;')
    lineas.append('        *)')
    lineas.append('            return 0')
    lineas.append('            ;;')
    lineas.append('    esac')
    lineas.append('    x=$((mon_x + x)); y=$((mon_y + y))')
    # wmctrl -e recibe el área cliente: no restar las decoraciones del gestor, o la ventana encoge el grosor del marco.
    lineas.append('    _aplicar_geometria "$win" "$x" "$y" "$w" "$h"')
    lineas.append('}')
    lineas.append('')
    lineas.append('_aplicar_geometria() {')
    lineas.append('    local win="$1" x="$2" y="$3" w="$4" h="$5"')
    lineas.append('    local token_file="$TMP_DIR/geometria_${win}.token" token="${BASHPID:-$$}-${RANDOM}-${SECONDS}"')
    lineas.append('    mkdir -p "$TMP_DIR"')
    lineas.append("    printf '%s\\n' \"$token\" > \"$token_file\" 2>/dev/null || true")
    # Solo wmctrl -e, repetido con retardos por si la app (Chrome, Electron, LibreOffice...) reaplica su tamaño.
    # No se verifica con getwindowgeometry (hasta 45 px de desfase). La última repetición va en un proceso
    # aparte (nohup) para actuar aunque la acción ya haya terminado.
    lineas.append('    wmctrl -ir "$win" -e "0,$x,$y,$w,$h" 2>/dev/null')
    lineas.append("    ( nohup bash -c 'sleep 0.4; [ \"$(cat \"$1\" 2>/dev/null)\" = \"$2\" ] && wmctrl -ir \"$3\" -e \"0,$4,$5,$6,$7\" 2>/dev/null' _ \"$token_file\" \"$token\" \"$win\" \"$x\" \"$y\" \"$w\" \"$h\" >/dev/null 2>&1 & )")
    lineas.append("    ( nohup bash -c 'sleep 1.2; [ \"$(cat \"$1\" 2>/dev/null)\" = \"$2\" ] && wmctrl -ir \"$3\" -e \"0,$4,$5,$6,$7\" 2>/dev/null' _ \"$token_file\" \"$token\" \"$win\" \"$x\" \"$y\" \"$w\" \"$h\" >/dev/null 2>&1 & )")
    lineas.append("    ( nohup bash -c 'sleep 2.5; [ \"$(cat \"$1\" 2>/dev/null)\" = \"$2\" ] && wmctrl -ir \"$3\" -e \"0,$4,$5,$6,$7\" 2>/dev/null' _ \"$token_file\" \"$token\" \"$win\" \"$x\" \"$y\" \"$w\" \"$h\" >/dev/null 2>&1 & )")
    lineas.append("    ( nohup bash -c 'sleep 4.5; [ \"$(cat \"$1\" 2>/dev/null)\" = \"$2\" ] && wmctrl -ir \"$3\" -e \"0,$4,$5,$6,$7\" 2>/dev/null' _ \"$token_file\" \"$token\" \"$win\" \"$x\" \"$y\" \"$w\" \"$h\" >/dev/null 2>&1 & )")
    lineas.append('}')
    lineas.append('')
    # Sondea la geometría (posición y tamaño) hasta que no cambia entre dos lecturas, en vez de un tiempo fijo
    # (máx. ~1,7 s). La usan la colocación y el clic con «activar ventana antes».
    lineas.append('_esperar_estabilizar_ventana() {')
    lineas.append('    local win="$1" intentos=0 w_prev="" h_prev="" x_prev="" y_prev="" WIDTH="" HEIGHT="" X="" Y=""')
    lineas.append('    sleep 0.15')
    lineas.append('    command -v xdotool >/dev/null 2>&1 || return 0')
    lineas.append('    while [ "$intentos" -lt 12 ]; do')
    lineas.append('        WIDTH=""; HEIGHT=""; X=""; Y=""')
    lineas.append('        eval "$(xdotool getwindowgeometry --shell "$win" 2>/dev/null)"')
    lineas.append('        [ -n "$WIDTH" ] && [ "$WIDTH" = "$w_prev" ] && [ "$HEIGHT" = "$h_prev" ] && [ "$X" = "$x_prev" ] && [ "$Y" = "$y_prev" ] && return 0')
    lineas.append('        w_prev="$WIDTH"; h_prev="$HEIGHT"; x_prev="$X"; y_prev="$Y"')
    lineas.append('        sleep 0.12')
    lineas.append('        intentos=$((intentos + 1))')
    lineas.append('    done')
    lineas.append('}')
    lineas.append('')
    # «xdotool mousemove --sync» espera a que el puntero SE MUEVA: si ya está en el punto (clics seguidos en el mismo sitio) o
    # el punto cae fuera de pantalla y ya está en el borde, no llega ningún movimiento y xdotool 3.20160805 tarda ~15 s en
    # rendirse. Solo se espera cuando hay que mover el puntero y como mucho 2 s (sin «timeout», no se espera).
    # El eval también asigna SCREEN y WINDOW: no se declaran local porque ShellCheck daría SC2034 (igual que en
    # _esperar_estabilizar_ventana).
    lineas.append('_mover_puntero() {')
    lineas.append('    local X="" Y=""')
    lineas.append('    eval "$(xdotool getmouselocation --shell 2>/dev/null)"')
    lineas.append('    [ "$X" = "$1" ] && [ "$Y" = "$2" ] && return 0')
    lineas.append('    if command -v timeout >/dev/null 2>&1; then')
    lineas.append('        timeout 2 xdotool mousemove --sync -- "$1" "$2" 2>/dev/null')
    lineas.append('    else')
    lineas.append('        xdotool mousemove -- "$1" "$2" 2>/dev/null')
    lineas.append('    fi')
    lineas.append('}')
    lineas.append('')
    lineas.append(f'_ml_msg running {_q(nombre_accion)} >&2')

    navegador_sistema = _una_sola_vez(_detectar_navegador_predeterminado)  # xdg-settings se consulta una vez por script
    for i, paso in enumerate(pasos, start=1):
        tipo = paso.get('tipo')
        lineas.append('')
        lineas.append(f'# --- Paso {i}: {_una_linea(TIPOS_PASO.get(tipo, tipo))} ---')
        lineas.append(f'_ml_msg step_line {i} {_q(_una_linea(resumen_paso(paso))[:80])} >&2')

        if tipo in TIPOS_CON_VENTANA:
            if tipo == 'programa':
                cmd = _comando_shell_programa(paso)
            elif tipo == 'documento':
                cmd = _comando_shell_documento(paso)
            elif tipo == 'web':
                cmd = _comando_shell_web(paso, navegador_sistema)
            else:
                cmd = paso.get('comando', '')
            espera = _segundos(paso.get('espera', 2.0), 2.0)
            # "espera" es un MÁXIMO (ver _esperar_ventana_nueva): intentos de 0.2 s, redondeando hacia arriba.
            intentos_max = max(1, int(math.ceil(espera / 0.2)))
            lineas.append('ANTES="$(_snapshot)"')
            lineas.append('ACTIVA_ANTES="$(xdotool getactivewindow 2>/dev/null)"')
            if tipo == 'comando':
                lineas.append(f'_abrir_en_terminal {_q(cmd)}')
                pista_arg = '"$TERM_PISTA"'
            else:
                # "bash -c" para que funcionen igual los comandos simples y los compuestos (&&, |, comillas).
                lineas.append(f'( nohup bash -c {_q(cmd)} >/dev/null 2>&1 & )')
                pista_arg = _q(_pista_clase_para_paso(paso, navegador_sistema))
            lineas.append(f'NUEVA="$(_esperar_ventana_nueva "$ANTES" "$ACTIVA_ANTES" {intentos_max} {pista_arg})"')
            lineas.append('[ -n "$NUEVA" ] && ULTIMA_WIN="$NUEVA"')
            lineas.append(f'[ -n "$NUEVA" ] && ALIAS_WIN[{_q(_id_ventana(paso, i - 1))}]="$NUEVA"')
            if paso.get('colocar_ventana'):
                # Colocación integrada sobre la ventana recién detectada ($NUEVA), sin volver a localizarla después.
                lineas.append('if [ -n "$NUEVA" ]; then')
                lineas.append('    xdotool windowactivate "$NUEVA" 2>/dev/null')
                lineas.append('    _esperar_estabilizar_ventana "$NUEVA"')
                lineas.append('    xdotool windowactivate "$NUEVA" 2>/dev/null')
                lineas.extend('    ' + l for l in _lineas_posicionar_ventana(paso, 'NUEVA'))
                lineas.append('else')
                lineas.append('    _ml_msg place_failed >&2')
                lineas.append('fi')

        elif tipo == 'esperar':
            lineas.append(f'sleep {_segundos(paso.get("segundos", 1), 1):g}')

        elif tipo == 'ventana':
            lineas.append(_bloque_resolver_objetivo(paso))
            lineas.append('if [ -n "$WIN" ]; then')
            lineas.append('    xdotool windowactivate "$WIN" 2>/dev/null')
            lineas.append('    _esperar_estabilizar_ventana "$WIN"')
            lineas.append('    xdotool windowactivate "$WIN" 2>/dev/null')
            lineas.extend('    ' + l for l in _lineas_posicionar_ventana(paso, 'WIN'))
            lineas.append('else')
            lineas.append('    _ml_msg target_window_ventana >&2')
            lineas.append('fi')

        elif tipo == 'clic':
            # Coordenadas ABSOLUTAS de pantalla, sin resolver ventana; opcionalmente se activa una antes (compatible
            # con acciones migradas del formato antiguo, de coordenadas relativas).
            x = int(paso.get('x', 0))
            y = int(paso.get('y', 0))
            absolutas = paso.get('coords_absolutas', True)
            activar = bool(paso.get('activar_ventana'))
            boton = str(paso.get('boton', '1'))
            # _CX/_CY son globales (este bloque no está en una función): se reinician en cada paso para no heredar
            # el punto de un clic anterior si este paso no llega a fijarlos.
            lineas.append('_CX=""; _CY=""')
            if activar:
                lineas.append(_bloque_resolver_objetivo(paso))
                lineas.append('if [ -n "$WIN" ]; then')
                lineas.append('    xdotool windowactivate "$WIN" 2>/dev/null')
                # Se espera a que la geometría deje de cambiar (como en el paso "ventana") y se reactiva la ventana por
                # si algo robó el foco.
                lineas.append('    _esperar_estabilizar_ventana "$WIN"')
                lineas.append('    xdotool windowactivate "$WIN" 2>/dev/null')
                if absolutas:
                    lineas.append(f'    _CX={x}; _CY={y}')
                else:
                    # X/Y (de "xdotool getwindowgeometry" vía eval) son globales y las comparte _actualizar_monitor: se
                    # reinician antes de consultar para no arrastrar la posición de OTRA ventana si la consulta falla.
                    lineas.append('    X=""; Y=""')
                    lineas.append('    eval "$(xdotool getwindowgeometry --shell "$WIN" 2>/dev/null)"')
                    lineas.append('    if [ -n "$X" ] && [ -n "$Y" ]; then')
                    lineas.append(f'        _CX=$((X + {x})); _CY=$((Y + {y}))')
                    lineas.append('    fi')
                lineas.append('else')
                if absolutas and paso.get('objetivo_modo') != '_alias':
                    lineas.append(f'    _CX={x}; _CY={y}')
                else:
                    lineas.append('    _ml_msg activate_before_click >&2')
                lineas.append('fi')
            else:
                lineas.append(f'_CX={x}; _CY={y}')
            lineas.append('if command -v xdotool >/dev/null 2>&1; then')
            lineas.append('    if [ -n "$_CX" ] && [ -n "$_CY" ]; then')
            # Avisa (sin bloquear el clic) si el punto cae fuera de la pantalla: p. ej. cambió la resolución o se desconectó un monitor.
            lineas.append('        if [ "$_CX" -lt 0 ] || [ "$_CY" -lt 0 ] || [ "$_CX" -ge "$ANCHO_PANTALLA" ] || [ "$_CY" -ge "$ALTO_PANTALLA" ]; then')
            lineas.append('            _ml_msg click_outside "$_CX" "$_CY" "$ANCHO_PANTALLA" "$ALTO_PANTALLA" >&2')
            lineas.append('        fi')
            # _mover_puntero espera a que el puntero llegue de verdad; el sleep breve deja reaccionar al "hover";
            # --clearmodifiers evita que un Ctrl/Shift/Alt pulsado por casualidad cambie el clic.
            lineas.append('        _mover_puntero "$_CX" "$_CY"')
            lineas.append('        sleep 0.1')
            if paso.get('doble'):
                lineas.append(f'        xdotool click --clearmodifiers --repeat 2 --delay 150 {_q(boton)} 2>/dev/null || _ml_msg click_failed >&2')
            else:
                lineas.append(f'        xdotool click --clearmodifiers {_q(boton)} 2>/dev/null || _ml_msg click_failed >&2')
            # Sin ventana ya avisó activate_before_click: click_coords solo si hay ventana y falló su geometría.
            lineas.append('    elif [ -n "$WIN" ]; then' if activar else '    else')
            lineas.append('        _ml_msg click_coords >&2')
            lineas.append('    fi')
            lineas.append('else')
            lineas.append('    _ml_msg xdotool_click_missing >&2')
            lineas.append('fi')

        elif tipo == 'tecla':
            # La ventana se activa con --sync y la tecla se envía SIN --window (XTEST, al foco real): con --window
            # xdotool usa XSendEvent al nivel superior y muchas apps (GTK3, LibreOffice, Electron, navegadores) lo
            # ignoran, porque el foco está en un widget hijo.
            lineas.append(_bloque_resolver_objetivo(paso))
            lineas.append('if [ -n "$WIN" ]; then')
            lineas.append('    if command -v xdotool >/dev/null 2>&1; then')
            lineas.append('        xdotool windowactivate --sync "$WIN" 2>/dev/null')
            lineas.append('        xdotool windowfocus --sync "$WIN" 2>/dev/null')
            lineas.append('        sleep 0.3')
            combinacion = paso.get('combinacion', '')
            # xdotool devuelve 0 aunque la tecla no exista (solo escribe en stderr): se mira también su salida.
            lineas.append(f'        _ML_OUT="$(xdotool key -- {_q(combinacion)} 2>&1)" && [ -z "$_ML_OUT" ] || _ml_msg key_failed {_q(combinacion)} >&2')
            lineas.append('    else')
            lineas.append('        _ml_msg xdotool_key_missing >&2')
            lineas.append('    fi')
            lineas.append('else')
            lineas.append('    _ml_msg target_window_tecla >&2')
            lineas.append('fi')

        elif tipo == 'texto':
            # Igual que en "tecla": se activa con --sync y se escribe SIN --window (XTEST). El --delay sube sobre
            # el valor por defecto (12 ms), demasiado rápido para acentos y eñes en algunas apps.
            lineas.append(_bloque_resolver_objetivo(paso))
            lineas.append('if [ -n "$WIN" ]; then')
            lineas.append('    if command -v xdotool >/dev/null 2>&1; then')
            lineas.append('        xdotool windowactivate --sync "$WIN" 2>/dev/null')
            lineas.append('        xdotool windowfocus --sync "$WIN" 2>/dev/null')
            lineas.append('        sleep 0.3')
            texto = paso.get('texto', '')
            lineas.append(f'        xdotool type --clearmodifiers --delay 30 -- {_q(texto)} 2>/dev/null')
            lineas.append('    else')
            lineas.append('        _ml_msg xdotool_text_missing >&2')
            lineas.append('    fi')
            lineas.append('else')
            lineas.append('    _ml_msg target_window_texto >&2')
            lineas.append('fi')

    lineas.append('')
    lineas.append('_ml_msg action_finished >&2')
    return '\n'.join(lineas) + '\n'


def _dir_temporal():
    """TMP_DIR, creada de nuevo si se borró con el programa abierto."""
    os.makedirs(TMP_DIR, exist_ok=True)
    return TMP_DIR


def _limpiar_temporales_antiguos():
    try:
        ahora = time.time()
        for f in os.listdir(TMP_DIR):
            ruta = os.path.join(TMP_DIR, f)
            try:
                if ahora - os.path.getmtime(ruta) > 86400:
                    os.remove(ruta)
            except Exception:
                pass
    except Exception:
        pass


def notificar(texto, titulo='Mi Lanzador'):
    texto = tr(texto)
    titulo = tr(titulo)
    try:
        ajustes = cargar_ajustes()
        if not ajustes.get('notificaciones', True):
            return
        if HAY_NOTIFY:
            if not Notify.is_initted():
                Notify.init('Mi Lanzador')
            Notify.Notification.new(titulo, texto, 'mi-lanzador').show()
        else:
            subprocess.Popen(['notify-send', '-i', 'mi-lanzador', titulo, texto])
    except Exception:
        pass


def _avisar_fallo_de_ejecucion(mensaje, ventana_padre):
    """Diálogo con `mensaje` si hay ventana; sin ella (acceso directo .desktop: ni ventana ni terminal), notificación."""
    if ventana_padre is not None:
        ventana_padre.mostrar_dialogo_error(mensaje)
    else:
        notificar(mensaje, 'Mi Lanzador ⚠')


def _abrir_registro_de_ejecucion(ruta_log):
    """Abre el registro de una ejecución, en su propio archivo de TMP_DIR; `ruta_log` pasa a ser otro nombre (enlace
    duro) del de la última que empezó. Si dos acciones compartieran archivo, la segunda lo truncaría y se
    mezclarían. Sin enlaces duros se escribe en `ruta_log`. Devuelve (archivo abierto, ruta desde la que leerlo)."""
    fd, propia = tempfile.mkstemp(prefix='ejecucion_', suffix='.log', dir=_dir_temporal())
    archivo = os.fdopen(fd, 'w', encoding='utf-8')
    enlace = propia + '.enlace'
    try:
        os.link(propia, enlace)
        os.replace(enlace, ruta_log)
        return archivo, propia
    except OSError:
        archivo.close()
        for sobrante in (enlace, propia):
            try:
                os.remove(sobrante)
            except OSError:
                pass
    return open(ruta_log, 'w', encoding='utf-8'), ruta_log


def _mismo_archivo(a, b):
    try:
        return os.path.samefile(a, b)
    except OSError:
        return False


def ejecutar_accion(accion, ventana_padre=None):
    pasos = accion.get('pasos', [])
    if not pasos:  # solo con el JSON editado a mano: guardar exige al menos un paso
        _avisar_fallo_de_ejecucion(tr('La acción "{name}" no tiene pasos.').format(name=accion.get('nombre', '')), ventana_padre)
        return None
    _limpiar_temporales_antiguos()
    try:
        script = generar_script_bash(pasos, accion.get('nombre', 'acción'))
        fd, ruta_script = tempfile.mkstemp(prefix='accion_', suffix='.sh', dir=_dir_temporal())
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(script)
        os.chmod(ruta_script, 0o755)
        # La salida del script generado se guarda en un registro para diagnosticar pasos que no hicieron lo esperado;
        # con avisos o error se notifica dónde verlo.
        ruta_log = os.path.join(CONFIG_DIR, 'ultima_ejecucion.log')
        log_f, ruta_propia = _abrir_registro_de_ejecucion(ruta_log)
        with log_f:  # el hijo conserva su propio descriptor
            proceso = subprocess.Popen(['bash', ruta_script], start_new_session=True,
                                        stdout=log_f, stderr=log_f)
        notificar(tr('Ejecutando: {name} ({count} paso{plural})').format(name=accion.get('nombre', ''), count=len(pasos), plural='s' if len(pasos) != 1 else ''))

        def _vigilar_avisos():
            try:
                proceso.wait()
            except Exception:
                pass
            try:
                with open(ruta_propia, 'r', encoding='utf-8', errors='ignore') as f:
                    contenido = f.read()
            except Exception:
                contenido = ''
            hubo_aviso = bool(RE_AVISO_LOG.search(contenido))
            fallo = proceso.returncode not in (0, None)
            if not (hubo_aviso or fallo):
                return
            # Se notifica desde este hilo: con un acceso directo (.desktop) no hay Gtk.main() y un GLib.idle_add nunca
            # se ejecutaría (notificar() no toca widgets). Si otra acción empezó después, ruta_log ya es el registro
            # de aquélla: se da el archivo propio.
            log_mostrado = ruta_log if _mismo_archivo(ruta_log, ruta_propia) else ruta_propia
            notificar(tr('"{name}" terminó con avisos. Revisa el registro:\n{log}').format(name=accion.get('nombre', ''), log=log_mostrado), 'Mi Lanzador ⚠')

        hilo = threading.Thread(target=_vigilar_avisos, daemon=True)
        hilo.start()
        return hilo
    except Exception as e:
        _registrar_error('ejecutar la acción', e)
        _avisar_fallo_de_ejecucion(tr('No se pudo ejecutar la acción:\n{error}').format(error=e), ventana_padre)
        return None


def ejecutar_accion_por_id(id_accion):
    accion = _accion_por_id(id_accion)
    if accion:
        return ejecutar_accion(accion, None)
    mensaje = tr('No se encontró ninguna acción con id "{id}"').format(id=id_accion)
    print(mensaje, file=sys.stderr)
    notificar(mensaje, 'Mi Lanzador ⚠')  # desde un .desktop no hay terminal donde ver stderr
    return None


def icono_por_tipo_paso(tipo):
    return {
        'programa': 'application-x-executable',
        'documento': 'text-x-generic',
        'web': 'web-browser',
        'comando': 'utilities-terminal',
        'esperar': 'appointment-soon',
        'ventana': 'preferences-system-windows',
        'clic': 'input-mouse',
        'tecla': 'input-keyboard',
        'texto': 'input-keyboard',
    }.get(tipo, 'application-x-executable')


def obtener_pixbuf(accion, tamano=26):
    ruta_icono = accion.get('icono')
    try:
        if ruta_icono and os.path.isfile(ruta_icono):
            return GdkPixbuf.Pixbuf.new_from_file_at_size(ruta_icono, tamano, tamano)
    except Exception:
        pass
    try:
        tema = Gtk.IconTheme.get_default()
        primer_tipo = accion.get('pasos', [{}])[0].get('tipo') if accion.get('pasos') else None
        return tema.load_icon(icono_por_tipo_paso(primer_tipo), tamano, 0)
    except Exception:
        return None


def sanear_nombre_archivo(nombre):
    permitidos = "-_.() "
    limpio = ''.join(c if c.isalnum() or c in permitidos else '_' for c in nombre)
    # Al archivo final se le añade «-<id>.desktop» y su temporal algo más: el nombre se recorta en bytes para no
    # pasar de los 255 del sistema de archivos (si no, con un nombre largo no se creaba el acceso directo).
    return limpio.encode('utf-8')[:120].decode('utf-8', 'ignore').strip() or 'accion'


def _valor_desktop(texto):
    """Texto como valor de una clave del .desktop: en una sola línea y con las barras invertidas duplicadas (si no,
    «\\t» se lee como tabulador, «\\s» como espacio y una barra final deja la clave ilegible)."""
    return re.sub(r'[\r\n\t]+', ' ', texto).replace('\\', '\\\\')


_EXEC_RESERVADOS = re.compile(r'[\s"\'\\<>~|&;$*?#()`]')  # los que la especificación obliga a entrecomillar


def _arg_exec(texto):
    """Un argumento de Exec= como lo define la especificación Desktop Entry: tal cual si no lleva caracteres
    reservados y, si los lleva (o está vacío), entre comillas dobles con «"», «`», «$» y «\\» precedidos de una barra.
    Las comillas simples no existen en la especificación: GLib las entiende, pero `desktop-file-validate` las
    rechaza y otros lanzadores no tienen por qué aceptarlas. El escape de GKeyFile lo añade _exec_desktop."""
    if texto and not _EXEC_RESERVADOS.search(texto):
        return texto
    return '"' + re.sub(r'(["`$\\])', r'\\\1', texto) + '"'


def _exec_desktop(linea):
    """Línea de comandos como valor de Exec=: la barra se duplica (escape de GKeyFile, como en _valor_desktop) y «%»
    pasa a «%%»; si no, «a%b» llegaría como «a» (macro de Exec) y «a\\sb» como «a b»."""
    return linea.replace('\\', '\\\\').replace('%', '%%')


def generar_desktop_entry(accion, icono):
    nombre = _valor_desktop(accion.get('nombre', 'Acceso directo'))
    n_pasos = len(accion.get('pasos', []))
    exec_line = _exec_desktop(f'bash {_arg_exec(APP_SCRIPT_PATH)} --ejecutar {_arg_exec(accion.get("id", ""))}')
    lineas = [
        '[Desktop Entry]',
        'Type=Application',
        'Version=1.0',
        f'Name={nombre}',
        f'Comment=Shortcut created with Mi Lanzador ({n_pasos} step{"s" if n_pasos != 1 else ""})',
        f'Comment[es]=Acceso directo creado con Mi Lanzador ({n_pasos} paso{"s" if n_pasos != 1 else ""})',
        f'Exec={exec_line}',
        f'Icon={_valor_desktop(icono)}',
        'Terminal=false',
        'Categories=Utility;',
    ]
    return '\n'.join(lineas) + '\n'


def crear_acceso_directo(accion, destinos):
    icono_custom = accion.get('icono')
    primer_tipo = accion.get('pasos', [{}])[0].get('tipo') if accion.get('pasos') else None
    icono_final = icono_custom if icono_custom and os.path.isfile(icono_custom) else icono_por_tipo_paso(primer_tipo)
    contenido = generar_desktop_entry(accion, icono_final)
    # El id único va en el nombre del archivo: dos acciones con el mismo nombre no se pisan.
    nombre_archivo = f"{sanear_nombre_archivo(accion.get('nombre', 'accion'))}-{accion.get('id', '')}.desktop"
    rutas_creadas = []
    for destino in destinos:
        try:
            os.makedirs(destino, exist_ok=True)
            ruta = os.path.join(destino, nombre_archivo)
            _escribir_atomico(ruta, contenido, 0o755)
            _borrar_accesos_en(destino, accion.get('id', ''), conservar=nombre_archivo)  # el de antes de renombrar
            try:
                subprocess.run(['gio', 'set', ruta, 'metadata::trusted', 'true'],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except Exception:
                pass
            rutas_creadas.append(ruta)
        except Exception as e:
            _registrar_error(f'crear acceso directo en {destino}', e)
    if os.path.expanduser('~/.local/share/applications') in destinos:
        try:
            subprocess.run(['update-desktop-database', os.path.expanduser('~/.local/share/applications')],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass
    return rutas_creadas


def _id_de_acceso(ruta):
    """Id de la acción que ejecuta el .desktop `ruta` (el argumento tras «--ejecutar» de su Exec=); None si no es un
    acceso de Mi Lanzador o no se puede leer."""
    try:
        with open(ruta, 'r', encoding='utf-8', errors='ignore') as f:
            for linea in f:
                if linea.startswith('Exec='):
                    valor = re.sub(r'\\\\|%%', lambda m: m.group()[0], linea[5:].rstrip('\n'))  # deshace _exec_desktop
                    partes = GLib.shell_parse_argv(valor)[1]  # el mismo análisis que hace GLib al lanzar el .desktop
                    return partes[-1] if len(partes) >= 2 and partes[-2] == '--ejecutar' else None
    except (OSError, ValueError, GLib.Error):
        pass
    return None


def _accesos_en(carpeta, accion_id):
    """Nombres de los .desktop de la acción en `carpeta`: sufijo «-<id>.desktop» (ver crear_acceso_directo) y su Exec=
    ejecuta ese id. El sufijo solo no basta: con ids que llevan «-» (a mano o importados), «5» lo es también de «x-5»."""
    if not accion_id or not carpeta or not os.path.isdir(carpeta):
        return []
    try:
        return [n for n in os.listdir(carpeta)
                if n.endswith(f'-{accion_id}.desktop') and _id_de_acceso(os.path.join(carpeta, n)) == accion_id]
    except Exception:
        return []


def _borrar_accesos_en(carpeta, accion_id, conservar=None):
    """Borra de `carpeta` los .desktop de la acción salvo `conservar`."""
    for nombre_archivo in _accesos_en(carpeta, accion_id):
        if nombre_archivo != conservar:
            try:
                os.remove(os.path.join(carpeta, nombre_archivo))
            except Exception:
                pass


def _carpetas_de_accesos():
    """Carpetas donde se crean los accesos directos: menú de aplicaciones y Escritorio."""
    return [os.path.expanduser('~/.local/share/applications'), _dir_escritorio()]


def actualizar_accesos_directos(accion):
    """Rehace los accesos directos que la acción ya tiene, con su nombre, icono y número de pasos actuales. Donde
    no hay ninguno no crea nada."""
    carpetas = [c for c in _carpetas_de_accesos() if _accesos_en(c, accion.get('id', ''))]
    if carpetas:
        crear_acceso_directo(accion, carpetas)
    return carpetas


def eliminar_accesos_directos(accion_id):
    """Borra los .desktop de la acción del menú de aplicaciones y del Escritorio."""
    for carpeta in _carpetas_de_accesos():
        _borrar_accesos_en(carpeta, accion_id)


# --- Interfaz gráfica ---
# El CSS fija siempre fondo y texto juntos en los nodos que toca (borde, pestañas, títulos): si solo fija el
# texto, el fondo lo pone el tema y puede quedar ilegible. El resto de etiquetas sigue el tema del sistema.
# En las pestañas el rótulo no lleva fondo (el de la pestaña basta) y se anula el box-shadow con el que el tema
# dibuja su propio indicador: sin eso asoma una línea azul sobre el subrayado violeta.
CSS = b"""
window {
    background-color: #f5f6fa;
}
/* Ventana con HeaderBar propia = decoracion "lado cliente" de GTK. Sin
   estas dos reglas, el borde/sombra de esa decoracion los pinta el tema
   del sistema (a menudo un borde claro/blanco que no pega con la app). */
decoration {
    background-color: #6c5ce7;
    border: none;
    border-radius: 10px 10px 0 0;
    box-shadow: 0 2px 14px rgba(0, 0, 0, 0.35);
}
/* Misma geometria de sombra que activa; solo cambia el alfa. GTK saca de ella
   el marco invisible de la ventana: si difiere, al minimizar y restaurar la
   ventana se redimensiona y se mueve (tembleque). */
decoration:backdrop {
    box-shadow: 0 2px 14px rgba(0, 0, 0, 0.18);
}
headerbar {
    background: linear-gradient(120deg, #6c5ce7, #8e7cff);
    color: #ffffff;
    min-height: 42px;
}
headerbar label {
    color: #ffffff;
    font-weight: 600;
}
headerbar button {
    color: #ffffff;
}
/* Los botones propios (+ e idioma) fijan fondo junto al texto blanco; los de ventana (.titlebutton) quedan
   como los pinta el tema. Solo ASCII: el CSS es un literal de bytes. */
headerbar button:not(.titlebutton) {
    background-image: none;
    background-color: rgba(30, 20, 90, 0.30);
    border: 1px solid rgba(255, 255, 255, 0.30);
    box-shadow: none;
}
headerbar button:not(.titlebutton):hover {
    background-color: rgba(30, 20, 90, 0.50);
}
notebook > header.top {
    background-color: #f5f6fa;
}
notebook > header.top > tabs > tab {
    padding: 8px 18px;
    background-color: #f5f6fa;
    color: #4a4a58;
    box-shadow: none;
}
notebook > header.top > tabs > tab label {
    font-weight: 600;
    font-size: 10.5pt;
    color: #4a4a58;
}
notebook > header.top > tabs > tab:hover {
    background-color: #dfe2f9;
    color: #2d2d3a;
}
notebook > header.top > tabs > tab:hover label {
    color: #2d2d3a;
}
notebook > header.top > tabs > tab:checked {
    background-color: #eef0ff;
    border-bottom: 3px solid #6c5ce7;
    color: #4b3fa8;
}
notebook > header.top > tabs > tab:checked label {
    color: #4b3fa8;
}
button.suggested-action {
    background-image: none;
    background-color: #6c5ce7;
    color: #ffffff;
    border: none;
    border-radius: 8px;
    padding: 8px 20px;
}
button.suggested-action:hover {
    background-color: #5b4bd6;
}
button {
    border-radius: 8px;
    padding: 6px 14px;
}
treeview {
    font-size: 10.5pt;
}
treeview:selected {
    background-color: #6c5ce7;
    color: #ffffff;
}
.titulo-form {
    font-size: 13pt;
    font-weight: 700;
    color: #2d2d3a;
    background-color: #eef0ff;
    padding: 6px 12px;
    border-radius: 8px;
}
/* Fondo propio, como .titulo-form: el tema pinta el del dialogo y un texto rojo fijo no se lee sobre uno oscuro. */
.aviso-x11 {
    color: #8a1c1c;
    background-color: #fdecec;
    font-size: 9pt;
    padding: 6px 10px;
    border-radius: 8px;
}
"""


def _fila_grid(grid, fila, texto_label, widget, span_widget=2):
    grid.attach(Gtk.Label(label=texto_label, halign=Gtk.Align.END), 0, fila, 1, 1)
    grid.attach(widget, 1, fila, span_widget, 1)
    return fila + 1


def _fijar_id_combo(combo, ident):
    """Selecciona `ident` en un ComboBoxText; si no está (JSON editado a mano) añade una fila con ese texto, porque
    `set_active_id` con un id desconocido deja el combo como estaba y se guardaría otro valor sin avisar."""
    combo.set_active_id(ident)
    if combo.get_active_id() != ident:
        combo.append(ident, ident)
        combo.set_active_id(ident)


# --- Selector visual de coordenadas en pantalla (para el paso "clic") ---
# Cuenta atrás para colocar el cursor y leer la posición con "xdotool getmouselocation": más fiable que
# una capa transparente con Gdk.Seat.grab, que dependía del gestor de ventanas y del modo de foco.
SEGUNDOS_CUENTA_ATRAS_CLIC = 3


def _capturar_punto_pantalla():
    """Da unos segundos para colocar el ratón y lee la posición con "xdotool getmouselocation".
    Devuelve (x, y) absolutas, o None si falta xdotool o la lectura falla."""
    if not shutil.which('xdotool'):
        return None

    # Ventana tipo POPUP: el gestor de ventanas no la gestiona, así que se coloca justo donde se pide, sin decoración.
    aviso = Gtk.Window(type=Gtk.WindowType.POPUP)
    aviso.set_accept_focus(False)  # nunca roba el foco: no hace falta clic ni tecla

    # override_background_color sobre un EventBox en vez de CSS: una regla por #id queda bajo el
    # 'background-image' del tema y dejaba un cuadro en blanco.
    caja = Gtk.EventBox()
    caja.override_background_color(Gtk.StateFlags.NORMAL, Gdk.RGBA(0.10, 0.10, 0.10, 0.92))
    etiqueta = Gtk.Label()
    etiqueta.set_justify(Gtk.Justification.CENTER)
    etiqueta.override_color(Gtk.StateFlags.NORMAL, Gdk.RGBA(1, 1, 1, 1))
    etiqueta.set_margin_top(14)
    etiqueta.set_margin_bottom(14)
    etiqueta.set_margin_start(20)
    etiqueta.set_margin_end(20)
    caja.add(etiqueta)
    aviso.add(caja)

    estado = {'restante': SEGUNDOS_CUENTA_ATRAS_CLIC}

    def _texto(segundos):
        return tr('🎯 Coloca el cursor en el punto exacto\nCapturando en {seconds} s…').format(seconds=segundos)

    def _tick():
        if estado['restante'] <= 0:
            Gtk.main_quit()
            return False
        etiqueta.set_text(_texto(estado['restante']))
        estado['restante'] -= 1
        return True

    # El texto se fija ANTES de mostrar la ventana: algunos gestores fijan el tamaño al mapearla y, vacía,
    # queda mínima.
    _tick()
    aviso.move(40, 40)
    aviso.show_all()
    GLib.timeout_add_seconds(1, _tick)
    Gtk.main()
    aviso.destroy()
    while Gtk.events_pending():
        Gtk.main_iteration()

    try:
        salida = subprocess.run(['xdotool', 'getmouselocation', '--shell'],
                                 capture_output=True, text=True, timeout=2).stdout
        datos = dict(l.split('=', 1) for l in salida.strip().splitlines() if '=' in l)
        return int(datos['X']), int(datos['Y'])
    except Exception as excepcion:
        _registrar_error('Leer posición del ratón para elegir punto', excepcion)
        return None


def _nombre_de_ventana_x(win_id):
    """Título de una ventana X según xdotool; '' si no tiene o falla."""
    try:
        return subprocess.run(['xdotool', 'getwindowname', win_id],
                              capture_output=True, text=True, timeout=2).stdout.strip()
    except Exception:
        return ''


def _hijas_de_ventana_x(win_id):
    """Ids de las ventanas hijas directas según `xwininfo -children`; [] si falta xwininfo o falla."""
    if not shutil.which('xwininfo'):
        return []
    try:
        salida = subprocess.run(['xwininfo', '-children', '-id', win_id],
                                capture_output=True, text=True, timeout=2).stdout
    except Exception:
        return []
    hijas, en_lista = [], False
    for linea in salida.splitlines():
        if re.match(r'\s*\d+ child(?:ren)?:', linea):
            en_lista = True
        elif en_lista:
            coincidencia = re.match(r'\s+(0x[0-9a-fA-F]+)\s', linea)
            if coincidencia:
                hijas.append(coincidencia.group(1))
    return hijas


def _ventana_cliente_con_nombre(win_id, profundidad=3):
    """(id, título) de la ventana con nombre en `win_id` o debajo de ella. Con un gestor de ventanas, el ratón
    señala el marco (sin título); la ventana real es una hija suya. Sin ninguna: (win_id, '')."""
    pendientes, nivel = [win_id], 0
    while pendientes and nivel <= profundidad:
        siguientes = []
        for candidata in pendientes:
            nombre = _nombre_de_ventana_x(candidata)
            if nombre:
                return candidata, nombre
            siguientes.extend(_hijas_de_ventana_x(candidata))
        pendientes, nivel = siguientes, nivel + 1
    return win_id, ''


def _resolver_ventana_bajo_punto(x_root, y_root):
    """Con xdotool, (x_relativo, y_relativo, título) de la ventana bajo un punto absoluto; si no se puede,
    las coordenadas absolutas y título vacío. Usa la posición ACTUAL del ratón (un clic no la mueve): llamarla
    justo tras el clic, antes de restaurar/mover otra ventana. La ventana es la real, no el marco del gestor."""
    x_root_i, y_root_i = int(round(x_root)), int(round(y_root))
    if not shutil.which('xdotool'):
        return x_root_i, y_root_i, ''
    try:
        salida = subprocess.run(['xdotool', 'getmouselocation', '--shell'],
                                capture_output=True, text=True, timeout=2).stdout
        datos = dict(l.split('=', 1) for l in salida.strip().splitlines() if '=' in l)
        win_id = datos.get('WINDOW')
        if not win_id:
            return x_root_i, y_root_i, ''
        win_id, nombre = _ventana_cliente_con_nombre(win_id)
        geo_salida = subprocess.run(['xdotool', 'getwindowgeometry', '--shell', win_id],
                                    capture_output=True, text=True, timeout=2).stdout
        geo = dict(l.split('=', 1) for l in geo_salida.strip().splitlines() if '=' in l)
        wx, wy = int(geo.get('X', 0)), int(geo.get('Y', 0))
        return x_root_i - wx, y_root_i - wy, nombre
    except Exception:
        return x_root_i, y_root_i, ''


# Teclas que son en sí mismas modificadoras: al pulsarlas solas hay que
# seguir esperando (forman parte de la combinación, no son "la tecla
# principal"). Se detectan por keyval, no por nombre, para no depender de
# strings.
_TECLAS_MODIFICADORAS = {
    Gdk.KEY_Control_L, Gdk.KEY_Control_R,
    Gdk.KEY_Alt_L, Gdk.KEY_Alt_R,
    Gdk.KEY_Shift_L, Gdk.KEY_Shift_R,
    Gdk.KEY_Super_L, Gdk.KEY_Super_R,
    Gdk.KEY_Meta_L, Gdk.KEY_Meta_R,
    Gdk.KEY_ISO_Level3_Shift, Gdk.KEY_ISO_Level5_Shift,
    Gdk.KEY_Caps_Lock, Gdk.KEY_Num_Lock,
}


def _combinacion_desde_evento_tecla(evento):
    """Traduce un evento de teclado GTK al formato xdotool ('ctrl+shift+n', 'alt+Tab', 'F11'...).
    Gdk.keyval_name() ya da los keysyms de X11: solo se antepone el modificador y las letras sueltas pasan a
    minúscula (Shift queda como modificador aparte)."""
    estado = evento.state
    partes = []
    if estado & Gdk.ModifierType.CONTROL_MASK:
        partes.append('ctrl')
    if estado & Gdk.ModifierType.MOD1_MASK:
        partes.append('alt')
    if estado & Gdk.ModifierType.SHIFT_MASK:
        partes.append('shift')
    if estado & (Gdk.ModifierType.SUPER_MASK | Gdk.ModifierType.MOD4_MASK):
        partes.append('super')
    if estado & Gdk.ModifierType.MOD5_MASK:  # AltGr, en la mayoría de teclados
        partes.append('ISO_Level3_Shift')
    nombre = Gdk.keyval_name(evento.keyval) or ''
    if not nombre:
        return ''
    if len(nombre) == 1 and nombre.isalpha():
        nombre = nombre.lower()
    partes.append(nombre)
    return '+'.join(partes)


def _nombre_modificador_solo(keyval):
    """Nombre en formato xdotool para un modificador capturado SIN combinar
    con ninguna otra tecla (p. ej. pulsar y soltar solo la tecla Windows)."""
    if keyval in (Gdk.KEY_Control_L, Gdk.KEY_Control_R):
        return 'ctrl'
    if keyval in (Gdk.KEY_Alt_L, Gdk.KEY_Alt_R):
        return 'alt'
    if keyval in (Gdk.KEY_Shift_L, Gdk.KEY_Shift_R):
        return 'shift'
    if keyval in (Gdk.KEY_Super_L, Gdk.KEY_Super_R):
        return 'super'
    return Gdk.keyval_name(keyval) or ''


def _agarrar_dispositivo(gdk_window, capacidades):
    """Agarra el teclado de todo el sistema para que las teclas que Cinnamon reserva (Super, F1-F12…) lleguen al
    diálogo. Devuelve el Gdk.Seat agarrado (hay que llamar a .ungrab()); lanza una excepción si no se puede."""
    pantalla = Gdk.Display.get_default()
    asiento = pantalla.get_default_seat() if pantalla is not None else None
    if asiento is None or gdk_window is None:
        raise RuntimeError(tr('No se pudo obtener el dispositivo de entrada (Gdk.Seat).'))
    # owner_events=False: todo evento de teclado va a gdk_window, sin excepciones.
    estado = asiento.grab(gdk_window, capacidades, False, None, None, None)
    if estado != Gdk.GrabStatus.SUCCESS:
        raise RuntimeError(tr('El sistema no concedió el agarre de teclado (estado: {status}).').format(status=estado))
    return asiento


def _capturar_combinacion_teclado(parent):
    """Diálogo modal que captura EN VIVO la próxima tecla o combinación pulsada. Devuelve el texto en
    formato xdotool, o None si se cancela. No se usa Esc para cancelar: es una tecla legítima que también
    puede capturarse."""
    dialogo = Gtk.Dialog(title=tr('Capturar tecla / combinación'), transient_for=parent, modal=True)
    dialogo.set_default_size(440, 160)
    dialogo.add_button(tr('Cancelar'), Gtk.ResponseType.CANCEL)
    caja = dialogo.get_content_area()
    caja.set_border_width(20)
    etiqueta = Gtk.Label()
    texto_base_etiqueta = tr(
        '⌨  <b>Pulsa ahora</b> la tecla o combinación que quieras enviar\n'
        '(incluida Esc, que también se puede capturar y usar como paso).\n'
        'Si una tecla reservada por el sistema (F1-F12, Super…) no se detecta, cierra esto y escríbela a mano en el campo, ej. <b>Alt+F10</b>.')
    etiqueta.set_markup(texto_base_etiqueta)
    etiqueta.set_justify(Gtk.Justification.CENTER)
    etiqueta.set_line_wrap(True)
    caja.pack_start(etiqueta, True, True, 6)
    dialogo.set_can_focus(True)

    resultado = {'valor': None}
    solo_modificador = {'keyval': None}  # último modificador pulsado en solitario

    def _on_key_press(_widget, evento):
        if evento.keyval in _TECLAS_MODIFICADORAS:
            solo_modificador['keyval'] = (
                evento.keyval if solo_modificador['keyval'] is None else False)
            return True  # sigue esperando la tecla "principal"
        solo_modificador['keyval'] = False
        combinacion = _combinacion_desde_evento_tecla(evento)
        if not combinacion:
            return True  # tecla sin nombre reconocible (rara); se ignora
        resultado['valor'] = combinacion
        dialogo.response(Gtk.ResponseType.OK)
        return True

    def _on_key_release(_widget, evento):
        # Un modificador solo (p. ej. la tecla Windows): si se suelta el único modificador pulsado hasta ahora,
        # esa es la combinación capturada.
        if evento.keyval in _TECLAS_MODIFICADORAS and solo_modificador['keyval'] == evento.keyval:
            resultado['valor'] = _nombre_modificador_solo(evento.keyval)
            dialogo.response(Gtk.ResponseType.OK)
        return True

    dialogo.add_events(Gdk.EventMask.KEY_RELEASE_MASK)
    dialogo.connect('key-press-event', _on_key_press)
    dialogo.connect('key-release-event', _on_key_release)
    dialogo.show_all()

    # Se agarra el teclado (no el ratón, para poder pulsar "Cancelar") para recibir F1-F12 o Super, que
    # Cinnamon reserva. Tras show_all() la ventana puede no estar mapeada aún: el agarre se reintenta un rato corto.
    asiento = None
    error_agarre = None
    for _intento in range(15):
        while Gtk.events_pending():
            Gtk.main_iteration()
        try:
            asiento = _agarrar_dispositivo(dialogo.get_window(), Gdk.SeatCapabilities.KEYBOARD)
            error_agarre = None
            break
        except Exception as excepcion:
            error_agarre = excepcion
            time.sleep(0.02)
    if asiento is None:
        _registrar_error('Agarrar teclado para capturar tecla', error_agarre)
        etiqueta.set_markup(
            texto_base_etiqueta +
            '\n<span foreground="#a15c00">' + tr('⚠ No se pudo bloquear el teclado del sistema: aquí podrían no detectarse teclas reservadas.') + '</span>')

    try:
        dialogo.run()
    finally:  # el agarre es global: tiene que soltarse pase lo que pase
        if asiento is not None:
            try:
                asiento.ungrab()
            except Exception:
                pass
        dialogo.destroy()
    return resultado['valor']


class DialogoPaso(Gtk.Dialog):
    """Diálogo para crear o editar un único paso dentro de una acción."""

    def __init__(self, parent, pasos_previos, paso_inicial=None, alias_prohibidos=None):
        titulo = tr('Editar paso') if paso_inicial else tr('Añadir paso')
        super().__init__(title=titulo, transient_for=parent, flags=0)
        self.set_default_size(640, 560)
        self.add_buttons(tr('Cancelar'), Gtk.ResponseType.CANCEL, tr('Aceptar'), Gtk.ResponseType.OK)
        self.pasos_previos = pasos_previos
        # Alias ya usados por OTROS pasos de la acción: con dos pasos con el mismo alias, ALIAS_WIN apuntaría a la
        # ventana del segundo y los pasos posteriores actuarían sobre la ventana equivocada.
        self.alias_prohibidos = set(alias_prohibidos or ())
        self._coords_absolutas_actual = True

        area = self.get_content_area()
        area.set_border_width(14)
        area.set_spacing(10)

        herramientas = herramientas_x11_disponibles()
        faltan_herramientas = not (herramientas['xdotool'] and herramientas['wmctrl'])
        # En Wayland nativo xdotool y wmctrl no funcionan aunque estén instalados: también se avisa entonces.
        if faltan_herramientas or SESION_WAYLAND:
            if SESION_WAYLAND:
                texto_aviso = tr('⚠ Sesión Wayland nativa detectada: xdotool y wmctrl NO funcionan aquí (aunque estén instalados). Los pasos de ventana, clic y tecla no van a funcionar hasta que inicies sesión en "Cinnamon" (X11) en vez de "Cinnamon (Wayland)".')
            else:
                tools = tr(' y ').join(n for n, ok in herramientas.items() if not ok)
                texto_aviso = tr('⚠ Faltan {tools}. Algunos pasos de ventana, clic y tecla podrían no funcionar hasta instalarlo(s) con: sudo apt install xdotool wmctrl (también puedes hacerlo desde Ajustes → «Instalar ahora»).').format(tools=tools)
            aviso = Gtk.Label(label=texto_aviso)
            aviso.get_style_context().add_class('aviso-x11')
            aviso.set_line_wrap(True)
            aviso.set_halign(Gtk.Align.START)
            area.add(aviso)

        fila_tipo = Gtk.Box(spacing=8)
        fila_tipo.add(Gtk.Label(label=tr('Tipo de paso:')))
        self.combo_tipo = Gtk.ComboBoxText()
        for clave in ORDEN_TIPOS_PASO:
            self.combo_tipo.append(clave, _texto_tipo(clave))
        self.combo_tipo.connect('changed', self._on_cambio_tipo)
        fila_tipo.pack_start(self.combo_tipo, True, True, 0)
        area.add(fila_tipo)

        self.stack = Gtk.Stack()
        self.stack.set_transition_type(Gtk.StackTransitionType.NONE)
        area.add(self.stack)
        self.stack.set_vexpand(True)

        self._crear_pagina_programa()
        self._crear_pagina_documento()
        self._crear_pagina_web()
        self._crear_pagina_comando()
        self._crear_pagina_esperar()
        self._crear_pagina_ventana()
        self._crear_pagina_clic()
        self._crear_pagina_tecla()
        self._crear_pagina_texto()

        self.btn_probar_paso = Gtk.Button(label=tr('▶ Probar este paso ahora'))
        self.btn_probar_paso.set_tooltip_text(tr(
            'Ejecuta solo este paso tal y como está configurado ahora mismo (abre el programa/'
            'web/comando, hace el clic, envía la tecla o coloca la ventana, según el tipo), '
            'sin guardar ni tocar el resto de la acción.'))
        self.btn_probar_paso.set_halign(Gtk.Align.START)
        self.btn_probar_paso.connect('clicked', self._on_probar_paso)
        area.add(self.btn_probar_paso)

        area.show_all()

        if paso_inicial:
            self._cargar_paso(paso_inicial)
        else:
            self.combo_tipo.set_active_id('programa')

    # -- construcción de páginas -------------------------------------------
    def _crear_selector_objetivo(self, indice_paso):
        """Selector compartido «Aplicar a qué ventana» de los pasos ventana/clic/tecla/texto."""
        caja = Gtk.Grid(column_spacing=10, row_spacing=6)
        combo = Gtk.ComboBoxText()
        combo.append('_ultima', tr('Última ventana abierta por esta acción'))
        for alias_id, etiqueta in alias_disponibles_antes_de(self.pasos_previos, indice_paso):
            combo.append(f'_alias:{alias_id}', f'{tr("Ventana de:")} {etiqueta}')
        combo.append('_buscar', tr('Buscar por título de ventana…'))
        combo.set_active_id('_ultima')
        rotulo_buscar = Gtk.Label(label=tr('Buscar título:'), halign=Gtk.Align.END)
        entry_buscar = Gtk.Entry()
        entry_buscar.set_placeholder_text(tr('Texto que aparece en el título de la ventana'))
        for widget in (rotulo_buscar, entry_buscar):
            widget.set_no_show_all(True)
            widget.set_visible(False)
        # El rótulo sigue siempre al campo: nunca se ve uno sin el otro.
        entry_buscar.connect('notify::visible', lambda e, _p: rotulo_buscar.set_visible(e.get_visible()))

        def _cambio(c):
            entry_buscar.set_visible(c.get_active_id() == '_buscar')
        combo.connect('changed', _cambio)

        _fila_grid(caja, 0, tr('Aplicar a:'), combo)
        caja.attach(rotulo_buscar, 0, 1, 1, 1)
        caja.attach(entry_buscar, 1, 1, 2, 1)
        return caja, combo, entry_buscar

    def _leer_objetivo(self, combo, entry_buscar, paso):
        activo = combo.get_active_id() or '_ultima'
        if activo == '_buscar':
            paso['objetivo_modo'] = '_buscar'
            paso['objetivo_buscar'] = entry_buscar.get_text().strip()
        elif activo.startswith('_alias:'):
            paso['objetivo_modo'] = '_alias'
            paso['objetivo_alias'] = activo.split(':', 1)[1]
        else:
            paso['objetivo_modo'] = '_ultima'

    def _fijar_objetivo(self, combo, entry_buscar, paso):
        modo = paso.get('objetivo_modo', '_ultima')
        if modo == '_alias':
            alias = paso.get('objetivo_alias', '')
            combo.set_active_id(f'_alias:{alias}')
            if combo.get_active_id() != f'_alias:{alias}':  # con un id desconocido el combo sigue en «Última ventana»
                # Ningún paso anterior abre ya esa ventana (se borró, se movió o cambió de nombre): se conserva la
                # referencia, marcada, en vez de pasar en silencio a «Última ventana»; al guardar se sigue avisando.
                combo.insert(1, f'_alias:{alias}', tr('⚠ Ventana de «{alias}»: ya no la abre ningún paso anterior').format(alias=alias or '?'))
                combo.set_active_id(f'_alias:{alias}')
        elif modo == '_buscar':
            combo.set_active_id('_buscar')
            entry_buscar.set_text(paso.get('objetivo_buscar', ''))
            entry_buscar.set_visible(True)
        else:
            combo.set_active_id('_ultima')

    # -- sección reutilizable: "colocar ventana tras abrir" -----------------
    def _crear_seccion_colocar_ventana(self, prefijo):
        """Controles para colocar la ventana tras abrirla; se guardan en self.colocar_<prefijo> (dict de
        widgets). Los usan los pasos programa, documento, web y comando."""
        marco = Gtk.Frame(label=tr(' Colocación de la ventana (opcional) '))
        caja = Gtk.Grid(column_spacing=12, row_spacing=8)
        caja.set_border_width(10)
        marco.add(caja)

        check = Gtk.CheckButton(label=tr('Colocar / organizar esta ventana justo después de abrirla'))
        caja.attach(check, 0, 0, 3, 1)

        combo = Gtk.ComboBoxText()
        for clave in ORDEN_POSICIONES:
            combo.append(clave, tr(POSICIONES[clave]))
        combo.set_active_id('maximizar')
        _fila_grid(caja, 1, tr('Acción sobre la ventana:'), combo)

        grid_pers = Gtk.Grid(column_spacing=10, row_spacing=6)
        spin_x = Gtk.SpinButton.new_with_range(0, 100, 1)
        spin_y = Gtk.SpinButton.new_with_range(0, 100, 1)
        spin_w = Gtk.SpinButton.new_with_range(1, 100, 1)
        spin_h = Gtk.SpinButton.new_with_range(1, 100, 1)
        spin_w.set_value(50)
        spin_h.set_value(50)
        _fila_grid(grid_pers, 0, tr('Posición X (% pantalla):'), spin_x)
        _fila_grid(grid_pers, 1, tr('Posición Y (% pantalla):'), spin_y)
        _fila_grid(grid_pers, 2, tr('Ancho (% pantalla):'), spin_w)
        _fila_grid(grid_pers, 3, tr('Alto (% pantalla):'), spin_h)
        caja.attach(grid_pers, 0, 2, 3, 1)
        grid_pers.set_visible(False)
        grid_pers.set_no_show_all(True)

        def _actualizar_sensibilidad(*_args):
            activo = check.get_active()
            combo.set_sensitive(activo)
            grid_pers.set_visible(activo and combo.get_active_id() == 'personalizada')
        check.connect('toggled', _actualizar_sensibilidad)
        combo.connect('changed', _actualizar_sensibilidad)
        combo.set_sensitive(False)

        widgets = {'check': check, 'combo': combo, 'spin_x': spin_x, 'spin_y': spin_y,
                   'spin_w': spin_w, 'spin_h': spin_h}
        setattr(self, f'colocar_{prefijo}', widgets)
        return marco

    def _leer_colocar_ventana(self, prefijo, paso):
        """Lee los controles de 'colocar ventana' hacia el paso. Devuelve un mensaje de error si no son válidos
        (p. ej. porcentajes personalizados que se salen de pantalla) o None."""
        w = getattr(self, f'colocar_{prefijo}')
        paso['colocar_ventana'] = w['check'].get_active()
        if paso['colocar_ventana']:
            paso['accion_ventana'] = w['combo'].get_active_id() or 'maximizar'
            if paso['accion_ventana'] == 'personalizada':
                paso['personalizada_x'] = int(w['spin_x'].get_value())
                paso['personalizada_y'] = int(w['spin_y'].get_value())
                paso['personalizada_w'] = int(w['spin_w'].get_value())
                paso['personalizada_h'] = int(w['spin_h'].get_value())
                return _validar_rango_personalizada(paso)
        return None

    def _leer_apertura(self, paso, entry_alias, spin_espera, texto_base):
        """Alias, espera y colocación de un paso que abre ventana. Devuelve el mensaje de error o None."""
        alias = entry_alias.get_text().strip()
        if alias and alias in self.alias_prohibidos:
            return tr('Ya hay otro paso de esta acción usando el alias «{alias}». Elige un nombre distinto para poder diferenciar sus ventanas.').format(alias=alias)
        paso['alias'] = alias or sugerir_alias(self.pasos_previos, paso['tipo'], texto_base, self.alias_prohibidos)
        paso['espera'] = round(spin_espera.get_value(), 1)
        return self._leer_colocar_ventana(paso['tipo'], paso)

    def _fijar_colocar_ventana(self, prefijo, paso):
        w = getattr(self, f'colocar_{prefijo}')
        w['check'].set_active(bool(paso.get('colocar_ventana')))
        w['combo'].set_active_id(paso.get('accion_ventana', 'maximizar'))
        w['spin_x'].set_value(paso.get('personalizada_x', 0))
        w['spin_y'].set_value(paso.get('personalizada_y', 0))
        w['spin_w'].set_value(paso.get('personalizada_w', 50))
        w['spin_h'].set_value(paso.get('personalizada_h', 50))
        w['combo'].set_sensitive(w['check'].get_active())

    # -- páginas de pasos -----------------------------------------------
    def _crear_pagina_programa(self):
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        outer.set_border_width(6)

        self.stack_programa = Gtk.Stack()
        self.stack_programa.set_transition_type(Gtk.StackTransitionType.NONE)
        switcher_programa = Gtk.StackSwitcher()
        switcher_programa.set_stack(self.stack_programa)
        switcher_programa.set_halign(Gtk.Align.START)
        outer.pack_start(switcher_programa, False, False, 0)
        outer.pack_start(self.stack_programa, False, False, 0)

        # -- sub-página: catálogo de aplicaciones/accesos directos detectados
        pag_catalogo = Gtk.Grid(column_spacing=12, row_spacing=8)
        pag_catalogo.set_border_width(6)
        try:
            self._apps_instaladas = listar_aplicaciones_instaladas()
        except Exception:
            # Un .desktop raro no debe impedir abrir el diálogo: catálogo vacío (queda la pestaña de ruta manual).
            self._apps_instaladas = []
        self.store_apps = Gtk.ListStore(str, str, str)  # nombre, ruta .desktop, exec
        for app in self._apps_instaladas:
            self.store_apps.append([app['nombre'], app['ruta'], app['exec']])

        self.entry_app_instalada = Gtk.Entry()
        self._ruta_app_seleccionada = None
        self.entry_app_instalada.set_placeholder_text(
            tr('Escribe para buscar entre {count} aplicaciones y accesos directos detectados…').format(count=len(self._apps_instaladas)))
        self._autocompletar_apps(self.entry_app_instalada, '_ruta_app_seleccionada')

        f = 0
        f = _fila_grid(pag_catalogo, f, tr('Aplicación / acceso directo:'), self.entry_app_instalada)
        btn_recargar = Gtk.Button(label=tr('🔄 Volver a detectar aplicaciones instaladas'))
        btn_recargar.connect('clicked', self._on_recargar_apps)
        pag_catalogo.attach(btn_recargar, 1, f, 2, 1)
        f += 1
        ayuda_catalogo = Gtk.Label(
            label=tr('Busca por nombre: se detectan automáticamente los programas instalados '
                  '(incluidos Snap y Flatpak) y los accesos directos de tu Escritorio. Si no '
                  'encuentras algo aquí, usa la pestaña "Ruta / comando manual".'))
        ayuda_catalogo.set_line_wrap(True)
        ayuda_catalogo.set_halign(Gtk.Align.START)
        pag_catalogo.attach(ayuda_catalogo, 0, f, 3, 1)
        self.stack_programa.add_titled(pag_catalogo, 'instalado', tr('Aplicación instalada'))

        # -- sub-página: ruta o comando manual ---------------------------
        pag_manual = Gtk.Grid(column_spacing=12, row_spacing=8)
        pag_manual.set_border_width(6)
        self.chooser_programa = Gtk.FileChooserButton(title=tr('Selecciona el ejecutable o el acceso directo'),
                                                        action=Gtk.FileChooserAction.OPEN)
        self.chooser_programa.set_current_folder('/usr/bin')
        filtro_desktop = Gtk.FileFilter()
        filtro_desktop.set_name(tr('Accesos directos (.desktop)'))
        filtro_desktop.add_pattern('*.desktop')
        filtro_todos = Gtk.FileFilter()
        filtro_todos.set_name(tr('Todos los archivos'))
        filtro_todos.add_pattern('*')
        self.chooser_programa.add_filter(filtro_desktop)
        self.chooser_programa.add_filter(filtro_todos)
        fm = 0
        fm = _fila_grid(pag_manual, fm, tr('Ejecutable o .desktop:'), self.chooser_programa)
        self.entry_argumentos = Gtk.Entry()
        self.entry_argumentos.set_placeholder_text(tr('Ej: --nueva-ventana archivo.txt (se ignora si eliges un .desktop)'))
        fm = _fila_grid(pag_manual, fm, tr('Argumentos (opcional):'), self.entry_argumentos)
        ayuda_manual = Gtk.Label(
            label=tr('Úsalo para binarios o scripts que no aparecen en el catálogo, o para elegir a '
                  'mano un acceso directo (.desktop) guardado en otra carpeta.'))
        ayuda_manual.set_line_wrap(True)
        ayuda_manual.set_halign(Gtk.Align.START)
        pag_manual.attach(ayuda_manual, 0, fm, 3, 1)
        self.stack_programa.add_titled(pag_manual, 'manual', tr('Ruta / comando manual'))
        self.stack_programa.set_visible_child_name('instalado')

        # -- campos comunes a ambos modos ---------------------------------
        grid_comun = Gtk.Grid(column_spacing=12, row_spacing=8)
        fc = 0
        self.entry_alias_programa = Gtk.Entry()
        self.entry_alias_programa.set_placeholder_text(tr('(opcional) nombre para referirte a esta ventana después'))
        fc = _fila_grid(grid_comun, fc, tr('Alias de la ventana:'), self.entry_alias_programa)
        self.spin_espera_programa = Gtk.SpinButton.new_with_range(0, 30, 0.5)
        self.spin_espera_programa.set_value(2.5)
        self.spin_espera_programa.set_digits(1)
        fc = _fila_grid(grid_comun, fc, tr('Esperar como máximo tras abrir (s):'), self.spin_espera_programa)
        outer.pack_start(grid_comun, False, False, 0)

        outer.pack_start(self._crear_seccion_colocar_ventana('programa'), False, False, 0)

        self.stack.add_titled(outer, 'programa', _texto_tipo('programa'))

    def _autocompletar_apps(self, entry, atributo_ruta):
        """Autocompletado de `entry` con el catálogo self.store_apps (coincide en cualquier parte del nombre).
        Al elegir una sugerencia, su .desktop queda en self.<atributo_ruta>."""
        completado = Gtk.EntryCompletion()
        completado.set_model(self.store_apps)
        completado.set_text_column(0)
        completado.set_inline_selection(True)
        completado.set_minimum_key_length(0)

        def _coincide(completion, cadena, iterador, datos=None):
            return cadena.lower() in self.store_apps[iterador][0].lower()
        completado.set_match_func(_coincide)

        def _on_coincidencia(completion, modelo, iterador):
            # 'match-selected' es señal de GtkEntryCompletion, no de GtkEntry: conectarla al Entry lanza TypeError.
            entry.set_text(modelo[iterador][0])
            entry.set_position(-1)
            setattr(self, atributo_ruta, modelo[iterador][1])
            return True
        completado.connect('match-selected', _on_coincidencia)
        entry.set_completion(completado)

    def _on_recargar_apps(self, widget):
        try:
            self._apps_instaladas = listar_aplicaciones_instaladas()
        except Exception:
            self._apps_instaladas = []
        self.store_apps.clear()
        for app in self._apps_instaladas:
            self.store_apps.append([app['nombre'], app['ruta'], app['exec']])
        self.entry_app_instalada.set_placeholder_text(
            tr('Escribe para buscar entre {count} aplicaciones y accesos directos detectados…').format(count=len(self._apps_instaladas)))

    def _buscar_app_por_nombre(self, texto):
        texto_l = texto.strip().lower()
        if not texto_l:
            return None
        for fila in self.store_apps:
            if fila[0].strip().lower() == texto_l:
                return fila[1]
        return None

    def _resolver_ruta_app_seleccionada(self):
        return self._resolver_ruta_app_desde(self.entry_app_instalada, self._ruta_app_seleccionada)

    def _resolver_ruta_app_desde(self, entry_widget, ruta_seleccionada_actual):
        """.desktop elegido en un entry con autocompletado: la sugerencia marcada si el texto no cambió; si no, por nombre."""
        texto = entry_widget.get_text().strip()
        if ruta_seleccionada_actual:
            for fila in self.store_apps:
                if fila[1] == ruta_seleccionada_actual and fila[0] == texto:
                    return ruta_seleccionada_actual
        return self._buscar_app_por_nombre(texto)

    def _crear_pagina_documento(self):
        """Paso 'documento': abre un archivo elegido con Gtk.FileChooserButton, por defecto con la app
        predeterminada (xdg-open) o, opcionalmente, con una app del catálogo ya detectado (self.store_apps)."""
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        outer.set_border_width(6)
        grid = Gtk.Grid(column_spacing=12, row_spacing=8)

        self.chooser_documento = Gtk.FileChooserButton(
            title=tr('Selecciona el documento o archivo a abrir'), action=Gtk.FileChooserAction.OPEN)
        self.chooser_documento.set_current_folder(os.path.expanduser('~'))
        filtro_todos_doc = Gtk.FileFilter()
        filtro_todos_doc.set_name(tr('Todos los archivos'))
        filtro_todos_doc.add_pattern('*')
        self.chooser_documento.add_filter(filtro_todos_doc)
        f = 0
        f = _fila_grid(grid, f, tr('Documento / archivo:'), self.chooser_documento)

        self.check_abrir_con_app = Gtk.CheckButton(
            label=tr('Abrir con una aplicación instalada concreta (opcional)'))
        grid.attach(self.check_abrir_con_app, 1, f, 2, 1)
        f += 1

        self.entry_app_documento = Gtk.Entry()
        self._ruta_app_documento_seleccionada = None
        self.entry_app_documento.set_placeholder_text(tr('Escribe para buscar entre las aplicaciones instaladas…'))
        # Reutiliza self.store_apps (lo rellena _crear_pagina_programa): no se vuelven a escanear los .desktop.
        self._autocompletar_apps(self.entry_app_documento, '_ruta_app_documento_seleccionada')
        f = _fila_grid(grid, f, tr('Aplicación:'), self.entry_app_documento)
        self.entry_app_documento.set_sensitive(False)
        self.check_abrir_con_app.connect(
            'toggled', lambda c: self.entry_app_documento.set_sensitive(c.get_active()))

        self.entry_alias_documento = Gtk.Entry()
        self.entry_alias_documento.set_placeholder_text(tr('(opcional) nombre para referirte a esta ventana después'))
        f = _fila_grid(grid, f, tr('Alias de la ventana:'), self.entry_alias_documento)
        self.spin_espera_documento = Gtk.SpinButton.new_with_range(0, 30, 0.5)
        self.spin_espera_documento.set_value(2.5)
        self.spin_espera_documento.set_digits(1)
        f = _fila_grid(grid, f, tr('Esperar como máximo tras abrir (s):'), self.spin_espera_documento)

        ayuda_doc = Gtk.Label(
            label=tr('Por defecto se abre con la aplicación predeterminada del sistema para ese tipo '
                  'de archivo (xdg-open) — lo mismo que un doble clic desde el gestor de archivos. '
                  'Marca la casilla de arriba solo si necesitas forzar una aplicación concreta.'))
        ayuda_doc.set_line_wrap(True)
        ayuda_doc.set_halign(Gtk.Align.START)
        grid.attach(ayuda_doc, 0, f, 3, 1)

        outer.pack_start(grid, False, False, 0)
        outer.pack_start(self._crear_seccion_colocar_ventana('documento'), False, False, 0)
        self.stack.add_titled(outer, 'documento', _texto_tipo('documento'))

    def _crear_pagina_web(self):
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        outer.set_border_width(6)
        grid = Gtk.Grid(column_spacing=12, row_spacing=8)
        self.entry_url = Gtk.Entry()
        self.entry_url.set_placeholder_text('https://...')
        f = 0
        f = _fila_grid(grid, f, tr('URL:'), self.entry_url)
        self.combo_navegador = Gtk.ComboBoxText()
        for clave, info in NAVEGADORES.items():
            self.combo_navegador.append(clave, tr(info['nombre']))
        # El navegador predeterminado de Ajustes es el valor inicial de todo paso web nuevo (editable a mano).
        _fijar_id_combo(self.combo_navegador, cargar_ajustes().get('navegador_predeterminado') or 'sistema')
        f = _fila_grid(grid, f, tr('Navegador:'), self.combo_navegador)
        self.check_nueva_ventana = Gtk.CheckButton(label=tr('Abrir en una ventana nueva (si no, se abre como pestaña)'))
        grid.attach(self.check_nueva_ventana, 1, f, 2, 1)
        f += 1
        ayuda_nueva_ventana = Gtk.Label(
            label=tr('Con "Predeterminado del sistema" se detecta automáticamente qué navegador es '
                  '(Firefox, Chrome, Chromium o Brave) para poder abrir la ventana nueva.'))
        ayuda_nueva_ventana.set_line_wrap(True)
        ayuda_nueva_ventana.set_halign(Gtk.Align.START)
        grid.attach(ayuda_nueva_ventana, 1, f, 2, 1)
        f += 1
        self.check_modo_app = Gtk.CheckButton(label=tr('Abrir como app (sin barra de direcciones; solo Chrome/Chromium/Brave)'))
        grid.attach(self.check_modo_app, 1, f, 2, 1)
        f += 1
        self.entry_alias_web = Gtk.Entry()
        self.entry_alias_web.set_placeholder_text(tr('(opcional) nombre para referirte a esta ventana después'))
        f = _fila_grid(grid, f, tr('Alias de la ventana:'), self.entry_alias_web)
        self.spin_espera_web = Gtk.SpinButton.new_with_range(0, 30, 0.5)
        self.spin_espera_web.set_value(3.0)
        self.spin_espera_web.set_digits(1)
        f = _fila_grid(grid, f, tr('Esperar como máximo tras abrir (s):'), self.spin_espera_web)
        outer.pack_start(grid, False, False, 0)
        outer.pack_start(self._crear_seccion_colocar_ventana('web'), False, False, 0)
        self.stack.add_titled(outer, 'web', _texto_tipo('web'))

    def _crear_pagina_comando(self):
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        outer.set_border_width(6)
        grid = Gtk.Grid(column_spacing=12, row_spacing=8)
        self.entry_comando = Gtk.Entry()
        self.entry_comando.set_placeholder_text(tr("Ej: notify-send 'Hola'  /  ~/scripts/backup.sh"))
        f = 0
        f = _fila_grid(grid, f, tr('Comando:'), self.entry_comando)
        self.entry_alias_comando = Gtk.Entry()
        self.entry_alias_comando.set_placeholder_text(tr('(opcional) nombre para referirte a esta ventana después'))
        f = _fila_grid(grid, f, tr('Alias de la ventana:'), self.entry_alias_comando)
        self.spin_espera_comando = Gtk.SpinButton.new_with_range(0, 30, 0.5)
        self.spin_espera_comando.set_value(2.5)
        self.spin_espera_comando.set_digits(1)
        f = _fila_grid(grid, f, tr('Esperar como máximo tras ejecutar (s):'), self.spin_espera_comando)
        ayuda_comando = Gtk.Label(
            label=tr('El comando se ejecuta en una terminal visible (para poder ver su salida o '
                  'cualquier error); la terminal queda abierta al terminar hasta pulsar Intro.'))
        ayuda_comando.set_line_wrap(True)
        ayuda_comando.set_halign(Gtk.Align.START)
        grid.attach(ayuda_comando, 0, f, 3, 1)
        outer.pack_start(grid, False, False, 0)
        outer.pack_start(self._crear_seccion_colocar_ventana('comando'), False, False, 0)
        self.stack.add_titled(outer, 'comando', _texto_tipo('comando'))

    def _crear_pagina_esperar(self):
        grid = Gtk.Grid(column_spacing=12, row_spacing=8)
        grid.set_border_width(6)
        self.spin_segundos_esperar = Gtk.SpinButton.new_with_range(0.5, 120, 0.5)
        self.spin_segundos_esperar.set_value(2)
        self.spin_segundos_esperar.set_digits(1)
        _fila_grid(grid, 0, tr('Esperar (segundos):'), self.spin_segundos_esperar)
        self.stack.add_titled(grid, 'esperar', _texto_tipo('esperar'))

    def _crear_pagina_ventana(self):
        grid = Gtk.Grid(column_spacing=12, row_spacing=8)
        grid.set_border_width(6)
        aviso_avanzado = Gtk.Label(
            label=tr('Avanzado: úsalo solo para reposicionar una ventana que ya estaba abierta de '
                  'antes (buscándola por título). Para la ventana que abre un paso de programa/web/'
                  'comando, activa "Colocar / organizar ventana" dentro de ese mismo paso: es más fiable.'))
        aviso_avanzado.set_line_wrap(True)
        aviso_avanzado.set_halign(Gtk.Align.START)
        grid.attach(aviso_avanzado, 0, 0, 3, 1)
        selector, self.combo_objetivo_ventana, self.entry_buscar_ventana = self._crear_selector_objetivo(None)
        grid.attach(selector, 0, 1, 3, 1)
        self.combo_posicion = Gtk.ComboBoxText()
        for clave in ORDEN_POSICIONES:
            self.combo_posicion.append(clave, _texto_posicion(clave))
        self.combo_posicion.set_active_id('maximizar')
        self.combo_posicion.connect('changed', self._on_cambio_posicion)
        _fila_grid(grid, 2, tr('Acción sobre la ventana:'), self.combo_posicion)

        self.caja_personalizada = Gtk.Grid(column_spacing=10, row_spacing=6)
        self.spin_pers_x = Gtk.SpinButton.new_with_range(0, 100, 1)
        self.spin_pers_y = Gtk.SpinButton.new_with_range(0, 100, 1)
        self.spin_pers_w = Gtk.SpinButton.new_with_range(1, 100, 1)
        self.spin_pers_h = Gtk.SpinButton.new_with_range(1, 100, 1)
        self.spin_pers_w.set_value(50)
        self.spin_pers_h.set_value(50)
        _fila_grid(self.caja_personalizada, 0, tr('Posición X (% pantalla):'), self.spin_pers_x)
        _fila_grid(self.caja_personalizada, 1, tr('Posición Y (% pantalla):'), self.spin_pers_y)
        _fila_grid(self.caja_personalizada, 2, tr('Ancho (% pantalla):'), self.spin_pers_w)
        _fila_grid(self.caja_personalizada, 3, tr('Alto (% pantalla):'), self.spin_pers_h)
        grid.attach(self.caja_personalizada, 0, 4, 3, 1)
        self.caja_personalizada.set_visible(False)
        self.caja_personalizada.set_no_show_all(True)

        self.stack.add_titled(grid, 'ventana', _texto_tipo('ventana'))

    def _crear_pagina_clic(self):
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        outer.set_border_width(6)

        grid = Gtk.Grid(column_spacing=12, row_spacing=8)
        # El clic usa por defecto coordenadas ABSOLUTAS de pantalla (las del selector de punto): no hace falta elegir
        # ninguna ventana ni depende de que al ejecutar se resuelva la misma que al elegir el punto.
        ayuda = Gtk.Label(
            label=tr('Coordenadas absolutas de pantalla: el clic se simula siempre en ese punto '
                    'exacto, sin necesidad de elegir ninguna ventana.'))
        ayuda.set_line_wrap(True)
        ayuda.set_halign(Gtk.Align.START)
        grid.attach(ayuda, 0, 0, 3, 1)
        self.spin_x_clic = Gtk.SpinButton.new_with_range(0, 20000, 1)
        self.spin_y_clic = Gtk.SpinButton.new_with_range(0, 20000, 1)
        self.spin_x_clic.set_value(100)
        self.spin_y_clic.set_value(100)
        _fila_grid(grid, 1, tr('Coordenada X:'), self.spin_x_clic)
        _fila_grid(grid, 2, tr('Coordenada Y:'), self.spin_y_clic)

        btn_elegir_punto = Gtk.Button(label=tr('🎯  Elegir punto en la pantalla…'))
        btn_elegir_punto.connect('clicked', self._on_elegir_punto_clic)
        grid.attach(btn_elegir_punto, 1, 3, 2, 1)
        self.label_punto_detectado = Gtk.Label(label='')
        self.label_punto_detectado.set_line_wrap(True)
        self.label_punto_detectado.set_halign(Gtk.Align.START)
        grid.attach(self.label_punto_detectado, 0, 4, 3, 1)

        self.combo_boton = Gtk.ComboBoxText()
        for clave, etiqueta in BOTONES_RATON.items():
            self.combo_boton.append(clave, tr(etiqueta))
        self.combo_boton.set_active_id('1')
        _fila_grid(grid, 5, tr('Botón del ratón:'), self.combo_boton)
        self.check_doble_clic = Gtk.CheckButton(label=tr('Doble clic'))
        grid.attach(self.check_doble_clic, 1, 6, 2, 1)
        outer.pack_start(grid, False, False, 0)

        # -- sección opcional: activar una ventana concreta antes del clic
        marco_activar = Gtk.Frame(label=tr(' Activar una ventana antes de hacer clic (opcional) '))
        caja_activar = Gtk.Grid(column_spacing=12, row_spacing=8)
        caja_activar.set_border_width(10)
        marco_activar.add(caja_activar)
        self.check_activar_ventana_clic = Gtk.CheckButton(
            label=tr('Activar/enfocar una ventana justo antes de hacer el clic'))
        caja_activar.attach(self.check_activar_ventana_clic, 0, 0, 3, 1)
        ayuda_activar = Gtk.Label(
            label=tr('Solo hace falta si esa ventana pudiera estar minimizada o detrás de otras '
                  '(por ejemplo si no la coloca ningún paso anterior).'))
        ayuda_activar.set_line_wrap(True)
        ayuda_activar.set_halign(Gtk.Align.START)
        caja_activar.attach(ayuda_activar, 0, 1, 3, 1)
        selector_clic, self.combo_objetivo_clic, self.entry_buscar_clic = self._crear_selector_objetivo(None)
        caja_activar.attach(selector_clic, 0, 2, 3, 1)
        selector_clic.set_sensitive(False)
        self.check_activar_ventana_clic.connect(
            'toggled', lambda c: selector_clic.set_sensitive(c.get_active()))
        outer.pack_start(marco_activar, False, False, 0)

        self.stack.add_titled(outer, 'clic', _texto_tipo('clic'))

    def _on_elegir_punto_clic(self, widget):
        if getattr(self, '_captura_en_curso', False):
            return  # ya hay una captura en curso
        herramientas = herramientas_x11_disponibles()
        if not herramientas['xdotool']:
            self.label_punto_detectado.set_text(tr(
                '⚠ Instala xdotool para poder elegir el punto y simular el clic '
                '(sudo apt install xdotool).'))
            return
        # Se avisa con el diálogo aún visible de cómo proceder y del tiempo disponible, antes de ocultar nada.
        self.label_punto_detectado.set_text(
            tr('🕒 Esta ventana se va a ocultar un momento: coloca el cursor donde quieras hacer clic. Tendrás {seconds} segundos en cuanto veas la cuenta atrás en la esquina.')
            .format(seconds=SEGUNDOS_CUENTA_ATRAS_CLIC))
        self._captura_en_curso = True
        while Gtk.events_pending():
            Gtk.main_iteration()
        GLib.timeout_add(900, self._ocultar_para_capturar)

    def _ocultar_para_capturar(self):
        if not self.get_visible():  # el diálogo se cerró durante el aviso previo: no se oculta nada ni se captura
            self._captura_en_curso = False
            return False
        # run() termina al recibir "unmap", así que no se oculta con hide(): se deja mapeado, fuera de pantalla
        # y con opacidad 0.
        self._ventana_principal_para_captura = self.get_transient_for()
        self._posicion_previa_captura = self.get_position()
        self.set_opacity(0)
        self.move(-32000, -32000)
        if self._ventana_principal_para_captura is not None:
            vp = self._ventana_principal_para_captura
            # skip_taskbar/skip_pager además de iconify(): ningún botón visible en el panel durante la captura.
            vp.set_skip_taskbar_hint(True)
            vp.set_skip_pager_hint(True)
            vp.iconify()
        while Gtk.events_pending():
            Gtk.main_iteration()
        GLib.timeout_add(250, self._lanzar_captura_punto)
        return False

    def _lanzar_captura_punto(self):
        ventana_principal = getattr(self, '_ventana_principal_para_captura', None)
        punto = None
        nombre_ventana = ''
        try:
            punto = _capturar_punto_pantalla()
            # Se resuelve la ventana bajo el punto aquí, antes de restaurar: la ventana principal recolocada podría
            # quedar bajo el cursor y robarle el resultado.
            if punto is not None:
                _, _, nombre_ventana = _resolver_ventana_bajo_punto(*punto)
        except Exception as excepcion:
            _registrar_error('Elegir punto en la pantalla', excepcion)
        finally:
            # La restauración va en "finally": ocurre aunque _capturar_punto_pantalla() lance una excepción.
            if ventana_principal is not None:
                ventana_principal.deiconify()
                ventana_principal.present()
                ventana_principal.set_skip_taskbar_hint(False)
                ventana_principal.set_skip_pager_hint(False)
            # El diálogo nunca se ocultó: basta devolverlo a su sitio y hacerlo opaco (sin show()/hide()).
            pos = getattr(self, '_posicion_previa_captura', None)
            if pos is not None:
                self.move(*pos)
            self.set_opacity(1)
            self.present()
            self._captura_en_curso = False

        if punto is not None:
            x_abs, y_abs = int(round(punto[0])), int(round(punto[1]))
            self.spin_x_clic.set_value(max(0, x_abs))
            self.spin_y_clic.set_value(max(0, y_abs))
            # Una captura nueva siempre da coordenadas absolutas, aunque el paso viniera de una versión antigua.
            self._coords_absolutas_actual = True
            if nombre_ventana:
                self.label_punto_detectado.set_text(tr('✔ Punto capturado: ({x}, {y}) — sobre la ventana «{window}».').format(x=x_abs, y=y_abs, window=nombre_ventana))
                # Si más tarde se activa «Activar ventana antes de hacer clic», el buscador ya queda listo con esta.
                self.entry_buscar_clic.set_text(nombre_ventana)
            else:
                self.label_punto_detectado.set_text((tr('✔ Punto capturado: ({x}, {y}).').format(x=x_abs, y=y_abs)))
        else:
            self.label_punto_detectado.set_text(tr(
                '⚠ No se pudo leer la posición del ratón (¿xdotool instalado?). '
                'Vuelve a pulsar «Elegir punto en la pantalla…» para intentarlo de nuevo.'))
        return False

    def _crear_pagina_tecla(self):
        grid = Gtk.Grid(column_spacing=12, row_spacing=8)
        grid.set_border_width(6)
        selector, self.combo_objetivo_tecla, self.entry_buscar_tecla = self._crear_selector_objetivo(None)
        grid.attach(selector, 0, 0, 3, 1)
        self.entry_combinacion = Gtk.Entry()
        self.entry_combinacion.set_placeholder_text(tr('Ej: Alt+F10'))
        _fila_grid(grid, 1, tr('Tecla / combinación:'), self.entry_combinacion)
        btn_capturar_tecla = Gtk.Button(label=tr('⌨  Capturar pulsando…'))
        btn_capturar_tecla.connect('clicked', self._on_capturar_tecla)
        grid.attach(btn_capturar_tecla, 1, 2, 2, 1)
        self.label_tecla_capturada = Gtk.Label(label='')
        self.label_tecla_capturada.set_line_wrap(True)
        self.label_tecla_capturada.set_halign(Gtk.Align.START)
        grid.attach(self.label_tecla_capturada, 0, 3, 3, 1)
        ayuda = Gtk.Label(label=tr('💡 También puedes escribirla tú mismo en el campo de arriba, sin '
                                 'necesidad de capturarla: por ejemplo Alt+F10, Ctrl+Shift+Esc o '
                                 'Super+D (Super es la tecla del logo de Windows). Varias teclas '
                                 'unidas con "+" forman una combinación; añade varios pasos de este '
                                 'tipo para enviarlas en secuencia, una detrás de otra.'))
        ayuda.set_line_wrap(True)
        ayuda.set_halign(Gtk.Align.START)
        grid.attach(ayuda, 0, 4, 3, 1)
        self.stack.add_titled(grid, 'tecla', _texto_tipo('tecla'))

    def _on_capturar_tecla(self, widget):
        """Abre el diálogo de captura en vivo (ver _capturar_combinacion_teclado) y vuelca el resultado, si lo hay,
        en el campo de la combinación."""
        try:
            combinacion = _capturar_combinacion_teclado(self)
        except Exception as excepcion:
            _registrar_error('Capturar tecla en vivo', excepcion)
            self.label_tecla_capturada.set_text(f"⚠ {tr('No se pudo capturar la tecla:')} {excepcion}")
            return
        if combinacion:
            self.entry_combinacion.set_text(combinacion)
            self.label_tecla_capturada.set_text(f"{tr('✔ Capturado:')} {combinacion}")
        else:
            self.label_tecla_capturada.set_text(tr('Captura cancelada.'))

    def _crear_pagina_texto(self):
        grid = Gtk.Grid(column_spacing=12, row_spacing=8)
        grid.set_border_width(6)
        selector, self.combo_objetivo_texto, self.entry_buscar_texto = self._crear_selector_objetivo(None)
        grid.attach(selector, 0, 0, 3, 1)
        self.entry_texto = Gtk.Entry()
        self.entry_texto.set_placeholder_text(tr('Texto que se escribirá donde esté el cursor/foco'))
        _fila_grid(grid, 1, tr('Texto a escribir:'), self.entry_texto)
        self.stack.add_titled(grid, 'texto', _texto_tipo('texto'))

    # -- eventos internos ----------------------------------------------------
    def _on_cambio_tipo(self, combo):
        tipo = combo.get_active_id()
        if tipo:
            self.stack.set_visible_child_name(tipo)
            if hasattr(self, 'btn_probar_paso'):
                # "Probar este paso ahora" es genérico: genera y ejecuta un script de un solo paso, sea cual sea su tipo.
                self.btn_probar_paso.set_visible(tipo != 'esperar')

    def _mostrar_info_prueba(self, texto, es_error=False):
        dialogo = Gtk.MessageDialog(
            transient_for=self, flags=0,
            message_type=Gtk.MessageType.ERROR if es_error else Gtk.MessageType.INFO,
            buttons=Gtk.ButtonsType.OK, text=tr(texto))
        dialogo.run()
        dialogo.destroy()

    def _on_probar_paso(self, widget):
        """Valida y ejecuta SOLO el paso en edición (con su colocación de ventana), sin guardar nada. Corre en
        segundo plano (GLib.timeout_add, sin bloquear la interfaz) y al terminar muestra el registro."""
        try:
            paso, error = self.validar_y_construir()
        except Exception as excepcion:
            _registrar_error('Probar este paso (validación)', excepcion)
            self._mostrar_info_prueba(tr('Error al leer los datos del paso:\n{error}').format(error=excepcion), es_error=True)
            return
        if error:
            self._mostrar_info_prueba(error, es_error=True)
            return

        try:
            script = generar_script_bash([paso], tr('Prueba de paso'))
            fd, ruta_script = tempfile.mkstemp(prefix='prueba_paso_', suffix='.sh', dir=_dir_temporal())
            with os.fdopen(fd, 'w', encoding='utf-8') as f:
                f.write(script)
            os.chmod(ruta_script, 0o755)
            fd_log, ruta_log = tempfile.mkstemp(prefix='prueba_paso_', suffix='.log', dir=_dir_temporal())
            os.close(fd_log)
        except Exception as excepcion:
            _registrar_error('Probar este paso (preparación)', excepcion)
            self._mostrar_info_prueba(tr('No se pudo preparar la prueba:\n{error}').format(error=excepcion), es_error=True)
            return

        etiqueta_original = widget.get_label()
        widget.set_sensitive(False)
        widget.set_label(tr('⏳ Probando…'))
        try:
            with open(ruta_log, 'w', encoding='utf-8') as log_f:
                proceso = subprocess.Popen(['bash', ruta_script], stdout=subprocess.DEVNULL,
                                            stderr=log_f, start_new_session=True)
        except Exception as excepcion:
            _registrar_error('Probar este paso (ejecución)', excepcion)
            widget.set_sensitive(True)
            widget.set_label(etiqueta_original)
            self._mostrar_info_prueba(tr('No se pudo ejecutar la prueba:\n{error}').format(error=excepcion), es_error=True)
            return

        def _revisar(*_args):
            try:
                if proceso.poll() is None:
                    return True  # seguir comprobando
                try:
                    widget.set_sensitive(True)
                    widget.set_label(etiqueta_original)
                except Exception:
                    pass
                try:
                    with open(ruta_log, 'r', encoding='utf-8', errors='ignore') as f:
                        salida = f.read().strip()
                except Exception:
                    salida = ''
                texto = salida or tr('(sin mensajes; revisa visualmente si la ventana se colocó donde esperabas)')
                try:
                    self._mostrar_info_prueba(tr('Resultado de la prueba:\n\n{result}').format(result=texto))
                except Exception:
                    pass
            except Exception as excepcion:
                _registrar_error('Probar este paso (revisión)', excepcion)
            return False

        GLib.timeout_add(300, _revisar)

    def _on_cambio_posicion(self, combo):
        self.caja_personalizada.set_visible(combo.get_active_id() == 'personalizada')

    # -- carga de un paso existente para editar ------------------------------
    def _cargar_paso(self, paso):
        tipo = paso.get('tipo')
        if tipo not in ORDEN_TIPOS_PASO:  # sin tipo o desconocido (JSON a mano): se abre como «programa» para rehacerlo
            tipo = 'programa'
        self.combo_tipo.set_active_id(tipo)
        if tipo == 'programa':
            modo = paso.get('modo', 'manual')
            if modo == 'instalado' and paso.get('ruta_desktop'):
                self.stack_programa.set_visible_child_name('instalado')
                self.entry_app_instalada.set_text(paso.get('nombre_detectado', ''))
                self._ruta_app_seleccionada = paso.get('ruta_desktop')
            else:
                self.stack_programa.set_visible_child_name('manual')
                ruta_manual = paso.get('ruta_desktop') if modo == 'desktop' else paso.get('ruta')
                if ruta_manual:
                    self.chooser_programa.set_filename(ruta_manual)
                self.entry_argumentos.set_text(paso.get('argumentos', '') or '')
            self.entry_alias_programa.set_text(paso.get('alias', '') or '')
            self.spin_espera_programa.set_value(paso.get('espera', 2.5))
            self._fijar_colocar_ventana('programa', paso)
        elif tipo == 'documento':
            ruta_doc = paso.get('ruta', '')
            if ruta_doc:
                self.chooser_documento.set_filename(ruta_doc)
            abrir_con_app = paso.get('abrir_con') == 'app'
            self.check_abrir_con_app.set_active(abrir_con_app)
            self.entry_app_documento.set_sensitive(abrir_con_app)
            if abrir_con_app:
                self.entry_app_documento.set_text(paso.get('nombre_detectado', ''))
                self._ruta_app_documento_seleccionada = paso.get('ruta_desktop')
            self.entry_alias_documento.set_text(paso.get('alias', '') or '')
            self.spin_espera_documento.set_value(paso.get('espera', 2.5))
            self._fijar_colocar_ventana('documento', paso)
        elif tipo == 'web':
            self.entry_url.set_text(paso.get('url', ''))
            _fijar_id_combo(self.combo_navegador, paso.get('navegador') or 'sistema')
            self.check_nueva_ventana.set_active(paso.get('nueva_ventana', False))
            self.check_modo_app.set_active(paso.get('modo_app', False))
            self.entry_alias_web.set_text(paso.get('alias', '') or '')
            self.spin_espera_web.set_value(paso.get('espera', 3.0))
            self._fijar_colocar_ventana('web', paso)
        elif tipo == 'comando':
            self.entry_comando.set_text(paso.get('comando', ''))
            self.entry_alias_comando.set_text(paso.get('alias', '') or '')
            self.spin_espera_comando.set_value(paso.get('espera', 2.5))
            self._fijar_colocar_ventana('comando', paso)
        elif tipo == 'esperar':
            self.spin_segundos_esperar.set_value(paso.get('segundos', 2))
        elif tipo == 'ventana':
            self._fijar_objetivo(self.combo_objetivo_ventana, self.entry_buscar_ventana, paso)
            self.combo_posicion.set_active_id(paso.get('accion_ventana', 'maximizar'))
            self.spin_pers_x.set_value(paso.get('personalizada_x', 0))
            self.spin_pers_y.set_value(paso.get('personalizada_y', 0))
            self.spin_pers_w.set_value(paso.get('personalizada_w', 50))
            self.spin_pers_h.set_value(paso.get('personalizada_h', 50))
        elif tipo == 'clic':
            activar = bool(paso.get('activar_ventana', False))
            self.check_activar_ventana_clic.set_active(activar)
            self._fijar_objetivo(self.combo_objetivo_clic, self.entry_buscar_clic, paso)
            self.spin_x_clic.set_value(paso.get('x', 100))
            self.spin_y_clic.set_value(paso.get('y', 100))
            _fijar_id_combo(self.combo_boton, str(paso.get('boton', '1')))
            self.check_doble_clic.set_active(paso.get('doble', False))
            # Recuerda si el paso venía con coordenadas relativas (formato antiguo) para no reinterpretarlas como
            # absolutas al guardar sin recapturar el punto.
            self._coords_absolutas_actual = paso.get('coords_absolutas', True)
            if not self._coords_absolutas_actual:
                self.label_punto_detectado.set_text(tr(
                    '⚠ Este paso usa coordenadas de una versión antigua (relativas a la ventana '
                    'activada). Vuelve a pulsar «Elegir punto en la pantalla…» para pasarlas a '
                    'coordenadas absolutas, o déjalo así si prefieres mantener el comportamiento '
                    'anterior.'))
        elif tipo == 'tecla':
            self._fijar_objetivo(self.combo_objetivo_tecla, self.entry_buscar_tecla, paso)
            self.entry_combinacion.set_text(paso.get('combinacion', ''))
        elif tipo == 'texto':
            self._fijar_objetivo(self.combo_objetivo_texto, self.entry_buscar_texto, paso)
            self.entry_texto.set_text(paso.get('texto', ''))
        self.stack.set_visible_child_name(tipo)

    # -- validación y construcción del paso resultado ------------------------
    def validar_y_construir(self):
        tipo = self.combo_tipo.get_active_id()
        paso = {'tipo': tipo}
        if tipo == 'programa':
            modo_activo = self.stack_programa.get_visible_child_name() or 'instalado'
            if modo_activo == 'instalado':
                ruta_desktop = self._resolver_ruta_app_seleccionada()
                texto = self.entry_app_instalada.get_text().strip()
                if not ruta_desktop:
                    return None, tr('Elige una aplicación de la lista (escribe y selecciona una '
                                    'sugerencia), o usa la pestaña "Ruta / comando manual".')
                paso['modo'] = 'instalado'
                paso['ruta_desktop'] = ruta_desktop
                paso['nombre_detectado'] = texto
                nombre_base = texto
            else:
                ruta = self.chooser_programa.get_filename()
                if not ruta:
                    return None, tr('Selecciona el ejecutable o el acceso directo (.desktop) del programa.')
                if ruta.endswith('.desktop'):
                    paso['modo'] = 'desktop'
                    paso['ruta_desktop'] = ruta
                    info = _parsear_desktop_entry(ruta)
                    paso['nombre_detectado'] = (info or {}).get('nombre') or os.path.splitext(os.path.basename(ruta))[0]
                    nombre_base = paso['nombre_detectado']
                else:
                    paso['modo'] = 'manual'
                    paso['ruta'] = ruta
                    paso['argumentos'] = self.entry_argumentos.get_text().strip()
                    nombre_base = os.path.basename(ruta)
            error = self._leer_apertura(paso, self.entry_alias_programa, self.spin_espera_programa, nombre_base)
            if error:
                return None, error
        elif tipo == 'documento':
            ruta_doc = self.chooser_documento.get_filename()
            if not ruta_doc:
                return None, tr('Selecciona el documento o archivo a abrir (con el explorador de archivos).')
            if not os.path.isfile(ruta_doc):
                return None, tr('No se encuentra el archivo:\n{path}\n\n¿Se ha movido o borrado?').format(path=ruta_doc)
            paso['ruta'] = ruta_doc
            nombre_base = os.path.basename(ruta_doc)
            if self.check_abrir_con_app.get_active():
                ruta_desktop_app = self._resolver_ruta_app_desde(
                    self.entry_app_documento, self._ruta_app_documento_seleccionada)
                if not ruta_desktop_app:
                    return None, tr('Elige una aplicación de la lista para abrir el documento (escribe y selecciona una sugerencia), o desmarca "Abrir con una aplicación instalada concreta" para usar la predeterminada del sistema.')
                paso['abrir_con'] = 'app'
                paso['ruta_desktop'] = ruta_desktop_app
                info = _parsear_desktop_entry(ruta_desktop_app) or {}
                paso['nombre_detectado'] = info.get('nombre') or self.entry_app_documento.get_text().strip()
            else:
                paso['abrir_con'] = 'sistema'
            error = self._leer_apertura(paso, self.entry_alias_documento, self.spin_espera_documento, nombre_base)
            if error:
                return None, error
        elif tipo == 'web':
            url = self.entry_url.get_text().strip()
            if not url:
                return None, tr('Escribe la URL del sitio web.')
            if not RE_ESQUEMA_URL.match(url):
                url = 'https://' + url
            host = _host_de_url(url)
            if host is None:
                return None, tr('La URL no es válida:\n{url}').format(url=url)
            paso['url'] = url
            paso['navegador'] = self.combo_navegador.get_active_id() or 'sistema'
            paso['nueva_ventana'] = self.check_nueva_ventana.get_active()
            paso['modo_app'] = self.check_modo_app.get_active()
            error = self._leer_apertura(paso, self.entry_alias_web, self.spin_espera_web, host or 'web')
            if error:
                return None, error
        elif tipo == 'comando':
            comando = self.entry_comando.get_text().strip()
            if not comando:
                return None, tr('Escribe el comando a ejecutar.')
            paso['comando'] = comando
            error = self._leer_apertura(paso, self.entry_alias_comando, self.spin_espera_comando, comando.split()[0])
            if error:
                return None, error
        elif tipo == 'esperar':
            paso['segundos'] = round(self.spin_segundos_esperar.get_value(), 1)
        elif tipo == 'ventana':
            self._leer_objetivo(self.combo_objetivo_ventana, self.entry_buscar_ventana, paso)
            paso['accion_ventana'] = self.combo_posicion.get_active_id()
            if paso['accion_ventana'] == 'personalizada':
                paso['personalizada_x'] = int(self.spin_pers_x.get_value())
                paso['personalizada_y'] = int(self.spin_pers_y.get_value())
                paso['personalizada_w'] = int(self.spin_pers_w.get_value())
                paso['personalizada_h'] = int(self.spin_pers_h.get_value())
                error_rango = _validar_rango_personalizada(paso)
                if error_rango:
                    return None, error_rango
        elif tipo == 'clic':
            paso['activar_ventana'] = self.check_activar_ventana_clic.get_active()
            if paso['activar_ventana']:
                self._leer_objetivo(self.combo_objetivo_clic, self.entry_buscar_clic, paso)
            paso['x'] = int(self.spin_x_clic.get_value())
            paso['y'] = int(self.spin_y_clic.get_value())
            paso['coords_absolutas'] = getattr(self, '_coords_absolutas_actual', True)
            paso['boton'] = self.combo_boton.get_active_id()
            paso['doble'] = self.check_doble_clic.get_active()
        elif tipo == 'tecla':
            self._leer_objetivo(self.combo_objetivo_tecla, self.entry_buscar_tecla, paso)
            combinacion = self.entry_combinacion.get_text().strip()
            if not combinacion:
                return None, tr('Escribe la tecla o combinación a enviar (ej: ctrl+t).')
            paso['combinacion'] = combinacion
        elif tipo == 'texto':
            self._leer_objetivo(self.combo_objetivo_texto, self.entry_buscar_texto, paso)
            texto = self.entry_texto.get_text()
            if not texto:
                return None, tr('Escribe el texto a simular con el teclado.')
            paso['texto'] = texto
        if paso.get('objetivo_modo') == '_buscar' and not paso.get('objetivo_buscar'):
            return None, tr('Escribe el título (o parte del título) de la ventana que quieres buscar.')
        return paso, None


class VentanaPrincipal(Gtk.Window):
    def __init__(self):
        super().__init__(title=tr('Mi Lanzador'))
        self.set_default_size(980, 680)
        self.set_icon_name('mi-lanzador')
        self.editando_id = None
        self.pasos_actual = []

        self._aplicar_estilos()

        header = Gtk.HeaderBar()
        header.set_show_close_button(True)
        header.props.title = tr('Mi Lanzador')
        header.props.subtitle = tr('Automatiza tus accesos directos')
        self.set_titlebar(header)

        self.btn_idioma = Gtk.Button(label='L')
        self.btn_idioma.set_tooltip_text(tr('Cambiar idioma (L)'))
        self.btn_idioma.connect('clicked', self._on_cambiar_idioma)
        self.btn_idioma.set_size_request(34, -1)
        header.pack_end(self.btn_idioma)

        boton_rapido = Gtk.Button()
        boton_rapido.add(Gtk.Image.new_from_icon_name('list-add-symbolic', Gtk.IconSize.BUTTON))
        boton_rapido.set_tooltip_text(tr('Crear nueva acción'))
        boton_rapido.connect('clicked', lambda w: self.ir_a_tab_nueva())
        header.pack_end(boton_rapido)

        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.add(vbox)

        self.notebook = Gtk.Notebook()
        self.notebook.set_tab_pos(Gtk.PositionType.TOP)
        vbox.pack_start(self.notebook, True, True, 0)

        self.notebook.append_page(self._crear_tab_lista(), Gtk.Label(label=tr('🚀 Mis accesos')))
        self.notebook.append_page(self._crear_tab_nueva(), Gtk.Label(label=tr('➕ Nueva acción')))
        self.notebook.append_page(self._crear_tab_ajustes(), Gtk.Label(label=tr('⚙️ Ajustes')))

        self.connect('destroy', Gtk.main_quit)
        self.connect('delete-event', lambda w, e: not self._confirmar_descartar())
        self.connect('key-press-event', self._on_tecla_idioma)
        self.cargar_lista()

    def _hay_cambios_sin_guardar(self):
        return bool(self.pasos_actual or self.entry_nombre.get_text().strip() or self.editando_id)

    def _confirmar_descartar(self, texto=None):
        """True si el formulario no tiene nada que perder o el usuario acepta descartarlo."""
        if not self._hay_cambios_sin_guardar():
            return True
        dialogo = Gtk.MessageDialog(transient_for=self, flags=0, message_type=Gtk.MessageType.QUESTION,
                                     buttons=Gtk.ButtonsType.YES_NO,
                                     text=texto or tr('Hay cambios sin guardar en el formulario. ¿Descartarlos y continuar?'))
        respuesta = dialogo.run()
        dialogo.destroy()
        return respuesta == Gtk.ResponseType.YES

    def _alias_en_uso(self, excepto=None):
        """Alias de los pasos del formulario, salvo el del índice `excepto` (el paso que se edita)."""
        return {p['alias'] for i, p in enumerate(self.pasos_actual)
                if i != excepto and p.get('tipo') in TIPOS_CON_VENTANA and p.get('alias')}

    def _on_tecla_idioma(self, widget, evento):
        # MOD1_MASK es Alt en GTK3; ALT_MASK no existe y lanzaría AttributeError.
        if evento.state & (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.MOD1_MASK | Gdk.ModifierType.SUPER_MASK | Gdk.ModifierType.SHIFT_MASK):
            return False
        if evento.keyval not in (Gdk.KEY_l, Gdk.KEY_L):
            return False
        foco = self.get_focus()
        # Las listas buscan al escribir («l» salta a «Lanzar…»): ahí la tecla no es un atajo.
        if isinstance(foco, (Gtk.Entry, Gtk.TextView, Gtk.SearchEntry, Gtk.TreeView)):
            return False
        self._on_cambiar_idioma(self.btn_idioma)
        return True

    def _on_cambiar_idioma(self, widget):
        nuevo = 'en' if IDIOMA == 'es' else 'es'
        if not self._confirmar_descartar(tr('Cambiar el idioma reiniciará la interfaz y descartará los cambios no guardados. ¿Continuar?')):
            return
        if not guardar_idioma(nuevo):  # sin guardar, reiniciar solo descartaría el trabajo sin cambiar nada
            self.mostrar_dialogo_error(tr('No se pudo guardar el idioma. Detalles en:\n{log}').format(log=ERROR_LOG_FILE))
            return
        os.environ.pop('MI_LANZADOR_LANG', None)  # el forzado es «de un solo lanzamiento»: no puede anular lo recién guardado
        os.execv('/bin/bash', ['/bin/bash', APP_SCRIPT_PATH])

    # -- estilos -------------------------------------------------------
    def _aplicar_estilos(self):
        proveedor = Gtk.CssProvider()
        proveedor.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), proveedor, Gtk.STYLE_PROVIDER_PRIORITY_USER
        )

    # -- pestaña: lista de acciones ------------------------------------
    def _crear_tab_lista(self):
        contenedor = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        contenedor.set_border_width(16)

        etiqueta = Gtk.Label(label=tr('Tus accesos configurados'))
        etiqueta.get_style_context().add_class('titulo-form')
        etiqueta.set_halign(Gtk.Align.START)
        contenedor.pack_start(etiqueta, False, False, 0)

        # id, pixbuf, nombre, nº de pasos, resumen
        self.store = Gtk.ListStore(str, GdkPixbuf.Pixbuf, str, str, str)
        self.tree = Gtk.TreeView(model=self.store)
        self.tree.set_headers_visible(True)
        self.tree.connect('row-activated', self._on_fila_doble_clic)

        col_icono = Gtk.TreeViewColumn('', Gtk.CellRendererPixbuf(), pixbuf=1)
        self.tree.append_column(col_icono)

        col_nombre = Gtk.TreeViewColumn(tr('Nombre'), Gtk.CellRendererText(), text=2)
        col_nombre.set_expand(True)
        self.tree.append_column(col_nombre)

        col_pasos = Gtk.TreeViewColumn(tr('Pasos'), Gtk.CellRendererText(), text=3)
        self.tree.append_column(col_pasos)

        col_detalle = Gtk.TreeViewColumn(tr('Resumen'), Gtk.CellRendererText(), text=4)
        col_detalle.set_expand(True)
        self.tree.append_column(col_detalle)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scroll.add(self.tree)
        scroll.set_vexpand(True)
        contenedor.pack_start(scroll, True, True, 0)

        barra = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)

        def crear_boton(texto, icono_nombre, callback, clase=None):
            b = Gtk.Button()
            caja = Gtk.Box(spacing=6)
            caja.pack_start(Gtk.Image.new_from_icon_name(icono_nombre, Gtk.IconSize.BUTTON), False, False, 0)
            caja.pack_start(Gtk.Label(label=tr(texto)), False, False, 0)
            b.add(caja)
            b.connect('clicked', callback)
            if clase:
                b.get_style_context().add_class(clase)
            return b

        barra.pack_start(crear_boton('Ejecutar', 'media-playback-start-symbolic', self._on_ejecutar, 'suggested-action'), False, False, 0)
        barra.pack_start(crear_boton('Crear acceso directo', 'emblem-symbolic-link', self._on_crear_acceso), False, False, 0)
        barra.pack_start(crear_boton('Editar', 'document-edit-symbolic', self._on_editar), False, False, 0)
        barra.pack_start(crear_boton('Ver script generado', 'text-x-script', self._on_ver_script), False, False, 0)
        barra.pack_start(crear_boton('Eliminar', 'user-trash-symbolic', self._on_eliminar), False, False, 0)

        contenedor.pack_start(barra, False, False, 0)
        return contenedor

    # -- pestaña: nueva acción ------------------------------------------
    def _crear_tab_nueva(self):
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        outer.set_border_width(16)

        self.titulo_form = Gtk.Label(label=tr('Crear nueva acción'))
        self.titulo_form.get_style_context().add_class('titulo-form')
        self.titulo_form.set_halign(Gtk.Align.START)
        outer.pack_start(self.titulo_form, False, False, 0)

        grid_cab = Gtk.Grid(column_spacing=12, row_spacing=8)
        outer.pack_start(grid_cab, False, False, 0)
        f = 0
        self.entry_nombre = Gtk.Entry()
        self.entry_nombre.set_placeholder_text(tr('Ej: Rutina de trabajo, Backup diario, Abrir Gmail y Slack...'))
        f = _fila_grid(grid_cab, f, tr('Nombre de la acción:'), self.entry_nombre)
        self.chooser_icono = Gtk.FileChooserButton(title=tr('Selecciona un icono'), action=Gtk.FileChooserAction.OPEN)
        filtro = Gtk.FileFilter()
        filtro.set_name(tr('Imágenes'))
        for patron in ('*.png', '*.svg', '*.jpg', '*.jpeg', '*.ico', '*.xpm'):
            filtro.add_pattern(patron)
        self.chooser_icono.add_filter(filtro)
        self.chooser_icono.set_filter(filtro)
        f = _fila_grid(grid_cab, f, tr('Icono personalizado (opcional):'), self.chooser_icono)

        etiqueta_pasos = Gtk.Label(label=tr('Pasos de esta acción (se ejecutan en el orden mostrado):'))
        etiqueta_pasos.set_halign(Gtk.Align.START)
        outer.pack_start(etiqueta_pasos, False, False, 4)

        # nº, tipo legible, resumen
        self.store_pasos = Gtk.ListStore(int, str, str)
        self.tree_pasos = Gtk.TreeView(model=self.store_pasos)
        self.tree_pasos.connect('row-activated', lambda *_: self._on_editar_paso(None))
        col_n = Gtk.TreeViewColumn('#', Gtk.CellRendererText(), text=0)
        self.tree_pasos.append_column(col_n)
        col_tipo = Gtk.TreeViewColumn(tr('Tipo'), Gtk.CellRendererText(), text=1)
        self.tree_pasos.append_column(col_tipo)
        col_resumen = Gtk.TreeViewColumn(tr('Detalle'), Gtk.CellRendererText(), text=2)
        col_resumen.set_expand(True)
        self.tree_pasos.append_column(col_resumen)

        scroll_pasos = Gtk.ScrolledWindow()
        scroll_pasos.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scroll_pasos.add(self.tree_pasos)
        scroll_pasos.set_vexpand(True)
        scroll_pasos.set_min_content_height(220)
        outer.pack_start(scroll_pasos, True, True, 0)

        barra_pasos = Gtk.Box(spacing=8)
        btn_add = Gtk.Button(label=tr('➕ Añadir paso'))
        btn_add.get_style_context().add_class('suggested-action')
        btn_add.connect('clicked', self._on_anadir_paso)
        btn_editar_paso = Gtk.Button(label=tr('Editar paso'))
        btn_editar_paso.connect('clicked', self._on_editar_paso)
        btn_quitar_paso = Gtk.Button(label=tr('Eliminar paso'))
        btn_quitar_paso.connect('clicked', self._on_quitar_paso)
        btn_subir = Gtk.Button(label=tr('⬆ Subir'))
        btn_subir.connect('clicked', self._on_subir_paso)
        btn_bajar = Gtk.Button(label=tr('⬇ Bajar'))
        btn_bajar.connect('clicked', self._on_bajar_paso)
        barra_pasos.pack_start(btn_add, False, False, 0)
        barra_pasos.pack_start(btn_editar_paso, False, False, 0)
        barra_pasos.pack_start(btn_quitar_paso, False, False, 0)
        barra_pasos.pack_start(btn_subir, False, False, 0)
        barra_pasos.pack_start(btn_bajar, False, False, 0)
        outer.pack_start(barra_pasos, False, False, 0)

        barra_botones = Gtk.Box(spacing=8)
        self.btn_guardar = Gtk.Button(label=tr('💾 Guardar acción'))
        self.btn_guardar.get_style_context().add_class('suggested-action')
        self.btn_guardar.connect('clicked', self._on_guardar_accion)
        btn_limpiar = Gtk.Button(label=tr('Limpiar formulario'))
        btn_limpiar.connect('clicked', lambda w: self.limpiar_formulario())
        barra_botones.pack_start(self.btn_guardar, False, False, 0)
        barra_botones.pack_start(btn_limpiar, False, False, 0)
        outer.pack_start(barra_botones, False, False, 10)

        return outer

    # -- pestaña: ajustes -------------------------------------------------
    def _crear_tab_ajustes(self):
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        outer.set_border_width(16)

        titulo = Gtk.Label(label=tr('Ajustes generales'))
        titulo.get_style_context().add_class('titulo-form')
        titulo.set_halign(Gtk.Align.START)
        outer.pack_start(titulo, False, False, 0)

        idioma_label = Gtk.Label(label=tr('Idioma de la interfaz:'))
        idioma_label.set_halign(Gtk.Align.START)
        idioma_value = Gtk.Label(label=NOMBRES_IDIOMA.get(IDIOMA, 'English'))
        idioma_value.set_halign(Gtk.Align.START)
        idioma_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        idioma_box.pack_start(idioma_label, False, False, 0)
        idioma_box.pack_start(idioma_value, False, False, 0)
        outer.pack_start(idioma_box, False, False, 0)

        ajustes = cargar_ajustes()
        grid = Gtk.Grid(column_spacing=12, row_spacing=12)
        outer.pack_start(grid, False, False, 0)

        grid.attach(Gtk.Label(label=tr("Navegador predeterminado para 'Sitio web':"), halign=Gtk.Align.END), 0, 0, 1, 1)
        self.combo_navegador_defecto = Gtk.ComboBoxText()
        for clave, info in NAVEGADORES.items():
            self.combo_navegador_defecto.append(clave, tr(info['nombre']))
        _fijar_id_combo(self.combo_navegador_defecto, ajustes.get('navegador_predeterminado') or 'sistema')
        grid.attach(self.combo_navegador_defecto, 1, 0, 1, 1)

        self.check_auto_acceso = Gtk.CheckButton(
            label=tr('Crear automáticamente un acceso directo en el Escritorio al guardar una acción nueva'))
        self.check_auto_acceso.set_active(ajustes.get('crear_acceso_automatico', False))
        grid.attach(self.check_auto_acceso, 0, 1, 2, 1)

        self.check_notificaciones = Gtk.CheckButton(label=tr('Mostrar notificaciones al ejecutar una acción'))
        self.check_notificaciones.set_active(ajustes.get('notificaciones', True))
        grid.attach(self.check_notificaciones, 0, 2, 2, 1)

        grid.attach(Gtk.Label(label=tr('Carpeta de configuración:'), halign=Gtk.Align.END), 0, 3, 1, 1)
        caja_carpeta = Gtk.Box(spacing=6)
        etiqueta_carpeta = Gtk.Label(label=CONFIG_DIR)
        etiqueta_carpeta.set_selectable(True)
        caja_carpeta.pack_start(etiqueta_carpeta, False, False, 0)
        btn_abrir_carpeta = Gtk.Button(label=tr('Abrir'))
        btn_abrir_carpeta.connect('clicked', lambda w: subprocess.Popen(['xdg-open', CONFIG_DIR]))
        caja_carpeta.pack_start(btn_abrir_carpeta, False, False, 0)
        grid.attach(caja_carpeta, 1, 3, 1, 1)

        herramientas = herramientas_x11_disponibles()
        if herramientas['xdotool'] and herramientas['wmctrl']:
            estado = tr('✅ Disponibles')
        else:
            faltan = ', '.join(k for k, v in herramientas.items() if not v)
            estado = tr('⚠ Faltan: {tools}').format(tools=faltan)
        herramientas_label = tr('xdotool / wmctrl (ventanas, clics, teclas):')
        grid.attach(Gtk.Label(label=herramientas_label, halign=Gtk.Align.END), 0, 4, 1, 1)
        caja_x11 = Gtk.Box(spacing=8)
        self.etiqueta_estado_x11 = Gtk.Label(label=estado)
        self.etiqueta_estado_x11.set_halign(Gtk.Align.START)
        caja_x11.pack_start(self.etiqueta_estado_x11, False, False, 0)
        self.btn_instalar_x11 = Gtk.Button(label=tr('🔧 Instalar ahora'))
        self.btn_instalar_x11.set_no_show_all(True)
        self.btn_instalar_x11.set_visible(not (herramientas['xdotool'] and herramientas['wmctrl']))
        self.btn_instalar_x11.connect('clicked', self._on_instalar_x11)
        caja_x11.pack_start(self.btn_instalar_x11, False, False, 0)
        grid.attach(caja_x11, 1, 4, 1, 1)

        btn_guardar_ajustes = Gtk.Button(label=tr('💾 Guardar ajustes'))
        btn_guardar_ajustes.get_style_context().add_class('suggested-action')
        btn_guardar_ajustes.connect('clicked', self._on_guardar_ajustes)
        outer.pack_start(btn_guardar_ajustes, False, False, 10)

        outer.pack_start(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL), False, False, 6)

        acerca = Gtk.Label()
        acerca.set_markup(tr(
            '<small>Mi Lanzador {version} · Crea accesos directos que encadenan programas, sitios web, comandos,\n'
            'esperas, posicionamiento de ventanas, clics y teclas. Todos tus datos se guardan\n'
            'localmente en tu carpeta de configuración.\n'
            'Programador: Filonux</small>').format(version=VERSION))
        acerca.set_halign(Gtk.Align.START)
        outer.pack_start(acerca, False, False, 0)

        return outer

    # -- helpers de datos / lista -----------------------------------------
    def cargar_lista(self):
        self.store.clear()
        for accion in cargar_acciones():
            pixbuf = obtener_pixbuf(accion)
            pasos = accion.get('pasos', [])
            self.store.append([accion.get('id', ''), pixbuf, accion.get('nombre', ''),
                                str(len(pasos)), resumen_pasos(pasos)])
        if AVISOS_DATOS:
            GLib.idle_add(self._mostrar_avisos_datos)

    def _mostrar_avisos_datos(self):
        if AVISOS_DATOS:  # varias llamadas encoladas: solo la primera encuentra avisos
            texto = '\n\n'.join(AVISOS_DATOS)
            del AVISOS_DATOS[:]
            self.mostrar_dialogo_error(texto)
        return False

    def refrescar_store_pasos(self):
        self.store_pasos.clear()
        for i, paso in enumerate(self.pasos_actual, start=1):
            self.store_pasos.append([i, _texto_tipo(paso.get('tipo')), resumen_paso(paso)])

    def obtener_seleccion(self):
        seleccion = self.tree.get_selection()
        modelo, iterador = seleccion.get_selected()
        if iterador is None:
            self.mostrar_dialogo_error(tr('Selecciona primero una acción de la lista.'))
            return None
        return self._accion_de_fila(modelo[iterador][0])

    def _accion_de_fila(self, id_accion):
        accion = _accion_por_id(id_accion)
        if accion is None:
            self.cargar_lista()  # ya no está en el archivo: se retira la fila
        return accion

    def obtener_indice_paso_seleccionado(self):
        seleccion = self.tree_pasos.get_selection()
        modelo, iterador = seleccion.get_selected()
        if iterador is None:
            return None
        path = modelo.get_path(iterador)
        return path.get_indices()[0]

    def obtener_dir_escritorio(self):
        return _dir_escritorio()

    def limpiar_formulario(self):
        self.entry_nombre.set_text('')
        self.chooser_icono.unselect_all()
        self.pasos_actual = []
        self.refrescar_store_pasos()
        self.editando_id = None
        self.btn_guardar.set_label(tr('💾 Guardar acción'))

    def ir_a_tab_nueva(self):
        if self.editando_id:
            if not self._confirmar_descartar():
                return
            self.limpiar_formulario()
        self.notebook.set_current_page(1)

    def crear_acceso_para(self, accion):
        dialogo = Gtk.Dialog(title=tr('Crear acceso directo'), transient_for=self, flags=0)
        dialogo.add_buttons(tr('Cancelar'), Gtk.ResponseType.CANCEL, tr('Crear'), Gtk.ResponseType.OK)
        area = dialogo.get_content_area()
        area.set_border_width(14)
        area.set_spacing(8)
        etiqueta = Gtk.Label(label=tr('¿Dónde quieres crear el acceso directo de "{name}"?').format(name=accion.get('nombre', '')))
        etiqueta.set_halign(Gtk.Align.START)
        area.add(etiqueta)
        check_escritorio = Gtk.CheckButton(label=tr('Escritorio'))
        check_escritorio.set_active(True)
        check_menu = Gtk.CheckButton(label=tr('Menú de aplicaciones'))
        area.add(check_escritorio)
        area.add(check_menu)

        def _actualizar_crear(_boton=None):  # sin ningún destino marcado «Crear» no haría nada (y sin avisar)
            dialogo.set_response_sensitive(Gtk.ResponseType.OK, check_escritorio.get_active() or check_menu.get_active())
        check_escritorio.connect('toggled', _actualizar_crear)
        check_menu.connect('toggled', _actualizar_crear)
        dialogo.show_all()
        respuesta = dialogo.run()
        destinos = []
        if respuesta == Gtk.ResponseType.OK:
            if check_escritorio.get_active():
                destinos.append(self.obtener_dir_escritorio())
            if check_menu.get_active():
                destinos.append(os.path.expanduser('~/.local/share/applications'))
        dialogo.destroy()
        if destinos:
            rutas = crear_acceso_directo(accion, destinos)
            if len(rutas) < len(destinos):
                self.mostrar_dialogo_error(tr('No se pudo crear el acceso directo en todas las ubicaciones elegidas. Detalles en:\n{log}').format(log=ERROR_LOG_FILE))
            if rutas:
                notificar(tr('Acceso directo creado para "{name}".').format(name=accion.get('nombre', '')))
                self.mostrar_dialogo_info(tr(
                    "Si al hacer doble clic te pide 'confiar' o 'permitir ejecución', acepta esa opción "
                    "una sola vez (clic derecho sobre el icono → Propiedades → Permisos → "
                    "'Permitir ejecutar como programa', o 'Confiar y lanzar')."
                ))

    def mostrar_dialogo_error(self, texto):
        texto = tr(texto)
        dialogo = Gtk.MessageDialog(transient_for=self, flags=0, message_type=Gtk.MessageType.ERROR,
                                     buttons=Gtk.ButtonsType.OK, text=texto)
        dialogo.run()
        dialogo.destroy()

    def mostrar_dialogo_info(self, texto):
        texto = tr(texto)
        dialogo = Gtk.MessageDialog(transient_for=self, flags=0, message_type=Gtk.MessageType.INFO,
                                     buttons=Gtk.ButtonsType.OK, text=texto)
        dialogo.run()
        dialogo.destroy()

    def mostrar_dialogo_texto_largo(self, titulo, texto):
        titulo = tr(titulo)
        texto = tr(texto)
        dialogo = Gtk.Dialog(title=titulo, transient_for=self, flags=0)
        dialogo.add_buttons(tr('Cerrar'), Gtk.ResponseType.CLOSE)
        dialogo.set_default_size(720, 520)
        area = dialogo.get_content_area()
        area.set_border_width(10)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        vista = Gtk.TextView()
        vista.set_editable(False)
        vista.set_monospace(True)
        vista.get_buffer().set_text(texto)
        scroll.add(vista)
        scroll.set_vexpand(True)
        area.add(scroll)
        dialogo.show_all()
        dialogo.run()
        dialogo.destroy()

    # -- manejadores de eventos: pasos ---------------------------------------
    def _pedir_paso(self, contexto, pasos_previos, paso_inicial=None, excepto=None):
        """Abre el diálogo de paso y devuelve el paso validado, o None si se cancela. Si la validación falla,
        el diálogo sigue abierto con los datos intactos; una excepción al construirlo se muestra (si no, el
        botón parecía «no hacer nada»)."""
        dialogo = None
        try:
            dialogo = DialogoPaso(self, pasos_previos, paso_inicial=paso_inicial,
                                   alias_prohibidos=self._alias_en_uso(excepto))
            while dialogo.run() == Gtk.ResponseType.OK:
                paso, error = dialogo.validar_y_construir()
                if not error:
                    return paso
                self.mostrar_dialogo_error(error)
        except Exception as excepcion:
            _mostrar_error_excepcion(self, contexto, excepcion)
        finally:
            if dialogo is not None:
                dialogo.destroy()
        return None

    def _on_anadir_paso(self, widget):
        paso = self._pedir_paso(tr('Añadir paso'), self.pasos_actual)
        if paso:
            self.pasos_actual.append(paso)
            self.refrescar_store_pasos()

    def _on_editar_paso(self, widget):
        idx = self.obtener_indice_paso_seleccionado()
        if idx is None:
            self.mostrar_dialogo_error(tr('Selecciona primero un paso de la lista.'))
            return
        paso = self._pedir_paso(tr('Editar paso'), self.pasos_actual[:idx], self.pasos_actual[idx], idx)
        if paso:
            self.pasos_actual[idx] = paso
            self.refrescar_store_pasos()

    def _on_quitar_paso(self, widget):
        idx = self.obtener_indice_paso_seleccionado()
        if idx is None:
            self.mostrar_dialogo_error(tr('Selecciona primero un paso de la lista.'))
            return
        del self.pasos_actual[idx]
        self.refrescar_store_pasos()

    def _on_subir_paso(self, widget):
        idx = self.obtener_indice_paso_seleccionado()
        if idx is None or idx == 0:
            return
        self.pasos_actual[idx - 1], self.pasos_actual[idx] = self.pasos_actual[idx], self.pasos_actual[idx - 1]
        self.refrescar_store_pasos()
        self.tree_pasos.get_selection().select_path(idx - 1)

    def _on_bajar_paso(self, widget):
        idx = self.obtener_indice_paso_seleccionado()
        if idx is None or idx >= len(self.pasos_actual) - 1:
            return
        self.pasos_actual[idx + 1], self.pasos_actual[idx] = self.pasos_actual[idx], self.pasos_actual[idx + 1]
        self.refrescar_store_pasos()
        self.tree_pasos.get_selection().select_path(idx + 1)

    # -- manejadores de eventos: acción completa ------------------------------
    def _on_guardar_accion(self, widget):
        nombre = self.entry_nombre.get_text().strip()
        if not nombre:
            self.mostrar_dialogo_error(tr('Escribe un nombre para la acción.'))
            return
        if not self.pasos_actual:
            self.mostrar_dialogo_error(tr('Añade al menos un paso a la acción.'))
            return
        rotas = referencias_rotas(self.pasos_actual)
        if rotas:
            self.mostrar_dialogo_error('\n\n'.join(tr('Paso {n}: apunta a la ventana de «{alias}», que ningún paso anterior abre (se borró, se movió o cambió de nombre). Edítalo y elige otra ventana: si no, se omitirá al ejecutar la acción.').format(n=n, alias=alias) for n, alias in rotas))
            return

        accion = {'id': self.editando_id or str(uuid.uuid4())[:8], 'nombre': nombre,
                  'pasos': self.pasos_actual}

        icono_sel = self.chooser_icono.get_filename()
        anterior = _accion_por_id(self.editando_id) if self.editando_id else None
        icono_previo = anterior.get('icono') if anterior else None
        if icono_sel:
            try:
                destino_icono = os.path.join(ICONOS_DIR, accion['id'] + os.path.splitext(icono_sel)[1])
                if not (os.path.exists(destino_icono) and os.path.samefile(icono_sel, destino_icono)):
                    _copiar_atomico(icono_sel, destino_icono)
                if icono_previo != destino_icono:  # otra extensión: no dejar el anterior huérfano
                    _borrar_icono_propio(icono_previo)
                accion['icono'] = destino_icono
            except Exception as e:
                _registrar_error('copiar el icono de la acción', e)
                if icono_previo:
                    accion['icono'] = icono_previo
        elif icono_previo:
            accion['icono'] = icono_previo

        acciones = cargar_acciones()
        if anterior:
            acciones = [accion if a.get('id') == accion['id'] else a for a in acciones]
        else:
            acciones.append(accion)
        guardar_acciones(acciones)

        editando_previo = self.editando_id
        if editando_previo:
            actualizar_accesos_directos(accion)
        self.cargar_lista()
        self.limpiar_formulario()
        self.notebook.set_current_page(0)
        notificar(tr('Acción "{name}" guardada correctamente.').format(name=nombre))

        if not editando_previo:
            ajustes = cargar_ajustes()
            if ajustes.get('crear_acceso_automatico'):
                if crear_acceso_directo(accion, [self.obtener_dir_escritorio()]):
                    notificar(tr('Se creó el acceso directo en el Escritorio automáticamente.'))
                else:
                    self.mostrar_dialogo_error(tr('No se pudo crear el acceso directo en el Escritorio. Detalles en:\n{log}').format(log=ERROR_LOG_FILE))
            else:
                dialogo = Gtk.MessageDialog(transient_for=self, flags=0, message_type=Gtk.MessageType.QUESTION,
                                             buttons=Gtk.ButtonsType.YES_NO,
                                             text=tr('¿Crear también un acceso directo ahora?'))
                respuesta = dialogo.run()
                dialogo.destroy()
                if respuesta == Gtk.ResponseType.YES:
                    self.crear_acceso_para(accion)

    def _on_instalar_x11(self, widget):
        """Instala xdotool y wmctrl bajo demanda (botón 'Instalar ahora' en Ajustes)."""
        if not shutil.which('pkexec'):
            self.mostrar_dialogo_error(tr(
                'No se encontró "pkexec" en el sistema, así que no puedo abrir una ventana para pedirte la contraseña. Instálalo manualmente abriendo una terminal y escribiendo:\n\nsudo apt install xdotool wmctrl'))
            return

        # Confirmación previa a pkexec que deja claro EXACTAMENTE qué se instalará.
        dialogo_confirmar = Gtk.MessageDialog(
            transient_for=self, flags=0, message_type=Gtk.MessageType.QUESTION,
            buttons=Gtk.ButtonsType.YES_NO,
            text=tr('Se van a instalar los paquetes "xdotool" y "wmctrl" mediante apt.\n\nA continuación se te pedirá tu contraseña de administrador. ¿Continuar?'))
        respuesta_confirmar = dialogo_confirmar.run()
        dialogo_confirmar.destroy()
        if respuesta_confirmar != Gtk.ResponseType.YES:
            return

        widget.set_sensitive(False)
        self.etiqueta_estado_x11.set_text(tr('⏳ Instalando… responde al diálogo de contraseña si aparece'))
        log_path = os.path.join(CONFIG_DIR, 'instalacion_dependencias_x11.log')

        def instalar():  # fuera del hilo de GTK: pkexec + apt pueden tardar minutos
            error = None
            try:
                resultado = subprocess.run(['pkexec', 'apt-get', 'install', '-y', 'xdotool', 'wmctrl'],
                                           capture_output=True, text=True)
                with open(log_path, 'w', encoding='utf-8') as f:
                    f.write((resultado.stdout or '') + (resultado.stderr or ''))
            except Exception as excepcion:
                error = excepcion
            GLib.idle_add(self._terminar_instalacion_x11, widget, error, log_path)

        threading.Thread(target=instalar, daemon=True).start()

    def _terminar_instalacion_x11(self, widget, error, log_path):
        if error is not None:
            _mostrar_error_excepcion(self, tr('Instalar xdotool/wmctrl'), error)
        herramientas = herramientas_x11_disponibles()
        ok = herramientas['xdotool'] and herramientas['wmctrl']
        self.etiqueta_estado_x11.set_text(
            (tr('✅ Disponibles') if ok else
            tr('⚠ Faltan: {tools}').format(tools=', '.join(k for k, v in herramientas.items() if not v)))
        )
        widget.set_visible(not ok)
        widget.set_sensitive(True)

        if error is not None:
            return  # ya avisado arriba
        if ok:
            notificar(tr('xdotool y wmctrl instalados correctamente.'))
        else:
            self.mostrar_dialogo_error(
                tr('No se pudo completar la instalación automática (revisa tu conexión a internet, o si cancelaste el diálogo de contraseña). Puedes ver el detalle técnico en:\n{log}\n\nO instalarlo a mano abriendo una terminal:\nsudo apt install xdotool wmctrl').format(log=log_path)
            )

    def _on_guardar_ajustes(self, widget):
        ajustes = cargar_ajustes()  # conserva las claves que esta pestaña no edita (p. ej. de una versión más nueva)
        ajustes.update({
            'navegador_predeterminado': self.combo_navegador_defecto.get_active_id() or 'sistema',
            'crear_acceso_automatico': self.check_auto_acceso.get_active(),
            'notificaciones': self.check_notificaciones.get_active(),
        })
        guardar_ajustes(ajustes)
        notificar(tr('Ajustes guardados correctamente.'))

    def _lanzar_accion(self, accion):
        """Ejecuta la acción tras minimizar Mi Lanzador, para no interferir con lo que hace en pantalla (clics,
        ventanas). Sin pasos no hay nada que ejecutar: solo se avisa, sin minimizar. Un clic como primer paso se
        dispara antes de que el gestor termine de minimizar (abrir un programa o una web tarda más): se espera a
        que la ventana conste como minimizada, 1 s como máximo por si el gestor no lo notifica."""
        pasos = accion.get('pasos')
        if not pasos:
            ejecutar_accion(accion, self)
            return
        self.iconify()
        if pasos[0].get('tipo') != 'clic':
            ejecutar_accion(accion, self)
            return
        intentos = [40]  # × 25 ms

        def _esperar_minimizada():
            ventana = self.get_window()
            if intentos[0] > 0 and ventana is not None and not (ventana.get_state() & Gdk.WindowState.ICONIFIED):
                intentos[0] -= 1
                return True
            ejecutar_accion(accion, self)
            return False
        GLib.timeout_add(25, _esperar_minimizada)

    def _on_ejecutar(self, widget):
        accion = self.obtener_seleccion()
        if accion:
            self._lanzar_accion(accion)

    def _on_crear_acceso(self, widget):
        accion = self.obtener_seleccion()
        if accion:
            self.crear_acceso_para(accion)

    def _on_ver_script(self, widget):
        accion = self.obtener_seleccion()
        if not accion:
            return
        script = generar_script_bash(accion.get('pasos', []), accion.get('nombre', ''))
        self.mostrar_dialogo_texto_largo(tr('Script de "{name}"').format(name=accion.get('nombre', '')), script)

    def _on_editar(self, widget):
        accion = self.obtener_seleccion()
        if not accion or not self._confirmar_descartar():
            return
        self.editando_id = accion.get('id')
        self.entry_nombre.set_text(accion.get('nombre', ''))
        self.chooser_icono.unselect_all()
        self.pasos_actual = [dict(p) for p in accion.get('pasos', [])]
        self.refrescar_store_pasos()
        self.btn_guardar.set_label(tr('💾 Guardar cambios'))
        self.notebook.set_current_page(1)

    def _on_eliminar(self, widget):
        accion = self.obtener_seleccion()
        if not accion:
            return
        dialogo = Gtk.MessageDialog(transient_for=self, flags=0, message_type=Gtk.MessageType.WARNING,
                                     buttons=Gtk.ButtonsType.YES_NO,
                                     text=tr('¿Eliminar la acción "{name}"?').format(name=accion.get('nombre', '')))
        respuesta = dialogo.run()
        dialogo.destroy()
        if respuesta == Gtk.ResponseType.YES:
            acciones = [a for a in cargar_acciones() if a.get('id') != accion.get('id')]
            guardar_acciones(acciones)
            eliminar_accesos_directos(accion.get('id', ''))
            _borrar_icono_propio(accion.get('icono'))
            self.cargar_lista()
            notificar(tr('Acción "{name}" eliminada.').format(name=accion.get('nombre', '')))

    def _on_fila_doble_clic(self, tree, path, column):
        accion = self._accion_de_fila(tree.get_model()[path][0])
        if accion:
            self._lanzar_accion(accion)


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == '--ejecutar':
        hilo = ejecutar_accion_por_id(sys.argv[2])
        if hilo is not None:
            hilo.join()
        return
    ventana = VentanaPrincipal()
    ventana.show_all()
    Gtk.main()


if __name__ == '__main__':
    main()
PYEOF
