<a href="assets/icon.svg"><img src="assets/icon.svg" alt="Icono de Mi Lanzador" width="140"></a>

# Mi Lanzador

Creador de accesos directos automatizados para Linux Mint 22.3 (Cinnamon, sesión X11).

[![Bash 4+](https://img.shields.io/badge/bash-%3E%3D4.0-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/) [![Linux Mint 22.3 Cinnamon](https://img.shields.io/badge/Linux%20Mint-22.3%20Cinnamon-87CF3E?logo=linuxmint&logoColor=white)](https://linuxmint.com/) [![Licencia GPLv3](https://img.shields.io/badge/licencia-GPLv3-blue)](LICENSE)

Es una interfaz gráfica para armar "acciones": secuencias de pasos que abren programas, documentos, páginas web o comandos, colocan ventanas, simulan clics y pulsan teclas, encadenados y en orden — como una macro de AutoHotkey, pero con xdotool/wmctrl por debajo. Cualquier acción se convierte en un acceso directo de un clic (Escritorio y/o menú de aplicaciones) que ejecuta todos sus pasos sin abrir la ventana de la app.

Todo — interfaz y lógica — vive en un único archivo `.sh`; tus datos (acciones, ajustes, iconos) se guardan aparte, en tu carpeta de configuración (ver «Dónde guarda las cosas» más abajo).

## Qué hace cada tipo de paso

- **Abrir programa** — catálogo con lo que tengas instalado (sistema, Snap, Flatpak, accesos de escritorio) o ruta/comando manual, con argumentos si hace falta.
- **Abrir documento o archivo** — se elige con el explorador de archivos de siempre; se abre con la aplicación predeterminada del sistema (como un doble clic desde el gestor de archivos) o, si lo prefieres, forzando una aplicación instalada concreta.
- **Abrir sitio web** — en pestaña, en ventana nueva de verdad o "como app" (sin barra de direcciones; solo Chrome/Chromium/Brave), con opción de usar el navegador predeterminado del sistema, que detecta automáticamente entre Firefox, Chrome, Chromium y Brave.
- **Ejecutar comando** y **esperar** unos segundos. El comando se abre en una terminal de verdad y se queda ahí, mostrando el resultado, hasta que pulsas Intro.
- **Colocar ventana** — maximizar, restaurar tamaño normal, mitad de pantalla (izquierda, derecha, arriba o abajo), cuartos de pantalla, centrada (80% de la pantalla), tamaño/posición a medida en % de pantalla, minimizar, cerrar. Va integrado en el paso que abre el programa/documento/web/comando, y también existe suelto para reposicionar una ventana que ya estaba abierta. Con varias pantallas, calcula el porcentaje sobre el monitor donde esté la ventana, no sobre todo el escritorio virtual.
- **Clic** en coordenadas X,Y absolutas — a mano o con una cuenta atrás de 3s para colocar el cursor mientras la app se aparta sola. Eliges botón (izquierdo, central o derecho) y si quieres doble clic. Puede activar antes una ventana concreta.
- **Tecla o combinación**, y **escribir texto** — la combinación se puede capturar pulsándola, o escribirla a mano (ej. `Alt+F10`); ambas se aplican a la última ventana abierta por la acción, a la ventana de un paso anterior por su alias, o a la que encuentres buscando por título.

## Otras funciones

- **Icono por acción** — puedes poner una imagen propia (PNG, SVG, JPG, ICO o XPM) para cada acción; si no pones ninguna, coge un icono automático según el primer paso.
- **Probar este paso ahora** — al crear o editar un paso, puedes ejecutarlo suelto para comprobar que hace lo que quieres, sin guardar la acción ni tocar los demás pasos.
- **Ver script generado** — para cada acción guardada puedes ver el script bash real que se ejecuta, paso a paso.
- **Notificaciones de escritorio** — avisa al lanzar una acción, y de nuevo si algo no ha ido bien; se puede desactivar en Ajustes.
- **Ajustes** — navegador predeterminado para "Sitio web", crear el acceso directo en el Escritorio automáticamente al guardar una acción nueva (si no, te lo pregunta cada vez), notificaciones, acceso directo a la carpeta de configuración, y un botón para (re)instalar xdotool/wmctrl cuando quieras.

Al crear un acceso directo eliges Escritorio, menú de aplicaciones, o ambos. Si al hacer doble clic Cinnamon te pide "confiar" o "permitir ejecución" la primera vez, es normal — acéptalo una vez y no se vuelve a preguntar.

## Requisitos

- Linux Mint 22.3, Cinnamon, sesión **X11** (ver el apartado de Wayland más abajo).
- Python 3 (ya viene con el sistema).
- GTK3 para Python: `python3-gi gir1.2-gtk-3.0 python3-gi-cairo gir1.2-notify-0.7`
- `xdotool` y `wmctrl`, solo si vas a colocar ventanas, hacer clic, enviar teclas o escribir texto (incluida la colocación integrada dentro de abrir programa/documento/web/comando).

El script detecta si faltan las dos últimas (GTK3 y xdotool/wmctrl) y se ofrece a instalarlas con `pkexec`, pidiendo confirmación explícita antes de tocar nada. Si dices que no, o no hay `pkexec` disponible, te deja el comando exacto para hacerlo tú mismo. Para xdotool/wmctrl puedes además reintentarlo cuando quieras desde Ajustes → «Instalar ahora»; GTK3 no tiene ese botón — sin él la interfaz no llega a abrirse, así que tampoco hay Ajustes al que entrar — basta con volver a ejecutar el script una vez lo hayas instalado a mano. Python 3 es el único requisito que el script no ofrece instalar por ti: si llegara a faltar (no debería, en una instalación normal de Mint), directamente te muestra el comando.

## Instalación

```bash
chmod +x mi-lanzador.sh
./mi-lanzador.sh
```

Con eso basta. La primera vez:

1. Se copia a `~/.local/share/mi-lanzador/mi-lanzador.sh` — esa pasa a ser la copia "instalada"; el `.sh` que descargaste ya no hace falta.
2. Crea su lanzador en el menú de aplicaciones y una copia en tu Escritorio.
3. Comprueba dependencias y pregunta antes de instalar nada que falte.

Después de eso, ábrelo desde el menú o el icono del Escritorio, como cualquier otra app.

## Dónde guarda las cosas

| Qué | Dónde |
|---|---|
| Acciones | `~/.config/mi-lanzador/acciones.json` |
| Ajustes | `~/.config/mi-lanzador/ajustes.json` |
| Iconos personalizados | `~/.config/mi-lanzador/iconos/` |
| Registro de la última ejecución | `~/.config/mi-lanzador/ultima_ejecucion.log` |
| Log de errores | `~/.config/mi-lanzador/error.log` |
| Script instalado | `~/.local/share/mi-lanzador/mi-lanzador.sh` |

Cualquier error inesperado se registra en el log de errores y además se muestra en un aviso: no falla en silencio, porque normalmente se abre con doble clic, sin terminal donde ver nada. El registro de la última ejecución, en cambio, es la salida de la última acción que has lanzado (avisos incluidos) — útil para ver por qué un paso concreto no hizo lo que esperabas.

## Sobre Wayland

Si tu sesión de Cinnamon es Wayland nativo, abrir programas/webs/comandos funciona igual, pero colocar ventanas, hacer clic, enviar teclas y escribir texto **no van a funcionar**, aunque tengas xdotool y wmctrl instalados — es una limitación de esas herramientas, no del script. Se detecta sola y avisa una vez al día. Para tener todo, elige la sesión "Cinnamon" (X11) en la pantalla de inicio de sesión, no la que dice "Cinnamon (Wayland)".

## Ejecutar una acción sin abrir la ventana

```bash
mi-lanzador.sh --ejecutar <id_de_la_accion>
```

Corre esa acción de principio a fin sin mostrar ninguna ventana. Es lo que usan por dentro los accesos directos `.desktop` que genera la app, y sirve igual de bien para asignarle un atajo de teclado propio desde Cinnamon.

## Por dentro

Un único `.sh`: la parte de bash hace la auto-instalación, comprueba/instala dependencias y avisa de Wayland; al final hace `exec python3` sobre un heredoc con toda la interfaz en PyGObject (GTK3). Sin build, sin paquetes propios que instalar — el archivo es el programa.

## Licencia

GPLv3 — © 2026 Filonux. Ver `LICENSE`.
