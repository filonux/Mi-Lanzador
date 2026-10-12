# How to contribute

Thanks for your interest. This guide covers the basics so your contribution can be reviewed and accepted quickly.

## Before writing code

- For large changes, or changes to the current behavior, open an issue first (using the feature request template) to discuss the approach before investing time in the implementation.
- For one-off bugs or small improvements, you can go straight to a *pull request*.

## Sending the pull request

- Run `bash tests/test_project.sh` before sending it: it checks the script's syntax and runs the whole suite. It needs `sudo apt install xvfb openbox x11-utils x11-apps xdotool wmctrl xdg-user-dirs python3-gi gir1.2-gtk-3.0 gir1.2-notify-0.7 libgtk-3-bin librsvg2-common dbus-daemon python3-pytest desktop-file-utils shellcheck`; without the last two, the tests that validate the generated `.desktop` files and the generated script are skipped instead of failing (CI installs both). `tests/test_real_terminals.py` also runs the “command” step through every terminal the script knows that is installed (`gnome-terminal`, `mate-terminal`, `xfce4-terminal`, `tilix`, `terminator`, `konsole`, `xterm`; also `lxterminal`, `urxvt`, `kitty` and `alacritty` as `x-terminal-emulator`) and skips the others.
- CI (`.github/workflows/ci.yml`) runs that same command on every pull request. Locally, `imagemagick fonts-dejavu-core` are optional: `tests/test_aesthetic.py` uses them to measure text widths and falls back to an estimate without them.
- If you change a user-interface text, add its English translation to `TR_EN`.
- If you change the behavior, add or adjust a test in `tests/`.

## Reporting bugs or suggesting ideas

Use the repository's issue templates; they open automatically when you create a new issue. The more context you give (distro, `zenity` version, exact steps), the faster it can be diagnosed.

For security matters, prefer reporting privately over a public issue — see [`SECURITY.md`](SECURITY.md).
