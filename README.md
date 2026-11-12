# 小宁翻译 · XiaoNing Translate

给经常跟海外客户沟通的人用的划词翻译工具，背后是 Claude。**支持 Mac 和 Windows。**

用鼠标**选中任意文字**，旁边就会弹出工具条：

**翻译 · 译成英文 · 译成〔上次的语言〕· 其他语言 · 润色 · 复制**

- **看客户消息**：选中客户发来的外语，点「翻译」，弹出中文译文（选中文就翻成英文）。
- **写回复**：在输入框里用中文写好，选中，点「译成英文」或「其他语言」，自动翻译 + 润色成地道的客服语气，**直接替换**进输入框。不满意按 ⌘Z 撤销。
- Intercom、邮件、Telegram、WhatsApp、钉钉、网页……几乎所有软件都能用。
- **固定翻译框**：点译文框右上角的图钉图标，框就不会自动关闭，下次翻译直接显示在里面；点 × 关闭。
- **截图翻译**：Mac 按 `⌃⌥S`（Control+Option+S），Windows 按 `Ctrl+Alt+S`，框选屏幕区域，识别图里的文字并翻译；报错截图会附一句说明。

## Windows 安装（约 2 分钟）

需要 Windows 10（1803 及以后）或 Windows 11。

1. 打开 **PowerShell**（点开始菜单，搜 **PowerShell**，打开「Windows PowerShell」），粘贴下面这一行，回车：

   ```powershell
   irm https://raw.githubusercontent.com/wenluisme/xiaoning-translate/main/install.ps1 | iex
   ```

   它会自动：下载小宁翻译、下载免费的 [AutoHotkey](https://www.autohotkey.com)（运行它的小工具，不需要管理员权限）、问你要 API Key、设成开机自动启动。

2. 提示输入 **API Key** 时，粘贴你的 Claude API Key（`sk-ant-` 开头）；公司有网关的，接着填网关地址。没有的话先回车跳过，以后再填。
3. 装好后右下角托盘区会出现一个绿色的 **H** 图标，看到「小宁翻译已就绪」的提示就可以用了。

- 改 Key / 网关：右键托盘图标 → **打开配置文件**，改完保存，再右键 → **重新加载**。
- 业务术语提示词：右键托盘图标 → **打开提示词文件夹**，把 `write.txt`、`read.txt` 放进去，再 → **重新加载**。
- 更新：再运行一次上面那行命令，Key 和提示词会保留。
- 替换后不满意按 **Ctrl+Z** 撤销；开关工具条 **Ctrl+Alt+T**。

## Mac 安装（约 2 分钟）

1. 打开「终端」（启动台里搜 **终端** / Terminal），粘贴下面这一行，回车：

   ```bash
   curl -fsSL https://raw.githubusercontent.com/wenluisme/xiaoning-translate/main/install.sh | bash
   ```

   它会自动：下载小宁翻译、安装免费的 [Hammerspoon](https://www.hammerspoon.org)（运行它的小工具）、问你要 API Key。

2. 提示输入 **API Key** 时，粘贴你的 Claude API Key（`sk-ant-` 开头）。没有的话先回车跳过，以后再填。
3. 系统设置会自动打开到「隐私与安全性 → **辅助功能**」：把 **Hammerspoon** 打开。
   想用截图翻译，再到「**屏幕录制**」里也打开 Hammerspoon。
4. 点屏幕右上角菜单栏的**小锤子图标** → **Reload Config**。

看到「小宁翻译已就绪」的提示就可以用了。

### Mac：以后要改 API Key / 更新版本

- 改 Key：编辑 `~/xiaoning-translate/config.lua` 里的 `apiKey`，然后小锤子 → Reload Config。
- 更新：再运行一次上面那行安装命令即可，你的 Key 和自定义提示词会保留。

## 用法细节

| 工具条按钮 | 作用 |
|---|---|
| **翻译** | 弹出译文框（客户消息 → 中文；中文 → 英文），不改原文 |
| **译成英文** | 翻译 + 润色成英文，直接替换选中的文字 |
| **译成〔上次的语言〕** | 用上次在「其他语言」里选过的语言 |
| **其他语言** | 20 种语言可选（可搜索），选完直接替换 |
| **润色** | 不换语言，只把文字改得更地道 |
| **复制** | 复制选中的文字 |
| **更多** | 选中的是客户消息时只显示「翻译 / 复制 / 更多」，点「更多」展开全部 |

- 工具条在点别处、打字、滚动或 8 秒后自动消失；选中纯数字、IP、网址、邮箱时不出现。
- 译文是边生成边显示的；鼠标移到按钮上就会提前开始翻译，点下去时通常已经有结果。
- 译文框可以按住顶部拖动位置。
- `⌃⌥T`：开关划词工具条。

## 加入你公司的业务术语（可选）

把 `prompts/write.example.txt`、`prompts/read.example.txt` 复制成 `prompts/write.txt`、`prompts/read.txt`，写上公司介绍、产品术语的固定译法、语气要求。这两个文件只在你电脑上，不会上传。

## 常见问题

- **选中文字没有工具条**：确认「辅助功能」里 Hammerspoon 已打开；小锤子 → Reload Config；按 `⌃⌥T` 看是不是被关掉了。
- **提示「出错了」/「超时」**：检查 API Key 和网络；用公司网关的，确认 `config.lua` 里的 `endpoint` 地址正确。
- **截图只截到桌面背景**：「屏幕录制」里打开 Hammerspoon。

## 技术说明

- Mac：运行在 Hammerspoon 上的 Lua 脚本（`xiaoning.lua`）。Windows：运行在 AutoHotkey v2 上的脚本（`windows/xiaoning.ahk`），用系统自带的 `curl.exe` 流式调用接口，配置在 `config.ini`。
- 两边都调用 Anthropic Messages API（或任何兼容网关），支持流式输出，共用 `prompts/` 里的提示词。
- Windows 版每次推送都会在 GitHub 的 Windows 测试机上自动检查（语法、核心逻辑、模拟接口的流式请求、安装脚本），见 `.github/workflows/windows-check.yml`。
- 配置：`config.lua`（`endpoint`、`apiKey`、`model`，或 `useClaudeCodeSettings = true` 复用 Claude Code 的令牌）。见 `config.example.lua`。
- 判断选中的文字能不能编辑：Mac 看鼠标位置下的辅助功能元素是不是输入框；Windows 看选区末尾有没有输入光标。读取选中文字优先用辅助功能接口，不行再静默复制（会恢复剪贴板）。
- Sonnet 5.x 使用 `thinking: between_tools`，翻译时不走思考步骤，快 1.5–2 秒。

## License

MIT
