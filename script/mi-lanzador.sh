#!/bin/bash
# ============================================================================
#  Copyright (C) 2026 Filonux
#
#  Licencia:
#  Mi Lanzador es software libre distribuido bajo los términos de la
#  GNU General Public License versión 3 (GPLv3).
#  Consulte el archivo LICENSE para obtener el texto completo de la licencia.
# ============================================================================
#
#  MI LANZADOR — Creador de accesos directos automatizados
#  Para Linux Mint 22.3 (Cinnamon) — sesión X11
#
#  Programador / Autor: Filonux
#
#  ¿Qué hace este script?
#   - Abre una interfaz gráfica donde puedes crear "acciones" compuestas por
#     VARIOS PASOS encadenados:
#       · Abrir programa: elige de un catálogo con TODAS tus aplicaciones y
#         accesos directos detectados automáticamente (sistema, Snap,
#         Flatpak y Escritorio), o indica una ruta/comando manual.
#       · Abrir página web: en pestaña o en VENTANA NUEVA de verdad (también
#         con "predeterminado del sistema", detectando qué navegador es).
#       · Ejecutar comando; esperar unos segundos.
#       · Colocar/organizar la ventana justo abierta (maximizar, mitad
#         izquierda/derecha, cuartos de pantalla, tamaño/posición
#         personalizados, minimizar, cerrar) — integrado en el propio paso
#         que abre el programa/web/comando, para que siempre actúe sobre la
#         ventana correcta. (También existe un paso "ventana" aparte, para
#         el caso avanzado de reposicionar una ventana que ya estaba abierta
#         de antes.)
#       · Simular clics de ratón en coordenadas X,Y absolutas de pantalla,
#         eligiéndolas con una cuenta atrás de 3s (colocas el ratón en el
#         punto exacto y listo, minimizando la app mientras tanto) o a
#         mano; opcionalmente puede activar antes una ventana concreta.
#       · Enviar teclas o combinaciones (atajos); escribir texto.
#     Tal y como haría una macro de AutoHotkey, pero usando xdotool/wmctrl
#     (las herramientas equivalentes en X11/Linux).
#   - Desde la lista de acciones puedes generar un ACCESO DIRECTO (.desktop)
#     para tu Escritorio y/o el menú de aplicaciones, con un clic. Ese acceso
#     directo ejecuta todos los pasos de la acción, en orden, sin abrir la
#     ventana de Mi Lanzador.
#   - La primera vez que lo ejecutas, se instala solo: se copia a
#     ~/.local/share/mi-lanzador/ y crea su propio lanzador en el menú de
#     aplicaciones (y una copia en el Escritorio).
#
#  Cómo usarlo:
#   1) chmod +x mi-lanzador.sh
#   2) ./mi-lanzador.sh          (o doble clic una vez marcado como ejecutable)
#
#  Todo — interfaz, lógica y datos — vive en este único archivo .sh.
#  Los datos de tus acciones se guardan en ~/.config/mi-lanzador/acciones.json
#
#  Requisitos para las funciones de ventanas/clics/teclas (X11):
#     sudo apt install xdotool wmctrl
#  (el propio script se ofrece a instalarlas automáticamente, pidiendo
#  siempre confirmación antes de hacerlo — nunca instala nada sin que lo
#  apruebes explícitamente).
# ============================================================================

set -u -o pipefail

APP_DIR="$HOME/.local/share/mi-lanzador"
APP_SCRIPT="$APP_DIR/mi-lanzador.sh"
CONFIG_DIR="$HOME/.config/mi-lanzador"
DESKTOP_APPS_DIR="$HOME/.local/share/applications"
DESKTOP_LAUNCHER="$DESKTOP_APPS_DIR/mi-lanzador.desktop"
FIRST_RUN_FLAG="$CONFIG_DIR/.instalado"

if ! mkdir -p "$APP_DIR" "$CONFIG_DIR" "$DESKTOP_APPS_DIR" "$CONFIG_DIR/tmp"; then
    echo "Mi Lanzador: no se pudieron crear los directorios de datos (revisa permisos y espacio en disco)." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1) Auto-instalación: copiar este script a una ubicación estable
# ---------------------------------------------------------------------------
SELF_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
if [[ "$SELF_PATH" != "$APP_SCRIPT" ]]; then
    cp -f "$SELF_PATH" "$APP_SCRIPT" 2>/dev/null || true
    chmod +x "$APP_SCRIPT" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 2) Crear el lanzador .desktop propio (menú de aplicaciones)
# ---------------------------------------------------------------------------
if [[ ! -f "$DESKTOP_LAUNCHER" ]]; then
    cat > "$DESKTOP_LAUNCHER" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Mi Lanzador
GenericName=Creador de accesos directos
Comment=Crea accesos directos que encadenan programas, webs, ventanas, clics y teclas · por Filonux
Exec=/bin/bash "$APP_SCRIPT"
Icon=system-run
Terminal=false
Categories=Utility;
StartupNotify=true
EOF
    chmod +x "$DESKTOP_LAUNCHER"
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$DESKTOP_APPS_DIR" >/dev/null 2>&1
    command -v gio >/dev/null 2>&1 && gio set "$DESKTOP_LAUNCHER" metadata::trusted true >/dev/null 2>&1
fi

# ---------------------------------------------------------------------------
# 3) Copia en el Escritorio, solo en la primera ejecución
# ---------------------------------------------------------------------------
if [[ ! -f "$FIRST_RUN_FLAG" ]]; then
    DESK_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
    if [[ -d "$DESK_DIR" ]]; then
        cp -f "$DESKTOP_LAUNCHER" "$DESK_DIR/Mi Lanzador.desktop" 2>/dev/null || true
        chmod +x "$DESK_DIR/Mi Lanzador.desktop" 2>/dev/null || true
        command -v gio >/dev/null 2>&1 && gio set "$DESK_DIR/Mi Lanzador.desktop" metadata::trusted true >/dev/null 2>&1
    fi
    mkdir -p "$CONFIG_DIR"
    touch "$FIRST_RUN_FLAG"
fi

# ---------------------------------------------------------------------------
# 4) Comprobar dependencias (Python 3 + GTK3 vía PyGObject, y xdotool/wmctrl)
# ---------------------------------------------------------------------------
python_gtk_disponible() {
    python3 -c "import gi; gi.require_version('Gtk','3.0'); from gi.repository import Gtk" >/dev/null 2>&1
}

mostrar_error_dependencias() {
    local msg="$1"
    if command -v zenity >/dev/null 2>&1; then
        zenity --error --title="Mi Lanzador" --text="$msg" 2>/dev/null
    elif command -v yad >/dev/null 2>&1; then
        yad --title="Mi Lanzador" --text="$msg" --button=Cerrar:0 2>/dev/null
    else
        echo "$msg" >&2
    fi
}

# Pide confirmación explícita antes de instalar nada: usa zenity si está
# disponible; si no, un diálogo mínimo de GTK; si tampoco hay GTK, pregunta
# por terminal. Sin ninguna forma de preguntar, responde que no.
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
        read -r -p "¿Instalar ahora? [s/N] " respuesta
        case "$respuesta" in
            [sS]|[sS][iI]) return 0 ;;
            *) return 1 ;;
        esac
    fi
    return 1
}

if ! command -v python3 >/dev/null 2>&1; then
    # Comillas ANSI-C ($'...') para que el \n sea un salto de línea real.
    mostrar_error_dependencias $'Falta Python 3. Instálalo con:\nsudo apt install python3'
    exit 1
fi

if ! python_gtk_disponible; then
    if command -v pkexec >/dev/null 2>&1 && confirmar_instalacion $'Mi Lanzador necesita instalar unos paquetes del sistema para poder mostrar su interfaz:\n\n  python3-gi, gir1.2-gtk-3.0, python3-gi-cairo, gir1.2-notify-0.7\n\n¿Instalarlos ahora? Se te pedirá tu contraseña de administrador.'; then
        pkexec apt-get install -y python3-gi gir1.2-gtk-3.0 python3-gi-cairo gir1.2-notify-0.7 \
            > "$CONFIG_DIR/instalacion_dependencias.log" 2>&1
    fi
    if ! python_gtk_disponible; then
        mostrar_error_dependencias $'Faltan dependencias de GTK para Python. Instálalas con:\nsudo apt install python3-gi gir1.2-gtk-3.0 python3-gi-cairo gir1.2-notify-0.7'
        exit 1
    fi
fi

# Límite de "una vez al día" para reintentos y avisos: si han pasado 24h o
# más desde la marca guardada en $1, actualiza esa marca y devuelve éxito.
ha_pasado_un_dia() {
    local archivo="$1" ahora ultimo
    ahora="$(date +%s 2>/dev/null || echo 0)"
    ultimo="$(cat "$archivo" 2>/dev/null || echo 0)"
    case "$ultimo" in ''|*[!0-9]*) ultimo=0 ;; esac
    if (( ahora - ultimo >= 86400 )); then
        echo "$ahora" > "$archivo" 2>/dev/null || true
        return 0
    fi
    return 1
}

# xdotool y wmctrl no son obligatorios para abrir programas/webs/comandos,
# pero SÍ son necesarios para los pasos de "colocar ventana", "clic" y
# "tecla". Se ofrece instalarlos automáticamente, previa confirmación, con
# un reintento máximo de una vez al día mientras sigan faltando (también se
# puede forzar desde Ajustes → «Instalar ahora»).
X11_INTENTO_TS="$CONFIG_DIR/.intento_instalacion_x11"
if { ! command -v xdotool >/dev/null 2>&1 || ! command -v wmctrl >/dev/null 2>&1; } \
    && ha_pasado_un_dia "$X11_INTENTO_TS"; then
    FALTAN_LISTA=""
    command -v xdotool >/dev/null 2>&1 || FALTAN_LISTA="xdotool"
    command -v wmctrl >/dev/null 2>&1 || FALTAN_LISTA="${FALTAN_LISTA:+$FALTAN_LISTA y }wmctrl"

    if command -v pkexec >/dev/null 2>&1 && confirmar_instalacion \
        "Mi Lanzador necesita $FALTAN_LISTA para poder colocar ventanas, simular clics y enviar teclas.

¿Instalarlo(s) ahora? Se te pedirá tu contraseña de administrador.

(Si dices que no, se te volverá a preguntar como mucho una vez al día. También puedes instalarlo cuando quieras desde Ajustes → «Instalar ahora».)"; then
        pkexec apt-get install -y xdotool wmctrl \
            > "$CONFIG_DIR/instalacion_dependencias_x11.log" 2>&1 || true
    fi

    # Se avisa igualmente si, tras lo anterior, siguen faltando: cubre tanto
    # que no haya pkexec como que el usuario dijera que no o que la
    # instalación fallase, casos que antes se quedaban sin ningún aviso.
    if ! command -v xdotool >/dev/null 2>&1 || ! command -v wmctrl >/dev/null 2>&1; then
        mostrar_error_dependencias "Mi Lanzador funcionará, pero sin $FALTAN_LISTA no podrás colocar ventanas, simular clics ni enviar teclas.

Instálalo cuando quieras con:
sudo apt install xdotool wmctrl

(o desde Ajustes → «Instalar ahora» dentro de la aplicación)."
    fi
fi

# ---------------------------------------------------------------------------
# 4bis) Aviso si la sesión gráfica activa es Wayland nativo
# ---------------------------------------------------------------------------
# xdotool y wmctrl (colocar ventana, clic, tecla) solo funcionan en X11 (o
# XWayland), nunca en una sesión Wayland nativa, aunque estén instalados.
# Se detecta con $XDG_SESSION_TYPE y se avisa una vez al día como máximo.
WAYLAND_AVISO_TS="$CONFIG_DIR/.aviso_wayland"
if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]] && ha_pasado_un_dia "$WAYLAND_AVISO_TS"; then
    mostrar_error_dependencias $'Estás en una sesión Wayland nativa de Cinnamon.\nxdotool y wmctrl (colocar ventana, clic, tecla) SOLO funcionan en X11 y no van a funcionar aquí, aunque los instales.\n\nAbrir programas, páginas web y comandos SÍ seguirá funcionando con normalidad.\n\nSi necesitas los demás pasos, cierra la sesión y elige "Cinnamon" (la sesión X11, no la que dice "Wayland") en la pantalla de inicio de sesión.'
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
# -*- coding: utf-8 -*-
"""
Mi Lanzador — interfaz gráfica.
Embebido dentro de mi-lanzador.sh para mantener todo en un único archivo.
"""
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

# ---------------------------------------------------------------------------
# Rutas y almacenamiento
# ---------------------------------------------------------------------------
CONFIG_DIR = os.environ.get('MI_LANZADOR_CONFIG_DIR', os.path.expanduser('~/.config/mi-lanzador'))
APP_SCRIPT_PATH = os.environ.get('MI_LANZADOR_APP_SCRIPT', os.path.expanduser('~/.local/share/mi-lanzador/mi-lanzador.sh'))
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


# ---------------------------------------------------------------------------
# Red de seguridad ante errores inesperados
# ---------------------------------------------------------------------------
# Registra cualquier error inesperado en ERROR_LOG_FILE y lo muestra siempre
# en un aviso visible, para que un fallo nunca pase en silencio (importante
# cuando la app se abre con doble clic, sin terminal donde ver nada).
def _registrar_error(contexto, excepcion):
    detalle = ''.join(traceback.format_exception(type(excepcion), excepcion, excepcion.__traceback__))
    try:
        with open(ERROR_LOG_FILE, 'a', encoding='utf-8') as f:
            f.write(f'\n--- {contexto} ---\n{detalle}\n')
    except Exception:
        pass
    return detalle


def _mostrar_error_excepcion(ventana, contexto, excepcion):
    detalle = _registrar_error(contexto, excepcion)
    mensaje = (f'Ha ocurrido un error inesperado en «{contexto}»:\n\n{excepcion}\n\n'
               f'El detalle técnico completo se ha guardado en:\n{ERROR_LOG_FILE}')
    try:
        dialogo = Gtk.MessageDialog(transient_for=ventana, flags=0, message_type=Gtk.MessageType.ERROR,
                                     buttons=Gtk.ButtonsType.OK, text=mensaje)
        dialogo.run()
        dialogo.destroy()
    except Exception:
        print(mensaje, file=sys.stderr)
        print(detalle, file=sys.stderr)


def _excepthook_global(tipo, valor, tb):
    """Red de seguridad general: cualquier excepción no controlada en
    cualquier parte de la interfaz queda registrada y visible, en vez de
    hacer que la aplicación (o un botón) se quede sin responder en
    silencio."""
    traceback.print_exception(tipo, valor, tb)
    _registrar_error('excepción no controlada', valor)
    try:
        _mostrar_error_excepcion(None, 'la aplicación', valor)
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
    # En Linux Mint el paquete de Chromium instala el binario "chromium"
    # (a diferencia de Ubuntu, donde "chromium-browser" es el paquete de
    # transición hacia el snap). Se prueban ambos nombres y se usa el
    # primero que exista realmente en el sistema.
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

# El paso 'documento' abre un archivo concreto (elegido con el explorador de
# GTK), con la app predeterminada del sistema (xdg-open) o, opcionalmente,
# con una aplicación instalada concreta. Se trata igual que programa/web/
# comando en todo lo relacionado con detección de ventana, alias y
# colocación integrada.

# La colocación de ventana para un programa/documento/web/comando se
# configura integrada dentro del propio paso ('colocar_ventana'), en vez de
# depender de un paso 'ventana' aparte que tuviera que volver a localizarla
# después. El paso 'ventana' se mantiene solo para el caso avanzado de
# reposicionar una ventana que ya estaba abierta de antes, por eso va al
# final y marcado como "avanzado".
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


# ---------------------------------------------------------------------------
# Detección del navegador predeterminado real del sistema
# ---------------------------------------------------------------------------
def _detectar_navegador_predeterminado():
    """Cuando el navegador elegido es 'Predeterminado del sistema', xdg-open
    no permite pedir 'ventana nueva' ni 'modo app' (los ignora siempre y
    abre como el propio navegador decida, normalmente una pestaña). Para
    poder cumplir esas opciones también con el navegador por defecto, aquí
    se intenta averiguar CUÁL es ese navegador y traducirlo a una de las
    claves conocidas de NAVEGADORES. Devuelve None si no se puede saber o
    si es un navegador no soportado (en ese caso se seguirá usando
    xdg-open, sin garantía de ventana nueva)."""
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


# ---------------------------------------------------------------------------
# Detección de programas instalados y accesos directos (.desktop)
# ---------------------------------------------------------------------------
def _directorios_aplicaciones():
    """Carpetas estándar donde Linux Mint / Cinnamon guarda los accesos
    directos (.desktop) de las aplicaciones: del sistema, del usuario, de
    Snap, de Flatpak, y el propio Escritorio del usuario."""
    dirs = [
        '/usr/share/applications',
        '/usr/local/share/applications',
        os.path.expanduser('~/.local/share/applications'),
        '/var/lib/snapd/desktop/applications',
        '/var/lib/flatpak/exports/share/applications',
        os.path.expanduser('~/.local/share/flatpak/exports/share/applications'),
    ]
    try:
        dir_escritorio = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_DESKTOP)
    except Exception:
        dir_escritorio = None
    dirs.append(dir_escritorio or os.path.expanduser('~/Desktop'))
    return dirs


def _parsear_desktop_entry(ruta):
    """Lee un fichero .desktop y devuelve sus campos básicos, o None si no
    es una aplicación visible/lanzable (Type distinto de Application,
    NoDisplay=true o Hidden=true)."""
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
                    idioma = clave[5:-1].split('_')[0].split('@')[0].lower()
                    if idioma == 'es':
                        datos['NameEs'] = valor
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
    # FALLO CORREGIDO: el propio lanzador de Mi Lanzador y los accesos
    # directos que genera para cada acción se guardan en
    # ~/.local/share/applications, la misma carpeta que aquí se escanea, y
    # todos ellos ejecutan este script (Exec=bash .../mi-lanzador.sh ...).
    # Sin este filtro, cualquier programa para el que ya se hubiera creado
    # una acción aparecía duplicado en el catálogo.
    if APP_SCRIPT_PATH in datos.get('Exec', ''):
        return None
    return {
        'nombre': datos.get('NameEs') or datos.get('Name'),
        'ruta': ruta,
        'icono': datos.get('Icon', ''),
        'exec': datos.get('Exec', ''),
        'terminal': datos.get('Terminal', 'false').lower() == 'true',
        'startup_wm_class': datos.get('StartupWMClass', ''),
    }


def _normalizar_exec_para_dedup(exec_val):
    """Reduce un valor Exec= a una forma comparable: quita los marcadores
    de sustitución (%f, %U, %i...) y colapsa espacios. Sirve para reconocer
    cuándo dos accesos directos EN REALIDAD lanzan lo mismo."""
    if not exec_val:
        return ''
    limpio = re.sub(r'%[fFuUdDnNickvm]', '', exec_val)
    return ' '.join(limpio.split()).strip().lower()


