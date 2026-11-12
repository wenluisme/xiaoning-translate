# claude-translator-mac

A tiny macOS translation & writing helper for people who chat with customers in other languages — powered by Claude and [Hammerspoon](https://www.hammerspoon.org).

- **Write**: type your reply in Chinese (or any language) in *any* app — Intercom, email, Telegram, WhatsApp, Slack — press a hotkey, and the text is translated **and polished** into the target language and written straight back into the input box. `⌘Z` to undo.
- **Read**: select a customer's message and a small 「译」 icon appears; hover it to see the translation in a popup. Or grab a screenshot region and let Claude read + translate it (error screenshots get a one-line explanation).

No app to install besides Hammerspoon, no subscription — it uses your own Anthropic API key (or any Anthropic-compatible gateway).

[中文说明见下方](#中文说明)

## Hotkeys

| Hotkey | Action |
|---|---|
| `⌃⇧` (press Control+Shift together, release) | Translate + polish into **English**, replace in place |
| `⌃⌥L` | Pick a language (20 built in, searchable), translate + polish, replace |
| `⌃⌥K` | Repeat with the last picked language |
| `⌃⌥P` | Polish only, keep the language |
| select text → hover the 「译」 icon | Translate selection into Chinese (Chinese → English) |
| `⌃⌥R` | Translate the current selection (without the icon) |
| `⌃⌥S` | Select a screen region → OCR + translate with Claude vision |
| `⌃⌥T` | Toggle the selection icon |

With nothing selected, the write hotkeys select the whole input field first. When replying to email, select just your part — otherwise the quoted thread is included.

## Install

1. Install [Hammerspoon](https://www.hammerspoon.org) and open it once.
2. Clone this repo and run the installer:
   ```bash
   git clone https://github.com/wenluisme/claude-translator-mac.git ~/claude-translator-mac
   ~/claude-translator-mac/install.sh
   ```
3. Edit `config.lua` (created from `config.example.lua`): set your `apiKey`, or set `useClaudeCodeSettings = true` to reuse the token from `~/.claude/settings.json`.
4. Hammerspoon menu bar icon → **Reload Config**.
5. System Settings → Privacy & Security → enable Hammerspoon under **Accessibility** (and **Screen Recording** for screenshot translation).

## Customize

- `prompts/write.example.txt` / `prompts/read.example.txt` are the default rules. Copy them to `prompts/write.txt` / `prompts/read.txt` and add your company, product terms and tone. Your own `prompts/*.txt` and `config.lua` are git-ignored.
- Languages, hotkeys and model live at the top / bottom of `claude_replace.lua`.

## How it works

- Write: copies the selection (⌘C, or the app's Edit ▸ Copy menu for apps such as Telegram for macOS that ignore synthetic ⌘C), sends it to the Claude Messages API with your prompt, pastes the result back, then restores your clipboard. If you switch windows while waiting, nothing is pasted — the result is left on the clipboard.
- Read: reads the selection through the macOS Accessibility API when possible, otherwise via a silent copy (clipboard restored). Chinese, numbers, IPs and URLs don't trigger the icon.

## License

MIT

---

## 中文说明

一个给跟海外客户聊天的人用的 Mac 小工具：

- **写**：在任意输入框用中文写好回复，按 `Control+Shift`（同时按下再松开），自动翻译并润色成英文，直接替换回输入框；`⌃⌥L` 选其他语言。
- **看**：选中客户的外语消息，旁边出现「译」字图标，鼠标移上去就弹出中文翻译；`⌃⌥S` 截图翻译。

安装：装好 Hammerspoon → 克隆本仓库 → 运行 `install.sh` → 在 `config.lua` 填 API Key → Hammerspoon 菜单 Reload Config → 系统设置里给 Hammerspoon 开「辅助功能」和「屏幕录制」权限。

想加入自己公司的业务背景和术语：把 `prompts/*.example.txt` 复制成 `prompts/*.txt` 再改，这些文件不会被提交。
