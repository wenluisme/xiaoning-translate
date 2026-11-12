-- Claude 翻译助手（Hammerspoon）
--
-- 写回复（直接替换输入框里的文字，⌘Z 可撤销）：
--   ⌃⇧   同时按下 Control+Shift 再松开 = 翻译润色成英文
--   ⌃⌥L  弹出语言列表，选一种语言翻译润色（会记住）
--   ⌃⌥K  用上次在列表里选的语言再来一次
--   ⌃⌥P  只润色，不换语言
-- 看消息（弹窗显示，不改原文）：
--   ⌃⌥R  选中文字 → 翻译成中文（中文则翻成英文）
--   ⌃⌥S  框选截图 → 识别并翻译成中文，报错会附一句说明
-- 弹窗：Esc 或点 × 关闭，「复制」按钮复制译文。

local M = {}

local HOME = os.getenv("HOME")
-- Folder this script lives in (so the project can be cloned anywhere).
local DIR = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")) or (HOME .. "/.hammerspoon")

-- Optional local settings in config.lua (not committed). See config.example.lua.
local function loadConfig()
  local path = DIR .. "/config.lua"
  local f = io.open(path, "r")
  if not f then return {} end
  f:close()
  local ok, cfg = pcall(dofile, path)
  if ok and type(cfg) == "table" then return cfg end
  hs.alert.show("config.lua 读取失败：" .. tostring(cfg), 5)
  return {}
end
local CFG = loadConfig()

