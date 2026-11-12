#!/bin/bash
# XiaoNing Translate (小宁翻译) — one-step installer for macOS.
# Messages shown during installation are in Chinese for the team this was built for.
#
#   curl -fsSL https://raw.githubusercontent.com/wenluisme/xiaoning-translate/main/install.sh | bash
#
# or, from a cloned copy:  ./install.sh
set -euo pipefail

REPO="wenluisme/xiaoning-translate"
DEST="$HOME/xiaoning-translate"

say() { printf "\n\033[1;38;5;173m▸ %s\033[0m\n" "$1"; }

# 1. Get the files (use this folder if we're running from a clone)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/xiaoning.lua" ]; then
  DEST="$SCRIPT_DIR"
  say "使用当前文件夹：$DEST"
else
  say "下载小宁翻译到 $DEST"
  TMP="$(mktemp -d)"
  curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/main" -o "$TMP/x.tgz"
  mkdir -p "$TMP/x" && tar -xzf "$TMP/x.tgz" -C "$TMP/x" --strip-components=1
  mkdir -p "$DEST"
  # keep the user's own config/prompts when updating
  rsync -a --exclude config.lua --exclude 'prompts/*.txt' "$TMP/x/" "$DEST/" 2>/dev/null || cp -R "$TMP/x/." "$DEST/"
  cp -n "$TMP/x/prompts/"*.example.txt "$DEST/prompts/" 2>/dev/null || true
  rm -rf "$TMP"
fi

# 2. Hammerspoon (the free, open-source app that runs the script)
if [ ! -d "/Applications/Hammerspoon.app" ]; then
  say "安装 Hammerspoon（免费开源的 Mac 自动化工具）"
  URL="$(curl -fsSL https://api.github.com/repos/Hammerspoon/hammerspoon/releases/latest | grep -o 'https://[^"]*Hammerspoon-[^"]*\.zip' | head -1)"
  TMP="$(mktemp -d)"
  curl -fsSL "$URL" -o "$TMP/hs.zip"
  ditto -x -k "$TMP/hs.zip" "$TMP"
  ditto "$TMP/Hammerspoon.app" "/Applications/Hammerspoon.app"
  rm -rf "$TMP"
else
  say "已安装 Hammerspoon"
fi

# 3. API key
CFG="$DEST/config.lua"
if [ ! -f "$CFG" ]; then
  say "设置 Claude API Key"
  echo "小宁翻译需要一个 Anthropic（Claude）API Key，形如 sk-ant-...。"
  echo "没有的话可以先直接回车跳过，以后再编辑 $CFG 填写。"
  ask() { # ask "prompt" → reads from the terminal even when run via curl | bash
    local reply=""
    if [ -t 0 ]; then read -r -p "$1" reply || true
    elif { exec 3</dev/tty; } 2>/dev/null; then read -r -p "$1" reply <&3 || true; exec 3<&-
    else read -r reply || true; fi
    printf '%s' "$reply"
  }
  KEY="$(ask "API Key: ")"
  ENDPOINT="https://api.anthropic.com/v1/messages"
  EP="$(ask "接口地址（直接回车用官方地址）: ")"
  [ -n "$EP" ] && ENDPOINT="$EP"
  # escape for a Lua string
  KEY="${KEY//\\/\\\\}"; KEY="${KEY//\"/\\\"}"
  ENDPOINT="${ENDPOINT//\"/}"
  cat > "$CFG" <<EOF
-- XiaoNing Translate — local config (never committed)
return {
  endpoint = "$ENDPOINT",
  apiKey = "$KEY",
  model = "claude-sonnet-5-5",
}
EOF
  chmod 600 "$CFG"
else
  say "已有配置文件 $CFG，保留不动"
fi

# 4. Load it from Hammerspoon
INIT="$HOME/.hammerspoon/init.lua"
mkdir -p "$HOME/.hammerspoon"
if ! grep -q 'require("xiaoning")' "$INIT" 2>/dev/null; then
  cat >> "$INIT" <<EOF

-- XiaoNing Translate
require("hs.ipc")
hs.autoLaunch(true)
package.path = "$DEST/?.lua;" .. package.path
xiaoning = require("xiaoning")
xiaoning.start()
EOF
  say "已加入 $INIT"
fi

# 5. Start + permissions
if [ "${XN_NO_OPEN:-}" = "1" ]; then say "（测试模式：跳过启动）"; exit 0; fi
say "启动 Hammerspoon"
defaults write org.hammerspoon.Hammerspoon MJShowDockIconKey -bool false
open -a Hammerspoon
sleep 2
osascript -e 'tell application "Hammerspoon" to execute lua code "hs.reload()"' >/dev/null 2>&1 || true
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

cat <<'EOF'

✅ 小宁翻译安装完成！还差最后一步：

  1. 在刚打开的「系统设置 → 隐私与安全性 → 辅助功能」里，把 Hammerspoon 打开
     （列表里没有就点 + 号，从「应用程序」里选 Hammerspoon）
  2. 想用截图翻译（⌃⌥S），再到「屏幕录制」里也打开 Hammerspoon
  3. 点菜单栏的小锤子图标 → Reload Config

用法：用鼠标选中任意文字，旁边会出现工具条，点「翻译」「译成英文」等按钮即可。
EOF
