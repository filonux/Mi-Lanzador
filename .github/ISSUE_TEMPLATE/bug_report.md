---
name: Bug report
about: Something does not work as expected (a step, a shortcut, the window...)
title: ''
labels: bug
assignees: ''
---

<!-- You can write in English or Spanish. Delete the parts that do not apply. -->
<!-- Security problem? Please report it privately instead of here: see SECURITY.md. -->

**Describe the bug**
A clear and concise description of what the bug is.

**To Reproduce**
Which step type fails (open program, document, website, run a command, wait, place window, click, key, type text)? Steps to reproduce the behavior:
1. Create or open an action with '...'
2. Add the step '....'
3. Run it from '....' (the app window, a Desktop shortcut, the applications menu)
4. See error

**Expected behavior**
A clear and concise description of what you expected to happen.

**Screenshots**
If applicable, add screenshots to help explain your problem.

**Environment (please complete the following information):**
 - Mi Lanzador version: [shown at the bottom of the Settings tab, e.g. 2.1.0]
 - Distro and version: [e.g. Linux Mint 22.3]
 - Desktop environment: [e.g. Cinnamon]
 - Session type: [X11 or Wayland; `echo $XDG_SESSION_TYPE` shows it]
 - `xdotool` and `wmctrl`: [installed or not; `xdotool --version`, `wmctrl -V`]
 - Terminal emulator, only for "Run a command" steps: [e.g. gnome-terminal]
 - `zenity` version, only if the problem is in the install dialog: [`zenity --version`, or "not installed"]

<!-- On Wayland the app opens, but placing windows, clicks and automated keys are not available (see "About Wayland" in the README). -->

**Logs**
Paste the relevant lines, or attach the files:
 - `~/.config/mi-lanzador/error.log` (unexpected errors)
 - `~/.config/mi-lanzador/ultima_ejecucion.log` (output of the last action you ran)

<!-- Check the logs before posting: they may include commands, paths or URLs from your actions. Remove anything private (passwords, tokens, personal data). -->

**Additional context**
Add any other context about the problem here.
