#!/usr/bin/env bash
# Build snip, install it with its user service, and link the omarchy-shell plugin.
set -euo pipefail
cd "$(dirname "$0")"

PLUGIN_ID=mvrcelo.snippets
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/snippets"

echo ":: building snip"
if cargo --version >/dev/null 2>&1; then
  cargo build --release --manifest-path daemon/Cargo.toml
else
  mise exec rust@stable -- cargo build --release --manifest-path daemon/Cargo.toml
fi
install -Dm755 daemon/target/release/snip "$HOME/.local/bin/snip"

# The panel watches this file to reload when a capture lands.
mkdir -p "$STATE_DIR"
[[ -f "$STATE_DIR/changed" ]] || date -Is >"$STATE_DIR/changed"

echo ":: installing user service"
install -Dm644 dist/snip.service "$HOME/.config/systemd/user/snip.service"
systemctl --user daemon-reload
systemctl --user enable snip.service >/dev/null
systemctl --user restart snip.service

# Copied, not symlinked: the shell's file watcher doesn't follow symlinks,
# and a real directory hot-reloads like any other plugin.
echo ":: installing plugin -> $PLUGIN_DIR"
[[ -L "$PLUGIN_DIR" ]] && rm "$PLUGIN_DIR"
install -Dm644 -t "$PLUGIN_DIR" plugin/manifest.json plugin/BarWidget.qml plugin/Panel.qml
omarchy-shell shell rescanPlugins >/dev/null || true
omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1 || omarchy-shell shell setPluginEnabled "$PLUGIN_ID" true >/dev/null || true

if [[ ! -f /etc/udev/rules.d/70-snippets-keyboard.rules ]]; then
  cat <<MSG

:: one manual step left: let snip read keyboards (needs sudo, no relogin)
   sudo install -m644 $PWD/dist/70-snippets-keyboard.rules /etc/udev/rules.d/ \\
     && sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=input
MSG
fi
echo ":: done. Items live in $(~/.local/bin/snip dir)"
