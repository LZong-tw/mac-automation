#!/bin/bash
LOG="$HOME/.local/log/input-source-changes.log"
mkdir -p "$(dirname "$LOG")"
prev=""
while true; do
  current=$(defaults read ~/Library/Preferences/com.apple.HIToolbox AppleSelectedInputSources 2>/dev/null | grep "Input Mode\|KeyboardLayout Name" | head -1)
  if [ -n "$prev" ] && [ "$current" != "$prev" ]; then
    app=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || echo "unknown")
    # Capture recently active processes (sorted by CPU, top 5 non-idle)
    recent=$(ps -arcwwxo pid,comm -r 2>/dev/null | head -6 | tail -5 | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$app] active=[$recent] $current" >> "$LOG"
  fi
  prev="$current"
  sleep 0.5
done