def listar_aplicaciones_instaladas():
    """Escanea las carpetas estándar de accesos directos (.desktop) del
    sistema, del usuario, de Snap/Flatpak y del Escritorio, y devuelve la
    lista de aplicaciones detectadas —[{nombre, ruta, icono, exec,
    terminal}]— ordenada alfabéticamente y sin duplicados.

    FALLO CORREGIDO: antes solo se descartaba un fichero .desktop si su
    ruta REAL ya se había visto (protegía de symlinks repetidos, pero
    nada más). Como resultado, una misma app solía aparecer 2 veces en el
    catálogo: lo más habitual es un acceso directo del sistema (p. ej.
    /usr/share/applications/app.desktop) copiado también al Escritorio
    con "Añadir al escritorio" — dos ficheros distintos, con la misma
    Ruta real, pero mismo Nombre/Exec — o el mismo "id" de .desktop
    presente en más de una carpeta (p. ej. Flatpak instalado a la vez a
    nivel de sistema y de usuario). Ahora se descarta un .desktop si su
    "id" (nombre de fichero) ya se vio antes en una carpeta de mayor
    prioridad, o si otro ya visto tiene el mismo Nombre + Exec (una vez
    quitados los marcadores %f/%U/etc.). Dos instalaciones DISTINTAS de la
    misma app (p. ej. Firefox por .deb y por Snap, con Exec diferente) se
    siguen mostrando por separado, ya que sí son opciones distintas que
    elegir."""
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
            clave_app = (app['nombre'].strip().lower(),
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


def cargar_json(ruta, valor_por_defecto):
    if os.path.isfile(ruta):
        try:
            with open(ruta, 'r', encoding='utf-8') as f:
                return json.load(f)
        except Exception:
            return valor_por_defecto
    return valor_por_defecto


def guardar_json(ruta, datos):
    with open(ruta, 'w', encoding='utf-8') as f:
        json.dump(datos, f, ensure_ascii=False, indent=2)


def _migrar_accion_antigua(accion):
    """Convierte acciones del formato antiguo (una sola tipo/valor) al nuevo
    formato basado en 'pasos', para no perder configuraciones ya creadas."""
    tipo = accion.get('tipo', 'comando')
    paso = {'tipo': tipo if tipo in ('programa', 'web', 'comando') else 'comando',
             'espera': 2.5 if tipo == 'programa' else (3.0 if tipo == 'web' else 2.5)}
    if paso['tipo'] == 'programa':
        paso['ruta'] = accion.get('valor', '')
        paso['argumentos'] = accion.get('argumentos', '')
        nombre_base = os.path.basename(paso['ruta']) or 'programa'
    elif paso['tipo'] == 'web':
        paso['url'] = accion.get('valor', '')
        paso['navegador'] = accion.get('navegador', 'sistema')
        paso['nueva_ventana'] = False
        paso['modo_app'] = accion.get('modo_app', False)
        nombre_base = urlparse(paso['url']).netloc or 'web'
    else:
        paso['comando'] = accion.get('valor', '')
        nombre_base = paso['comando'].split()[0] if paso['comando'].split() else 'comando'
    # Se genera siempre un alias real (nunca vacío): el script generado solo
    # rellena ALIAS_WIN[...] cuando el alias no está vacío, así que un paso
    # posterior que apuntase "a la ventana de" este paso migrado necesita
    # que exista un alias con el que encontrarla.
    paso['alias'] = sugerir_alias([], paso['tipo'], nombre_base)
    nueva = {
        'id': accion.get('id', str(uuid.uuid4())[:8]),
        'nombre': accion.get('nombre', 'Acción'),
        'icono': accion.get('icono'),
        'pasos': [paso],
    }
    return nueva


def _migrar_paso_clic_antiguo(paso):
    """Los pasos de clic de versiones anteriores usaban siempre coordenadas
    relativas a una ventana objetivo obligatoria. Para no romper acciones ya
    creadas, un paso de clic sin la clave 'activar_ventana' se marca como
    'coords_absolutas': False y 'activar_ventana': True, preservando el
    comportamiento con el que se guardó."""
    if paso.get('tipo') == 'clic' and 'activar_ventana' not in paso:
        paso = dict(paso)
        paso['activar_ventana'] = True
        paso['coords_absolutas'] = False
    return paso


def cargar_acciones():
    acciones = cargar_json(ACCIONES_FILE, [])
    cambiado = False
    resultado = []
    for a in acciones:
        if 'pasos' not in a:
            a = _migrar_accion_antigua(a)
            cambiado = True
        pasos_migrados = [_migrar_paso_clic_antiguo(p) for p in a.get('pasos', [])]
        if pasos_migrados != a.get('pasos', []):
            a = dict(a, pasos=pasos_migrados)
            cambiado = True
        resultado.append(a)
    if cambiado:
        guardar_json(ACCIONES_FILE, resultado)
    return resultado


def guardar_acciones(acciones):
    guardar_json(ACCIONES_FILE, acciones)


def cargar_ajustes():
    ajustes = dict(AJUSTES_POR_DEFECTO)
    ajustes.update(cargar_json(AJUSTES_FILE, {}))
    return ajustes


def guardar_ajustes(ajustes):
    guardar_json(AJUSTES_FILE, ajustes)


# ---------------------------------------------------------------------------
# Descripciones legibles (para la lista y para los desplegables de "objetivo")
# ---------------------------------------------------------------------------
def describir_objetivo(paso):
    modo = paso.get('objetivo_modo', '_ultima')
    if modo == '_alias':
        return f"ventana de «{paso.get('objetivo_alias', '?')}»"
    if modo == '_buscar':
        return f"ventana con título «{paso.get('objetivo_buscar', '')}»"
    return 'última ventana abierta'


def resumen_paso(paso):
    tipo = paso.get('tipo')
    if tipo == 'programa':
        modo = paso.get('modo', 'manual')
        if modo in ('instalado', 'desktop'):
            nombre_app = paso.get('nombre_detectado') or os.path.basename(paso.get('ruta_desktop', '')) or '(sin elegir)'
            base = f'Abrir programa: {nombre_app}'
        else:
            archivo = os.path.basename(paso.get('ruta', '')) or '(sin ruta)'
            extra = f' {paso["argumentos"]}' if paso.get('argumentos') else ''
            base = f'Abrir programa: {archivo}{extra}'
        if paso.get('colocar_ventana'):
            base += f'  ·  colocar: {POSICIONES.get(paso.get("accion_ventana"), "?")}'
        return base
    if tipo == 'documento':
        archivo = os.path.basename(paso.get('ruta', '')) or '(sin elegir)'
        con_app = f' con {paso.get("nombre_detectado", "")}' if paso.get('abrir_con') == 'app' else ''
        base = f'Abrir documento: {archivo}{con_app}'
        if paso.get('colocar_ventana'):
            base += f'  ·  colocar: {POSICIONES.get(paso.get("accion_ventana"), "?")}'
        return base
    if tipo == 'web':
        extra = ' (nueva ventana)' if paso.get('nueva_ventana') else ''
        base = f'Abrir web: {paso.get("url", "")}{extra}'
        if paso.get('colocar_ventana'):
            base += f'  ·  colocar: {POSICIONES.get(paso.get("accion_ventana"), "?")}'
        return base
    if tipo == 'comando':
        c = paso.get('comando', '')
        base = f'Comando: {c[:45]}{"…" if len(c) > 45 else ""}'
        if paso.get('colocar_ventana'):
            base += f'  ·  colocar: {POSICIONES.get(paso.get("accion_ventana"), "?")}'
        return base
    if tipo == 'esperar':
        return f'Esperar {paso.get("segundos", 1)} s'
    if tipo == 'ventana':
        return f'Ventana ({describir_objetivo(paso)}): {POSICIONES.get(paso.get("accion_ventana"), "?")}'
    if tipo == 'clic':
        doble = ' doble' if paso.get('doble') else ''
        boton = BOTONES_RATON.get(str(paso.get('boton', '1')), 'Izquierdo')
        coords = f'({paso.get("x", 0)},{paso.get("y", 0)})'
        if paso.get('activar_ventana'):
            return f'Clic{doble} ({boton}) en {coords}  ·  activa {describir_objetivo(paso)}'
        return f'Clic{doble} ({boton}) en {coords} (coordenadas de pantalla)'
    if tipo == 'tecla':
        return f'Tecla "{paso.get("combinacion", "")}" en {describir_objetivo(paso)}'
    if tipo == 'texto':
        t = paso.get('texto', '')
        return f'Escribir "{t[:25]}{"…" if len(t) > 25 else ""}" en {describir_objetivo(paso)}'
    return tipo or '?'


def resumen_pasos(pasos, max_pasos=4):
    partes = [resumen_paso(p) for p in pasos[:max_pasos]]
    if len(pasos) > max_pasos:
        partes.append(f'… (+{len(pasos) - max_pasos})')
    return '  →  '.join(partes)


def alias_disponibles_antes_de(pasos, indice):
    """Devuelve [(alias, etiqueta), ...] de los pasos que abren ventanas
    (programa/web/comando) situados ANTES del índice dado, para poder
    elegirlos como 'objetivo' en pasos posteriores."""
    disponibles = []
    for i, p in enumerate(pasos):
        if indice is not None and i >= indice:
            break
        if p.get('tipo') in ('programa', 'documento', 'web', 'comando'):
            alias = p.get('alias') or f'paso {i + 1}'
            disponibles.append((p.get('alias') or f'__paso{i}', f'{alias}  —  {resumen_paso(p)[:40]}'))
    return disponibles


def sugerir_alias(pasos, tipo, texto_base, extra_existentes=None):
    base = ''.join(c if c.isalnum() else '_' for c in texto_base.lower()).strip('_') or tipo
    base = base[:20]
    existentes = {p.get('alias', '') for p in pasos if p.get('tipo') in ('programa', 'documento', 'web', 'comando')}
    existentes |= set(extra_existentes or ())
    candidato = base
    n = 2
    while candidato in existentes:
        candidato = f'{base}_{n}'
        n += 1
    return candidato


# ---------------------------------------------------------------------------
# Generación del script bash que ejecuta todos los pasos de una acción
# ---------------------------------------------------------------------------
def _q(valor):
    """Escapa un valor para insertarlo con seguridad en el script bash."""
    return shlex.quote(str(valor))


def _comando_shell_programa(paso):
    modo = paso.get('modo', 'manual')
    if modo in ('instalado', 'desktop'):
        ruta_desktop = paso.get('ruta_desktop', '')
        id_desktop = id_desktop_de_ruta(ruta_desktop)
        # gio siempre está presente en Mint (paquete base libglib2.0-bin).
        # Si por lo que sea faltara, se prueba gtk-launch y, en último
        # caso, xdg-open sobre el propio fichero .desktop.
        return (f'gio launch {_q(ruta_desktop)} 2>/dev/null '
                f'|| gtk-launch {_q(id_desktop)} 2>/dev/null '
                f'|| xdg-open {_q(ruta_desktop)}')
    ruta = paso.get('ruta', '')
    args = (paso.get('argumentos') or '').strip()
    return f'{_q(ruta)} {args}'.strip()


def _comando_shell_documento(paso):
    """Genera el comando shell para el paso 'documento': abrir un archivo
    concreto con la app predeterminada del sistema (xdg-open) o, si se ha
    elegido explícitamente, con una aplicación instalada concreta. Para el
    caso de "aplicación concreta" se usa 'gio launch <desktop> <archivo>',
    que sí admite pasar el archivo como parámetro respetando los
    marcadores %f/%F/%u/%U del .desktop (igual que hace un doble clic
    desde el gestor de archivos); con reserva en 'gtk-launch' y, en último
    caso, en 'xdg-open' (que ignora la app elegida pero al menos abre el
    archivo con lo que haya predeterminado, en vez de no hacer nada)."""
    ruta = paso.get('ruta', '')
    if paso.get('abrir_con') == 'app' and paso.get('ruta_desktop'):
        ruta_desktop = paso.get('ruta_desktop', '')
        id_desktop = id_desktop_de_ruta(ruta_desktop)
        return (f'gio launch {_q(ruta_desktop)} {_q(ruta)} 2>/dev/null '
                f'|| gtk-launch {_q(id_desktop)} {_q(ruta)} 2>/dev/null '
                f'|| xdg-open {_q(ruta)}')
    return f'xdg-open {_q(ruta)}'


def _resolver_binario_navegador(info):
    """Devuelve el primer binario que exista realmente en el sistema entre
    el principal y sus alternativas conocidas (el nombre del paquete puede
    variar según la distribución, p. ej. chromium vs chromium-browser)."""
    candidatos = [info.get('bin')] + list(info.get('bin_alt', []))
    for candidato in candidatos:
        if candidato and shutil.which(candidato):
            return candidato
    return candidatos[0]


def _comando_shell_web(paso):
    url = paso.get('url', '')
    nav = paso.get('navegador', 'sistema')
    nueva_ventana = paso.get('nueva_ventana', False)
    modo_app = paso.get('modo_app', False)

    if nav == 'sistema' and (nueva_ventana or modo_app):
        # xdg-open no admite pedir "ventana nueva" ni "modo app": siempre
        # deja que el navegador decida (normalmente abre una pestaña en la
        # ventana ya existente). Para poder cumplir esas opciones también
        # con "Predeterminado del sistema" hay que saber qué navegador es
        # realmente y usar sus parámetros propios.
        detectado = _detectar_navegador_predeterminado()
        if detectado:
            nav = detectado

    info = NAVEGADORES.get(nav, NAVEGADORES['sistema'])
    binario = _resolver_binario_navegador(info) if info.get('bin') else None

    if nav == 'sistema' or not binario or not shutil.which(binario):
        # No se pudo identificar/usar un navegador concreto: se recurre al
        # predeterminado del sistema, sin poder garantizar ventana nueva.
        return f'xdg-open {_q(url)}'

    if modo_app and nav in ('chrome', 'chromium', 'brave'):
        return f'{binario} --app={_q(url)}'
    if nueva_ventana:
        return f'{binario} --new-window {_q(url)}'
    return f'{binario} {_q(url)}'


# WM_CLASS habitual de cada navegador, usado como pista para el plan B de
# "buscar una ventana ya existente" (ver _pista_clase_para_paso).
_CLASE_NAVEGADOR = {
    'firefox': 'firefox',
    'chrome': 'google-chrome',
    'chromium': 'chromium',
    'brave': 'brave-browser',
}


def _pista_clase_para_paso(paso):
    """Devuelve un texto (para buscar por WM_CLASS/título con 'wmctrl -lx')
    que probablemente identifique la ventana de este paso. Se usa como
    ÚLTIMO RECURSO cuando, tras abrir el programa/web/comando, no se
    detecta ninguna ventana nueva ni un cambio de foco — típicamente
    porque la app YA ESTABA ABIERTA de antes y lo único que ha pasado es
    que se ha activado una pestaña/ventana ya existente en vez de abrirse
    una nueva. Es solo una aproximación: si no coincide con nada, el
    resultado es el mismo que sin esta mejora (no se coloca la ventana)."""
    tipo = paso.get('tipo')
    if tipo == 'programa':
        modo = paso.get('modo', 'manual')
        if modo in ('instalado', 'desktop'):
            info = _parsear_desktop_entry(paso.get('ruta_desktop', '')) or {}
            clase = info.get('startup_wm_class', '')
            if clase:
                return clase
            # Sin StartupWMClass en el .desktop: se usa el primer token de
            # Exec (el binario, sin ruta ni argumentos/placeholders %U etc.)
            exec_val = (info.get('exec') or '').strip()
            binario = exec_val.split()[0] if exec_val.split() else ''
            return os.path.basename(binario)
        return os.path.basename(paso.get('ruta', '') or '')
    if tipo == 'documento':
        if paso.get('abrir_con') == 'app' and paso.get('ruta_desktop'):
            info = _parsear_desktop_entry(paso.get('ruta_desktop', '')) or {}
            clase = info.get('startup_wm_class', '')
            if clase:
                return clase
            exec_val = (info.get('exec') or '').strip()
            binario = exec_val.split()[0] if exec_val.split() else ''
            return os.path.basename(binario)
        # Con xdg-open no se puede saber de antemano qué app lo abrirá,
        # así que no hay ninguna pista de clase que ofrecer (se seguirá
        # usando la detección por snapshot / cambio de foco, ver más abajo).
        return ''
    if tipo == 'web':
        nav = paso.get('navegador', 'sistema')
        if nav == 'sistema':
            nav = _detectar_navegador_predeterminado() or ''
        return _CLASE_NAVEGADOR.get(nav, '')
    # 'comando' no tiene pista aquí: la ventana real es la de la TERMINAL
    # que lo ejecuta (no la del comando en sí), y esa se resuelve en bash
    # con la variable TERM_PISTA que rellena _abrir_en_terminal.
    return ''


def _bloque_resolver_objetivo(paso, var_win='WIN'):
    modo = paso.get('objetivo_modo', '_ultima')
    alias_ref = paso.get('objetivo_alias', '') if modo == '_alias' else ''
    busqueda = paso.get('objetivo_buscar', '') if modo == '_buscar' else ''
    return (
        f'_resolver_ventana {_q(modo)} {_q(alias_ref)} {_q(busqueda)}\n'
        f'{var_win}="$VENTANA_OBJETIVO"\n'
    )


def _validar_rango_personalizada(paso):
    """Comprueba que la posición + el tamaño personalizados (en % de
    pantalla) no se salgan de los límites. Devuelve un mensaje de error, o
    None si está bien."""
    x = paso.get('personalizada_x', 0)
    y = paso.get('personalizada_y', 0)
    w = paso.get('personalizada_w', 50)
    h = paso.get('personalizada_h', 50)
    if x + w > 100:
        return (f'La posición X ({x}%) más el ancho ({w}%) suman {x + w}%: la ventana '
                'aparecería fuera de la pantalla por la derecha. Ajusta esos valores para '
                'que sumen 100% o menos.')
    if y + h > 100:
        return (f'La posición Y ({y}%) más el alto ({h}%) suman {y + h}%: la ventana '
                'aparecería fuera de la pantalla por abajo. Ajusta esos valores para que '
                'sumen 100% o menos.')
    return None


def _lineas_posicionar_ventana(paso, var_win='WIN'):
    """Genera la línea bash (sin indentar; el llamador añade la sangría) que
    coloca/organiza una ventana ya identificada por la variable bash
    var_win, delegando en la función '_colocar_ventana' definida una sola
    vez en el preámbulo del script (ver generar_script_bash). La usan tanto
    el paso independiente 'ventana' (avanzado) como la colocación integrada
    en los pasos de abrir programa/web/comando. Todo el cálculo de
    geometría vive dentro de esa función bash con variables "local", para
    que no haya estado compartido entre pasos cuando una acción coloca
    varias ventanas."""
    accion_v = paso.get('accion_ventana', 'maximizar')
    # Salvaguarda: si accion_ventana trajera un valor que no reconocemos (un
    # dato corrupto o de una versión futura/antigua incompatible), usar
    # 'maximizar' en vez de dejarlo pasar sin más (ver _colocar_ventana).
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


def generar_script_bash(pasos, nombre_accion='acción'):
    lineas = []
    lineas.append('#!/bin/bash')
    lineas.append(f'# Script generado por Mi Lanzador para la acción: {nombre_accion}')
    lineas.append('# No pensado para editar a mano (se regenera cada vez que se ejecuta la acción).')
    lineas.append('set +e')
    lineas.append('declare -A ALIAS_WIN')
    lineas.append('ULTIMA_WIN=""')
    # Si falta xdotool, se prueba con xdpyinfo (también habitual en X11)
    # antes de usar el valor fijo 1920x1080 como último recurso.
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
    # "_snapshot" (lista de ventanas visibles, para detectar cuál es "la
    # nueva" tras abrir un programa) usa wmctrl como alternativa si falta
    # xdotool, así la detección de ventana nueva sigue funcionando.
    lineas.append('_snapshot() {')
    lineas.append('    if command -v xdotool >/dev/null 2>&1; then')
    lineas.append('        xdotool search --onlyvisible "" 2>/dev/null | sort -u')
    lineas.append('    elif command -v wmctrl >/dev/null 2>&1; then')
    lineas.append('        wmctrl -l 2>/dev/null | awk \'{print $1}\' | sort -u')
    lineas.append('    fi')
    lineas.append('}')
    lineas.append('')
    lineas.append('_detectar_nueva_ventana() {')
    lineas.append('    local antes="$1" despues nuevas')
    lineas.append('    despues="$(_snapshot)"')
    lineas.append('    nuevas="$(comm -13 <(printf \'%s\\n\' "$antes") <(printf \'%s\\n\' "$despues"))"')
    lineas.append('    printf \'%s\\n\' "$nuevas" | tail -n1')
    lineas.append('}')
    lineas.append('')
    # Prioriza el cambio de ventana activa (más fiable que comparar IDs, que a
    # veces detecta una ventana auxiliar de la app en vez de la principal); si
    # no cambia el foco, recurre al diff de snapshots. Degrada con elegancia
    # si falta xdotool (ver _snapshot).
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
    # Detecta con xrandr el monitor físico que contiene la ventana y deja su
    # geometría en MON_X/Y/W/H (evita que "mitad izquierda/derecha" o los
    # cuartos se descoloquen en equipos con varios monitores, donde
    # "xdotool getdisplaygeometry" devuelve la suma de todas las pantallas).
    # Si xrandr no está disponible cae a la pantalla virtual completa; si
    # falta xdotool, usa xwininfo como alternativa.
    lineas.append('_actualizar_monitor() {')
    lineas.append('    local win="$1"')
    lineas.append('    MON_X=0; MON_Y=0; MON_W="$ANCHO_PANTALLA"; MON_H="$ALTO_PANTALLA"')
    lineas.append('    command -v xrandr >/dev/null 2>&1 || return 0')
    lineas.append('    local wx="" wy=""')
    lineas.append('    if command -v xdotool >/dev/null 2>&1; then')
    # "X"/"Y" (las rellena "xdotool getwindowgeometry" vía eval) deben ser
    # "local" y reiniciarse antes de cada consulta: si no, una consulta
    # fallida heredaría en silencio el valor de la última ventana que sí
    # tuvo éxito, colocando la ventana en el monitor equivocado.
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
    lineas.append('        _alias) VENTANA_OBJETIVO="${ALIAS_WIN[$alias_ref]:-}" ;;')
    lineas.append('        _buscar) command -v xdotool >/dev/null 2>&1 && VENTANA_OBJETIVO="$(xdotool search --name -- "$busqueda" 2>/dev/null | head -n1)" ;;')
    lineas.append('        *) VENTANA_OBJETIVO="$ULTIMA_WIN" ;;')
    lineas.append('    esac')
    # Último recurso si no se resolvió ninguna ventana (alias o búsqueda sin
    # coincidencia, o paso ventana/clic/tecla/texto como primero de la
    # acción, sin ninguna ventana previa que usar): la ventana con foco.
    lineas.append('    if [ -z "$VENTANA_OBJETIVO" ] && command -v xdotool >/dev/null 2>&1; then')
    lineas.append('        VENTANA_OBJETIVO="$(xdotool getactivewindow 2>/dev/null)"')
    lineas.append('    fi')
    lineas.append('}')
    lineas.append('')
    # Plan B si el programa ya estaba abierto (se activa una pestaña o
    # instancia existente en vez de abrir ventana nueva, así que ni el
    # snapshot de IDs ni el cambio de foco detectan nada): buscar por
    # WM_CLASS o título, con "wmctrl -lx", una ventana ya existente que
    # coincida con la app lanzada.
    lineas.append('_buscar_por_clase() {')
    lineas.append('    local pista="$1"')
    lineas.append('    [ -z "$pista" ] && return 0')
    lineas.append('    command -v wmctrl >/dev/null 2>&1 || return 0')
    lineas.append('    wmctrl -lx 2>/dev/null | grep -iF -- "$pista" | awk \'{print $1}\' | head -n1')
    lineas.append('}')
    lineas.append('')
    # FALLO CORREGIDO: el paso "Enviar comando" ejecutaba SIEMPRE el comando
    # en segundo plano, sin ninguna terminal visible y con toda su salida
    # descartada (">/dev/null 2>&1"). Si el comando fallaba, tardaba, o
    # simplemente no abría ninguna ventana propia, no había manera de
    # verlo — parecía "no funcionar" o dar error sin ninguna explicación.
    # Ahora se abre una terminal de verdad (la primera que se encuentre
    # instalada, empezando por la que trae Linux Mint Cinnamon por
    # defecto) y el comando se ejecuta dentro, con su salida visible; la
    # terminal queda abierta al terminar, mostrando el código de salida,
    # hasta que el usuario pulsa Intro.
    lineas.append('_abrir_en_terminal() {')
    lineas.append('    local cmd_usuario="$1" term="" envoltura _lanzador=nohup')
    lineas.append('    command -v setsid >/dev/null 2>&1 && _lanzador="setsid nohup"')
    lineas.append('    for term in gnome-terminal mate-terminal xfce4-terminal tilix terminator konsole xterm x-terminal-emulator; do')
    lineas.append('        command -v "$term" >/dev/null 2>&1 && break')
    lineas.append('        term=""')
    lineas.append('    done')
    lineas.append('    TERM_PISTA=""')
    lineas.append('    if [ -z "$term" ]; then')
    lineas.append('        echo "  Aviso: no se encontró ninguna terminal instalada (gnome-terminal, xterm...); no se puede ejecutar el comando" >&2')
    lineas.append('        return 1')
    lineas.append('    fi')
    # FALLO CORREGIDO: para poder localizar después la ventana de la
    # terminal recién abierta (colocarla, o simplemente rastrearla como
    # "última ventana"), hace falta saber su WM_CLASS aproximada. Antes se
    # usaba el nombre del COMANDO del usuario (ej. "htop"), pero la
    # ventana real es la de la TERMINAL (ej. "gnome-terminal"), así que esa
    # búsqueda casi nunca encontraba nada. Se deja aquí, en una variable
    # SIN "local" (para que sobreviva a esta función), el nombre real del
    # binario de terminal elegido.
    lineas.append('    TERM_PISTA="$term"')
    # Concatenación de literales bash contiguos: "$cmd_usuario" (con el
    # comando del usuario ya expandido) pegado a un texto entrecomillado
    # con comillas simples (sin expandir todavía) que añade el aviso de
    # cierre — así "$_EST"/"$?" se evalúan al ejecutar $envoltura, no al
    # construirla.
    lineas.append('    envoltura="$cmd_usuario"\'; _EST=$?; echo; echo "[Mi Lanzador] El comando terminó (código $_EST). Pulsa Intro para cerrar esta terminal…"; read -r _ignorar\'')
    lineas.append('    case "$term" in')
    lineas.append('        gnome-terminal|tilix)')
    lineas.append('            $_lanzador "$term" -- bash -c "$envoltura" </dev/null >/dev/null 2>&1 &')
    lineas.append('            ;;')
    lineas.append('        konsole|xterm|x-terminal-emulator)')
    lineas.append('            $_lanzador "$term" -e bash -c "$envoltura" </dev/null >/dev/null 2>&1 &')
    lineas.append('            ;;')
    lineas.append('        *)')
    lineas.append('            $_lanzador "$term" -x bash -c "$envoltura" </dev/null >/dev/null 2>&1 &')
    lineas.append('            ;;')
    lineas.append('    esac')
    lineas.append('    return 0')
    lineas.append('}')
    lineas.append('')
    # Sondeo activo (cada 0.2s) en vez de un sleep fijo: continúa en cuanto
    # detecta la ventana nueva, sin superar el máximo de intentos. Si se
    # agota el tiempo, recurre al plan B de _buscar_por_clase.
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
    # ---------------------------------------------------------------------
    # Colocación/organización de ventanas: todo el cálculo de geometría vive
    # en funciones con variables "local" (nunca compartidas entre pasos, para
    # que una acción con varios pasos de colocación no vea "saltar" una
    # ventana a la geometría de otra). Cada acción comprueba qué herramienta
    # necesita y avisa si falta, con alternativas entre wmctrl/xdotool según
    # cuál esté instalado.
    # ---------------------------------------------------------------------
    lineas.append('_colocar_ventana() {')
    lineas.append('    local win="$1" accion="$2" p_x="${3:-0}" p_y="${4:-0}" p_w="${5:-50}" p_h="${6:-50}"')
    lineas.append('    if [ -z "$win" ]; then')
    lineas.append('        echo "  Aviso: no hay ninguna ventana sobre la que aplicar '"'"'$accion'"'"'" >&2')
    lineas.append('        return 1')
    lineas.append('    fi')
    lineas.append('    if ! command -v wmctrl >/dev/null 2>&1; then')
    lineas.append('        echo "  Aviso: falta wmctrl (sudo apt install wmctrl); no se puede colocar la ventana" >&2')
    lineas.append('        return 1')
    lineas.append('    fi')
    # FALLO CORREGIDO: a diferencia de la geometría personalizada (más abajo,
    # _aplicar_geometria), maximizar/restaurar/minimizar solo se pedían UNA
    # vez. Muchas apps (navegadores al restaurar su sesión/tamaño recordado)
    # deshacen ese estado un instante después de abrirse, así que a veces la
    # ventana quedaba sin maximizar pese a haberlo pedido. Se refuerza igual
    # que la geometría: reintentos en 2o plano a los 0.4/1.2/2.5/4.5s.
    lineas.append('    case "$accion" in')
    lineas.append('        maximizar)')
    lineas.append('            wmctrl -ir "$win" -b add,maximized_vert,maximized_horz 2>/dev/null')
    lineas.append('            ( nohup bash -c "sleep 0.4; wmctrl -ir \'$win\' -b add,maximized_vert,maximized_horz 2>/dev/null" >/dev/null 2>&1 & )')
    lineas.append('            ( nohup bash -c "sleep 1.2; wmctrl -ir \'$win\' -b add,maximized_vert,maximized_horz 2>/dev/null" >/dev/null 2>&1 & )')
    lineas.append('            ( nohup bash -c "sleep 2.5; wmctrl -ir \'$win\' -b add,maximized_vert,maximized_horz 2>/dev/null" >/dev/null 2>&1 & )')
    lineas.append('            ( nohup bash -c "sleep 4.5; wmctrl -ir \'$win\' -b add,maximized_vert,maximized_horz 2>/dev/null" >/dev/null 2>&1 & )')
    lineas.append('            ;;')
    lineas.append('        restaurar)')
    lineas.append('            wmctrl -ir "$win" -b remove,maximized_vert,maximized_horz 2>/dev/null')
    lineas.append('            ( nohup bash -c "sleep 0.4; wmctrl -ir \'$win\' -b remove,maximized_vert,maximized_horz 2>/dev/null" >/dev/null 2>&1 & )')
    lineas.append('            ( nohup bash -c "sleep 1.2; wmctrl -ir \'$win\' -b remove,maximized_vert,maximized_horz 2>/dev/null" >/dev/null 2>&1 & )')
    lineas.append('            ;;')
    lineas.append('        minimizar)')
    lineas.append('            if command -v xdotool >/dev/null 2>&1; then')
    lineas.append('                xdotool windowminimize "$win" 2>/dev/null')
    lineas.append('                ( nohup bash -c "sleep 0.4; xdotool windowminimize \'$win\' 2>/dev/null" >/dev/null 2>&1 & )')
    lineas.append('                ( nohup bash -c "sleep 1.2; xdotool windowminimize \'$win\' 2>/dev/null" >/dev/null 2>&1 & )')
    lineas.append('            else')
    lineas.append('                wmctrl -ir "$win" -b add,hidden 2>/dev/null')
    lineas.append('            fi')
    lineas.append('            ;;')
    lineas.append('        cerrar)')
    lineas.append('            if command -v xdotool >/dev/null 2>&1; then')
    lineas.append('                xdotool windowclose "$win" 2>/dev/null')
    lineas.append('            else')
    lineas.append('                wmctrl -ic "$win" 2>/dev/null')
    lineas.append('            fi')
    lineas.append('            ;;')
    lineas.append('        *)')
    lineas.append('            _colocar_ventana_geo "$win" "$accion" "$p_x" "$p_y" "$p_w" "$p_h"')
    lineas.append('            ;;')
    lineas.append('    esac')
    lineas.append('}')
    lineas.append('')
    # FALLO CORREGIDO: 'wmctrl -e' (usado por _aplicar_geometria, más abajo)
    # sigue el estándar EWMH de '_NET_MOVERESIZE_WINDOW': la X/Y que se le
    # pide es la esquina superior izquierda EXTERIOR de la ventana (con la
    # decoración — barra de título y bordes — ya incluida), pero el
    # ANCHO/ALTO que se le pide es el del área de CLIENTE, es decir, SIN
    # contar esa decoración. Como aquí siempre se pedía w/h = el tamaño
    # exterior deseado (p. ej. "la mitad de la pantalla") sin restarle el
    # tamaño de la decoración que añade Cinnamon/Muffin, la ventana
    # resultante quedaba un poco MAYOR de lo pedido (por el alto de su
    # barra de título y el grosor de sus bordes) — así, por ejemplo, dos
    # ventanas colocadas en mitad izquierda/mitad derecha no encajaban a
    # pixel: una tapaba ligeramente el borde de la otra, o quedaba un hueco
    # visible, en vez de repartirse la pantalla en dos mitades exactas. Esta
    # función consulta la propiedad EWMH '_NET_FRAME_EXTENTS' (que informa
    # de cuánto añade la decoración a cada lado) para poder restársela al
    # tamaño pedido antes de aplicarlo. Si no está disponible (falta xprop,
    # o el gestor de ventanas no la publica todavía en el momento de
    # consultarla), se asume 0 en los cuatro lados — el mismo comportamiento
    # que había antes de esta corrección, así que nunca queda peor que antes.
    lineas.append('_extensiones_marco() {')
    lineas.append('    local win="$1" salida')
    lineas.append('    FRAME_L=0; FRAME_R=0; FRAME_T=0; FRAME_B=0')
    lineas.append('    command -v xprop >/dev/null 2>&1 || return 0')
    lineas.append('    local intentos=0')
    lineas.append('    while [ "$intentos" -lt 6 ]; do')
    lineas.append('        salida="$(xprop -id "$win" _NET_FRAME_EXTENTS 2>/dev/null)"')
    lineas.append('        [ -n "$salida" ] && break')
    lineas.append('        sleep 0.05')
    lineas.append('        intentos=$((intentos + 1))')
    lineas.append('    done')
    lineas.append('    [ -z "$salida" ] && return 0')
    lineas.append('    salida="${salida#*= }"; salida="${salida//,/}"')
    lineas.append('    read -r FRAME_L FRAME_R FRAME_T FRAME_B <<< "$salida"')
    lineas.append('    case "$FRAME_L" in (\'\'|*[!0-9]*) FRAME_L=0 ;; esac')
    lineas.append('    case "$FRAME_R" in (\'\'|*[!0-9]*) FRAME_R=0 ;; esac')
    lineas.append('    case "$FRAME_T" in (\'\'|*[!0-9]*) FRAME_T=0 ;; esac')
    lineas.append('    case "$FRAME_B" in (\'\'|*[!0-9]*) FRAME_B=0 ;; esac')
    lineas.append('}')
    lineas.append('')
    lineas.append('_colocar_ventana_geo() {')
    lineas.append('    local win="$1" accion="$2" p_x="$3" p_y="$4" p_w="$5" p_h="$6"')
    lineas.append('    local mon_x mon_y mon_w mon_h')
    lineas.append('    _actualizar_monitor "$win"')
    lineas.append('    mon_x=$MON_X; mon_y=$MON_Y; mon_w=$MON_W; mon_h=$MON_H')
    lineas.append('')
    lineas.append('    wmctrl -ir "$win" -b remove,maximized_vert,maximized_horz 2>/dev/null')
    # FALLO CORREGIDO: pedir el cambio de geometría justo después de quitar
    # el estado "maximizado", sin confirmar que el gestor de ventanas ya lo
    # había aplicado, hacía que Cinnamon/Muffin ignorase la petición en
    # muchos casos (antes se esperaba un tiempo FIJO de 0.15s, insuficiente
    # a veces). Ahora se sondea activamente (con xprop) el estado real de
    # la ventana, hasta 1 segundo, y solo entonces se continúa.
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
    # Se resta la decoración (_extensiones_marco) al tamaño pedido antes de
    # aplicarlo, porque wmctrl -e espera ancho/alto del área de CLIENTE.
    lineas.append('    _extensiones_marco "$win"')
    lineas.append('    local w_cliente=$((w - FRAME_L - FRAME_R)) h_cliente=$((h - FRAME_T - FRAME_B))')
    lineas.append('    [ "$w_cliente" -ge 100 ] || w_cliente=$w')
    lineas.append('    [ "$h_cliente" -ge 100 ] || h_cliente=$h')
    lineas.append('    _aplicar_geometria "$win" "$x" "$y" "$w_cliente" "$h_cliente"')
    lineas.append('}')
    lineas.append('')
    lineas.append('_aplicar_geometria() {')
    lineas.append('    local win="$1" x="$2" y="$3" w="$4" h="$5"')
    # FALLO CORREGIDO (causa real de la ventana "transparente" y del
    # desajuste al encajar ventanas): "wmctrl -e" por sí solo ya coloca la
    # ventana con precisión (comprobado con medición física real). El fallo
    # estaba en comprobar el resultado leyendo la geometría con "xdotool
    # getwindowgeometry": esa lectura no coincide con la posición física
    # real de la ventana (llega a informar de un desplazamiento de hasta
    # 45px que no existe en pantalla), así que la comprobación fallaba casi
    # siempre aunque la ventana ya estuviera perfecta, y disparaba de más
    # un "plan B" de xdotool que además usa un convenio de coordenadas
    # distinto al de wmctrl (coloca el cliente, no el marco) y desplazaba
    # la ventana de su sitio correcto — a la vez que el propio tirón de dos
    # peticiones de mover/redimensionar casi simultáneas sobre una ventana
    # aún animándose es lo que la dejaba pintada a medias un instante. Se
    # elimina esa comprobación y el plan B: ahora solo se usa wmctrl -e,
    # repetido con retardos crecientes por si alguna app (Chrome, Electron,
    # LibreOffice...) reaplica después su propio tamaño recordado. La
    # última repetición se lanza en un proceso independiente (nohup) para
    # que actúe igual aunque la acción ya haya terminado.
    lineas.append('    wmctrl -ir "$win" -e "0,$x,$y,$w,$h" 2>/dev/null')
    lineas.append('    ( nohup bash -c "sleep 0.4; wmctrl -ir \'$win\' -e \'0,$x,$y,$w,$h\' 2>/dev/null" >/dev/null 2>&1 & )')
    lineas.append('    ( nohup bash -c "sleep 1.2; wmctrl -ir \'$win\' -e \'0,$x,$y,$w,$h\' 2>/dev/null" >/dev/null 2>&1 & )')
    lineas.append('    ( nohup bash -c "sleep 2.5; wmctrl -ir \'$win\' -e \'0,$x,$y,$w,$h\' 2>/dev/null" >/dev/null 2>&1 & )')
    # Reintento adicional más tardío: algunos navegadores (restaurar sesión,
    # pestañas pesadas) todavía reajustan su propio tamaño más allá de 2.5s.
    lineas.append('    ( nohup bash -c "sleep 4.5; wmctrl -ir \'$win\' -e \'0,$x,$y,$w,$h\' 2>/dev/null" >/dev/null 2>&1 & )')
    lineas.append('}')
    lineas.append('')
    # Sondea la geometría real (posición Y tamaño) hasta que deja de cambiar
    # entre dos lecturas seguidas, en vez de un tiempo fijo: así no falla con
    # apps lentas en animarse/moverse/redimensionar (navegadores, ventanas
    # que se desminimizan...) ni hace esperar de más a las rápidas. Máximo
    # ~1.7s. La usan tanto la colocación de ventana como el clic con
    # "activar ventana antes" (ver más abajo).
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
    lineas.append(f'printf \'%s\\n\' {_q("=== Mi Lanzador: ejecutando " + nombre_accion + " ===")} >&2')

    for i, paso in enumerate(pasos, start=1):
        tipo = paso.get('tipo')
        lineas.append('')
        lineas.append(f'# --- Paso {i}: {TIPOS_PASO.get(tipo, tipo)} ---')
        lineas.append(f'printf \'%s\\n\' {_q("  Paso " + str(i) + ": " + resumen_paso(paso)[:80])} >&2')

        if tipo in ('programa', 'documento', 'web', 'comando'):
            if tipo == 'programa':
                cmd = _comando_shell_programa(paso)
            elif tipo == 'documento':
                cmd = _comando_shell_documento(paso)
            elif tipo == 'web':
                cmd = _comando_shell_web(paso)
            else:
                cmd = paso.get('comando', '')
            espera = paso.get('espera', 2.0)
            alias = paso.get('alias', '')
            # MEJORA: "espera" ahora es un MÁXIMO, no un tiempo fijo — ver
            # _esperar_ventana_nueva más arriba. Se traduce a un número de
            # intentos de 0.2s cada uno (redondeando hacia arriba, para no
            # esperar menos de lo que el usuario configuró).
            intentos_max = max(1, int(math.ceil(espera / 0.2)))
            lineas.append('ANTES="$(_snapshot)"')
            lineas.append('ACTIVA_ANTES="$(xdotool getactivewindow 2>/dev/null)"')
            if tipo == 'comando':
                lineas.append(f'_abrir_en_terminal {_q(cmd)}')
                pista_arg = '"$TERM_PISTA"'
            else:
                # Se envuelve en "bash -c" (en vez de pasar el comando
                # directo a nohup) para que funcione igual con comandos
                # simples que con comandos compuestos (con &&, |, comillas).
                lineas.append(f'( nohup bash -c {_q(cmd)} >/dev/null 2>&1 & )')
                pista_arg = _q(_pista_clase_para_paso(paso))
            lineas.append(f'NUEVA="$(_esperar_ventana_nueva "$ANTES" "$ACTIVA_ANTES" {intentos_max} {pista_arg})"')
            lineas.append('[ -n "$NUEVA" ] && ULTIMA_WIN="$NUEVA"')
            if alias:
                lineas.append(f'[ -n "$NUEVA" ] && ALIAS_WIN[{_q(alias)}]="$NUEVA"')
            if paso.get('colocar_ventana'):
                # Colocación integrada: se aplica aquí mismo, sobre la
                # ventana que ACABA de detectarse ($NUEVA), en vez de
                # depender de volver a localizarla en un paso posterior.
                lineas.append('if [ -n "$NUEVA" ]; then')
                lineas.append('    xdotool windowactivate "$NUEVA" 2>/dev/null')
                lineas.append('    _esperar_estabilizar_ventana "$NUEVA"')
                lineas.append('    xdotool windowactivate "$NUEVA" 2>/dev/null')
                lineas.extend('    ' + l for l in _lineas_posicionar_ventana(paso, 'NUEVA'))
                lineas.append('else')
                lineas.append('    echo "  Aviso: no se pudo colocar la ventana (no se detectó ninguna ventana nueva, ni una existente que coincidiera)" >&2')
                lineas.append('fi')

        elif tipo == 'esperar':
            segundos = paso.get('segundos', 1)
            lineas.append(f'sleep {segundos}')

        elif tipo == 'ventana':
            lineas.append(_bloque_resolver_objetivo(paso))
            lineas.append('if [ -n "$WIN" ]; then')
            lineas.append('    xdotool windowactivate "$WIN" 2>/dev/null')
            lineas.append('    _esperar_estabilizar_ventana "$WIN"')
            lineas.append('    xdotool windowactivate "$WIN" 2>/dev/null')
            lineas.extend('    ' + l for l in _lineas_posicionar_ventana(paso, 'WIN'))
            lineas.append('else')
            lineas.append('    echo "  Aviso: no se encontró la ventana objetivo (paso de tipo ventana)" >&2')
            lineas.append('fi')

        elif tipo == 'clic':
            # FALLO CORREGIDO / REDISEÑADO: antes, el clic SIEMPRE dependía
            # de resolver primero una "ventana objetivo" (última ventana
            # abierta / alias / búsqueda por título) y calculaba la
            # coordenada como relativa a esa ventana. Esto fallaba en
            # cuanto esa ventana no se podía resolver (por ejemplo si el
            # paso de clic era el único paso de la acción, o si la
            # ventana detectada al ELEGIR el punto en pantalla no
            # coincidía con la que finalmente se resolvía al EJECUTAR el
            # paso): el clic no hacía nada, en silencio. Ahora, por
            # defecto, el punto elegido con el selector visual se guarda
            # y se usa tal cual, en coordenadas ABSOLUTAS de pantalla —
            # exactamente donde se hizo clic al elegirlo — sin depender de
            # resolver ninguna ventana. Opcionalmente (casilla "Activar
            # una ventana antes de hacer clic") se puede además activar/
            # enfocar una ventana concreta justo antes (útil si esa
            # ventana pudiera estar minimizada o detrás de otras), lo cual
            # sigue siendo compatible con acciones migradas del formato
            # antiguo (coordenadas relativas a esa ventana).
            x = int(paso.get('x', 0))
            y = int(paso.get('y', 0))
            absolutas = paso.get('coords_absolutas', True)
            activar = bool(paso.get('activar_ventana'))
            boton = str(paso.get('boton', '1'))
            # FALLO CORREGIDO: _CX/_CY son variables GLOBALES del script (no
            # pueden declararse "local": este bloque no vive dentro de una
            # función, sino en el cuerpo principal, igual que todos los
            # pasos). En una acción con más de un paso de clic, si ESTE paso
            # no llegaba a fijarlas (p. ej. no se encontraba la ventana a
            # activar, en un clic con coordenadas relativas heredado de una
            # versión antigua), el "if [ -n "$_CX" ]" de más abajo encontraba
            # el valor que hubiera dejado el ÚLTIMO paso de clic anterior que
            # sí tuvo éxito, y el clic se ejecutaba igualmente en ESE punto
            # -equivocado y de otro paso- en vez de omitirse con su aviso.
            # Ahora se reinician siempre a vacío al empezar cada paso.
            lineas.append('_CX=""; _CY=""')
            if activar:
                lineas.append(_bloque_resolver_objetivo(paso))
                lineas.append('if [ -n "$WIN" ]; then')
                lineas.append('    xdotool windowactivate "$WIN" 2>/dev/null')
                # MEJORA: reemplaza el "sleep 0.3" fijo por la misma espera
                # adaptativa que ya usa el paso "ventana" (sondea hasta que
                # la geometría deja de cambiar). Con un sleep fijo, una
                # ventana lenta en restaurarse/animarse podía dejar leer su
                # posición a medio mover, descuadrando el clic relativo.
                # Se reactiva otra vez después por si algo robó el foco
                # durante la espera.
                lineas.append('    _esperar_estabilizar_ventana "$WIN"')
                lineas.append('    xdotool windowactivate "$WIN" 2>/dev/null')
                if absolutas:
                    lineas.append(f'    _CX={x}; _CY={y}')
                else:
                    # FALLO CORREGIDO: por el mismo motivo, "X"/"Y" (las
                    # rellena "xdotool getwindowgeometry" vía eval) también
                    # son globales y las comparte "_actualizar_monitor". Si
                    # la consulta de geometría fallase para esta ventana
                    # (p. ej. se cerró justo entonces), antes se usaban tal
                    # cual, arrastrando en silencio la posición de OTRA
                    # ventana consultada antes. Ahora se reinician justo
                    # antes de preguntar, y solo se calcula la coordenada si
                    # la consulta realmente devolvió algo.
                    lineas.append('    X=""; Y=""')
                    lineas.append('    eval "$(xdotool getwindowgeometry --shell "$WIN" 2>/dev/null)"')
                    lineas.append('    if [ -n "$X" ] && [ -n "$Y" ]; then')
                    lineas.append(f'        _CX=$((X + {x})); _CY=$((Y + {y}))')
                    lineas.append('    fi')
                lineas.append('else')
                if absolutas:
                    lineas.append(f'    _CX={x}; _CY={y}')
                else:
                    lineas.append('    echo "  Aviso: no se encontró la ventana a activar antes del clic" >&2')
                lineas.append('fi')
            else:
                lineas.append(f'_CX={x}; _CY={y}')
            lineas.append('if command -v xdotool >/dev/null 2>&1; then')
            lineas.append('    if [ -n "$_CX" ] && [ -n "$_CY" ]; then')
            # MEJORA: avisa (sin bloquear el clic) si el punto cae fuera de
            # la pantalla actual — la causa más habitual es que cambiara la
            # resolución o se desconectara un monitor desde que se eligió.
            lineas.append('        if [ "$_CX" -lt 0 ] || [ "$_CY" -lt 0 ] || [ "$_CX" -ge "$ANCHO_PANTALLA" ] || [ "$_CY" -ge "$ALTO_PANTALLA" ]; then')
            lineas.append('            echo "  Aviso: el punto ($_CX,$_CY) cae fuera de la pantalla actual (${ANCHO_PANTALLA}x${ALTO_PANTALLA}); revisa si cambió la resolución o los monitores" >&2')
            lineas.append('        fi')
            # MEJORA: "--sync" hace que xdotool no continúe hasta que el
            # puntero ha llegado de verdad al punto (en vez de fiarlo todo a
            # que un sleep fijo sea suficiente); el sleep breve que sigue da
            # además tiempo a que la app reaccione visualmente al posible
            # "hover" antes de recibir el clic. "--clearmodifiers" evita que
            # una tecla modificadora (Ctrl/Shift/Alt) pulsada por casualidad
            # en ese instante cambie el significado del clic.
            lineas.append('        xdotool mousemove --sync -- "$_CX" "$_CY" 2>/dev/null')
            lineas.append('        sleep 0.1')
            if paso.get('doble'):
                lineas.append(f'        xdotool click --clearmodifiers --repeat 2 --delay 150 {_q(boton)} 2>/dev/null || echo "  Aviso: xdotool no pudo simular el clic" >&2')
            else:
                lineas.append(f'        xdotool click --clearmodifiers {_q(boton)} 2>/dev/null || echo "  Aviso: xdotool no pudo simular el clic" >&2')
            lineas.append('    else')
            lineas.append('        echo "  Aviso: no se pudo determinar la coordenada del clic" >&2')
            lineas.append('    fi')
            lineas.append('else')
            lineas.append('    echo "  Aviso: falta xdotool (sudo apt install xdotool); no se puede simular el clic" >&2')
            lineas.append('fi')

        elif tipo == 'tecla':
            # FALLO CORREGIDO: "xdotool key --window "$WIN"" envía el evento
            # de tecla con XSendEvent directamente a ese ID de ventana, sin
            # pasar por el foco de teclado real. Muchas apps modernas
            # (GTK3, LibreOffice, Electron, navegadores...) ignoran o solo
            # aceptan a veces ese tipo de evento "sintético", porque en
            # realidad el foco vive en un widget hijo concreto (la caja de
            # texto, el lienzo...) y no en la ventana de nivel superior —
            # de ahí que fallara de forma intermitente. Ahora se activa la
            # ventana con "--sync" (xdotool espera de verdad a que el
            # gestor de ventanas confirme que ya está activa, en vez de un
            # sleep fijo) y la tecla se envía SIN --window: así xdotool usa
            # la extensión XTEST (pulsación de teclado real, a nivel del
            # servidor X) dirigida a lo que tenga el foco en ese momento —
            # que es justo la ventana recién activada — igual que si el
            # usuario la hubiera pulsado físicamente.
            lineas.append(_bloque_resolver_objetivo(paso))
            lineas.append('if [ -n "$WIN" ]; then')
            lineas.append('    if command -v xdotool >/dev/null 2>&1; then')
            lineas.append('        xdotool windowactivate --sync "$WIN" 2>/dev/null')
            lineas.append('        xdotool windowfocus --sync "$WIN" 2>/dev/null')
            lineas.append('        sleep 0.3')
            combinacion = paso.get('combinacion', '')
            lineas.append(f'        xdotool key -- {_q(combinacion)} 2>/dev/null')
            lineas.append('    else')
            lineas.append('        echo "  Aviso: falta xdotool (sudo apt install xdotool); no se puede enviar la tecla" >&2')
            lineas.append('    fi')
            lineas.append('else')
            lineas.append('    echo "  Aviso: no se encontró la ventana objetivo (paso de tecla)" >&2')
            lineas.append('fi')

        elif tipo == 'texto':
            # FALLO CORREGIDO: mismo problema que en el paso "tecla" (ver
            # arriba) — "xdotool type --window "$WIN"" usaba XSendEvent en
            # vez del foco real, así que en un procesador de textos u otra
            # app con varios widgets internos, a veces el texto llegaba
            # bien y a veces no llegaba a ningún sitio (o se perdían las
            # primeras letras) según qué widget concreto tuviera el foco
            # en ese instante. Se activa/enfoca la ventana con "--sync" y
            # se escribe SIN --window (pulsaciones reales vía XTEST, al
            # foco actual). También se sube un poco el retardo entre
            # pulsaciones (--delay), porque con acentos/eñes el valor por
            # defecto (12 ms) a veces va demasiado rápido para que la app
            # procese cada tecla a tiempo.
            lineas.append(_bloque_resolver_objetivo(paso))
            lineas.append('if [ -n "$WIN" ]; then')
            lineas.append('    if command -v xdotool >/dev/null 2>&1; then')
            lineas.append('        xdotool windowactivate --sync "$WIN" 2>/dev/null')
            lineas.append('        xdotool windowfocus --sync "$WIN" 2>/dev/null')
            lineas.append('        sleep 0.3')
            texto = paso.get('texto', '')
            lineas.append(f'        xdotool type --clearmodifiers --delay 30 -- {_q(texto)} 2>/dev/null')
            lineas.append('    else')
            lineas.append('        echo "  Aviso: falta xdotool (sudo apt install xdotool); no se puede escribir el texto" >&2')
            lineas.append('    fi')
            lineas.append('else')
            lineas.append('    echo "  Aviso: no se encontró la ventana objetivo (paso de texto)" >&2')
            lineas.append('fi')

    lineas.append('')
    lineas.append('echo "=== Mi Lanzador: acción finalizada ===" >&2')
    return '\n'.join(lineas) + '\n'


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
    try:
        ajustes = cargar_ajustes()
        if not ajustes.get('notificaciones', True):
            return
        if HAY_NOTIFY:
            if not Notify.is_initted():
                Notify.init('Mi Lanzador')
            Notify.Notification.new(titulo, texto, 'system-run').show()
        else:
            subprocess.Popen(['notify-send', titulo, texto])
    except Exception:
        pass


def ejecutar_accion(accion, ventana_padre=None):
    pasos = accion.get('pasos', [])
    if not pasos:
        return
    _limpiar_temporales_antiguos()
    script = generar_script_bash(pasos, accion.get('nombre', 'acción'))
    try:
        fd, ruta_script = tempfile.mkstemp(prefix='accion_', suffix='.sh', dir=TMP_DIR)
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(script)
        os.chmod(ruta_script, 0o755)
        # FALLO CORREGIDO: antes se lanzaba con stdout/stderr redirigidos a
        # /dev/null. El script generado escribe en stderr avisos útiles
        # ("Aviso: no se pudo colocar la ventana...", "falta wmctrl...",
        # "no se encontró la ventana objetivo...") pensados precisamente
        # para poder diagnosticar por qué un paso no hizo lo esperado, pero
        # al descartarse siempre, el usuario no tenía NINGUNA pista cuando
        # algo fallaba: la acción simplemente "no hacía nada" en apariencia.
        # Ahora esa salida se guarda en un registro y, si contiene algún
        # aviso (o si el script termina con error), se avisa con una
        # notificación indicando dónde consultarlo.
        ruta_log = os.path.join(CONFIG_DIR, 'ultima_ejecucion.log')
        log_f = open(ruta_log, 'w', encoding='utf-8')
        proceso = subprocess.Popen(['bash', ruta_script], start_new_session=True,
                                    stdout=log_f, stderr=log_f)
        notificar(f'Ejecutando: {accion.get("nombre", "")} ({len(pasos)} paso{"s" if len(pasos) != 1 else ""})')

        def _vigilar_avisos():
            try:
                proceso.wait()
            except Exception:
                pass
            try:
                log_f.close()
            except Exception:
                pass
            try:
                with open(ruta_log, 'r', encoding='utf-8', errors='ignore') as f:
                    contenido = f.read()
            except Exception:
                contenido = ''
            hubo_aviso = 'Aviso:' in contenido
            fallo = proceso.returncode not in (0, None)
            if not (hubo_aviso or fallo):
                return
            # FALLO CORREGIDO: esta notificación se enviaba con GLib.idle_add
            # para que se ejecutase en el hilo principal de Gtk. Pero cuando
            # la acción se lanza desde un acceso directo (.desktop) —el modo
            # de uso más habitual—, main() no llega a arrancar Gtk.main() en
            # absoluto, así que ese idle_add nunca llegaba a dispararse: el
            # aviso se perdía en silencio y el proceso python terminaba antes
            # de que este hilo (daemon) llegase a notificar nada. notificar()
            # no toca ningún widget de Gtk (solo D-Bus/notify-send), así que
            # es seguro llamarla directamente desde este hilo en cualquiera
            # de los dos casos de uso.
            notificar(f'"{accion.get("nombre", "")}" terminó con avisos. Revisa el registro:\n{ruta_log}',
                      'Mi Lanzador ⚠')

        hilo = threading.Thread(target=_vigilar_avisos, daemon=True)
        hilo.start()
        return hilo
    except Exception as e:
        if ventana_padre is not None:
            ventana_padre.mostrar_dialogo_error(f'No se pudo ejecutar la acción:\n{e}')
        return None


def ejecutar_accion_por_id(id_accion):
    for accion in cargar_acciones():
        if accion.get('id') == id_accion:
            return ejecutar_accion(accion, None)
    print(f'Mi Lanzador: no se encontró ninguna acción con id "{id_accion}"', file=sys.stderr)
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
    limpio = limpio.strip() or 'accion'
    return limpio


def generar_desktop_entry(accion, icono):
    nombre = accion.get('nombre', 'Acceso directo')
    n_pasos = len(accion.get('pasos', []))
    exec_line = f'bash {shlex.quote(APP_SCRIPT_PATH)} --ejecutar {shlex.quote(accion.get("id", ""))}'
    lineas = [
        '[Desktop Entry]',
        'Type=Application',
        'Version=1.0',
        f'Name={nombre}',
        f'Comment=Acceso directo creado con Mi Lanzador ({n_pasos} paso{"s" if n_pasos != 1 else ""})',
        f'Exec={exec_line}',
        f'Icon={icono}',
        'Terminal=false',
        'Categories=Utility;',
    ]
    return '\n'.join(lineas) + '\n'


def crear_acceso_directo(accion, destinos):
    icono_custom = accion.get('icono')
    primer_tipo = accion.get('pasos', [{}])[0].get('tipo') if accion.get('pasos') else None
    icono_final = icono_custom if icono_custom and os.path.isfile(icono_custom) else icono_por_tipo_paso(primer_tipo)
    contenido = generar_desktop_entry(accion, icono_final)
    # FALLO CORREGIDO: el nombre del fichero .desktop se generaba solo a
    # partir del NOMBRE de la acción. Dos acciones distintas con el mismo
    # nombre (p. ej. dos acciones llamadas "Backup") producían el mismo
    # nombre de archivo, así que crear el acceso directo de la segunda
    # sobrescribía en silencio el de la primera. Se añade el id único de la
    # acción al nombre de archivo para que nunca puedan chocar entre sí.
    nombre_archivo = f"{sanear_nombre_archivo(accion.get('nombre', 'accion'))}-{accion.get('id', '')}.desktop"
    rutas_creadas = []
    for destino in destinos:
        try:
            os.makedirs(destino, exist_ok=True)
            ruta = os.path.join(destino, nombre_archivo)
            with open(ruta, 'w', encoding='utf-8') as f:
                f.write(contenido)
            os.chmod(ruta, 0o755)
            try:
                subprocess.run(['gio', 'set', ruta, 'metadata::trusted', 'true'],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except Exception:
                pass
            rutas_creadas.append(ruta)
        except Exception as e:
            print(f'Error creando acceso directo en {destino}: {e}', file=sys.stderr)
    if os.path.expanduser('~/.local/share/applications') in destinos:
        try:
            subprocess.run(['update-desktop-database', os.path.expanduser('~/.local/share/applications')],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass
    return rutas_creadas


def eliminar_accesos_directos(accion_id):
    """MEJORA: al eliminar una acción, sus accesos directos (.desktop) ya
    creados antes en el Escritorio y/o el menú de aplicaciones se quedaban
    huérfanos (apuntando a un id que ya no existe), dando la sensación de
    que el icono "no hace nada" al pulsarlo. Se localizan por su sufijo
    "-<id>.desktop" —único para cada acción, ver crear_acceso_directo— y se
    borran de las carpetas donde pudieron haberse creado."""
    if not accion_id:
        return
    sufijo = f'-{accion_id}.desktop'
    carpetas = [os.path.expanduser('~/.local/share/applications')]
    try:
        dir_escritorio = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_DESKTOP)
    except Exception:
        dir_escritorio = None
    carpetas.append(dir_escritorio or os.path.expanduser('~/Desktop'))
    for carpeta in carpetas:
        if not carpeta or not os.path.isdir(carpeta):
            continue
        try:
            nombres = os.listdir(carpeta)
        except Exception:
            continue
        for nombre_archivo in nombres:
            if nombre_archivo.endswith(sufijo):
                try:
                    os.remove(os.path.join(carpeta, nombre_archivo))
                except Exception:
                    pass


# ---------------------------------------------------------------------------
# Interfaz gráfica
# ---------------------------------------------------------------------------
# El CSS fija SIEMPRE fondo y texto juntos (nunca uno sin el otro) en los
# nodos que toca: borde de ventana, pestañas en sus 3 estados y título de
# cada sección. Si solo se fija el color del texto, quien pinta el fondo
# es el tema GTK/Cinnamon instalado, y si ese tema es oscuro donde aquí se
# daba por hecho que sería claro (o al revés), el resultado es ilegible.
# El resto de etiquetas de la interfaz no se toca a propósito: siguen el
# tema del sistema con normalidad.
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
decoration:backdrop {
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.18);
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
notebook > header.top {
    background-color: #f5f6fa;
}
notebook > header.top > tabs > tab {
    padding: 8px 18px;
    background-color: #f5f6fa;
    color: #4a4a58;
}
notebook > header.top > tabs > tab label {
    font-weight: 600;
    font-size: 10.5pt;
    color: #4a4a58;
}
notebook > header.top > tabs > tab:hover,
notebook > header.top > tabs > tab:hover label {
    background-color: #dfe2f9;
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
.aviso-x11 {
    color: #b33939;
    font-size: 9pt;
}
"""


def _fila_grid(grid, fila, texto_label, widget, span_widget=2):
    grid.attach(Gtk.Label(label=texto_label, halign=Gtk.Align.END), 0, fila, 1, 1)
    grid.attach(widget, 1, fila, span_widget, 1)
    return fila + 1


# ---------------------------------------------------------------------------
# Selector visual de coordenadas en pantalla (para el paso "clic")
# ---------------------------------------------------------------------------
# Cuenta atrás de unos segundos para que el usuario coloque el cursor en el
# punto exacto; al terminar, se lee la posición con "xdotool
# getmouselocation". Es más simple y fiable que cubrir toda la pantalla con
# una capa transparente a la espera de un clic (con Gdk.Seat.grab): ese
# enfoque dependía del gestor de ventanas y el modo de foco, y el clic no
# siempre llegaba a registrarse.
SEGUNDOS_CUENTA_ATRAS_CLIC = 3  # tiempo, en segundos, para colocar el cursor al elegir un punto


def _capturar_punto_pantalla():
    """Da al usuario unos segundos para colocar el ratón sobre el punto
    exacto que quiere usar y, al terminar la cuenta atrás, lee la posición
    del cursor con "xdotool getmouselocation". Devuelve (x, y) en
    coordenadas absolutas de pantalla, o None si xdotool no está
    disponible o la lectura falla."""
    if not shutil.which('xdotool'):
        return None

    # Ventana tipo POPUP: no la gestiona el gestor de ventanas, así que se
    # coloca exactamente donde se pide, sin decoración.
    aviso = Gtk.Window(type=Gtk.WindowType.POPUP)
    aviso.set_accept_focus(False)  # nunca roba el foco: no hace falta clic ni tecla

    # Fondo forzado con override_background_color sobre un Gtk.EventBox, en
    # vez de CSS: una regla CSS por #id puede quedar por debajo del
    # 'background-image' que el tema aplica a las ventanas, dejando un
    # cuadro en blanco en vez del aviso oscuro; override_background_color
    # pinta el color directamente, sin pasar por el tema.
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
        return f'🎯 Coloca el cursor en el punto exacto\nCapturando en {segundos} s…'

    def _tick():
        if estado['restante'] <= 0:
            Gtk.main_quit()
            return False
        etiqueta.set_text(_texto(estado['restante']))
        estado['restante'] -= 1
        return True

    # El texto se fija ANTES de mostrar la ventana: algunos gestores de
    # ventanas fijan el tamaño de una ventana sin decorar en cuanto se
    # mapea por primera vez, y si entonces está vacía queda a un tamaño
    # mínimo que el texto posterior ya no llega a ensanchar.
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


def _resolver_ventana_bajo_punto(x_root, y_root):
    """Dado un punto absoluto de pantalla, intenta averiguar (con xdotool)
    qué ventana hay debajo y devuelve (x_relativo, y_relativo,
    titulo_ventana). Si no se puede determinar, devuelve las coordenadas
    absolutas tal cual y título vacío. Se apoya en la posición ACTUAL del
    ratón (que un clic no mueve) en vez de en x_root/y_root para el
    identificador de ventana, así que hay que llamarla justo tras el clic,
    antes de restaurar/mover ninguna otra ventana."""
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
        geo_salida = subprocess.run(['xdotool', 'getwindowgeometry', '--shell', win_id],
                                     capture_output=True, text=True, timeout=2).stdout
        geo = dict(l.split('=', 1) for l in geo_salida.strip().splitlines() if '=' in l)
        wx, wy = int(geo.get('X', 0)), int(geo.get('Y', 0))
        nombre = ''
        try:
            nombre = subprocess.run(['xdotool', 'getwindowname', win_id],
                                     capture_output=True, text=True, timeout=2).stdout.strip()
        except Exception:
            pass
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
    """Traduce un evento de teclado GTK a texto en formato xdotool
    ('ctrl+shift+n', 'alt+Tab', 'F11'...). Gdk.keyval_name() ya devuelve
    justo los mismos nombres de keysym X11 que usa xdotool, así que no
    hace falta ninguna tabla de conversión propia; solo se antepone el
    modificador que estuviera pulsado y, para letras sueltas, se pasa a
    minúscula (el "Shift" ya queda reflejado como modificador aparte, en
    vez de duplicarlo en la propia letra)."""
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
    """Agarra el teclado a nivel de todo el sistema para que teclas que
    Cinnamon reserva para sus propios atajos (Super, F1-F12...) lleguen
    igualmente a nuestro diálogo. Devuelve el Gdk.Seat ya agarrado
    (llamar a .ungrab() al terminar); lanza una excepción si no se puede."""
    pantalla = Gdk.Display.get_default()
    asiento = pantalla.get_default_seat() if pantalla is not None else None
    if asiento is None or gdk_window is None:
        raise RuntimeError('No se pudo obtener el dispositivo de entrada (Gdk.Seat).')
    # owner_events=False: todo evento de teclado va SIEMPRE a gdk_window,
    # sin excepciones; es el agarre más exclusivo posible.
    estado = asiento.grab(gdk_window, capacidades, False, None, None, None)
    if estado != Gdk.GrabStatus.SUCCESS:
        raise RuntimeError(f'El sistema no concedió el agarre de teclado (estado: {estado}).')
    return asiento


def _capturar_combinacion_teclado(parent):
    """Diálogo modal que captura EN VIVO la próxima tecla o combinación que
    el usuario pulse — el equivalente, para teclado, del selector de punto
    en pantalla que ya existe para los clics. Devuelve el texto en formato
    xdotool, o None si se cancela (botón Cancelar o se cierra el diálogo).
    A propósito NO se usa Esc para cancelar: Escape es una tecla legítima
    que también se puede querer capturar como paso."""
    dialogo = Gtk.Dialog(title='Capturar tecla / combinación', transient_for=parent, modal=True)
    dialogo.set_default_size(440, 160)
    dialogo.add_button('Cancelar', Gtk.ResponseType.CANCEL)
    caja = dialogo.get_content_area()
    caja.set_border_width(20)
    etiqueta = Gtk.Label()
    texto_base_etiqueta = (
        '⌨  <b>Pulsa ahora</b> la tecla o combinación que quieras enviar\n'
        '(incluida Esc, que también se puede capturar y usar como paso).\n'
        'Si una tecla reservada por el sistema (F1-F12, Super…) no se detecta, '
        'cierra esto y escríbela a mano en el campo, ej. <b>Alt+F10</b>.')
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
        # Permite capturar un modificador solo (p. ej. la tecla Windows sin
        # combinar con nada más): si se suelta el ÚNICO modificador que se
        # había pulsado hasta ahora, esa es la combinación capturada.
        if evento.keyval in _TECLAS_MODIFICADORAS and solo_modificador['keyval'] == evento.keyval:
            resultado['valor'] = _nombre_modificador_solo(evento.keyval)
            dialogo.response(Gtk.ResponseType.OK)
        return True

    dialogo.add_events(Gdk.EventMask.KEY_RELEASE_MASK)
    dialogo.connect('key-press-event', _on_key_press)
    dialogo.connect('key-release-event', _on_key_release)
    dialogo.show_all()

    # Se agarra el teclado (no el ratón, para poder seguir pulsando
    # "Cancelar" con normalidad): así teclas como F1-F12 o la de Windows,
    # que Cinnamon reserva para sus propios atajos globales, llegan
    # también aquí. FALLO CORREGIDO: justo tras show_all() la ventana aún
    # puede no estar mapeada en el servidor X y el agarre fallaba por eso
    # (perdiéndose F1-F12/Super); ahora se reintenta un rato corto.
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
            '\n<span foreground="#a15c00">⚠ No se pudo bloquear el teclado del sistema: aquí '
            'podrían no detectarse teclas reservadas.</span>')

    dialogo.run()

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
        titulo = 'Editar paso' if paso_inicial else 'Añadir paso'
        super().__init__(title=titulo, transient_for=parent, flags=0)
        self.set_default_size(640, 560)
        self.add_buttons('Cancelar', Gtk.ResponseType.CANCEL, 'Aceptar', Gtk.ResponseType.OK)
        self.pasos_previos = pasos_previos
        # FALLO CORREGIDO: dos pasos de tipo programa/web/comando podían
        # guardarse con el MISMO alias (el campo "Alias de la ventana" no
        # comprobaba duplicados; sugerir_alias solo evita choques al
        # autogenerar el nombre cuando se deja vacío, no cuando el usuario
        # escribe uno a mano). Con dos pasos usando el mismo alias, el script
        # generado sobrescribe la entrada de ALIAS_WIN del primero con la
        # ventana del segundo, así que cualquier paso posterior de tipo
        # ventana/clic/tecla/texto que apuntase "a la ventana de" ese alias
        # acababa actuando en silencio sobre la ventana equivocada. Ahora se
        # recibe el conjunto de alias ya usados por OTROS pasos de la misma
        # acción y se valida en validar_y_construir().
        self.alias_prohibidos = set(alias_prohibidos or ())
        self.paso_resultado = None
        # Por defecto, un paso de clic nuevo usa coordenadas absolutas de
        # pantalla (ver _crear_pagina_clic / _cargar_paso / validar_y_construir).
        self._coords_absolutas_actual = True

        area = self.get_content_area()
        area.set_border_width(14)
        area.set_spacing(10)

        herramientas = herramientas_x11_disponibles()
        faltan_herramientas = not (herramientas['xdotool'] and herramientas['wmctrl'])
        # MEJORA: bajo una sesión Wayland nativa, xdotool y wmctrl no
        # funcionan aunque ESTÉN instalados, así que este aviso ya no
        # depende solo de si faltan los binarios: también se muestra (con
        # un mensaje distinto, más útil) cuando la sesión es Wayland.
        if faltan_herramientas or SESION_WAYLAND:
            if SESION_WAYLAND:
                texto_aviso = ('⚠ Sesión Wayland nativa detectada: xdotool y wmctrl NO funcionan '
                                'aquí (aunque estén instalados). Los pasos de ventana, clic y tecla '
                                'no van a funcionar hasta que inicies sesión en "Cinnamon" (X11) en '
                                'vez de "Cinnamon (Wayland)".')
            else:
                faltan_nombres = [n for n, ok in herramientas.items() if not ok]
                texto_aviso = ('⚠ Falta ' + ' y '.join(faltan_nombres) + '. Algunos pasos de ventana, '
                                'clic y tecla podrían no funcionar hasta instalarlo(s) con:  '
                                'sudo apt install xdotool wmctrl  (también puedes hacerlo desde '
                                'Ajustes → «Instalar ahora»).')
            aviso = Gtk.Label(label=texto_aviso)
            aviso.get_style_context().add_class('aviso-x11')
            aviso.set_line_wrap(True)
            aviso.set_halign(Gtk.Align.START)
            area.add(aviso)

        fila_tipo = Gtk.Box(spacing=8)
        fila_tipo.add(Gtk.Label(label='Tipo de paso:'))
        self.combo_tipo = Gtk.ComboBoxText()
        for clave in ORDEN_TIPOS_PASO:
            self.combo_tipo.append(clave, TIPOS_PASO[clave])
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

        # MEJORA: botón "Probar este paso ahora" para los pasos que abren
        # algo (programa/web/comando), para ver en el momento si la
        # ventana se coloca donde toca sin tener que guardar toda la
        # acción, cerrar el diálogo y ejecutarla entera. Ejecuta SOLO este
        # paso (con la colocación de ventana configurada, si la hay), de
        # forma independiente de los demás pasos de la acción.
        self.btn_probar_paso = Gtk.Button(label='▶ Probar este paso ahora')
        self.btn_probar_paso.set_tooltip_text(
            'Ejecuta solo este paso tal y como está configurado ahora mismo (abre el programa/'
            'web/comando, hace el clic, envía la tecla o coloca la ventana, según el tipo), '
            'sin guardar ni tocar el resto de la acción.')
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
        """Crea el widget compartido 'Aplicar a qué ventana' para los pasos
        de tipo ventana/clic/tecla/texto."""
        caja = Gtk.Grid(column_spacing=10, row_spacing=6)
        combo = Gtk.ComboBoxText()
        combo.append('_ultima', 'Última ventana abierta por esta acción')
        for alias_id, etiqueta in alias_disponibles_antes_de(self.pasos_previos, indice_paso):
            combo.append(f'_alias:{alias_id}', f'Ventana de: {etiqueta}')
        combo.append('_buscar', 'Buscar por título de ventana…')
        combo.set_active_id('_ultima')
        entry_buscar = Gtk.Entry()
        entry_buscar.set_placeholder_text('Texto que aparece en el título de la ventana')
        entry_buscar.set_visible(False)
        entry_buscar.set_no_show_all(True)

        def _cambio(c):
            entry_buscar.set_visible(c.get_active_id() == '_buscar')
        combo.connect('changed', _cambio)

        _fila_grid(caja, 0, 'Aplicar a:', combo)
        _fila_grid(caja, 1, 'Buscar título:', entry_buscar)
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
            combo.set_active_id(f'_alias:{paso.get("objetivo_alias", "")}')
            if combo.get_active_id() is None:
                combo.set_active_id('_ultima')
        elif modo == '_buscar':
            combo.set_active_id('_buscar')
            entry_buscar.set_text(paso.get('objetivo_buscar', ''))
            entry_buscar.set_visible(True)
        else:
            combo.set_active_id('_ultima')

    # -- sección reutilizable: "colocar ventana tras abrir" -----------------
    def _crear_seccion_colocar_ventana(self, prefijo):
        """Crea los controles para colocar/organizar automáticamente la
        ventana justo después de abrirla, y los guarda en
        self.colocar_<prefijo> (dict de widgets). Se usa igual en los pasos
        de programa, web y comando: así la colocación queda integrada en la
        propia apertura en vez de depender de un paso 'ventana' aparte que
        tenga que volver a localizarla después."""
        marco = Gtk.Frame(label=' Colocación de la ventana (opcional) ')
        caja = Gtk.Grid(column_spacing=12, row_spacing=8)
        caja.set_border_width(10)
        marco.add(caja)

        check = Gtk.CheckButton(label='Colocar / organizar esta ventana justo después de abrirla')
        caja.attach(check, 0, 0, 3, 1)

        combo = Gtk.ComboBoxText()
        for clave in ORDEN_POSICIONES:
            combo.append(clave, POSICIONES[clave])
        combo.set_active_id('maximizar')
        _fila_grid(caja, 1, 'Acción sobre la ventana:', combo)

        grid_pers = Gtk.Grid(column_spacing=10, row_spacing=6)
        spin_x = Gtk.SpinButton.new_with_range(0, 100, 1)
        spin_y = Gtk.SpinButton.new_with_range(0, 100, 1)
        spin_w = Gtk.SpinButton.new_with_range(1, 100, 1)
        spin_h = Gtk.SpinButton.new_with_range(1, 100, 1)
        spin_w.set_value(50)
        spin_h.set_value(50)
        _fila_grid(grid_pers, 0, 'Posición X (% pantalla):', spin_x)
        _fila_grid(grid_pers, 1, 'Posición Y (% pantalla):', spin_y)
        _fila_grid(grid_pers, 2, 'Ancho (% pantalla):', spin_w)
        _fila_grid(grid_pers, 3, 'Alto (% pantalla):', spin_h)
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
        """Lee los controles de 'colocar ventana' hacia el paso. Devuelve un
        mensaje de error (str) si la configuración no es válida (p. ej.
        porcentajes personalizados que se salen de pantalla), o None si
        todo está bien."""
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
            # No dejar que un .desktop raro en el sistema impida abrir el
            # diálogo de "Añadir paso"; simplemente se ofrece el catálogo
            # vacío (siempre queda la pestaña "Ruta / comando manual").
            self._apps_instaladas = []
        self.store_apps = Gtk.ListStore(str, str, str)  # nombre, ruta .desktop, exec
        for app in self._apps_instaladas:
            self.store_apps.append([app['nombre'], app['ruta'], app['exec']])

        completado = Gtk.EntryCompletion()
        completado.set_model(self.store_apps)
        completado.set_text_column(0)
        completado.set_inline_selection(True)
        completado.set_minimum_key_length(0)

        def _coincide(completion, cadena, iterador, datos=None):
            return cadena.lower() in self.store_apps[iterador][0].lower()
        completado.set_match_func(_coincide)

        self.entry_app_instalada = Gtk.Entry()
        self._ruta_app_seleccionada = None
        self.entry_app_instalada.set_placeholder_text(
            f'Escribe para buscar entre {len(self._apps_instaladas)} aplicaciones y accesos directos detectados…')
        self.entry_app_instalada.set_completion(completado)

        def _on_coincidencia(completion, modelo, iterador):
            # FALLO CORREGIDO: la señal 'match-selected' pertenece al objeto
            # GtkEntryCompletion (aquí "completado"), NO al GtkEntry. Estaba
            # conectada sobre self.entry_app_instalada, cuyo tipo (GtkEntry)
            # no tiene esa señal. PyGObject valida el nombre de la señal en
            # el momento del connect() y lanza
            # "TypeError: unknown signal name: match-selected" de inmediato,
            # así que este error saltaba SIEMPRE al construir la página
            # "Aplicación instalada" del diálogo, es decir, cada vez que se
            # abría "Añadir paso" (o "Editar paso"): por eso el botón
            # parecía "no hacer nada" / bloqueaba el uso del programa.
            self.entry_app_instalada.set_text(modelo[iterador][0])
            self.entry_app_instalada.set_position(-1)
            self._ruta_app_seleccionada = modelo[iterador][1]
            return True
        completado.connect('match-selected', _on_coincidencia)

        f = 0
        f = _fila_grid(pag_catalogo, f, 'Aplicación / acceso directo:', self.entry_app_instalada)
        btn_recargar = Gtk.Button(label='🔄 Volver a detectar aplicaciones instaladas')
        btn_recargar.connect('clicked', self._on_recargar_apps)
        pag_catalogo.attach(btn_recargar, 1, f, 2, 1)
        f += 1
        ayuda_catalogo = Gtk.Label(
            label='Busca por nombre: se detectan automáticamente los programas instalados '
                  '(incluidos Snap y Flatpak) y los accesos directos de tu Escritorio. Si no '
                  'encuentras algo aquí, usa la pestaña "Ruta / comando manual".')
        ayuda_catalogo.set_line_wrap(True)
        ayuda_catalogo.set_halign(Gtk.Align.START)
        pag_catalogo.attach(ayuda_catalogo, 0, f, 3, 1)
        self.stack_programa.add_titled(pag_catalogo, 'instalado', 'Aplicación instalada')

        # -- sub-página: ruta o comando manual ---------------------------
        pag_manual = Gtk.Grid(column_spacing=12, row_spacing=8)
        pag_manual.set_border_width(6)
        self.chooser_programa = Gtk.FileChooserButton(title='Selecciona el ejecutable o el acceso directo',
                                                        action=Gtk.FileChooserAction.OPEN)
        self.chooser_programa.set_current_folder('/usr/bin')
        filtro_desktop = Gtk.FileFilter()
        filtro_desktop.set_name('Accesos directos (.desktop)')
        filtro_desktop.add_pattern('*.desktop')
        filtro_todos = Gtk.FileFilter()
        filtro_todos.set_name('Todos los archivos')
        filtro_todos.add_pattern('*')
        self.chooser_programa.add_filter(filtro_desktop)
        self.chooser_programa.add_filter(filtro_todos)
        fm = 0
        fm = _fila_grid(pag_manual, fm, 'Ejecutable o .desktop:', self.chooser_programa)
        self.entry_argumentos = Gtk.Entry()
        self.entry_argumentos.set_placeholder_text('Ej: --nueva-ventana archivo.txt (se ignora si eliges un .desktop)')
        fm = _fila_grid(pag_manual, fm, 'Argumentos (opcional):', self.entry_argumentos)
        ayuda_manual = Gtk.Label(
            label='Úsalo para binarios o scripts que no aparecen en el catálogo, o para elegir a '
                  'mano un acceso directo (.desktop) guardado en otra carpeta.')
        ayuda_manual.set_line_wrap(True)
        ayuda_manual.set_halign(Gtk.Align.START)
        pag_manual.attach(ayuda_manual, 0, fm, 3, 1)
        self.stack_programa.add_titled(pag_manual, 'manual', 'Ruta / comando manual')
        self.stack_programa.set_visible_child_name('instalado')

        # -- campos comunes a ambos modos ---------------------------------
        grid_comun = Gtk.Grid(column_spacing=12, row_spacing=8)
        fc = 0
        self.entry_alias_programa = Gtk.Entry()
        self.entry_alias_programa.set_placeholder_text('(opcional) nombre para referirte a esta ventana después')
        fc = _fila_grid(grid_comun, fc, 'Alias de la ventana:', self.entry_alias_programa)
        self.spin_espera_programa = Gtk.SpinButton.new_with_range(0, 30, 0.5)
        self.spin_espera_programa.set_value(2.5)
        self.spin_espera_programa.set_digits(1)
        fc = _fila_grid(grid_comun, fc, 'Esperar como máximo tras abrir (s):', self.spin_espera_programa)
        outer.pack_start(grid_comun, False, False, 0)

        outer.pack_start(self._crear_seccion_colocar_ventana('programa'), False, False, 0)

        self.stack.add_titled(outer, 'programa', TIPOS_PASO['programa'])

    def _on_recargar_apps(self, widget):
        try:
            self._apps_instaladas = listar_aplicaciones_instaladas()
        except Exception:
            self._apps_instaladas = []
        self.store_apps.clear()
        for app in self._apps_instaladas:
            self.store_apps.append([app['nombre'], app['ruta'], app['exec']])
        self.entry_app_instalada.set_placeholder_text(
            f'Escribe para buscar entre {len(self._apps_instaladas)} aplicaciones y accesos directos detectados…')

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
        """Versión genérica de _resolver_ruta_app_seleccionada: dado
        cualquier Gtk.Entry con autocompletado sobre self.store_apps (y la
        última ruta que se marcó como 'seleccionada' desde la sugerencia
        del autocompletado), decide qué acceso directo (.desktop) usar. Se
        reutiliza tanto para el paso 'programa' como para "abrir con una
        aplicación concreta" del paso 'documento', para no duplicar esta
        lógica dos veces."""
        texto = entry_widget.get_text().strip()
        if ruta_seleccionada_actual:
            for fila in self.store_apps:
                if fila[1] == ruta_seleccionada_actual and fila[0] == texto:
                    return ruta_seleccionada_actual
        return self._buscar_app_por_nombre(texto)

    def _crear_pagina_documento(self):
        """NUEVO TIPO DE PASO: 'documento' — abrir un archivo/documento
        concreto, eligiéndolo con el explorador de archivos estándar de
        GTK (Gtk.FileChooserButton, el mismo widget que ya se usaba para
        el modo "Ruta / comando manual" del paso 'programa'). Por defecto
        se abre con la aplicación predeterminada del sistema para ese tipo
        de archivo (xdg-open, lo mismo que haría un doble clic desde el
        gestor de archivos); opcionalmente se puede forzar una aplicación
        instalada concreta, reutilizando el mismo catálogo de aplicaciones
        ya detectado para el paso 'programa' (self.store_apps)."""
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        outer.set_border_width(6)
        grid = Gtk.Grid(column_spacing=12, row_spacing=8)

        self.chooser_documento = Gtk.FileChooserButton(
            title='Selecciona el documento o archivo a abrir', action=Gtk.FileChooserAction.OPEN)
        self.chooser_documento.set_current_folder(os.path.expanduser('~'))
        filtro_todos_doc = Gtk.FileFilter()
        filtro_todos_doc.set_name('Todos los archivos')
        filtro_todos_doc.add_pattern('*')
        self.chooser_documento.add_filter(filtro_todos_doc)
        f = 0
        f = _fila_grid(grid, f, 'Documento / archivo:', self.chooser_documento)

        self.check_abrir_con_app = Gtk.CheckButton(
            label='Abrir con una aplicación instalada concreta (opcional)')
        grid.attach(self.check_abrir_con_app, 1, f, 2, 1)
        f += 1

        self.entry_app_documento = Gtk.Entry()
        self._ruta_app_documento_seleccionada = None
        self.entry_app_documento.set_placeholder_text('Escribe para buscar entre las aplicaciones instaladas…')
        # Reutiliza el mismo modelo (self.store_apps) que ya rellena
        # _crear_pagina_programa, así no hace falta volver a escanear los
        # .desktop del sistema una segunda vez.
        completado_doc = Gtk.EntryCompletion()
        completado_doc.set_model(self.store_apps)
        completado_doc.set_text_column(0)
        completado_doc.set_inline_selection(True)
        completado_doc.set_minimum_key_length(0)

        def _coincide_doc(completion, cadena, iterador, datos=None):
            return cadena.lower() in self.store_apps[iterador][0].lower()
        completado_doc.set_match_func(_coincide_doc)

        def _on_coincidencia_doc(completion, modelo, iterador):
            self.entry_app_documento.set_text(modelo[iterador][0])
            self.entry_app_documento.set_position(-1)
            self._ruta_app_documento_seleccionada = modelo[iterador][1]
            return True
        completado_doc.connect('match-selected', _on_coincidencia_doc)
        self.entry_app_documento.set_completion(completado_doc)
        f = _fila_grid(grid, f, 'Aplicación:', self.entry_app_documento)
        self.entry_app_documento.set_sensitive(False)
        self.check_abrir_con_app.connect(
            'toggled', lambda c: self.entry_app_documento.set_sensitive(c.get_active()))

        self.entry_alias_documento = Gtk.Entry()
        self.entry_alias_documento.set_placeholder_text('(opcional) nombre para referirte a esta ventana después')
        f = _fila_grid(grid, f, 'Alias de la ventana:', self.entry_alias_documento)
        self.spin_espera_documento = Gtk.SpinButton.new_with_range(0, 30, 0.5)
        self.spin_espera_documento.set_value(2.5)
        self.spin_espera_documento.set_digits(1)
        f = _fila_grid(grid, f, 'Esperar como máximo tras abrir (s):', self.spin_espera_documento)

        ayuda_doc = Gtk.Label(
            label='Por defecto se abre con la aplicación predeterminada del sistema para ese tipo '
                  'de archivo (xdg-open) — lo mismo que un doble clic desde el gestor de archivos. '
                  'Marca la casilla de arriba solo si necesitas forzar una aplicación concreta.')
        ayuda_doc.set_line_wrap(True)
        ayuda_doc.set_halign(Gtk.Align.START)
        grid.attach(ayuda_doc, 0, f, 3, 1)

        outer.pack_start(grid, False, False, 0)
        outer.pack_start(self._crear_seccion_colocar_ventana('documento'), False, False, 0)
        self.stack.add_titled(outer, 'documento', TIPOS_PASO['documento'])

    def _crear_pagina_web(self):
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        outer.set_border_width(6)
        grid = Gtk.Grid(column_spacing=12, row_spacing=8)
        self.entry_url = Gtk.Entry()
        self.entry_url.set_placeholder_text('https://...')
        f = 0
        f = _fila_grid(grid, f, 'URL:', self.entry_url)
        self.combo_navegador = Gtk.ComboBoxText()
        for clave, info in NAVEGADORES.items():
            self.combo_navegador.append(clave, info['nombre'])
        # FALLO CORREGIDO: el ajuste "Navegador predeterminado para Sitio
        # web" (pestaña Ajustes) se guardaba correctamente pero nunca se
        # leía en ningún sitio: todo paso nuevo de tipo "web" empezaba
        # siempre en "sistema" sin importar lo configurado. Ahora sí se usa
        # como valor inicial (el paso se puede seguir cambiando a mano).
        self.combo_navegador.set_active_id(cargar_ajustes().get('navegador_predeterminado', 'sistema'))
        f = _fila_grid(grid, f, 'Navegador:', self.combo_navegador)
        self.check_nueva_ventana = Gtk.CheckButton(label='Abrir en una ventana nueva (si no, se abre como pestaña)')
        grid.attach(self.check_nueva_ventana, 1, f, 2, 1)
        f += 1
        ayuda_nueva_ventana = Gtk.Label(
            label='Con "Predeterminado del sistema" se detecta automáticamente qué navegador es '
                  '(Firefox, Chrome, Chromium o Brave) para poder abrir la ventana nueva.')
        ayuda_nueva_ventana.set_line_wrap(True)
        ayuda_nueva_ventana.set_halign(Gtk.Align.START)
        grid.attach(ayuda_nueva_ventana, 1, f, 2, 1)
        f += 1
        self.check_modo_app = Gtk.CheckButton(label='Abrir como app (sin barra de direcciones; solo Chrome/Chromium/Brave)')
        grid.attach(self.check_modo_app, 1, f, 2, 1)
        f += 1
        self.entry_alias_web = Gtk.Entry()
        self.entry_alias_web.set_placeholder_text('(opcional) nombre para referirte a esta ventana después')
        f = _fila_grid(grid, f, 'Alias de la ventana:', self.entry_alias_web)
        self.spin_espera_web = Gtk.SpinButton.new_with_range(0, 30, 0.5)
        self.spin_espera_web.set_value(3.0)
        self.spin_espera_web.set_digits(1)
        f = _fila_grid(grid, f, 'Esperar como máximo tras abrir (s):', self.spin_espera_web)
        outer.pack_start(grid, False, False, 0)
        outer.pack_start(self._crear_seccion_colocar_ventana('web'), False, False, 0)
        self.stack.add_titled(outer, 'web', TIPOS_PASO['web'])

    def _crear_pagina_comando(self):
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        outer.set_border_width(6)
        grid = Gtk.Grid(column_spacing=12, row_spacing=8)
        self.entry_comando = Gtk.Entry()
        self.entry_comando.set_placeholder_text("Ej: notify-send 'Hola'  /  ~/scripts/backup.sh")
        f = 0
        f = _fila_grid(grid, f, 'Comando:', self.entry_comando)
        self.entry_alias_comando = Gtk.Entry()
        self.entry_alias_comando.set_placeholder_text('(opcional) nombre para referirte a esta ventana después')
        f = _fila_grid(grid, f, 'Alias de la ventana:', self.entry_alias_comando)
        self.spin_espera_comando = Gtk.SpinButton.new_with_range(0, 30, 0.5)
        self.spin_espera_comando.set_value(2.5)
        self.spin_espera_comando.set_digits(1)
        f = _fila_grid(grid, f, 'Esperar como máximo tras ejecutar (s):', self.spin_espera_comando)
        ayuda_comando = Gtk.Label(
            label='El comando se ejecuta en una terminal visible (para poder ver su salida o '
                  'cualquier error); la terminal queda abierta al terminar hasta pulsar Intro.')
        ayuda_comando.set_line_wrap(True)
        ayuda_comando.set_halign(Gtk.Align.START)
        grid.attach(ayuda_comando, 0, f, 3, 1)
        outer.pack_start(grid, False, False, 0)
        outer.pack_start(self._crear_seccion_colocar_ventana('comando'), False, False, 0)
        self.stack.add_titled(outer, 'comando', TIPOS_PASO['comando'])

    def _crear_pagina_esperar(self):
        grid = Gtk.Grid(column_spacing=12, row_spacing=8)
        grid.set_border_width(6)
        self.spin_segundos_esperar = Gtk.SpinButton.new_with_range(0.5, 120, 0.5)
        self.spin_segundos_esperar.set_value(2)
        self.spin_segundos_esperar.set_digits(1)
        _fila_grid(grid, 0, 'Esperar (segundos):', self.spin_segundos_esperar)
        self.stack.add_titled(grid, 'esperar', TIPOS_PASO['esperar'])

    def _crear_pagina_ventana(self):
        grid = Gtk.Grid(column_spacing=12, row_spacing=8)
        grid.set_border_width(6)
        aviso_avanzado = Gtk.Label(
            label='Avanzado: úsalo solo para reposicionar una ventana que ya estaba abierta de '
                  'antes (buscándola por título). Para la ventana que abre un paso de programa/web/'
                  'comando, activa "Colocar / organizar ventana" dentro de ese mismo paso: es más fiable.')
        aviso_avanzado.set_line_wrap(True)
        aviso_avanzado.set_halign(Gtk.Align.START)
        grid.attach(aviso_avanzado, 0, 0, 3, 1)
        selector, self.combo_objetivo_ventana, self.entry_buscar_ventana = self._crear_selector_objetivo(None)
        grid.attach(selector, 0, 1, 3, 1)
        self.combo_posicion = Gtk.ComboBoxText()
        for clave in ORDEN_POSICIONES:
            self.combo_posicion.append(clave, POSICIONES[clave])
        self.combo_posicion.set_active_id('maximizar')
        self.combo_posicion.connect('changed', self._on_cambio_posicion)
        _fila_grid(grid, 2, 'Acción sobre la ventana:', self.combo_posicion)

        self.caja_personalizada = Gtk.Grid(column_spacing=10, row_spacing=6)
        self.spin_pers_x = Gtk.SpinButton.new_with_range(0, 100, 1)
        self.spin_pers_y = Gtk.SpinButton.new_with_range(0, 100, 1)
        self.spin_pers_w = Gtk.SpinButton.new_with_range(1, 100, 1)
        self.spin_pers_h = Gtk.SpinButton.new_with_range(1, 100, 1)
        self.spin_pers_w.set_value(50)
        self.spin_pers_h.set_value(50)
        _fila_grid(self.caja_personalizada, 0, 'Posición X (% pantalla):', self.spin_pers_x)
        _fila_grid(self.caja_personalizada, 1, 'Posición Y (% pantalla):', self.spin_pers_y)
        _fila_grid(self.caja_personalizada, 2, 'Ancho (% pantalla):', self.spin_pers_w)
        _fila_grid(self.caja_personalizada, 3, 'Alto (% pantalla):', self.spin_pers_h)
        grid.attach(self.caja_personalizada, 0, 4, 3, 1)
        self.caja_personalizada.set_visible(False)
        self.caja_personalizada.set_no_show_all(True)

        self.stack.add_titled(grid, 'ventana', TIPOS_PASO['ventana'])

    def _crear_pagina_clic(self):
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        outer.set_border_width(6)

        grid = Gtk.Grid(column_spacing=12, row_spacing=8)
        # FALLO CORREGIDO / REDISEÑADO: antes era obligatorio elegir primero
        # una "ventana objetivo" (última ventana / alias / búsqueda) para
        # poder simular un clic, y la coordenada se guardaba relativa a esa
        # ventana. Aparte de innecesario (el selector de punto ya captura
        # una posición exacta de pantalla), esto era frágil: si al EJECUTAR
        # el paso se resolvía una ventana distinta de la que había bajo el
        # cursor al ELEGIR el punto, el clic acababa en el sitio equivocado
        # o no hacía nada. Ahora el clic usa coordenadas ABSOLUTAS de
        # pantalla por defecto (las mismas donde se hizo clic al elegir el
        # punto) y no hace falta seleccionar ninguna ventana en absoluto.
        ayuda = Gtk.Label(
            label='Coordenadas absolutas de pantalla: el clic se simula siempre en ese punto '
                  'exacto, sin necesidad de elegir ninguna ventana.')
        ayuda.set_line_wrap(True)
        ayuda.set_halign(Gtk.Align.START)
        grid.attach(ayuda, 0, 0, 3, 1)
        self.spin_x_clic = Gtk.SpinButton.new_with_range(0, 20000, 1)
        self.spin_y_clic = Gtk.SpinButton.new_with_range(0, 20000, 1)
        self.spin_x_clic.set_value(100)
        self.spin_y_clic.set_value(100)
        _fila_grid(grid, 1, 'Coordenada X:', self.spin_x_clic)
        _fila_grid(grid, 2, 'Coordenada Y:', self.spin_y_clic)

        btn_elegir_punto = Gtk.Button(label='🎯  Elegir punto en la pantalla…')
        btn_elegir_punto.connect('clicked', self._on_elegir_punto_clic)
        grid.attach(btn_elegir_punto, 1, 3, 2, 1)
        self.label_punto_detectado = Gtk.Label(label='')
        self.label_punto_detectado.set_line_wrap(True)
        self.label_punto_detectado.set_halign(Gtk.Align.START)
        grid.attach(self.label_punto_detectado, 0, 4, 3, 1)

        self.combo_boton = Gtk.ComboBoxText()
        for clave, etiqueta in BOTONES_RATON.items():
            self.combo_boton.append(clave, etiqueta)
        self.combo_boton.set_active_id('1')
        _fila_grid(grid, 5, 'Botón del ratón:', self.combo_boton)
        self.check_doble_clic = Gtk.CheckButton(label='Doble clic')
        grid.attach(self.check_doble_clic, 1, 6, 2, 1)
        outer.pack_start(grid, False, False, 0)

        # -- sección opcional: activar una ventana concreta antes del clic
        marco_activar = Gtk.Frame(label=' Activar una ventana antes de hacer clic (opcional) ')
        caja_activar = Gtk.Grid(column_spacing=12, row_spacing=8)
        caja_activar.set_border_width(10)
        marco_activar.add(caja_activar)
        self.check_activar_ventana_clic = Gtk.CheckButton(
            label='Activar/enfocar una ventana justo antes de hacer el clic')
        caja_activar.attach(self.check_activar_ventana_clic, 0, 0, 3, 1)
        ayuda_activar = Gtk.Label(
            label='Solo hace falta si esa ventana pudiera estar minimizada o detrás de otras '
                  '(por ejemplo si no la coloca ningún paso anterior).')
        ayuda_activar.set_line_wrap(True)
        ayuda_activar.set_halign(Gtk.Align.START)
        caja_activar.attach(ayuda_activar, 0, 1, 3, 1)
        selector_clic, self.combo_objetivo_clic, self.entry_buscar_clic = self._crear_selector_objetivo(None)
        caja_activar.attach(selector_clic, 0, 2, 3, 1)
        selector_clic.set_sensitive(False)
        self.check_activar_ventana_clic.connect(
            'toggled', lambda c: selector_clic.set_sensitive(c.get_active()))
        outer.pack_start(marco_activar, False, False, 0)

        self.stack.add_titled(outer, 'clic', TIPOS_PASO['clic'])

    def _on_elegir_punto_clic(self, widget):
        herramientas = herramientas_x11_disponibles()
        if not herramientas['xdotool']:
            self.label_punto_detectado.set_text(
                '⚠ Instala xdotool para poder elegir el punto y simular el clic '
                '(sudo apt install xdotool).')
            return
        # Se avisa aquí, con el diálogo todavía visible, de la forma de
        # proceder y el tiempo disponible, antes de ocultar nada.
        self.label_punto_detectado.set_text(
            '🕒 Esta ventana se va a ocultar un momento: coloca el cursor donde '
            f'quieras hacer clic. Tendrás {SEGUNDOS_CUENTA_ATRAS_CLIC} segundos en '
            'cuanto veas la cuenta atrás en la esquina.')
        while Gtk.events_pending():
            Gtk.main_iteration()
        GLib.timeout_add(900, self._ocultar_para_capturar)

    def _ocultar_para_capturar(self):
        # Este diálogo se muestra con Gtk.Dialog.run(), que vigila la señal
        # "unmap" para saber cuándo terminar. Ocultarlo con self.hide()
        # dispararía esa señal y run() terminaría solo, destruyendo el
        # diálogo antes de llegar a elegir el punto. Por eso, en vez de
        # ocultarlo, se saca de la vista dejándolo mapeado: se mueve fuera
        # de la pantalla visible y se pone a opacidad 0.
        self._ventana_principal_para_captura = self.get_transient_for()
        self._posicion_previa_captura = self.get_position()
        self.set_opacity(0)
        self.move(-32000, -32000)
        if self._ventana_principal_para_captura is not None:
            vp = self._ventana_principal_para_captura
            # skip_taskbar/skip_pager además de iconify(): así tampoco queda
            # ningún botón con su icono visible en la lista de ventanas del
            # panel mientras dura la captura de pantalla completa.
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
            # Se resuelve la ventana bajo el punto AQUÍ, con el resultado
            # recién obtenido y antes de restaurar nada: la propia ventana
            # principal, ya recolocada, podría quedar bajo el cursor y
            # "robarle" el resultado a la ventana que en realidad se pinchó.
            if punto is not None:
                _, _, nombre_ventana = _resolver_ventana_bajo_punto(*punto)
        except Exception as excepcion:
            _registrar_error('Elegir punto en la pantalla', excepcion)
        finally:
            # La restauración (deiconificar la ventana principal, devolver
            # este diálogo a su sitio) va en un "finally": así ocurre
            # siempre, aunque _capturar_punto_pantalla() lance una excepción.
            if ventana_principal is not None:
                ventana_principal.deiconify()
                ventana_principal.present()
                ventana_principal.set_skip_taskbar_hint(False)
                ventana_principal.set_skip_pager_hint(False)
            # El diálogo nunca se ocultó (ver _ocultar_para_capturar): solo
            # se movió fuera de pantalla y se puso a opacidad 0, así que
            # aquí basta con devolverlo a su sitio y hacerlo opaco de nuevo
            # — nada de show()/hide(), que es justo lo que había que evitar.
            pos = getattr(self, '_posicion_previa_captura', None)
            if pos is not None:
                self.move(*pos)
            self.set_opacity(1)
            self.present()

        if punto is not None:
            x_abs, y_abs = int(round(punto[0])), int(round(punto[1]))
            self.spin_x_clic.set_value(max(0, x_abs))
            self.spin_y_clic.set_value(max(0, y_abs))
            # Una captura nueva siempre produce coordenadas absolutas,
            # aunque el paso que se esté editando viniera de una versión
            # antigua con coordenadas relativas a una ventana.
            self._coords_absolutas_actual = True
            if nombre_ventana:
                self.label_punto_detectado.set_text(
                    f'✔ Punto capturado: ({x_abs}, {y_abs}) — sobre la ventana «{nombre_ventana}».')
                # Comodidad: si más tarde se activa "Activar ventana antes
                # de hacer clic", el buscador ya queda listo con esta.
                self.entry_buscar_clic.set_text(nombre_ventana)
            else:
                self.label_punto_detectado.set_text(f'✔ Punto capturado: ({x_abs}, {y_abs}).')
        else:
            self.label_punto_detectado.set_text(
                '⚠ No se pudo leer la posición del ratón (¿xdotool instalado?). '
                'Vuelve a pulsar «Elegir punto en la pantalla…» para intentarlo de nuevo.')
        return False

    def _crear_pagina_tecla(self):
        grid = Gtk.Grid(column_spacing=12, row_spacing=8)
        grid.set_border_width(6)
        selector, self.combo_objetivo_tecla, self.entry_buscar_tecla = self._crear_selector_objetivo(None)
        grid.attach(selector, 0, 0, 3, 1)
        self.entry_combinacion = Gtk.Entry()
        self.entry_combinacion.set_placeholder_text('Ej: Alt+F10')
        _fila_grid(grid, 1, 'Tecla / combinación:', self.entry_combinacion)
        btn_capturar_tecla = Gtk.Button(label='⌨  Capturar pulsando…')
        btn_capturar_tecla.connect('clicked', self._on_capturar_tecla)
        grid.attach(btn_capturar_tecla, 1, 2, 2, 1)
        self.label_tecla_capturada = Gtk.Label(label='')
        self.label_tecla_capturada.set_line_wrap(True)
        self.label_tecla_capturada.set_halign(Gtk.Align.START)
        grid.attach(self.label_tecla_capturada, 0, 3, 3, 1)
        ayuda = Gtk.Label(label='💡 También puedes escribirla tú mismo en el campo de arriba, sin '
                                 'necesidad de capturarla: por ejemplo Alt+F10, Ctrl+Shift+Esc o '
                                 'Super+D (Super es la tecla del logo de Windows). Varias teclas '
                                 'unidas con "+" forman una combinación; añade varios pasos de este '
                                 'tipo para enviarlas en secuencia, una detrás de otra.')
        ayuda.set_line_wrap(True)
        ayuda.set_halign(Gtk.Align.START)
        grid.attach(ayuda, 0, 4, 3, 1)
        self.stack.add_titled(grid, 'tecla', TIPOS_PASO['tecla'])

    def _on_capturar_tecla(self, widget):
        """Abre el diálogo de captura EN VIVO (ver _capturar_combinacion_
        teclado) y, si el usuario pulsa algo antes de cancelar, vuelca el
        resultado directamente en el campo de texto de la combinación."""
        try:
            combinacion = _capturar_combinacion_teclado(self)
        except Exception as excepcion:
            _registrar_error('Capturar tecla en vivo', excepcion)
            self.label_tecla_capturada.set_text(f'⚠ No se pudo capturar la tecla: {excepcion}')
            return
        if combinacion:
            self.entry_combinacion.set_text(combinacion)
            self.label_tecla_capturada.set_text(f'✔ Capturado: {combinacion}')
        else:
            self.label_tecla_capturada.set_text('Captura cancelada.')

    def _crear_pagina_texto(self):
        grid = Gtk.Grid(column_spacing=12, row_spacing=8)
        grid.set_border_width(6)
        selector, self.combo_objetivo_texto, self.entry_buscar_texto = self._crear_selector_objetivo(None)
        grid.attach(selector, 0, 0, 3, 1)
        self.entry_texto = Gtk.Entry()
        self.entry_texto.set_placeholder_text('Texto que se escribirá donde esté el cursor/foco')
        _fila_grid(grid, 1, 'Texto a escribir:', self.entry_texto)
        self.stack.add_titled(grid, 'texto', TIPOS_PASO['texto'])

    # -- eventos internos ----------------------------------------------------
    def _on_cambio_tipo(self, combo):
        tipo = combo.get_active_id()
        if tipo:
            self.stack.set_visible_child_name(tipo)
            if hasattr(self, 'btn_probar_paso'):
                # MEJORA: "Probar este paso ahora" es completamente genérico
                # (genera y ejecuta un script de un solo paso, sea cual sea
                # su tipo), así que no hay motivo para limitarlo solo a
                # programa/web/comando. Con las mejoras de esta revisión
                # (clic con coordenadas absolutas, y resolución de ventana
                # con respaldo a la ventana con foco), probar un clic, una
                # tecla o un paso de "ventana" suelto también funciona bien
                # de forma aislada.
                self.btn_probar_paso.set_visible(
                    tipo in ('programa', 'documento', 'web', 'comando', 'clic', 'tecla', 'texto', 'ventana'))

    def _mostrar_info_prueba(self, texto, es_error=False):
        dialogo = Gtk.MessageDialog(
            transient_for=self, flags=0,
            message_type=Gtk.MessageType.ERROR if es_error else Gtk.MessageType.INFO,
            buttons=Gtk.ButtonsType.OK, text=texto)
        dialogo.run()
        dialogo.destroy()

    def _on_probar_paso(self, widget):
        """MEJORA: 'Probar este paso ahora' — valida y ejecuta SOLO el paso
        que se está editando (con la misma colocación de ventana que
        tendría dentro de la acción completa), sin guardar nada ni afectar
        a los demás pasos. Se ejecuta en segundo plano (sondeando con
        GLib.timeout_add, sin bloquear la interfaz) y al terminar muestra
        el registro de lo que ha pasado."""
        try:
            paso, error = self.validar_y_construir()
        except Exception as excepcion:
            _registrar_error('Probar este paso (validación)', excepcion)
            self._mostrar_info_prueba(f'Error al leer los datos del paso:\n{excepcion}', es_error=True)
            return
        if error:
            self._mostrar_info_prueba(error, es_error=True)
            return

        try:
            script = generar_script_bash([paso], 'Prueba de paso')
            fd, ruta_script = tempfile.mkstemp(prefix='prueba_paso_', suffix='.sh', dir=TMP_DIR)
            with os.fdopen(fd, 'w', encoding='utf-8') as f:
                f.write(script)
            os.chmod(ruta_script, 0o755)
            fd_log, ruta_log = tempfile.mkstemp(prefix='prueba_paso_', suffix='.log', dir=TMP_DIR)
            os.close(fd_log)
        except Exception as excepcion:
            _registrar_error('Probar este paso (preparación)', excepcion)
            self._mostrar_info_prueba(f'No se pudo preparar la prueba:\n{excepcion}', es_error=True)
            return

        etiqueta_original = widget.get_label()
        widget.set_sensitive(False)
        widget.set_label('⏳ Probando…')
        try:
            log_f = open(ruta_log, 'w', encoding='utf-8')
            proceso = subprocess.Popen(['bash', ruta_script], stdout=subprocess.DEVNULL,
                                        stderr=log_f, start_new_session=True)
        except Exception as excepcion:
            _registrar_error('Probar este paso (ejecución)', excepcion)
            widget.set_sensitive(True)
            widget.set_label(etiqueta_original)
            self._mostrar_info_prueba(f'No se pudo ejecutar la prueba:\n{excepcion}', es_error=True)
            return

        def _revisar(*_args):
            try:
                if proceso.poll() is None:
                    return True  # seguir comprobando
                try:
                    log_f.close()
                except Exception:
                    pass
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
                texto = salida or '(sin mensajes; revisa visualmente si la ventana se colocó donde esperabas)'
                try:
                    self._mostrar_info_prueba(f'Resultado de la prueba:\n\n{texto}')
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
        tipo = paso.get('tipo', 'programa')
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
            self.combo_navegador.set_active_id(paso.get('navegador', 'sistema'))
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
            self.combo_boton.set_active_id(str(paso.get('boton', '1')))
            self.check_doble_clic.set_active(paso.get('doble', False))
            # Recuerda si este paso venía con coordenadas relativas a una
            # ventana (formato antiguo) para no reinterpretarlas por error
            # como absolutas si se guarda sin volver a capturar el punto.
            self._coords_absolutas_actual = paso.get('coords_absolutas', True)
            if not self._coords_absolutas_actual:
                self.label_punto_detectado.set_text(
                    '⚠ Este paso usa coordenadas de una versión antigua (relativas a la ventana '
                    'activada). Vuelve a pulsar «Elegir punto en la pantalla…» para pasarlas a '
                    'coordenadas absolutas, o déjalo así si prefieres mantener el comportamiento '
                    'anterior.')
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
                    return None, ('Elige una aplicación de la lista (escribe y selecciona una '
                                   'sugerencia), o usa la pestaña "Ruta / comando manual".')
                paso['modo'] = 'instalado'
                paso['ruta_desktop'] = ruta_desktop
                paso['nombre_detectado'] = texto
                nombre_base = texto
            else:
                ruta = self.chooser_programa.get_filename()
                if not ruta:
                    return None, 'Selecciona el ejecutable o el acceso directo (.desktop) del programa.'
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
            alias = self.entry_alias_programa.get_text().strip()
            if alias and alias in self.alias_prohibidos:
                return None, (f'Ya hay otro paso de esta acción usando el alias «{alias}». '
                               'Elige un nombre distinto para poder diferenciar sus ventanas.')
            paso['alias'] = alias or sugerir_alias(self.pasos_previos, tipo, nombre_base, self.alias_prohibidos)
            paso['espera'] = round(self.spin_espera_programa.get_value(), 1)
            error_colocar = self._leer_colocar_ventana('programa', paso)
            if error_colocar:
                return None, error_colocar
        elif tipo == 'documento':
            ruta_doc = self.chooser_documento.get_filename()
            if not ruta_doc:
                return None, 'Selecciona el documento o archivo a abrir (con el explorador de archivos).'
            if not os.path.isfile(ruta_doc):
                return None, f'No se encuentra el archivo:\n{ruta_doc}\n\n¿Se ha movido o borrado?'
            paso['ruta'] = ruta_doc
            nombre_base = os.path.basename(ruta_doc)
            if self.check_abrir_con_app.get_active():
                ruta_desktop_app = self._resolver_ruta_app_desde(
                    self.entry_app_documento, self._ruta_app_documento_seleccionada)
                if not ruta_desktop_app:
                    return None, ('Elige una aplicación de la lista para abrir el documento (escribe '
                                   'y selecciona una sugerencia), o desmarca "Abrir con una aplicación '
                                   'instalada concreta" para usar la predeterminada del sistema.')
                paso['abrir_con'] = 'app'
                paso['ruta_desktop'] = ruta_desktop_app
                info = _parsear_desktop_entry(ruta_desktop_app) or {}
                paso['nombre_detectado'] = info.get('nombre') or self.entry_app_documento.get_text().strip()
            else:
                paso['abrir_con'] = 'sistema'
            alias = self.entry_alias_documento.get_text().strip()
            if alias and alias in self.alias_prohibidos:
                return None, (f'Ya hay otro paso de esta acción usando el alias «{alias}». '
                               'Elige un nombre distinto para poder diferenciar sus ventanas.')
            paso['alias'] = alias or sugerir_alias(self.pasos_previos, tipo, nombre_base, self.alias_prohibidos)
            paso['espera'] = round(self.spin_espera_documento.get_value(), 1)
            error_colocar = self._leer_colocar_ventana('documento', paso)
            if error_colocar:
                return None, error_colocar
        elif tipo == 'web':
            url = self.entry_url.get_text().strip()
            if not url:
                return None, 'Escribe la URL del sitio web.'
            if not (url.startswith('http://') or url.startswith('https://')):
                url = 'https://' + url
            paso['url'] = url
            paso['navegador'] = self.combo_navegador.get_active_id()
            paso['nueva_ventana'] = self.check_nueva_ventana.get_active()
            paso['modo_app'] = self.check_modo_app.get_active()
            alias = self.entry_alias_web.get_text().strip()
            if alias and alias in self.alias_prohibidos:
                return None, (f'Ya hay otro paso de esta acción usando el alias «{alias}». '
                               'Elige un nombre distinto para poder diferenciar sus ventanas.')
            dominio = urlparse(url).netloc or 'web'
            paso['alias'] = alias or sugerir_alias(self.pasos_previos, tipo, dominio, self.alias_prohibidos)
            paso['espera'] = round(self.spin_espera_web.get_value(), 1)
            error_colocar = self._leer_colocar_ventana('web', paso)
            if error_colocar:
                return None, error_colocar
        elif tipo == 'comando':
            comando = self.entry_comando.get_text().strip()
            if not comando:
                return None, 'Escribe el comando a ejecutar.'
            paso['comando'] = comando
            alias = self.entry_alias_comando.get_text().strip()
            if alias and alias in self.alias_prohibidos:
                return None, (f'Ya hay otro paso de esta acción usando el alias «{alias}». '
                               'Elige un nombre distinto para poder diferenciar sus ventanas.')
            paso['alias'] = alias or sugerir_alias(self.pasos_previos, tipo,
                                                    comando.split()[0] if comando.split() else 'comando',
                                                    self.alias_prohibidos)
            paso['espera'] = round(self.spin_espera_comando.get_value(), 1)
            error_colocar = self._leer_colocar_ventana('comando', paso)
            if error_colocar:
                return None, error_colocar
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
                return None, 'Escribe la tecla o combinación a enviar (ej: ctrl+t).'
            paso['combinacion'] = combinacion
        elif tipo == 'texto':
            self._leer_objetivo(self.combo_objetivo_texto, self.entry_buscar_texto, paso)
            texto = self.entry_texto.get_text()
            if not texto:
                return None, 'Escribe el texto a simular con el teclado.'
            paso['texto'] = texto
        return paso, None


class VentanaPrincipal(Gtk.Window):
    def __init__(self):
        super().__init__(title='Mi Lanzador')
        self.set_default_size(980, 680)
        self.set_icon_name('system-run')
        self.editando_id = None
        self.pasos_actual = []

        self._aplicar_estilos()

        header = Gtk.HeaderBar()
        header.set_show_close_button(True)
        header.props.title = 'Mi Lanzador'
        header.props.subtitle = 'Automatiza tus accesos directos'
        self.set_titlebar(header)

        boton_rapido = Gtk.Button()
        boton_rapido.add(Gtk.Image.new_from_icon_name('list-add-symbolic', Gtk.IconSize.BUTTON))
        boton_rapido.set_tooltip_text('Crear nueva acción')
        boton_rapido.connect('clicked', lambda w: self.ir_a_tab_nueva())
        header.pack_end(boton_rapido)

        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.add(vbox)

        self.notebook = Gtk.Notebook()
        self.notebook.set_tab_pos(Gtk.PositionType.TOP)
        vbox.pack_start(self.notebook, True, True, 0)

        self.notebook.append_page(self._crear_tab_lista(), Gtk.Label(label='🚀 Mis accesos'))
        self.notebook.append_page(self._crear_tab_nueva(), Gtk.Label(label='➕ Nueva acción'))
        self.notebook.append_page(self._crear_tab_ajustes(), Gtk.Label(label='⚙️ Ajustes'))

        self.connect('destroy', Gtk.main_quit)
        self.cargar_lista()

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

        etiqueta = Gtk.Label(label='Tus accesos configurados')
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

        col_nombre = Gtk.TreeViewColumn('Nombre', Gtk.CellRendererText(), text=2)
        col_nombre.set_expand(True)
        self.tree.append_column(col_nombre)

        col_pasos = Gtk.TreeViewColumn('Pasos', Gtk.CellRendererText(), text=3)
        self.tree.append_column(col_pasos)

        col_detalle = Gtk.TreeViewColumn('Resumen', Gtk.CellRendererText(), text=4)
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
            caja.pack_start(Gtk.Label(label=texto), False, False, 0)
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

        self.titulo_form = Gtk.Label(label='Crear nueva acción')
        self.titulo_form.get_style_context().add_class('titulo-form')
        self.titulo_form.set_halign(Gtk.Align.START)
        outer.pack_start(self.titulo_form, False, False, 0)

        grid_cab = Gtk.Grid(column_spacing=12, row_spacing=8)
        outer.pack_start(grid_cab, False, False, 0)
        f = 0
        self.entry_nombre = Gtk.Entry()
        self.entry_nombre.set_placeholder_text('Ej: Rutina de trabajo, Backup diario, Abrir Gmail y Slack...')
        f = _fila_grid(grid_cab, f, 'Nombre de la acción:', self.entry_nombre)
        self.chooser_icono = Gtk.FileChooserButton(title='Selecciona un icono', action=Gtk.FileChooserAction.OPEN)
        filtro = Gtk.FileFilter()
        filtro.set_name('Imágenes')
        for patron in ('*.png', '*.svg', '*.jpg', '*.jpeg', '*.ico', '*.xpm'):
            filtro.add_pattern(patron)
        self.chooser_icono.add_filter(filtro)
        self.chooser_icono.set_filter(filtro)
        f = _fila_grid(grid_cab, f, 'Icono personalizado (opcional):', self.chooser_icono)

        etiqueta_pasos = Gtk.Label(label='Pasos de esta acción (se ejecutan en el orden mostrado):')
        etiqueta_pasos.set_halign(Gtk.Align.START)
        outer.pack_start(etiqueta_pasos, False, False, 4)

        # nº, tipo legible, resumen
        self.store_pasos = Gtk.ListStore(int, str, str)
        self.tree_pasos = Gtk.TreeView(model=self.store_pasos)
        self.tree_pasos.connect('row-activated', lambda t, p, c: self._on_editar_paso(None))
        col_n = Gtk.TreeViewColumn('#', Gtk.CellRendererText(), text=0)
        self.tree_pasos.append_column(col_n)
        col_tipo = Gtk.TreeViewColumn('Tipo', Gtk.CellRendererText(), text=1)
        self.tree_pasos.append_column(col_tipo)
        col_resumen = Gtk.TreeViewColumn('Detalle', Gtk.CellRendererText(), text=2)
        col_resumen.set_expand(True)
        self.tree_pasos.append_column(col_resumen)

        scroll_pasos = Gtk.ScrolledWindow()
        scroll_pasos.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scroll_pasos.add(self.tree_pasos)
        scroll_pasos.set_vexpand(True)
        scroll_pasos.set_min_content_height(220)
        outer.pack_start(scroll_pasos, True, True, 0)

        barra_pasos = Gtk.Box(spacing=8)
        btn_add = Gtk.Button(label='➕ Añadir paso')
        btn_add.get_style_context().add_class('suggested-action')
        btn_add.connect('clicked', self._on_anadir_paso)
        btn_editar_paso = Gtk.Button(label='Editar paso')
        btn_editar_paso.connect('clicked', self._on_editar_paso)
        btn_quitar_paso = Gtk.Button(label='Eliminar paso')
        btn_quitar_paso.connect('clicked', self._on_quitar_paso)
        btn_subir = Gtk.Button(label='⬆ Subir')
        btn_subir.connect('clicked', self._on_subir_paso)
        btn_bajar = Gtk.Button(label='⬇ Bajar')
        btn_bajar.connect('clicked', self._on_bajar_paso)
        barra_pasos.pack_start(btn_add, False, False, 0)
        barra_pasos.pack_start(btn_editar_paso, False, False, 0)
        barra_pasos.pack_start(btn_quitar_paso, False, False, 0)
        barra_pasos.pack_start(btn_subir, False, False, 0)
        barra_pasos.pack_start(btn_bajar, False, False, 0)
        outer.pack_start(barra_pasos, False, False, 0)

        barra_botones = Gtk.Box(spacing=8)
        self.btn_guardar = Gtk.Button(label='💾 Guardar acción')
        self.btn_guardar.get_style_context().add_class('suggested-action')
        self.btn_guardar.connect('clicked', self._on_guardar_accion)
        btn_limpiar = Gtk.Button(label='Limpiar formulario')
        btn_limpiar.connect('clicked', lambda w: self.limpiar_formulario())
        barra_botones.pack_start(self.btn_guardar, False, False, 0)
        barra_botones.pack_start(btn_limpiar, False, False, 0)
        outer.pack_start(barra_botones, False, False, 10)

        return outer

    # -- pestaña: ajustes -------------------------------------------------
    def _crear_tab_ajustes(self):
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        outer.set_border_width(16)

        titulo = Gtk.Label(label='Ajustes generales')
        titulo.get_style_context().add_class('titulo-form')
        titulo.set_halign(Gtk.Align.START)
        outer.pack_start(titulo, False, False, 0)

        ajustes = cargar_ajustes()
        grid = Gtk.Grid(column_spacing=12, row_spacing=12)
        outer.pack_start(grid, False, False, 0)

        grid.attach(Gtk.Label(label="Navegador predeterminado para 'Sitio web':", halign=Gtk.Align.END), 0, 0, 1, 1)
        self.combo_navegador_defecto = Gtk.ComboBoxText()
        for clave, info in NAVEGADORES.items():
            self.combo_navegador_defecto.append(clave, info['nombre'])
        self.combo_navegador_defecto.set_active_id(ajustes.get('navegador_predeterminado', 'sistema'))
        grid.attach(self.combo_navegador_defecto, 1, 0, 1, 1)

        self.check_auto_acceso = Gtk.CheckButton(
            label='Crear automáticamente un acceso directo en el Escritorio al guardar una acción nueva')
        self.check_auto_acceso.set_active(ajustes.get('crear_acceso_automatico', False))
        grid.attach(self.check_auto_acceso, 0, 1, 2, 1)

        self.check_notificaciones = Gtk.CheckButton(label='Mostrar notificaciones al ejecutar una acción')
        self.check_notificaciones.set_active(ajustes.get('notificaciones', True))
        grid.attach(self.check_notificaciones, 0, 2, 2, 1)

        grid.attach(Gtk.Label(label='Carpeta de configuración:', halign=Gtk.Align.END), 0, 3, 1, 1)
        caja_carpeta = Gtk.Box(spacing=6)
        etiqueta_carpeta = Gtk.Label(label=CONFIG_DIR)
        etiqueta_carpeta.set_selectable(True)
        caja_carpeta.pack_start(etiqueta_carpeta, False, False, 0)
        btn_abrir_carpeta = Gtk.Button(label='Abrir')
        btn_abrir_carpeta.connect('clicked', lambda w: subprocess.Popen(['xdg-open', CONFIG_DIR]))
        caja_carpeta.pack_start(btn_abrir_carpeta, False, False, 0)
        grid.attach(caja_carpeta, 1, 3, 1, 1)

        herramientas = herramientas_x11_disponibles()
        estado = ('✅ Disponibles' if herramientas['xdotool'] and herramientas['wmctrl']
                   else '⚠ Faltan: ' + ', '.join(k for k, v in herramientas.items() if not v))
        grid.attach(Gtk.Label(label='xdotool / wmctrl (ventanas, clics, teclas):', halign=Gtk.Align.END), 0, 4, 1, 1)
        caja_x11 = Gtk.Box(spacing=8)
        self.etiqueta_estado_x11 = Gtk.Label(label=estado)
        self.etiqueta_estado_x11.set_halign(Gtk.Align.START)
        caja_x11.pack_start(self.etiqueta_estado_x11, False, False, 0)
        self.btn_instalar_x11 = Gtk.Button(label='🔧 Instalar ahora')
        self.btn_instalar_x11.set_no_show_all(True)
        self.btn_instalar_x11.set_visible(not (herramientas['xdotool'] and herramientas['wmctrl']))
        self.btn_instalar_x11.connect('clicked', self._on_instalar_x11)
        caja_x11.pack_start(self.btn_instalar_x11, False, False, 0)
        grid.attach(caja_x11, 1, 4, 1, 1)

        btn_guardar_ajustes = Gtk.Button(label='💾 Guardar ajustes')
        btn_guardar_ajustes.get_style_context().add_class('suggested-action')
        btn_guardar_ajustes.connect('clicked', self._on_guardar_ajustes)
        outer.pack_start(btn_guardar_ajustes, False, False, 10)

        outer.pack_start(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL), False, False, 6)

        acerca = Gtk.Label()
        acerca.set_markup(
            '<small>Mi Lanzador · Crea accesos directos que encadenan programas, sitios web, comandos,\n'
            'esperas, posicionamiento de ventanas, clics y teclas. Todos tus datos se guardan\n'
            'localmente en tu carpeta de configuración.\n'
            'Programador: Filonux</small>')
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

    def refrescar_store_pasos(self):
        self.store_pasos.clear()
        for i, paso in enumerate(self.pasos_actual, start=1):
            self.store_pasos.append([i, TIPOS_PASO.get(paso.get('tipo'), paso.get('tipo')), resumen_paso(paso)])

    def obtener_seleccion(self):
        seleccion = self.tree.get_selection()
        modelo, iterador = seleccion.get_selected()
        if iterador is None:
            self.mostrar_dialogo_error('Selecciona primero una acción de la lista.')
            return None
        id_accion = modelo[iterador][0]
        for accion in cargar_acciones():
            if accion.get('id') == id_accion:
                return accion
        return None

    def obtener_indice_paso_seleccionado(self):
        seleccion = self.tree_pasos.get_selection()
        modelo, iterador = seleccion.get_selected()
        if iterador is None:
            return None
        path = modelo.get_path(iterador)
        return path.get_indices()[0]

    def obtener_dir_escritorio(self):
        ruta = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_DESKTOP)
        return ruta if ruta else os.path.expanduser('~/Desktop')

    def limpiar_formulario(self):
        self.entry_nombre.set_text('')
        self.chooser_icono.unselect_all()
        self.pasos_actual = []
        self.refrescar_store_pasos()
        self.editando_id = None
        self.btn_guardar.set_label('💾 Guardar acción')

    def ir_a_tab_nueva(self):
        self.limpiar_formulario()
        self.notebook.set_current_page(1)

    def crear_acceso_para(self, accion):
        dialogo = Gtk.Dialog(title='Crear acceso directo', transient_for=self, flags=0)
        dialogo.add_buttons('Cancelar', Gtk.ResponseType.CANCEL, 'Crear', Gtk.ResponseType.OK)
        area = dialogo.get_content_area()
        area.set_border_width(14)
        area.set_spacing(8)
        etiqueta = Gtk.Label(label=f'¿Dónde quieres crear el acceso directo de "{accion.get("nombre","")}"?')
        etiqueta.set_halign(Gtk.Align.START)
        area.add(etiqueta)
        check_escritorio = Gtk.CheckButton(label='Escritorio')
        check_escritorio.set_active(True)
        check_menu = Gtk.CheckButton(label='Menú de aplicaciones')
        area.add(check_escritorio)
        area.add(check_menu)
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
            if rutas:
                notificar(f'Acceso directo creado para "{accion.get("nombre","")}".')
                self.mostrar_dialogo_info(
                    "Si al hacer doble clic te pide 'confiar' o 'permitir ejecución', acepta esa opción "
                    "una sola vez (clic derecho sobre el icono → Propiedades → Permisos → "
                    "'Permitir ejecutar como programa', o 'Confiar y lanzar')."
                )

    def mostrar_dialogo_error(self, texto):
        dialogo = Gtk.MessageDialog(transient_for=self, flags=0, message_type=Gtk.MessageType.ERROR,
                                     buttons=Gtk.ButtonsType.OK, text=texto)
        dialogo.run()
        dialogo.destroy()

    def mostrar_dialogo_info(self, texto):
        dialogo = Gtk.MessageDialog(transient_for=self, flags=0, message_type=Gtk.MessageType.INFO,
                                     buttons=Gtk.ButtonsType.OK, text=texto)
        dialogo.run()
        dialogo.destroy()

    def mostrar_dialogo_texto_largo(self, titulo, texto):
        dialogo = Gtk.Dialog(title=titulo, transient_for=self, flags=0)
        dialogo.add_buttons('Cerrar', Gtk.ResponseType.CLOSE)
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
    def _on_anadir_paso(self, widget):
        # FALLO CORREGIDO: si algo fallaba al construir el diálogo (por
        # ejemplo al detectar aplicaciones instaladas en algún sistema
        # concreto) la excepción no se veía por ningún sitio y el botón
        # parecía "no hacer nada". Ahora se captura y se muestra siempre.
        dialogo = None
        try:
            alias_en_uso = {p.get('alias') for p in self.pasos_actual
                             if p.get('tipo') in ('programa', 'documento', 'web', 'comando') and p.get('alias')}
            dialogo = DialogoPaso(self, self.pasos_actual, alias_prohibidos=alias_en_uso)
            # FALLO CORREGIDO: antes, si "Aceptar" fallaba la validación
            # (por ejemplo URL vacía), el diálogo se cerraba de inmediato y
            # se perdía TODO lo que el usuario había rellenado, obligando a
            # empezar de cero. Ahora el diálogo permanece abierto (con los
            # datos intactos) y solo se cierra al cancelar o al validarse
            # correctamente.
            while True:
                respuesta = dialogo.run()
                if respuesta != Gtk.ResponseType.OK:
                    break
                paso, error = dialogo.validar_y_construir()
                if error:
                    self.mostrar_dialogo_error(error)
                    continue
                self.pasos_actual.append(paso)
                self.refrescar_store_pasos()
                break
        except Exception as excepcion:
            _mostrar_error_excepcion(self, 'Añadir paso', excepcion)
        finally:
            if dialogo is not None:
                dialogo.destroy()

    def _on_editar_paso(self, widget):
        idx = self.obtener_indice_paso_seleccionado()
        if idx is None:
            self.mostrar_dialogo_error('Selecciona primero un paso de la lista.')
            return
        dialogo = None
        try:
            pasos_previos = self.pasos_actual[:idx]
            alias_en_uso = {p.get('alias') for i, p in enumerate(self.pasos_actual)
                             if i != idx and p.get('tipo') in ('programa', 'documento', 'web', 'comando') and p.get('alias')}
            dialogo = DialogoPaso(self, pasos_previos, paso_inicial=self.pasos_actual[idx],
                                   alias_prohibidos=alias_en_uso)
            # FALLO CORREGIDO: ver nota en _on_anadir_paso — se mantiene el
            # diálogo abierto ante un error de validación en vez de perder
            # los cambios del usuario.
            while True:
                respuesta = dialogo.run()
                if respuesta != Gtk.ResponseType.OK:
                    break
                paso, error = dialogo.validar_y_construir()
                if error:
                    self.mostrar_dialogo_error(error)
                    continue
                self.pasos_actual[idx] = paso
                self.refrescar_store_pasos()
                break
        except Exception as excepcion:
            _mostrar_error_excepcion(self, 'Editar paso', excepcion)
        finally:
            if dialogo is not None:
                dialogo.destroy()

    def _on_quitar_paso(self, widget):
        idx = self.obtener_indice_paso_seleccionado()
        if idx is None:
            self.mostrar_dialogo_error('Selecciona primero un paso de la lista.')
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
            self.mostrar_dialogo_error('Escribe un nombre para la acción.')
            return
        if not self.pasos_actual:
            self.mostrar_dialogo_error('Añade al menos un paso a la acción.')
            return

        accion = {'id': self.editando_id or str(uuid.uuid4())[:8], 'nombre': nombre,
                  'pasos': self.pasos_actual}

        icono_sel = self.chooser_icono.get_filename()
        if icono_sel:
            try:
                destino_icono = os.path.join(ICONOS_DIR, accion['id'] + os.path.splitext(icono_sel)[1])
                shutil.copyfile(icono_sel, destino_icono)
                # MEJORA: si esta acción ya tenía un icono personalizado
                # distinto (p. ej. con otra extensión), se borra para no
                # dejarlo huérfano en la carpeta de iconos.
                if self.editando_id:
                    anteriores = [a for a in cargar_acciones() if a.get('id') == self.editando_id]
                    icono_previo = anteriores[0].get('icono') if anteriores else None
                    if (icono_previo and icono_previo != destino_icono
                            and os.path.dirname(icono_previo) == ICONOS_DIR):
                        try:
                            os.remove(icono_previo)
                        except Exception:
                            pass
                accion['icono'] = destino_icono
            except Exception:
                pass
        elif self.editando_id:
            anteriores = [a for a in cargar_acciones() if a.get('id') == self.editando_id]
            if anteriores and anteriores[0].get('icono'):
                accion['icono'] = anteriores[0]['icono']

        acciones = cargar_acciones()
        if self.editando_id:
            acciones = [accion if a.get('id') == self.editando_id else a for a in acciones]
        else:
            acciones.append(accion)
        guardar_acciones(acciones)

        editando_previo = self.editando_id
        self.editando_id = None
        self.btn_guardar.set_label('💾 Guardar acción')
        self.cargar_lista()
        self.limpiar_formulario()
        self.notebook.set_current_page(0)
        notificar(f'Acción "{nombre}" guardada correctamente.')

        if not editando_previo:
            ajustes = cargar_ajustes()
            if ajustes.get('crear_acceso_automatico'):
                crear_acceso_directo(accion, [self.obtener_dir_escritorio()])
                notificar('Se creó el acceso directo en el Escritorio automáticamente.')
            else:
                dialogo = Gtk.MessageDialog(transient_for=self, flags=0, message_type=Gtk.MessageType.QUESTION,
                                             buttons=Gtk.ButtonsType.YES_NO,
                                             text='¿Crear también un acceso directo ahora?')
                respuesta = dialogo.run()
                dialogo.destroy()
                if respuesta == Gtk.ResponseType.YES:
                    self.crear_acceso_para(accion)

    def _on_instalar_x11(self, widget):
        """Instala xdotool y wmctrl bajo demanda (botón 'Instalar ahora' en
        Ajustes). FALLO CORREGIDO: antes esto solo se intentaba en segundo
        plano al arrancar el script y, si fallaba, no había ninguna forma de
        reintentarlo ni de saber por qué desde la propia interfaz."""
        if not shutil.which('pkexec'):
            self.mostrar_dialogo_error(
                'No se encontró "pkexec" en el sistema, así que no puedo abrir una '
                'ventana para pedirte la contraseña. Instálalo manualmente abriendo '
                'una terminal y escribiendo:\n\nsudo apt install xdotool wmctrl'
            )
            return

        # MEJORA: aunque pulsar este botón ya es una acción explícita del
        # usuario, se pide una confirmación final (previa a pkexec) que
        # deja claro EXACTAMENTE qué se va a instalar, en línea con el
        # resto de instalaciones automáticas de la aplicación.
        dialogo_confirmar = Gtk.MessageDialog(
            transient_for=self, flags=0, message_type=Gtk.MessageType.QUESTION,
            buttons=Gtk.ButtonsType.YES_NO,
            text='Se van a instalar los paquetes "xdotool" y "wmctrl" mediante apt.\n\n'
                 'A continuación se te pedirá tu contraseña de administrador. ¿Continuar?')
        respuesta_confirmar = dialogo_confirmar.run()
        dialogo_confirmar.destroy()
        if respuesta_confirmar != Gtk.ResponseType.YES:
            return

        widget.set_sensitive(False)
        self.etiqueta_estado_x11.set_text('⏳ Instalando… responde al diálogo de contraseña si aparece')
        while Gtk.events_pending():
            Gtk.main_iteration()

        log_path = os.path.join(CONFIG_DIR, 'instalacion_dependencias_x11.log')
        salida_previa = ''
        try:
            resultado = subprocess.run(
                ['pkexec', 'apt-get', 'install', '-y', 'xdotool', 'wmctrl'],
                capture_output=True, text=True
            )
            salida_previa = (resultado.stdout or '') + (resultado.stderr or '')
            with open(log_path, 'w', encoding='utf-8') as f:
                f.write(salida_previa)
        except Exception as excepcion:
            _mostrar_error_excepcion(self, 'Instalar xdotool/wmctrl', excepcion)

        herramientas = herramientas_x11_disponibles()
        ok = herramientas['xdotool'] and herramientas['wmctrl']
        self.etiqueta_estado_x11.set_text(
            '✅ Disponibles' if ok else
            '⚠ Faltan: ' + ', '.join(k for k, v in herramientas.items() if not v)
        )
        widget.set_visible(not ok)
        widget.set_sensitive(True)

        if ok:
            notificar('xdotool y wmctrl instalados correctamente.')
        else:
            self.mostrar_dialogo_error(
                'No se pudo completar la instalación automática (revisa tu conexión a '
                'internet, o si cancelaste el diálogo de contraseña). Puedes ver el '
                f'detalle técnico en:\n{log_path}\n\n'
                'O instalarlo a mano abriendo una terminal:\nsudo apt install xdotool wmctrl'
            )

    def _on_guardar_ajustes(self, widget):
        ajustes = {
            'navegador_predeterminado': self.combo_navegador_defecto.get_active_id(),
            'crear_acceso_automatico': self.check_auto_acceso.get_active(),
            'notificaciones': self.check_notificaciones.get_active(),
        }
        guardar_ajustes(ajustes)
        notificar('Ajustes guardados correctamente.')

    def _on_ejecutar(self, widget):
        accion = self.obtener_seleccion()
        if accion:
            # MEJORA: Mi Lanzador se minimiza al ejecutar, para no interferir
            # con lo que la propia acción hace en pantalla (clics, ventanas
            # que coloca, etc.).
            self.iconify()
            ejecutar_accion(accion, self)

    def _on_crear_acceso(self, widget):
        accion = self.obtener_seleccion()
        if accion:
            self.crear_acceso_para(accion)

    def _on_ver_script(self, widget):
        accion = self.obtener_seleccion()
        if not accion:
            return
        script = generar_script_bash(accion.get('pasos', []), accion.get('nombre', ''))
        self.mostrar_dialogo_texto_largo(f'Script de "{accion.get("nombre","")}"', script)

    def _on_editar(self, widget):
        accion = self.obtener_seleccion()
        if not accion:
            return
        self.editando_id = accion.get('id')
        self.entry_nombre.set_text(accion.get('nombre', ''))
        self.chooser_icono.unselect_all()
        self.pasos_actual = [dict(p) for p in accion.get('pasos', [])]
        self.refrescar_store_pasos()
        self.btn_guardar.set_label('💾 Guardar cambios')
        self.notebook.set_current_page(1)

    def _on_eliminar(self, widget):
        accion = self.obtener_seleccion()
        if not accion:
            return
        dialogo = Gtk.MessageDialog(transient_for=self, flags=0, message_type=Gtk.MessageType.WARNING,
                                     buttons=Gtk.ButtonsType.YES_NO,
                                     text=f'¿Eliminar la acción "{accion.get("nombre","")}"?')
        respuesta = dialogo.run()
        dialogo.destroy()
        if respuesta == Gtk.ResponseType.YES:
            acciones = [a for a in cargar_acciones() if a.get('id') != accion.get('id')]
            guardar_acciones(acciones)
            eliminar_accesos_directos(accion.get('id', ''))
            icono = accion.get('icono')
            if icono and os.path.dirname(icono) == ICONOS_DIR and os.path.isfile(icono):
                try:
                    os.remove(icono)
                except Exception:
                    pass
            self.cargar_lista()
            notificar(f'Acción "{accion.get("nombre","")}" eliminada.')

    def _on_fila_doble_clic(self, tree, path, column):
        modelo = tree.get_model()
        id_accion = modelo[path][0]
        for accion in cargar_acciones():
            if accion.get('id') == id_accion:
                self.iconify()
                ejecutar_accion(accion, self)
                break


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == '--ejecutar':
        hilo = ejecutar_accion_por_id(sys.argv[2])
        if hilo is not None:
            hilo.join()
        return
    ventana = VentanaPrincipal()
    ventana.connect('delete-event', Gtk.main_quit)
    ventana.show_all()
    Gtk.main()


if __name__ == '__main__':
    main()
PYEOF
