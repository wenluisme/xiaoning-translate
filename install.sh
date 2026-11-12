#!/bin/bash
# Installs the Hammerspoon hook for this repo. Hammerspoon itself: https://www.hammerspoon.org
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
INIT="$HOME/.hammerspoon/init.lua"
mkdir -p "$HOME/.hammerspoon"
[ -f "$DIR/config.lua" ] || cp "$DIR/config.example.lua" "$DIR/config.lua"
if ! grep -q "claude_replace" "$INIT" 2>/dev/null; then
  cat >> "$INIT" <<EOF

-- claude-translator-mac
require("hs.ipc")
package.path = "$DIR/?.lua;" .. package.path
claudeReplace = require("claude_replace")
claudeReplace.start()
EOF
  echo "Added to $INIT"
else
  echo "$INIT already loads claude_replace"
fi
echo "Next: edit $DIR/config.lua (API key), then Hammerspoon menu > Reload Config."
echo "Grant Hammerspoon Accessibility (and Screen Recording for screenshot translation)."