-- Prompts: your own prompts/*.txt if present, otherwise the bundled examples.
local function promptPath(name)
  local own = DIR .. "/prompts/" .. name .. ".txt"
  local f = io.open(own, "r")
  if f then f:close() return own end
  return DIR .. "/prompts/" .. name .. ".example.txt"
end
local PROMPT_FILE = promptPath("write")
local READ_PROMPT_FILE = promptPath("read")

local ENDPOINT = CFG.endpoint or "https://api.anthropic.com/v1/messages"
local MODEL = CFG.model or "claude-sonnet-5-5"
local TIMEOUT = CFG.timeout or 45
local CLAUDE_SETTINGS_FILE = HOME .. "/.claude/settings.json"

local LANGUAGES = {
  "English", "Spanish", "Russian", "Portuguese (Brazil)", "French", "German",
  "Italian", "Turkish", "Arabic", "Vietnamese", "Indonesian", "Thai",
  "Japanese", "Korean", "Polish", "Ukrainian", "Persian", "Hindi",
  "Simplified Chinese", "Traditional Chinese",
}
local LANG_ZH = {
  ["English"] = "英语", ["Spanish"] = "西班牙语", ["Russian"] = "俄语",
  ["Portuguese (Brazil)"] = "葡萄牙语（巴西）", ["French"] = "法语", ["German"] = "德语",
  ["Italian"] = "意大利语", ["Turkish"] = "土耳其语", ["Arabic"] = "阿拉伯语",
  ["Vietnamese"] = "越南语", ["Indonesian"] = "印尼语", ["Thai"] = "泰语",
  ["Japanese"] = "日语", ["Korean"] = "韩语", ["Polish"] = "波兰语",
  ["Ukrainian"] = "乌克兰语", ["Persian"] = "波斯语", ["Hindi"] = "印地语",
  ["Simplified Chinese"] = "简体中文", ["Traditional Chinese"] = "繁体中文",
}

local busy = false
local alertId = nil

-- Timers that nothing references can be garbage-collected before they fire, so keep them here.
local pendingTimers = {}
local function later(seconds, fn)
  local t
  t = hs.timer.doAfter(seconds, function()
    pendingTimers[t] = nil
    fn()
  end)
  pendingTimers[t] = true
  return t
end

local function cancel(t)
  if t then t:stop() pendingTimers[t] = nil end
end

-- ---------------------------------------------------------------- helpers

-- Diagnostic log (last selections), see ~/Library/Logs/claude-replace.log
local LOG_FILE = HOME .. "/Library/Logs/claude-replace.log"
local DEBUG = false
local function log(msg)
  if not DEBUG then return end
  local f = io.open(LOG_FILE, "a")
  if f then f:write(os.date("%H:%M:%S ") .. msg .. "\n") f:close() end
end

local function short(s)
  if type(s) ~= "string" then return tostring(s) end
  return string.format("%q", s:sub(1, 40)) .. " (" .. #s .. "b)"
end


local function showAlert(text, seconds)
  if alertId then hs.alert.closeSpecific(alertId) end
  alertId = hs.alert.show(text, { textSize = 15, radius = 8 }, hs.screen.mainScreen(), seconds or 2)
end

local function closeAlert()
  if alertId then hs.alert.closeSpecific(alertId) alertId = nil end
end

local function readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- API key: config.lua `apiKey`, or (if `useClaudeCodeSettings = true`) the token Claude Code uses.
local function authToken()
  if CFG.apiKey and CFG.apiKey ~= "" then return CFG.apiKey end
  if CFG.useClaudeCodeSettings then
    local s = hs.json.read(CLAUDE_SETTINGS_FILE)
    local env = s and s.env or {}
    return env.ANTHROPIC_AUTH_TOKEN or env.ANTHROPIC_API_KEY
  end
  return nil
end

local function restoreClipboard(saved)
  if saved and next(saved) then hs.pasteboard.writeAllData(saved) end
end

-- Wait until the clipboard changes (up to `timeout` seconds).
local function waitForClipboardChange(marker, timeout)
  local waited = 0
  while waited < timeout do
    hs.timer.usleep(50000)
    waited = waited + 0.05
    if hs.pasteboard.changeCount() ~= marker then return true end
  end
  return false
end

-- Copy the current selection: ⌘C first; if the app ignores the synthetic key, use its Edit ▸ Copy menu.
local copyMethod = nil
-- Apps that ignore a synthetic ⌘C but copy fine from the menu (learned at runtime, remembered).
local menuCopyApps = hs.settings.get("claudeReplace.menuCopyApps") or { ["ru.keepcoder.Telegram"] = true }

local function menuCopy(app, pb)
  local marker = pb.changeCount()
  local ok = app:selectMenuItem({ "编辑", "拷贝" }) or app:selectMenuItem({ "Edit", "Copy" })
  if ok and waitForClipboardChange(marker, 0.45) then return pb.getContents() end
  return nil
end

local function copySelection()
  local pb = hs.pasteboard
  local app = hs.application.frontmostApplication()
  local bid = app and app:bundleID()
  if app and bid and menuCopyApps[bid] then
    local text = menuCopy(app, pb)
    if text then copyMethod = "menu" return text end
  end
  local marker = pb.changeCount()
  hs.eventtap.keyStroke({ "cmd" }, "c", 30000)
  if waitForClipboardChange(marker, 0.45) then copyMethod = "cmd-c" return pb.getContents() end
  if app and bid and not menuCopyApps[bid] then
    local text = menuCopy(app, pb)
    if text then
      menuCopyApps[bid] = true
      hs.settings.set("claudeReplace.menuCopyApps", menuCopyApps)
      copyMethod = "menu" return text
    end
  end
  copyMethod = "none"
  return nil
end

-- Copy the current selection. If selectAllIfEmpty, select the whole field when nothing is selected.
local function grabText(selectAllIfEmpty)
  local pb = hs.pasteboard
  local saved = pb.readAllData()
  local text = copySelection()
  local selectedAll = false
  if selectAllIfEmpty and (not text or text:match("^%s*$")) then
    hs.eventtap.keyStroke({ "cmd" }, "a", 30000)
    hs.timer.usleep(80000)
    text = copySelection()
    selectedAll = true
  end
  return text, saved, selectedAll
end

-- Call Claude; callback(resultText or nil, errorMessage or nil)
local function callClaude(system, content, callback)
  local token = authToken()
  if not token or not system then
    callback(nil, "读取配置失败：没有 API Key（请在 config.lua 里设置 apiKey），或缺少提示词文件")
    return
  end
  local body = hs.json.encode({
    model = MODEL,
    max_tokens = 2048,
    system = system,
    messages = { { role = "user", content = content } },
  })
  local headers = {
    ["content-type"] = "application/json",
    ["x-api-key"] = token,
    ["anthropic-version"] = "2023-06-01",
  }
  local finished = false
  local watchdog = later(TIMEOUT, function()
    if finished then return end
    finished = true
    callback(nil, "超时了：Claude 没有响应，请检查网络或 config.lua 里的 endpoint")
  end)
  hs.http.asyncPost(ENDPOINT, body, headers, function(status, respBody)
    if finished then return end
    finished = true
    cancel(watchdog)
    if status == 200 then
      local ok, data = pcall(hs.json.decode, respBody)
      if ok and data and data.content then
        local parts = {}
        for _, block in ipairs(data.content) do
          if block.type == "text" and block.text then table.insert(parts, block.text) end
        end
        local result = table.concat(parts):gsub("^%s+", ""):gsub("%s+$", "")
        if result ~= "" then callback(result, nil) return end
      end
    end
    callback(nil, "出错了（" .. tostring(status) .. "）：" .. tostring(respBody or ""):sub(1, 160))
  end)
end

-- ---------------------------------------------------------------- popup

local popup = nil
local popupText = ""
local escKey = nil

local function htmlEscape(s)
  return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function closePopup()
  if popup then popup:delete() popup = nil end
  if escKey then escKey:delete() escKey = nil end
end

local function popupHTML(title, body, isText)
  local dark = hs.host.interfaceStyle() == "Dark"
  local bg, fg, sub, btn = "#ffffff", "#1d1d1f", "#86868b", "#f2f2f7"
  if dark then bg, fg, sub, btn = "#2c2c2e", "#f5f5f7", "#98989d", "#3a3a3c" end
  local copyBtn = isText and
    '<button onclick="window.webkit.messageHandlers.cr.postMessage(\'copy\')">复制</button>' or ""
  return [[<!doctype html><html><head><meta charset="utf-8"><style>
  html,body{margin:0;background:]] .. bg .. [[;color:]] .. fg .. [[;
    font:14px/1.6 -apple-system,"PingFang SC",sans-serif;}
  .bar{display:flex;align-items:center;justify-content:space-between;padding:8px 12px;
    color:]] .. sub .. [[;font-size:12px;border-bottom:1px solid ]] .. btn .. [[;-webkit-user-select:none}
  .bar span{flex:1}
  button{background:]] .. btn .. [[;color:]] .. fg .. [[;border:0;border-radius:6px;padding:3px 10px;
    margin-left:6px;font-size:12px;cursor:pointer}
  .body{padding:10px 14px 14px;white-space:pre-wrap;word-wrap:break-word;-webkit-user-select:text}
  </style></head><body>
  <div class="bar"><span>]] .. htmlEscape(title) .. [[</span>]] .. copyBtn ..
  [[<button onclick="window.webkit.messageHandlers.cr.postMessage('close')">×</button></div>
  <div class="body">]] .. htmlEscape(body) .. [[</div></body></html>]]
end

local function showPopup(title, body, isText)
  local text = body
  if not popup then
    local uc = hs.webview.usercontent.new("cr")
    uc:setCallback(function(msg)
      if msg.body == "copy" and popup then
        hs.pasteboard.setContents(popupText)
        showAlert("已复制", 1)
      elseif msg.body == "close" then
        closePopup()
      end
    end)
    local mouse = hs.mouse.absolutePosition()
    local frame = hs.mouse.getCurrentScreen():frame()
    local w, h = 440, 260
    local x = math.min(math.max(mouse.x + 12, frame.x + 10), frame.x + frame.w - w - 10)
    local y = math.min(math.max(mouse.y + 18, frame.y + 10), frame.y + frame.h - h - 10)
    popup = hs.webview.new({ x = x, y = y, w = w, h = h }, { developerExtrasEnabled = false }, uc)
      :windowStyle({ "titled", "closable", "resizable", "utility", "nonactivating" })
      :level(hs.drawing.windowLevels.floating)
      :allowTextEntry(true)
      :shadow(true)
      :closeOnEscape(true)
      :windowTitle("Claude 翻译")
      :deleteOnClose(true)
      :windowCallback(function(action)
        if action == "closing" then
          popup = nil
          if escKey then escKey:delete() escKey = nil end
        end
      end)
    escKey = hs.hotkey.bind({}, "escape", closePopup)
  end
  popupText = text
  popup:html(popupHTML(title, body, isText))
  popup:show()
end

-- ---------------------------------------------------------------- write: translate & replace

local function run(targetLanguage)
  if busy then showAlert("上一条还在处理中…") return end
  local app = hs.application.frontmostApplication()
  local text, saved, selectedAll = grabText(true)
  log("run target=" .. tostring(targetLanguage) .. " app=" .. tostring(app and app:bundleID()) .. " copy=" .. tostring(copyMethod) .. " text=" .. short(text))
  if not text or text:match("^%s*$") then
    restoreClipboard(saved)
    showAlert("没有找到文字：请先把光标放在输入框里，或选中要处理的文字")
    return
  end
  if #text > 8000 then
    restoreClipboard(saved)
    showAlert("选中的文字太长（可能连邮件历史也选上了），请只选中你要发的那段")
    return
  end

  local tpl = readFile(PROMPT_FILE)
  local task
  if targetLanguage then
    task = "Translate and polish the draft into " .. targetLanguage ..
      ". If the draft is already in " .. targetLanguage .. ", just polish it."
  else
    task = "Polish the draft in the same language it is written in. Do not translate it."
  end
  local system = tpl and tpl:gsub("{{TASK}}", function() return task end)

  busy = true
  local label = targetLanguage and ("翻译润色 → " .. (LANG_ZH[targetLanguage] or targetLanguage)) or "润色中"
  showAlert("⏳ " .. label .. "…", TIMEOUT)

  callClaude(system, text, function(result, err)
    busy = false
    if not result then
      restoreClipboard(saved)
      showAlert(err, 5)
      return
    end
    local front = hs.application.frontmostApplication()
    hs.pasteboard.setContents(result)
    if not app or not front or front:bundleID() ~= app:bundleID() then
      showAlert("你已切换到别的窗口，结果已复制到剪贴板，⌘V 粘贴即可", 4)
      return
    end
    if selectedAll then
      hs.eventtap.keyStroke({ "cmd" }, "a", 0)
      hs.timer.usleep(60000)
    end
    hs.eventtap.keyStroke({ "cmd" }, "v", 0)
    log("run pasted result=" .. short(result))
    later(0.6, function() restoreClipboard(saved) end)
    showAlert("✅ 已替换（⌘Z 撤销）", 1.5)
  end)
end

-- ---------------------------------------------------------------- read: translate selection / screenshot

local readSeq = 0

local function readText(text)
  if #text > 20000 then text = text:sub(1, 20000) end
  readSeq = readSeq + 1
  local mySeq = readSeq
  showPopup("翻译中…", text, false)
  callClaude(readFile(READ_PROMPT_FILE), text, function(result, err)
    if not popup or mySeq ~= readSeq then return end
    if result then showPopup("译文", result, true) else showPopup("出错了", err, false) end
  end)
end

local function readSelection()
  local text, saved = grabText(false)
  restoreClipboard(saved)
  if not text or text:match("^%s*$") then
    showAlert("请先选中要翻译的文字")
    return
  end
  readText(text)
end

-- ---------------------------------------------------------------- auto icon after selecting text

local autoIconEnabled = hs.settings.get("claudeReplace.autoIcon")
if autoIconEnabled == nil then autoIconEnabled = true end

local icon = nil
local iconText = nil
local iconTimer = nil
local mouseDownPos = nil
local mouseTap = nil

local function hideIcon()
  cancel(iconTimer) iconTimer = nil
  if icon then icon:delete() icon = nil end
  iconText = nil
end

local function pointIn(p, f)
  return f and p.x >= f.x and p.x <= f.x + f.w and p.y >= f.y and p.y <= f.y + f.h
end

-- Read the selected text via Accessibility; fall back to a silent ⌘C that restores the clipboard.
local function selectedText()
  local ok, el = pcall(function()
    return hs.axuielement.systemWideElement():attributeValue("AXFocusedUIElement")
  end)
  local role = ok and el and el:attributeValue("AXRole") or "none"
  if ok and el then
    local ok2, sel = pcall(function() return el:attributeValue("AXSelectedText") end)
    log("  ax focused role=" .. tostring(role) .. " selectedText=" .. short(ok2 and sel or "ERR"))
    if ok2 and type(sel) == "string" and not sel:match("^%s*$") then return sel end
  else
    log("  ax focused element: none")
  end
  local text, saved = grabText(false)
  restoreClipboard(saved)
  log("  copy via " .. tostring(copyMethod) .. " text=" .. short(text))
  return text
end

local function worthTranslating(text)
  if not text then return false end
  local t = text:gsub("^%s+", ""):gsub("%s+$", "")
  if utf8.len(t) == nil or utf8.len(t) < 2 or #t > 20000 then return false end
  -- only numbers / IPs / punctuation → skip
  if not t:find("%a") and not t:find("[\128-\255]") then return false end
  -- skip URLs and emails
  if t:match("^%S+://%S+$") or t:match("^[%w%._%-]+@[%w%.%-]+$") then return false end
  -- mostly Chinese → skip (you can still press ⌃⌥R)
  local cjk, total = 0, 0
  for _, cp in utf8.codes(t) do
    if cp > 32 then
      total = total + 1
      if cp >= 0x4E00 and cp <= 0x9FFF then cjk = cjk + 1 end
    end
  end
  return total > 0 and cjk / total < 0.3
end

local function showIcon(text, pos)
  hideIcon()
  iconText = text
  local size = 26
  icon = hs.canvas.new({ x = pos.x + 10, y = pos.y + 10, w = size, h = size })
  icon:level(hs.canvas.windowLevels.popUpMenu)
  icon:appendElements(
    { type = "rectangle", action = "fill", roundedRectRadii = { xRadius = 7, yRadius = 7 },
      fillColor = { red = 0.85, green = 0.47, blue = 0.34, alpha = 0.95 },
      trackMouseEnterExit = true, trackMouseDown = true, id = "bg" },
    { type = "text", text = "译", textColor = { white = 1 }, textSize = 15,
      textAlignment = "center", frame = { x = 0, y = 3, w = size, h = size } }
  )
  icon:mouseCallback(function(_, message)
    if message == "mouseEnter" or message == "mouseDown" then
      local t = iconText
      hideIcon()
      if t then readText(t) end
    end
  end)
  icon:show()
  iconTimer = later(4, hideIcon)
end

local function onMouseUp(e)
  local up = hs.mouse.absolutePosition()
  local down = mouseDownPos
  local clicks = e:getProperty(hs.eventtap.event.properties.mouseEventClickState) or 1
  local dragged = down and (math.abs(up.x - down.x) + math.abs(up.y - down.y) > 8)
  if not dragged and clicks < 2 then return end
  local front = hs.application.frontmostApplication()
  local bid = front and front:bundleID() or "?"
  log(string.format("mouseUp app=%s dragged=%s clicks=%d", bid, tostring(dragged), clicks))
  if bid == "org.hammerspoon.Hammerspoon" then return end
  later(0.15, function()
    local text = selectedText()
    local worth = worthTranslating(text)
    log("  worth=" .. tostring(worth))
    if worth then showIcon(text, up) end
  end)
end

-- Control+Shift pressed together and released on their own (no other key) → English replace.
local chordArmed, chordStart = false, 0
local function onFlagsChanged(e)
  local f = e:getFlags()
  local onlyCtrlShift = f.ctrl and f.shift and not f.cmd and not f.alt and not f.fn
  local none = not (f.ctrl or f.shift or f.cmd or f.alt or f.fn)
  if onlyCtrlShift then
    if not chordArmed then chordArmed, chordStart = true, hs.timer.secondsSinceEpoch() end
  elseif none then
    if chordArmed and hs.timer.secondsSinceEpoch() - chordStart < 1.0 then
      log("chord ctrl+shift fired")
      later(0.05, function() run("English") end)
    end
    chordArmed = false
  elseif not (f.ctrl or f.shift) or f.cmd or f.alt or f.fn then
    chordArmed = false
  end
end

local function startAutoIcon()
  if mouseTap then mouseTap:stop() end
  mouseTap = hs.eventtap.new(
    { hs.eventtap.event.types.leftMouseDown, hs.eventtap.event.types.leftMouseUp,
      hs.eventtap.event.types.keyDown, hs.eventtap.event.types.mouseMoved,
      hs.eventtap.event.types.flagsChanged },
    function(e)
      local t = e:getType()
      if t == hs.eventtap.event.types.flagsChanged then
        onFlagsChanged(e)
        return false
      end
      if t ~= hs.eventtap.event.types.mouseMoved then chordArmed = false end
      if t == hs.eventtap.event.types.leftMouseDown then
        local p = hs.mouse.absolutePosition()
        mouseDownPos = p
        if icon and not pointIn(p, icon:frame()) then hideIcon() end
        if popup and not pointIn(p, popup:frame()) then closePopup() end
      elseif t == hs.eventtap.event.types.leftMouseUp then
        if autoIconEnabled then onMouseUp(e) end
      elseif t == hs.eventtap.event.types.keyDown then
        if icon then hideIcon() end
      elseif t == hs.eventtap.event.types.mouseMoved then
        if icon and iconText and pointIn(hs.mouse.absolutePosition(), icon:frame()) then
          local text = iconText
          hideIcon()
          later(0, function() readText(text) end)
        end
      end
      return false
    end)
  mouseTap:start()
end

local function toggleAutoIcon()
  autoIconEnabled = not autoIconEnabled
  hs.settings.set("claudeReplace.autoIcon", autoIconEnabled)
  if not autoIconEnabled then hideIcon() end
  showAlert(autoIconEnabled and "划词图标：已开启" or "划词图标：已关闭（⌃⌥R 仍可用）", 1.5)
end

local function readScreenshot()
  local path = os.tmpname() .. ".png"
  hs.task.new("/usr/sbin/screencapture", function(code)
    local f = io.open(path, "rb")
    if not f then return end -- user pressed Esc
    local data = f:read("*a")
    f:close()
    os.remove(path)
    if not data or #data == 0 then return end
    showPopup("识别翻译中…", "（截图已发送给 Claude）", false)
    local content = {
      { type = "image", source = { type = "base64", media_type = "image/png", data = hs.base64.encode(data) } },
      { type = "text", text = "Translate the text in this screenshot." },
    }
    callClaude(readFile(READ_PROMPT_FILE), content, function(result, err)
      if not popup then return end
      if result then showPopup("截图译文", result, true) else showPopup("出错了", err, false) end
    end)
  end, { "-i", "-x", path }):start()
end

-- ---------------------------------------------------------------- hotkeys

local lastLanguage = hs.settings.get("claudeReplace.lastLanguage") or "Spanish"

local activeChooser = nil
local function chooseLanguage()
  local chooser = hs.chooser.new(function(choice)
    if not choice then return end
    lastLanguage = choice.lang
    hs.settings.set("claudeReplace.lastLanguage", lastLanguage)
    later(0.15, function() run(lastLanguage) end)
  end)
  local choices = {}
  for _, lang in ipairs(LANGUAGES) do
    table.insert(choices, { text = LANG_ZH[lang] .. "  " .. lang, lang = lang })
  end
  chooser:choices(choices)
  chooser:placeholderText("翻译润色成哪种语言？（可输入搜索）")
  activeChooser = chooser
  chooser:show()
end

function M.start()
  -- load extensions up front so nothing gets lazily loaded inside event callbacks
  local _ = { hs.canvas, hs.axuielement, hs.mouse, hs.eventtap, hs.window, hs.webview, hs.webview.usercontent, hs.drawing, hs.styledtext, hs.settings, hs.alert, hs.timer, hs.hotkey,
    hs.pasteboard, hs.http, hs.json, hs.chooser, hs.task, hs.base64, hs.host, hs.screen, hs.application }
  hs.hotkey.bind({ "ctrl", "alt" }, "L", chooseLanguage)
  hs.hotkey.bind({ "ctrl", "alt" }, "K", function() run(lastLanguage) end)
  hs.hotkey.bind({ "ctrl", "alt" }, "P", function() run(nil) end)
  hs.hotkey.bind({ "ctrl", "alt" }, "R", readSelection)
  hs.hotkey.bind({ "ctrl", "alt" }, "S", readScreenshot)
  hs.hotkey.bind({ "ctrl", "alt" }, "T", toggleAutoIcon)
  startAutoIcon()
end

-- keep the event tap alive if macOS disables it
M.watchdog = hs.timer.doEvery(30, function()
  if mouseTap and not mouseTap:isEnabled() then mouseTap:start() end
end)

M.run = run
M.readSelection = readSelection
M.showPopup = showPopup
M.closePopup = closePopup
M.callClaude = callClaude

M.paths = function() return { dir = DIR, write = PROMPT_FILE, read = READ_PROMPT_FILE, endpoint = ENDPOINT, model = MODEL, hasKey = authToken() ~= nil } end

M.debugState = function()
  return { icon = icon ~= nil, iconFrame = icon and icon:frame(), iconText = iconText, popup = popup ~= nil, popupFrame = popup and popup:frame(), popupVisible = popup and popup:isVisible(), tap = mouseTap and mouseTap:isEnabled(), auto = autoIconEnabled }
end

return M
