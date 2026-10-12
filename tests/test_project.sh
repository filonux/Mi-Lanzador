#!/bin/bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
export PYTEST_DISABLE_PLUGIN_AUTOLOAD=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/script/mi-lanzador.sh"
bash -n "$SCRIPT"
TMP="$ROOT/script/.test-embedded.py"
sed -n '/^exec python3 - "\$@" <<'"'"'PYEOF'"'"'$/,/^PYEOF$/p' "$SCRIPT" | sed '1d;$d' > "$TMP"
python3 -m py_compile "$TMP"
rm -rf "$ROOT/script/__pycache__" "$TMP"
cd "$ROOT"
python3 -m pytest -q -p no:cacheprovider tests
