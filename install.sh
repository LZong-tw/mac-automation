#!/bin/bash
# Restore mac-automation: build, symlink scripts, install & start LaunchAgents. Idempotent.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"
AGENT_DIR="$HOME/Library/LaunchAgents"
mkdir -p "$BIN_DIR" "$AGENT_DIR" "$HOME/.local/log"

echo "== build Swift tools"
"$REPO_DIR/build.sh"

echo "== symlink bin/ → $BIN_DIR"
for f in "$REPO_DIR"/bin/*; do
    name="$(basename "$f")"
    target="$BIN_DIR/$name"
    if [ -e "$target" ] && [ ! -L "$target" ]; then
        mv "$target" "$target.pre-repo.bak"
        echo "   backed up existing $name → $name.pre-repo.bak"
    fi
    ln -sfn "$f" "$target"
    echo "   $name"
done

echo "== install LaunchAgents"
for plist in "$REPO_DIR"/launchagents/*.plist; do
    name="$(basename "$plist")"
    label="${name%.plist}"
    # launchd is unreliable with symlinked plists — always copy
    cp "$plist" "$AGENT_DIR/$name"
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$AGENT_DIR/$name"
    echo "   $label loaded"
done

echo "done."
