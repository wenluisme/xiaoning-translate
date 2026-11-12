<p align="center"><img src="assets/icon/icon.png" width="112" alt="XiaoNing Translate logo"></p>

# XiaoNing Translate (小宁翻译)

A select-to-translate tool for people who talk to customers in other languages, powered by Claude. **Works on macOS and Windows.**

Select any text with the mouse and a small toolbar pops up next to it:

**Translate · To English · To ⟨last language⟩ · Other languages · Polish · Copy**

- **Read customer messages**: select a message and click **Translate** — a popup shows the Chinese translation, what the customer means, and a suggested reply (the copy button copies the suggested reply).
- **Write replies**: draft your reply in your own language, select it, click **To English** or **Other languages** — it is translated and polished into a natural, friendly support tone and **written straight back into the input box**. Undo with ⌘Z / Ctrl+Z.
- Works almost everywhere: Intercom, email, Telegram, WhatsApp, DingTalk, Slack, web pages…
- **Pin the popup**: click the pin icon on the translation card to keep it open; the next translation shows up in the same card. Click × to close it.
- **Screenshot translation**: press `⌃⌥S` on Mac or `Ctrl+Alt+S` on Windows, select a screen area, and the text in it is read and translated. Error screenshots get a one-line explanation.

> The toolbar buttons and popups are in Chinese (the tool was built for a Chinese-speaking support team). Labels: 翻译 = Translate, 译成英文 = To English, 其他语言 = Other languages, 润色 = Polish, 复制 = Copy, 更多 = More.

## Install on Windows (about 2 minutes)

Requires Windows 10 (1803 or later) or Windows 11.

1. Open **PowerShell** (Start menu → search **PowerShell** → "Windows PowerShell"), paste this line and press Enter:

   ```powershell
   irm https://raw.githubusercontent.com/wenluisme/xiaoning-translate/main/install.ps1 | iex
   ```

   It downloads XiaoNing Translate and the free [AutoHotkey](https://www.autohotkey.com) runtime (no admin rights needed), asks for your API key, and sets it to start with Windows.

2. When asked for an **API key**, paste your Claude API key (starts with `sk-ant-`). If your company uses a gateway, enter its URL next. You can press Enter to skip and add them later.
3. The XiaoNing Translate icon (an orange speech bubble) appears in the system tray. When you see the "小宁翻译已就绪" (ready) message, you're good to go.

- Change the key / gateway: right-click the tray icon → **打开配置文件** (open config file), save, then right-click → **重新加载** (reload).
- Custom prompts: right-click the tray icon → **打开提示词文件夹** (open prompts folder), put `write.txt` / `read.txt` there, then reload.
- Updates: installed automatically — once a day it checks GitHub and, when there is a new version, asks whether to update now; click 立即更新 / Yes and it updates and restarts itself in about 10 seconds (your key and prompts are kept). To check now: right-click the tray icon → **检查更新** (check for updates). The first item in the tray menu shows the installed version; click it to see what changed ([Releases](https://github.com/wenluisme/xiaoning-translate/releases)).
- Turn the toolbar on/off: `Ctrl+Alt+T`.

## Install on macOS (about 2 minutes)

1. Open **Terminal**, paste this line and press Enter:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/wenluisme/xiaoning-translate/main/install.sh | bash
   ```

   It downloads XiaoNing Translate, installs the free [Hammerspoon](https://www.hammerspoon.org) app that runs it, and asks for your API key.

2. When asked for an **API key**, paste your Claude API key (starts with `sk-ant-`), or press Enter to skip and add it later.
3. System Settings opens at **Privacy & Security → Accessibility**: turn on **Hammerspoon**. For screenshot translation, also turn it on under **Screen Recording**.
4. Click the hammer icon in the menu bar → **Reload Config**.

- Change the key: edit `apiKey` in `~/xiaoning-translate/config.lua`, then hammer icon → Reload Config.
- Updates: installed automatically — once a day it checks GitHub and, when there is a new version, asks whether to update now; click 立即更新 / Yes and it updates and restarts itself in about 10 seconds (your key and prompts are kept). The XiaoNing Translate icon in the menu bar shows the installed version and has **检查更新** (check for updates); see what changed under [Releases](https://github.com/wenluisme/xiaoning-translate/releases).
- Turn the toolbar on/off: `⌃⌥T`.

## Toolbar buttons

| Button | What it does |
|---|---|
| **翻译** Translate | Shows the translation in a popup (foreign language → Chinese, Chinese → English); the original text is not changed |
| **译成英文** To English | Translates and polishes into English and replaces the selection |
| **译成⟨…⟩** To ⟨last language⟩ | Same, with the language you last picked under "Other languages" |
| **其他语言** Other languages | Pick one of 20 languages (searchable), then replace |
| **润色** Polish | Keeps the language, just makes it read naturally, then replaces |
| **复制** Copy | Copies the selection |
| **更多** More | Shown when the selection isn't in an input box (e.g. a customer's message), where only Translate / Copy / More appear; click it to show all buttons |

- The toolbar disappears when you click elsewhere, type, scroll, or after 8 seconds. It doesn't appear for plain numbers, IPs, URLs or emails.
- Translations stream in as they are generated, and a request starts as soon as you hover a button, so the result is often ready when you click.
- Drag the translation card by its header to move it.

## Add your company's terminology (optional)

Copy `prompts/write.example.txt` and `prompts/read.example.txt` to `prompts/write.txt` and `prompts/read.txt`, and add a short company description, fixed translations for your product terms, and the tone you want. These files stay on your computer and are never committed.

## Troubleshooting

- **Screenshot tools**: dragging a box in a screenshot tool (DingTalk, WeChat, Snipaste…) is ignored, so it no longer ends the capture.
- **No toolbar after selecting text**: macOS — make sure Hammerspoon is enabled under Accessibility, then Reload Config. Windows — make sure the tray icon is there; right-click → reload. Also check the toolbar isn't switched off (`⌃⌥T` / `Ctrl+Alt+T`).
- **"出错了" (error) or timeout**: check your API key and network; if you use a gateway, check the `endpoint` in your config.
- **Screenshot only captures the desktop (macOS)**: enable Hammerspoon under Screen Recording.

## How it works

- macOS: a Lua script (`xiaoning.lua`) running in Hammerspoon. Windows: an AutoHotkey v2 script (`windows/xiaoning.ahk`) that calls the API through the built-in `curl.exe`; settings live in `config.ini`.
- Both call the Anthropic Messages API (or any compatible gateway) with streaming, and share the prompts in `prompts/`.
- Settings: `config.lua` on macOS (`endpoint`, `apiKey`, `model`, or `useClaudeCodeSettings = true` to reuse Claude Code's token — see `config.example.lua`); `config.ini` on Windows.
- Input box detection: macOS checks whether the accessibility element under the mouse is a text input; Windows checks whether there is a text caret at the end of the selection. The selected text is read through the accessibility API where possible, otherwise via a silent copy that restores your clipboard.
- With Sonnet 5.x the request uses `thinking: between_tools`, so plain translation skips the thinking step (about 1.5–2 s faster).
- Every push runs the Windows checks on a GitHub Windows runner (syntax, core logic, streaming against a mock API, installer): `.github/workflows/windows-check.yml`.

## License

MIT
