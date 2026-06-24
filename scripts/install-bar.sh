#!/usr/bin/env bash
#
# install-bar.sh — build QuayBar, assemble a menu-bar (.app) bundle in
# ~/Applications, and register a per-user LaunchAgent so it appears in the menu
# bar at login (like OrbStack's). Run this in the GUI session you want it in.
#
# QuayBar is read-mostly: it polls quayd's status.json and offers a single
# action — Restart — which stops a service and lets quayd start it again.
#
# Usage:
#   scripts/install-bar.sh            # build, install, launch
#   scripts/install-bar.sh --uninstall
#
set -euo pipefail

LABEL="com.backspinlabs.quay.quaybar"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$HOME/Applications/QuayBar.app"
BIN_SRC="$REPO_ROOT/.build/release/QuayBar"
INFO_SRC="$REPO_ROOT/Resources/QuayBar-Info.plist"
AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_DST="$AGENTS_DIR/$LABEL.plist"
PLIST_SRC="$REPO_ROOT/Resources/$LABEL.plist.template"
GUI_DOMAIN="gui/$(id -u)"

note() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*"; }

uninstall() {
    note "Unloading LaunchAgent $LABEL"
    launchctl bootout "$GUI_DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST_DST"
    rm -rf "$APP_DIR"
    note "Removed $PLIST_DST and $APP_DIR"
    exit 0
}

[ "${1:-}" = "--uninstall" ] && uninstall

if [ "$(uname -s)" != "Darwin" ]; then
    warn "QuayBar is a macOS menu bar app; this installer only does useful work on macOS."
fi

# --- build release ---
note "Building release QuayBar (swift build -c release)…"
( cd "$REPO_ROOT" && swift build -c release --product QuayBar )
[ -x "$BIN_SRC" ] || { warn "build did not produce $BIN_SRC"; exit 1; }

# --- assemble the .app bundle ---
note "Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
install -m 0755 "$BIN_SRC" "$APP_DIR/Contents/MacOS/QuayBar"
cp "$INFO_SRC" "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
# Ad-hoc sign so the app has a stable identity (locally built, not notarized).
codesign --force --sign - "$APP_DIR" 2>/dev/null || warn "codesign skipped (continuing unsigned)"

# --- template + install the LaunchAgent ---
mkdir -p "$AGENTS_DIR" "$HOME/.config/quay"
sed \
    -e "s|__APP_BIN__|$APP_DIR/Contents/MacOS/QuayBar|g" \
    -e "s|__HOME__|$HOME|g" \
    "$PLIST_SRC" > "$PLIST_DST"
note "Wrote LaunchAgent -> $PLIST_DST"

# --- (re)bootstrap reliably ---
# bootout is async; bootstrapping before the old instance tears down returns
# "Input/output error" and leaves the agent unregistered. Wait, then retry.
launchctl bootout "$GUI_DOMAIN/$LABEL" 2>/dev/null || true
for _ in $(seq 1 50); do
    launchctl print "$GUI_DOMAIN/$LABEL" >/dev/null 2>&1 || break
    sleep 0.2
done

bootstrapped=0
for attempt in 1 2 3 4 5; do
    if launchctl bootstrap "$GUI_DOMAIN" "$PLIST_DST" 2>/dev/null; then
        bootstrapped=1; break
    fi
    warn "bootstrap attempt $attempt failed (service still settling) — retrying…"
    sleep 1
done
[ "$bootstrapped" = "1" ] || { warn "could not bootstrap $LABEL; run 'launchctl bootstrap $GUI_DOMAIN $PLIST_DST' manually"; exit 1; }

launchctl enable "$GUI_DOMAIN/$LABEL"
launchctl kickstart "$GUI_DOMAIN/$LABEL"
note "QuayBar installed and launched. Look for the shippingbox icon in the menu bar."
echo
echo "  Quit it from its own menu; it will stay quit (KeepAlive only fires on crash)."
echo "  Logs: ~/.config/quay/quaybar.{out,err}.log"
echo "  Uninstall: scripts/install-bar.sh --uninstall"
