#!/usr/bin/env bash
#
# install-agent.sh — build Quay in release, install quayd to ~/.local/bin, and
# register a PER-USER LaunchAgent so it autostarts at login and survives reboots.
#
# Everything derives from $HOME — nothing is hardcoded.
#
# Usage:
#   scripts/install-agent.sh            # build, install, bootstrap
#   QUAY_INTERVAL=30 scripts/install-agent.sh
#   scripts/install-agent.sh --uninstall
#
set -euo pipefail

LABEL="com.backspinlabs.quay.quayd"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/quay"
STACKS_DIR="$CONFIG_DIR/stacks"
AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_DST="$AGENTS_DIR/$LABEL.plist"
PLIST_SRC="$REPO_ROOT/Resources/$LABEL.plist.template"
INTERVAL="${QUAY_INTERVAL:-15}"
GUI_DOMAIN="gui/$(id -u)"

note() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*"; }

uninstall() {
    note "Unloading LaunchAgent $LABEL"
    launchctl bootout "$GUI_DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST_DST"
    note "Removed $PLIST_DST (binary and config left in place)."
    exit 0
}

[ "${1:-}" = "--uninstall" ] && uninstall

# --- platform sanity (warn, don't hard-fail: lets you stage on older macOS) ---
if [ "$(uname -s)" != "Darwin" ]; then
    warn "This installer targets macOS. Apple's \`container\` only runs on macOS 26+."
fi
if ! command -v container >/dev/null 2>&1; then
    warn "\`container\` CLI not found on PATH. Install apple/container first; quayd will idle-retry until it appears."
fi

# --- build release ---
note "Building release (swift build -c release)…"
( cd "$REPO_ROOT" && swift build -c release )
BUILD_BIN="$REPO_ROOT/.build/release/quayd"
[ -x "$BUILD_BIN" ] || { warn "build did not produce $BUILD_BIN"; exit 1; }

# --- install binary ---
mkdir -p "$BIN_DIR" "$STACKS_DIR"
install -m 0755 "$BUILD_BIN" "$BIN_DIR/quayd"
note "Installed quayd -> $BIN_DIR/quayd"

# Seed the example stack if the stacks dir is empty.
if [ -z "$(ls -A "$STACKS_DIR" 2>/dev/null || true)" ]; then
    cp "$REPO_ROOT/Examples/openwebui.quay.yaml" "$STACKS_DIR/"
    note "Seeded example stack -> $STACKS_DIR/openwebui.quay.yaml"
fi

# --- template + install the plist ---
mkdir -p "$AGENTS_DIR"
sed \
    -e "s|__BIN__|$BIN_DIR/quayd|g" \
    -e "s|__STACKS__|$STACKS_DIR|g" \
    -e "s|__HOME__|$HOME|g" \
    -e "s|__INTERVAL__|$INTERVAL|g" \
    "$PLIST_SRC" > "$PLIST_DST"
note "Wrote LaunchAgent -> $PLIST_DST"

# --- (re)bootstrap into the per-user GUI domain ---
# bootout is asynchronous: if we bootstrap before the old instance has fully
# torn down, launchctl returns "Input/output error" (errno 5) and leaves the
# agent UNREGISTERED. So wait for the service to actually disappear, then
# bootstrap with a short retry to ride out any residual settle time.
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
note "Bootstrapped and started $LABEL"

cat <<'EOF'

------------------------------------------------------------------------
quayd is installed and running under your user LaunchAgent.
  logs:   ~/.config/quay/quayd.err.log
  stacks: ~/.config/quay/stacks
  status: ~/.config/quay/status.json   (read by QuayBar)

APPLIANCE CHECKLIST  (a self-hosted box should come back on its own)
  [ ] Disable sleep (keep it always-on):
        sudo pmset -a sleep 0 disksleep 0 displaysleep 10
  [ ] Restart automatically after a power failure:
        sudo pmset -a autorestart 1
  [ ] Enable automatic login (so the LaunchAgent's GUI session exists at boot):
        System Settings ▸ Users & Groups ▸ Automatically log in as …
  [ ] Make sure Apple's container service starts for your user:
        container system start         # VERIFY exact subcommand on your build
------------------------------------------------------------------------
EOF
