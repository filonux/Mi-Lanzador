[🇬🇧 Read this README in English](README.md)

<a href="assets/icon.svg"><img src="assets/icon.svg" alt="Icono de Mi Lanzador" width="140"></a>

# Mi Lanzador

Creador de accesos directos automatizados para Linux Mint 22.3 (Cinnamon, sesión X11).

[![Bash 4+](https://img.shields.io/badge/bash-%3E%3D4.0-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/) [![Linux Mint 22.3 Cinnamon](https://img.shields.io/badge/Linux%20Mint-22.3%20Cinnamon-87CF3E?logo=linuxmint&logoColor=white)](https://linuxmint.com/) [![Licencia GPLv3](https://img.shields.io/badge/licencia-GPLv3-blue)](LICENSE.txt)

Es una interfaz gráfica para armar "acciones": secuencias de pasos que abren programas, documentos, páginas web o comandos, colocan ventanas, simulan clics y pulsan teclas, encadenados y en orden — como una macro de AutoHotkey, pero con xdotool/wmctrl por debajo. Cualquier acción se convierte en un acceso directo de un clic (Escritorio y/o menú de aplicaciones) que ejecuta todos sus pasos sin abrir la ventana de la app.

En la práctica, cualquier rutina que hoy hagas a mano —abrir tus apps de trabajo y colocarlas en su sitio, dejar todo listo para grabar, rellenar el mismo formulario de siempre— se queda guardada como un solo icono que la repite exactamente igual, todas las veces.

Todo — interfaz y lógica — vive en un único archivo `.sh`; tus datos (acciones, ajustes, iconos) se guardan aparte, en tu carpeta de configuración (ver «Dónde guarda las cosas» más abajo).

## Novedades de la versión 2.1.0

- **Interfaz en español e inglés**, elegida según el idioma del sistema y con cambio en un clic (botón `L`). Antes solo existía en español. Ver «Idioma».
- **Tus datos no se pierden.** Todo lo que guarda la app (acciones, ajustes, idioma, accesos directos, iconos) se escribe de forma atómica: un fallo a mitad de guardado no deja archivos a medias. Si `acciones.json` o `ajustes.json` están dañados, se apartan como `<nombre>.corrupt-<fecha>` (nunca se sobrescriben) y la app abre con datos vacíos, avisándote.
- **Aguanta archivos editados a mano.** Acepta la marca BOM de los editores de Windows, ignora campos de tipo incorrecto y repara ids vacíos, repetidos o inservibles como nombre de archivo, en lugar de fallar al arrancar.
- **Ejecuciones más fiables.** Lanzar una acción mientras otra sigue en marcha ya no borra su registro ni sus avisos. Un paso dirigido por alias a una ventana que ya se cerró se omite con un aviso, en lugar de actuar sobre otra. Un clic como primer paso espera a que Mi Lanzador se haya minimizado, así que cae en la ventana de debajo, y ya no se queda parado unos 15 segundos cuando el puntero ya está en el punto del clic. Y el texto del usuario con saltos de línea no puede inyectar comandos ni falsear avisos en el script generado.
- **Accesos directos y ventana más estables.** Al renombrar una acción se sustituye su acceso directo (no se duplica) y, si no se puede escribir el nuevo, se conserva el antiguo. La instalación de xdotool/wmctrl ya no congela la ventana mientras apt trabaja, y cerrar un formulario a medio rellenar pide confirmación.
- **Más de 450 pruebas automáticas** con GTK3 real sobre Xvfb, más ShellCheck y pyflakes en cada cambio (ver «Pruebas»).

## Vista previa

[Vídeo de demostración](assets/demo.mp4)

https://github.com/user-attachments/assets/39f252bd-b087-494a-becf-dae433429457

<img width="976" height="721" alt="Mi Lanzador - pestaña Mis accesos" src="assets/screenshots/1-menu-mi-lanzador-es.png" />
<img width="976" height="721" alt="Mi Lanzador - pestaña Nueva acción con el diálogo Añadir paso" src="assets/screenshots/2-newaction-es.png" />
<img width="982" height="727" alt="Mi Lanzador - pestaña Ajustes" src="assets/screenshots/3-mi-lanzador-ajustes-es.png" />

## Qué hace cada tipo de paso

- **Abrir programa** — catálogo con lo que tengas instalado (sistema, Snap, Flatpak, accesos de escritorio) o ruta/comando manual, con argumentos si hace falta.
- **Abrir documento o archivo** — se elige con el explorador de archivos de siempre; se abre con la aplicación predeterminada del sistema (como un doble clic desde el gestor de archivos) o, si lo prefieres, forzando una aplicación instalada concreta.
- **Abrir sitio web** — en pestaña, en ventana nueva de verdad o "como app" (sin barra de direcciones; solo Chrome/Chromium/Brave), con opción de usar el navegador predeterminado del sistema, que detecta automáticamente entre Firefox, Chrome, Chromium y Brave.
- **Ejecutar comando** y **esperar** unos segundos. El comando se abre en una terminal de verdad y se queda ahí, mostrando el resultado, hasta que pulsas Intro.
- **Colocar ventana** — maximizar, restaurar tamaño normal, mitad de pantalla (izquierda, derecha, arriba o abajo), cuartos de pantalla, centrada (80% de la pantalla), tamaño/posición a medida en % de pantalla, minimizar, cerrar. Va integrado en el paso que abre el programa/documento/web/comando, y también existe suelto para reposicionar una ventana que ya estaba abierta. Con varias pantallas, calcula el porcentaje sobre el monitor donde esté la ventana, no sobre todo el escritorio virtual.
- **Clic** en coordenadas X,Y absolutas — a mano o con una cuenta atrás de 3s para colocar el cursor mientras la app se aparta sola. Eliges botón (izquierdo, central o derecho) y si quieres doble clic. Puede activar antes una ventana concreta. Dos clics seguidos en el mismo punto salen con una fracción de segundo de diferencia y las aplicaciones pueden tomarlos como un doble clic: añade un paso de espera entre ellos para que sean dos clics separados.
- **Tecla o combinación**, y **escribir texto** — la combinación se puede capturar pulsándola, o escribirla a mano (ej. `Alt+F10`); los dos pasos se aplican a la última ventana abierta por la acción, a la ventana de un paso anterior por su alias, o a la que encuentres buscando por título.

## Ejemplos de acciones que puedes armar

Los pasos se encadenan libremente dentro de una misma acción, así que el límite real lo pone tu imaginación. Algunos ejemplos para que veas el alcance:

- **Arranque de la jornada** — abre el correo, el chat de trabajo y el calendario, cada uno colocado en un cuarto de pantalla, listos de un vistazo nada más sentarte.
- **Entorno de desarrollo** — el editor a un lado, una terminal con el servidor en marcha al otro (paso Ejecutar comando) y el navegador apuntando a `localhost`, cada cual en su sitio.
- **Modo presentación** — las diapositivas a pantalla completa y, antes, un par de pasos que minimizan el correo y el chat para que no salte ningún aviso en mitad de la charla.
- **Formulario repetitivo** — abre la página, hace clic en el primer campo, escribe el texto, salta al siguiente con Tab... la misma tarea de cada semana, reducida a un solo clic.
- **Cierre de jornada** — el inverso del arranque: minimiza o cierra todo lo del trabajo con un solo icono al terminar el día.
- **Controlar una ventana ya abierta** — la localiza por su título (el reproductor de música, por ejemplo), la activa y le envía una tecla (la de pausa, por ejemplo), sin que tengas que ir a buscarla.

Y como cada acción guardada tiene su propio icono, la siguiente vez ni siquiera hace falta abrir Mi Lanzador: con un doble clic en el Escritorio (o el atajo de teclado que le asignes — ver «Ejecutar una acción sin abrir la ventana» más abajo) ya está todo en marcha.

## Otras funciones

- **Icono por acción** — puedes poner una imagen propia (PNG, SVG, JPG, ICO o XPM) para cada acción; si no pones ninguna, coge un icono automático según el primer paso.
- **Probar este paso ahora** — al crear o editar un paso, puedes ejecutarlo suelto para comprobar que hace lo que quieres, sin guardar la acción ni tocar los demás pasos.
- **Ver script generado** — para cada acción guardada puedes ver el script bash real que se ejecuta, paso a paso.
- **Notificaciones de escritorio** — avisa al lanzar una acción, y de nuevo si algo no ha ido bien; se puede desactivar en Ajustes.
- **Ajustes** — navegador predeterminado para "Sitio web", crear el acceso directo en el Escritorio automáticamente al guardar una acción nueva (si no, te lo pregunta cada vez), notificaciones, acceso directo a la carpeta de configuración, y un botón para (re)instalar xdotool/wmctrl cuando quieras.
- **Interfaz bilingüe** — español/inglés, con detección automática del idioma del sistema (si no es español, se usa inglés). Más detalles en «Idioma» más abajo.

Al crear un acceso directo eliges Escritorio, menú de aplicaciones, o ambos. Si al hacer doble clic Cinnamon te pide "confiar" o "permitir ejecución" la primera vez, es normal — acéptalo una vez y no se vuelve a preguntar.

## Idioma

Mi Lanzador usa el idioma del sistema solo como valor inicial. Si guardas una elección en `~/.config/mi-lanzador/idioma`, esa elección tiene prioridad, así que cambiar después el idioma del escritorio no cambia la interfaz por sorpresa. El botón `L` de la barra superior (o la tecla `L` cuando el foco no está en un campo de texto ni en una lista) intercambia `es` y `en` y guarda la elección.

Para diagnóstico o pruebas automatizadas, `mi-lanzador.sh --print-language` muestra el idioma que se va a usar. Las variables de entorno `MI_LANZADOR_LANG=es` o `MI_LANZADOR_LANG=en` permiten forzar un idioma en un solo lanzamiento sin cambiar la preferencia guardada.

## Requisitos

- Linux Mint 22.3, Cinnamon, sesión **X11** — en Wayland la app abre igual, pero pierde la colocación de ventanas, los clics y el teclado automatizado (detalle en «Sobre Wayland» más abajo).
- Python 3 (ya viene con el sistema).
- GTK3 para Python: `python3-gi gir1.2-gtk-3.0 python3-gi-cairo gir1.2-notify-0.7`
- `xdotool` y `wmctrl`, solo si vas a colocar ventanas, hacer clic, enviar teclas o escribir texto (incluida la colocación integrada dentro de abrir programa/documento/web/comando).

El script detecta si faltan las dos últimas (GTK3 y xdotool/wmctrl) y se ofrece a instalarlas con `pkexec`, pidiendo confirmación explícita antes de tocar nada. Si dices que no, o no hay `pkexec` disponible, te deja el comando exacto para hacerlo tú mismo. Para xdotool/wmctrl puedes además reintentarlo cuando quieras desde Ajustes → «Instalar ahora»; GTK3 no tiene ese botón — sin él la interfaz no llega a abrirse, así que tampoco hay Ajustes al que entrar — basta con volver a ejecutar el script una vez lo hayas instalado a mano. Python 3 es el único requisito que el script no ofrece instalar por ti: si llegara a faltar (no debería, en una instalación normal de Mint), directamente te muestra el comando.

## Compatibilidad con otras distribuciones

Mi Lanzador se desarrolla y se prueba sobre Linux Mint 22.3 (Cinnamon, X11), y es la única combinación totalmente soportada. Dicho esto, el script no impone ningún candado por distribución: no comprueba en ningún punto qué sistema es, así que en cualquier sesión Linux/X11 con GTK3 debería comportarse igual. De hecho, varias partes ya son genéricas por diseño — detecta terminales instaladas (`gnome-terminal`, `mate-terminal`, `xfce4-terminal`, `tilix`, `terminator`, `konsole`, `xterm`...), navegadores (Firefox/Chrome/Chromium/Brave, con sus variantes de nombre de paquete), y coloca ventanas usando propiedades EWMH estándar que implementan la mayoría de gestores de ventanas X11 (Xfwm4 de XFCE, Marco de MATE, KWin en X11, Mutter en Xorg...), aunque solo se ha ajustado y probado a fondo contra Muffin, el de Cinnamon.

La única pieza realmente atada a Mint/Ubuntu/Debian es la instalación automática de dependencias, que usa `apt`. En una distribución con otro gestor de paquetes esa instalación automática no va a funcionar, pero si instalas tú mismo los paquetes equivalentes antes de lanzarlo, el resto de la aplicación debería arrancar sin más:

| Distro | Gestor | Paquetes aproximados |
|---|---|---|
| Fedora / RHEL | `dnf` | `python3-gobject gtk3 python3-cairo libnotify xdotool wmctrl` |
| openSUSE | `zypper` | `python3-gobject typelib-1_0-Gtk-3_0 typelib-1_0-Notify-0_7 xdotool wmctrl` |
| Arch / Manjaro | `pacman` | `python-gobject gtk3 python-cairo libnotify xdotool wmctrl` |

(Nombres orientativos — compruébalos con el buscador de paquetes de tu distro, pueden variar entre versiones.)

Como en Wayland (ver más abajo) la colocación de ventana, el clic y el teclado no funcionan en ningún escritorio, esa limitación aplica igual sin importar la distribución.

## Instalación

Descarga [`script/mi-lanzador.sh`](script/mi-lanzador.sh) (con el botón de descarga de GitHub) y, desde la carpeta donde lo guardes, ejecuta:

```bash
chmod +x mi-lanzador.sh
./mi-lanzador.sh
```

Con eso basta. La primera vez:

1. Se copia a `~/.local/share/mi-lanzador/mi-lanzador.sh` — esa pasa a ser la copia "instalada"; el `.sh` que descargaste ya no hace falta.
2. Instala su icono, crea su lanzador en el menú de aplicaciones y deja una copia en tu Escritorio.
3. Comprueba dependencias y pregunta antes de instalar nada que falte.

Después de eso, ábrelo desde el menú o el icono del Escritorio, como cualquier otra app.

## Instalar y lanzar Mi Lanzador con Scriptya (opcional)

[Scriptya](https://github.com/filonux/Scriptya) es un lanzador de scripts: organiza los tuyos en un menú con búsqueda y puede convertir cualquiera de ellos en una app de escritorio con su propio icono, sin escribir un `.desktop` a mano. Puedes añadir unos metadatos opcionales desde Scriptya para tenerlo organizado con el nombre, descripción, cambiar su icono, etc.

## Dónde guarda las cosas

| Qué | Dónde |
|---|---|
| Acciones | `~/.config/mi-lanzador/acciones.json` |
| Ajustes | `~/.config/mi-lanzador/ajustes.json` |
| Iconos personalizados | `~/.config/mi-lanzador/iconos/` |
| Preferencia de idioma | `~/.config/mi-lanzador/idioma` |
| Registro de la última ejecución | `~/.config/mi-lanzador/ultima_ejecucion.log` |
| Log de errores | `~/.config/mi-lanzador/error.log` |
| Script instalado | `~/.local/share/mi-lanzador/mi-lanzador.sh` |
| Icono del lanzador | `~/.local/share/icons/hicolor/scalable/apps/mi-lanzador.svg` |

Cualquier error inesperado se registra en el log de errores y además se muestra en un aviso: no falla en silencio, porque normalmente se abre con doble clic, sin terminal donde ver nada. El registro de la última ejecución, en cambio, es la salida de la última acción que has lanzado (avisos incluidos) — útil para ver por qué un paso concreto no hizo lo que esperabas.

Si `acciones.json` o `ajustes.json` no se pueden leer, se conservan en la misma carpeta como `<nombre>.corrupt-<fecha>`, la app abre con datos vacíos y te lo avisa. El log de errores se rota a `error.log.1` cuando pasa de 256 KB.

## Sobre Wayland

Si tu sesión de Cinnamon es Wayland nativo, abrir programas/webs/comandos funciona igual, pero colocar ventanas, hacer clic, enviar teclas y escribir texto **no van a funcionar**, aunque tengas xdotool y wmctrl instalados — es una limitación de esas herramientas, no del script. Se detecta sola y avisa una vez al día. Para tener todo, elige la sesión "Cinnamon" (X11) en la pantalla de inicio de sesión, no la que dice "Cinnamon (Wayland)".

## Ejecutar una acción sin abrir la ventana

```bash
mi-lanzador.sh --ejecutar <id_de_la_accion>
```

Corre esa acción de principio a fin sin mostrar ninguna ventana. Es lo que usan por dentro los accesos directos `.desktop` que genera la app, y sirve igual de bien para asignarle un atajo de teclado propio desde Cinnamon. El `id` es el campo `id` de la acción en `acciones.json`; también aparece al final de la línea `Exec=` de su acceso directo.

## Por dentro

Un único `.sh`: la parte de bash hace la auto-instalación, comprueba/instala dependencias y avisa de Wayland; al final hace `exec python3` sobre un heredoc con toda la interfaz en PyGObject (GTK3). Sin build, sin paquetes propios que instalar — el archivo es el programa.

## Pruebas

`bash tests/test_project.sh` comprueba la sintaxis del script y ejecuta más de 450 pruebas que arrancan la interfaz GTK3 real sobre un Xvfb virtual con Openbox; las dependencias que necesita están en [CONTRIBUTING.md](.github/CONTRIBUTING.md). GitHub Actions ejecuta el mismo comando en cada pull request y en cada push a la rama por defecto, junto con ShellCheck y pyflakes sobre el Python embebido.

## Licencia

Consulta el archivo [LICENSE.txt](LICENSE.txt) de este repositorio.

---

Hecho por **[Filonux](https://github.com/filonux)**.
