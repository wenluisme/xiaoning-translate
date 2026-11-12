# claude-translator-mac

A tiny macOS translation & writing helper for people who chat with customers in other languages — powered by Claude and [Hammerspoon](https://www.hammerspoon.org).

Select any text with the mouse and a small toolbar pops up next to it (like the selection bar in many AI browsers):

**翻译 Translate · 译成英文 To English · 译成〔last language〕· 其他语言 Other languages · 润色 Polish · 复制 Copy**

- **Translate** shows the translation in a popup (customer message → Chinese; Chinese → English), the original stays untouched.
- **To English / Other languages / Polish** translate **and polish** your draft and write the result straight back over the selection — in any app: Intercom, email, Telegram, WhatsApp, Slack. `⌘Z` to undo.
- If the selection can't be edited (e.g. a customer's message), only Translate and Copy are shown.
- `⌃⌥S`: grab a screen region and let Claude read + translate it (error screenshots get a one-line explanation).

No app to install besides Hammerspoon, no subscription — it uses your own Anthropic API key (or any Anthropic-compatible gateway).

[中文说明见下方](#中文说明)

## Toolbar & hotkeys

| | Action |
|---|---|
| Select text → **翻译** | Translate selection into Chinese (Chinese → English) in a popup |
| Select text → **译成英文** | Translate + polish into English, replace the selection |
| Select text → **译成〔…〕** | Same, with the last language picked from the list |
| Select text → **其他语言** | Pick from 20 languages (searchable), replace |
| Select text → **润色** | Polish only, keep the language, replace |
| Select text → **复制** | Copy |
| `⌃⌥S` | Select a screen region → OCR + translate with Claude vision |
| `⌃⌥T` | Toggle the selection toolbar |

The toolbar hides when you click elsewhere, type, scroll, or after 8 seconds. Numbers, IPs, URLs and emails don't trigger it.

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

- Replace: sends the selection to the Claude Messages API with your prompt and pastes the result over it (⌘C fallback uses the app's Edit ▸ Copy menu for apps such as Telegram for macOS that ignore synthetic ⌘C). If you switch windows while waiting, nothing is pasted — the result is left on the clipboard.
- Selection: read through the macOS Accessibility API when possible (which also tells whether the text is editable), otherwise via a silent copy with the clipboard restored. In apps that don't report editability, all buttons are shown and the result is also left on the clipboard as a backup.

## License

MIT

---

## 中文说明

一个给跟海外客户聊天的人用的 Mac 小工具：用鼠标选中任意文字，旁边弹出工具条——

- **翻译**：弹窗显示中文（选的是中文则翻成英文）。
- **译成英文 / 其他语言 / 润色**：把你写的中文翻译并润色好，直接替换选中的文字，⌘Z 撤销。
- **复制**；`⌃⌥S` 截图翻译；`⌃⌥T` 开关工具条。

安装：装好 Hammerspoon → 克隆本仓库 → 运行 `install.sh` → 在 `config.lua` 填 API Key → Hammerspoon 菜单 Reload Config → 系统设置里给 Hammerspoon 开「辅助功能」和「屏幕录制」权限。

想加入自己公司的业务背景和术语：把 `prompts/*.example.txt` 复制成 `prompts/*.txt` 再改，这些文件不会被提交。
