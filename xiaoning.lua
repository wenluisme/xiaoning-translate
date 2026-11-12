-- XiaoNing Translate (小宁翻译) for macOS — runs in Hammerspoon.
--
-- Select text with the mouse → a toolbar pops up next to it → click a button.
--   In someone else's message (read-only): Translate · Copy · More
--   In your own input box: Translate · To English · To <last language> · Other languages · Polish · Copy
-- ⌃⌥S screenshot translation; ⌃⌥T toggles the toolbar.
-- UI text is in Chinese on purpose (the tool is built for a Chinese-speaking support team).

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
local MODEL_WRITE = CFG.model or CFG.writeModel or "claude-sonnet-5-5"
local MODEL_READ = CFG.readModel or MODEL_WRITE
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


local ALERT_STYLE = {
  textSize = 14,
  radius = 10,
  fillColor = { red = 0.86, green = 0.47, blue = 0.34, alpha = 0.93 },
  textColor = { white = 1 },
  strokeColor = { alpha = 0 },
  atScreenEdge = 0,
}
local function showAlert(text, seconds)
  if alertId then hs.alert.closeSpecific(alertId) end
  alertId = hs.alert.show(text, ALERT_STYLE, hs.screen.mainScreen(), seconds or 2)
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

-- Sonnet/Opus 5.x think before answering by default; for plain translation that only adds delay.
-- "between_tools" skips thinking when no tools are involved (≈1.5–2 s faster to the first word).
local function requestBody(system, content, stream, model)
  local body = {
    model = model or MODEL_WRITE,
    max_tokens = 2048,
    system = system,
    messages = { { role = "user", content = content } },
    stream = stream or nil,
  }
  local thinking = CFG.thinking
  if thinking == nil and (body.model:find("sonnet") or body.model:find("opus")) then thinking = "between_tools" end
  if thinking and thinking ~= "default" then body.thinking = { type = thinking } end
  return hs.json.encode(body)
end

local function missingConfigError()
  return "读取配置失败：没有 API Key（请在 config.lua 里设置 apiKey），或缺少提示词文件"
end

-- Non-streaming call; callback(resultText or nil, errorMessage or nil). Used for screenshots.
local function callClaude(system, content, callback)
  local token = authToken()
  if not token or not system then callback(nil, missingConfigError()) return end
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
  hs.http.asyncPost(ENDPOINT, requestBody(system, content, false, MODEL_READ), headers, function(status, respBody)
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

-- Streaming call through curl; onDelta(fullTextSoFar), onDone(text or nil, err or nil).
-- Returns a handle with :cancel().
local liveTasks = {}
local function streamClaude(system, content, onDelta, onDone, model)
  local token = authToken()
  if not token or not system then onDone(nil, missingConfigError()) return { cancel = function() end } end
  local buffer, text, finished, raw = "", "", false, ""
  local function finish(result, err)
    if finished then return end
    finished = true
    log("  stream done ok=" .. tostring(result ~= nil) .. " err=" .. tostring(err))
    onDone(result, err)
  end
  local bodyFile = os.tmpname()
  local bf = io.open(bodyFile, "w")
  bf:write(requestBody(system, content, true, model))
  bf:close()
  local task
  task = hs.task.new("/usr/bin/curl", function(code, stdout, stderr)
    liveTasks[task] = nil
    os.remove(bodyFile)
    if finished then return end
    local t = text:gsub("^%s+", ""):gsub("%s+$", "")
    if t ~= "" then finish(t, nil) return end
    local msg = raw:match('"message"%s*:%s*"([^"]+)"') or (stderr ~= "" and stderr) or raw
    finish(nil, "出错了（curl " .. tostring(code) .. "）：" .. tostring(msg):sub(1, 160))
  end, function(_, stdout, _)
    if finished then return false end
    raw = (raw .. (stdout or "")):sub(-2000)
    buffer = buffer .. (stdout or "")
    while true do
      local nl = buffer:find("\n", 1, true)
      if not nl then break end
      local line = buffer:sub(1, nl - 1)
      buffer = buffer:sub(nl + 1)
      local data = line:match("^data:%s*(.*)$")
      if data and data ~= "" then
        local ok, ev = pcall(hs.json.decode, data)
        if ok and ev then
          if ev.type == "content_block_delta" and ev.delta and ev.delta.type == "text_delta" then
            text = text .. (ev.delta.text or "")
            onDelta(text)
          elseif ev.type == "error" then
            finish(nil, "出错了：" .. tostring(ev.error and ev.error.message or data):sub(1, 160))
          end
        end
      end
    end
    return true
  end, {
    "-sS", "-N", "--max-time", tostring(TIMEOUT), ENDPOINT,
    "-H", "content-type: application/json",
    "-H", "x-api-key: " .. token,
    "-H", "anthropic-version: 2023-06-01",
    "--data-binary", "@" .. bodyFile,
  })
  liveTasks[task] = true
  task:start()
  return { cancel = function()
    log("  stream cancelled")
    finished = true
    if task:isRunning() then task:terminate() end
    liveTasks[task] = nil
    os.remove(bodyFile)
  end }
end

-- Requests keyed by action+text, so a request started on hover is reused when you click.
local requests = {}

local function request(key, system, content, model)
  local r = requests[key]
  if r then return r end
  r = { text = "", done = false, err = nil, listeners = {} }
  requests[key] = r
  r.handle = streamClaude(system, content,
    function(t)
      r.text = t
      for _, l in ipairs(r.listeners) do if l.onDelta then l.onDelta(t) end end
    end,
    function(t, err)
      r.done, r.err = true, err
      if t then r.text = t end
      for _, l in ipairs(r.listeners) do l.onDone(t, err) end
      r.listeners = {}
    end, model)
  return r
end

local function listen(r, onDelta, onDone)
  if r.done then onDone(r.err and nil or r.text, r.err) return end
  if onDelta and r.text ~= "" then onDelta(r.text) end
  table.insert(r.listeners, { onDelta = onDelta, onDone = onDone })
end

-- Cancel unfinished requests that nobody is waiting for (except keepKey).
local function dropRequests(keepKey)
  for k, r in pairs(requests) do
    if k ~= keepKey and (r.done or #r.listeners == 0) then
      if not r.done and r.handle then r.handle.cancel() end
      requests[k] = nil
    end
  end
end

-- ---------------------------------------------------------------- popup (translation card)

local APP_NAME = "小宁翻译"

-- Claude-style palette
local function palette()
  if hs.host.interfaceStyle() == "Dark" then
    return { bg = "#262624", fg = "#FAF9F5", muted = "#A6A39A", border = "#3D3D3A",
             hover = "#30302E", accent = "#D97757", accentSoft = "rgba(217,119,87,.16)" }
  end
  return { bg = "#FAF9F5", fg = "#141413", muted = "#87867F", border = "#E8E6DC",
           hover = "#F0EEE6", accent = "#C96442", accentSoft = "rgba(201,100,66,.10)" }
end

local popup = nil
local popupText = ""
local popupPinned = false
local escKey = nil
local POPUP_W = 440
local MARGIN = 14 -- transparent margin around the card so its shadow is visible

local function htmlEscape(s)
  return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function closePopup()
  if popup then popup:delete() popup = nil end
  if escKey then escKey:delete() escKey = nil end
  popupPinned = false
end

local ICON_PIN = [[<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 17v5"/><path d="M9 3h6l-1 6 3 3v2H7v-2l3-3z"/></svg>]]
local ICON_COPY = [[<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V6a2 2 0 0 1 2-2h9"/></svg>]]
local ICON_CLOSE = [[<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M6 6l12 12M18 6L6 18"/></svg>]]
local ICON_SPARK = [[<svg viewBox="0 0 24 24" width="16" height="16"><path fill="currentColor" d="M12 2l1.9 6.1L20 10l-6.1 1.9L12 18l-1.9-6.1L4 10l6.1-1.9z"/></svg>]]

local function popupHTML()
  local c = palette()
  return [[<!doctype html><html><head><meta charset="utf-8"><style>
  html,body{margin:0;background:transparent;-webkit-user-select:none;cursor:default}
  .card{margin:]] .. MARGIN .. [[px;background:]] .. c.bg .. [[;color:]] .. c.fg .. [[;
    border:1px solid ]] .. c.border .. [[;border-radius:14px;overflow:hidden;
    box-shadow:0 8px 28px rgba(0,0,0,.14),0 1px 3px rgba(0,0,0,.08);
    font:14px/1.65 -apple-system,"PingFang SC","Helvetica Neue",sans-serif}
  .head{display:flex;align-items:center;gap:6px;padding:9px 10px 9px 14px;cursor:grab}
  .logo{color:]] .. c.accent .. [[;display:flex}
  .name{font-weight:600;font-size:13px;letter-spacing:.2px}
  .status{font-size:12px;color:]] .. c.muted .. [[;margin-left:4px;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .dot{display:inline-block;width:6px;height:6px;border-radius:50%;background:]] .. c.accent .. [[;
    margin-right:6px;vertical-align:middle;animation:p 1s ease-in-out infinite}
  @keyframes p{0%,100%{opacity:.25}50%{opacity:1}}
  .btn{width:28px;height:28px;border-radius:8px;border:0;background:transparent;color:]] .. c.muted .. [[;
    display:flex;align-items:center;justify-content:center;cursor:pointer;padding:0}
  .btn:hover{background:]] .. c.hover .. [[;color:]] .. c.fg .. [[}
  .btn.on{color:]] .. c.accent .. [[;background:]] .. c.accentSoft .. [[}
  .src{margin:0 14px;padding:8px 10px;border-radius:8px;background:]] .. c.hover .. [[;color:]] .. c.muted .. [[;
    font-size:12.5px;line-height:1.5;max-height:58px;overflow:hidden;white-space:pre-wrap;word-wrap:break-word;
    -webkit-user-select:text;cursor:text}
  .src:empty{display:none}
  .body{padding:10px 16px 16px;white-space:pre-wrap;word-wrap:break-word;-webkit-user-select:text;cursor:text;
    max-height:420px;overflow-y:auto}
  .err{color:]] .. c.accent .. [[}
  </style></head><body><div class="card" id="card">
  <div class="head" id="head">
    <span class="logo">]] .. ICON_SPARK .. [[</span><span class="name">]] .. APP_NAME .. [[</span>
    <span class="status" id="status"></span>
    <button class="btn" id="pin" title="固定：点别处不关闭，下次翻译直接显示在这里">]] .. ICON_PIN .. [[</button>
    <button class="btn" id="copy" title="复制译文">]] .. ICON_COPY .. [[</button>
    <button class="btn" id="close" title="关闭">]] .. ICON_CLOSE .. [[</button>
  </div>
  <div class="src" id="src"></div>
  <div class="body" id="b"></div>
  </div><script>
  const post=m=>window.webkit.messageHandlers.cr.postMessage(m);
  document.getElementById('pin').onclick=()=>post('pin');
  document.getElementById('copy').onclick=()=>post('copy');
  document.getElementById('close').onclick=()=>post('close');
  document.getElementById('head').addEventListener('mousedown',e=>{ if(!e.target.closest('.btn')) post('drag'); });
  function size(){ post('h:'+Math.ceil(document.getElementById('card').getBoundingClientRect().height)); }
  function setBody(t){ const b=document.getElementById('b'); b.classList.remove('err'); b.textContent=t; size(); }
  function setErr(t){ const b=document.getElementById('b'); b.classList.add('err'); b.textContent=t; size(); }
  function setSrc(t){ document.getElementById('src').textContent=t; size(); }
  function setStatus(t,busy){ document.getElementById('status').innerHTML=(busy?'<span class="dot"></span>':'')+t; }
  function setPinned(on){ document.getElementById('pin').classList.toggle('on',on); }
  size();
  </script></body></html>]]
end

local function js(fn, ...)
  if not popup then return end
  local args = {}
  for i, v in ipairs({ ... }) do args[i] = hs.json.encode({ v }) .. "[0]" end
  popup:evaluateJavaScript(fn .. "(" .. table.concat(args, ",") .. ")")
end

-- dragging the card by its header
local dragging = nil
local function startDrag()
  if not popup then return end
  local m, f = hs.mouse.absolutePosition(), popup:frame()
  dragging = { dx = m.x - f.x, dy = m.y - f.y }
end

local function setPinned(on)
  popupPinned = on
  js("setPinned", on)
  if on then
    if escKey then escKey:delete() escKey = nil end -- don't steal Esc from other apps while pinned
  elseif not escKey then
    escKey = hs.hotkey.bind({}, "escape", closePopup)
  end
end

local popupReady = false
local pendingCalls = {}

local function ensurePopup()
  if popup then return end
  popupReady = false
  pendingCalls = {}
  local uc = hs.webview.usercontent.new("cr")
  uc:setCallback(function(msg)
    local b = msg.body
    if b == "copy" then
      if popupText ~= "" then hs.pasteboard.setContents(popupText) showAlert("已复制", 1) end
    elseif b == "close" then closePopup()
    elseif b == "pin" then setPinned(not popupPinned)
    elseif b == "drag" then startDrag()
    elseif type(b) == "string" and b:sub(1, 2) == "h:" and popup then
      local h = tonumber(b:sub(3)) or 200
      local f = popup:frame()
      f.h = math.min(h + MARGIN * 2, 560)
      popup:frame(f)
      if not popupReady then
        popupReady = true
        for _, call in ipairs(pendingCalls) do call() end
        pendingCalls = {}
      end
    end
  end)
  local mouse = hs.mouse.absolutePosition()
  local screen = hs.mouse.getCurrentScreen():frame()
  local w, h = POPUP_W + MARGIN * 2, 200
  local x = math.min(math.max(mouse.x - MARGIN, screen.x + 4), screen.x + screen.w - w - 4)
  local y = math.min(math.max(mouse.y + 16 - MARGIN, screen.y + 4), screen.y + screen.h - 300)
  popup = hs.webview.new({ x = x, y = y, w = w, h = h }, { developerExtrasEnabled = false }, uc)
    :windowStyle({ "borderless", "nonactivating" })
    :transparent(true)
    :level(hs.drawing.windowLevels.floating)
    :allowTextEntry(true)
    :shadow(false)
    :deleteOnClose(true)
    :windowCallback(function(action)
      if action == "closing" then
        popup = nil
        if escKey then escKey:delete() escKey = nil end
      end
    end)
  popup:html(popupHTML())
  popup:show()
  setPinned(false)
end

-- run fn once the page has loaded (first size message)
local function whenReady(fn)
  if popupReady then fn() else table.insert(pendingCalls, fn) end
end

-- status: text in the header; busy: show the pulsing dot
local function showPopup(status, body, isText, busy, source)
  ensurePopup()
  popupText = isText and body or ""
  whenReady(function()
    js("setStatus", status or "", busy and true or false)
    if source ~= nil then js("setSrc", source) end
    if isText or busy then js("setBody", body or "") else js("setErr", body or "") end
    js("setPinned", popupPinned)
  end)
  popup:show()
end

-- Update the popup body in place while text streams in (no reload, no flicker).
local function popupStream(text)
  if not popup then return end
  popupText = text
  whenReady(function() js("setBody", text) end)
end

-- ---------------------------------------------------------------- write: translate & replace

local function writeSystem(targetLanguage)
  local tpl = readFile(PROMPT_FILE)
  local task
  if targetLanguage then
    task = "Translate and polish the draft into " .. targetLanguage ..
      ". If the draft is already in " .. targetLanguage .. ", just polish it."
  else
    task = "Polish the draft in the same language it is written in. Do not translate it."
  end
  return tpl and tpl:gsub("{{TASK}}", function() return task end)
end

local function writeKey(targetLanguage, text)
  return "write:" .. tostring(targetLanguage) .. ":" .. text
end

local function paste(app)
  local bid = app and app:bundleID()
  if bid and menuCopyApps[bid] then
    -- apps that ignore a synthetic ⌘C usually ignore ⌘V too
    if app:selectMenuItem({ "编辑", "粘贴" }) or app:selectMenuItem({ "Edit", "Paste" }) then return end
  end
  hs.eventtap.keyStroke({ "cmd" }, "v", 0)
end

-- preset = { text = ..., editable = true|false|nil } when called from the selection toolbar.
local function run(targetLanguage, preset)
  if busy then showAlert("上一条还在处理中…") return end
  local app = hs.application.frontmostApplication()
  local text, saved, selectedAll
  if preset then
    text, saved, selectedAll = preset.text, hs.pasteboard.readAllData(), false
  else
    text, saved, selectedAll = grabText(true)
  end
  log("run target=" .. tostring(targetLanguage) .. " app=" .. tostring(app and app:bundleID()) .. " text=" .. short(text))
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

  busy = true
  local label = targetLanguage and ("翻译润色 → " .. (LANG_ZH[targetLanguage] or targetLanguage)) or "润色中"
  local key = writeKey(targetLanguage, text)
  local r = request(key, writeSystem(targetLanguage), text)
  if not r.done then showAlert("⏳ " .. label .. "…", TIMEOUT) end

  listen(r, nil, function(result, err)
    log("run got result=" .. short(result) .. " err=" .. tostring(err))
    busy = false
    requests[key] = nil
    closeAlert()
    if not result then
      restoreClipboard(saved)
      showAlert(err or "出错了", 5)
      return
    end
    -- selection that can't be edited (e.g. a customer's message): just show the result
    if preset and preset.editable == false then
      showPopup("结果", result, true, false)
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
    paste(app)
    log("run pasted result=" .. short(result))
    later(0.6, function() restoreClipboard(saved) end)
    showAlert("✅ 已替换（⌘Z 撤销）", 1.2)
  end)
end

-- ---------------------------------------------------------------- read: translate selection / screenshot

local readSeq = 0

local function readKey(text) return "read:" .. text end

local function readText(text)
  if #text > 20000 then text = text:sub(1, 20000) end
  readSeq = readSeq + 1
  local mySeq = readSeq
  local key = readKey(text)
  local r = request(key, readFile(READ_PROMPT_FILE), text, MODEL_READ)
  showPopup(r.done and "译文" or "翻译中…", r.text, r.done, not r.done, nil)
  listen(r,
    function(t)
      if popup and mySeq == readSeq then
        popupStream(t)
        js("setStatus", "翻译中…", true)
      end
    end,
    function(result, err)
      requests[key] = nil
      if not popup or mySeq ~= readSeq then return end
      if result then
        showPopup("译文", result, true, false, nil)
      else
        js("setStatus", "出错了", false)
        js("setErr", err or "出错了")
      end
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

-- ---------------------------------------------------------------- selection toolbar

local toolbarEnabled = hs.settings.get("claudeReplace.autoIcon")
if toolbarEnabled == nil then toolbarEnabled = true end

local lastLanguage = hs.settings.get("claudeReplace.lastLanguage") or "Spanish"

local toolbar = nil
local toolbarSel = nil
local toolbarTimer = nil
local toolbarButtons = {}
local mouseDownPos = nil
local mouseTap = nil

local function hideToolbar(keepKey)
  cancel(toolbarTimer) toolbarTimer = nil
  if toolbar then toolbar:delete() toolbar = nil end
  toolbarSel = nil
  dropRequests(keepKey)
end

local function pointIn(p, f)
  return f and p.x >= f.x and p.x <= f.x + f.w and p.y >= f.y and p.y <= f.y + f.h
end

local EDITABLE_ROLES = { AXTextField = true, AXTextArea = true, AXComboBox = true, AXSearchField = true }

-- Is the text under the mouse inside an input box? true / false / nil (app exposes nothing).
local axPrimed = {}
local function editableAt(pos)
  local app = hs.application.frontmostApplication()
  if not app then return nil end
  local ax = hs.axuielement.applicationElement(app)
  if ax and not axPrimed[app:pid()] then
    -- Chromium/Electron apps only build their accessibility tree when asked
    axPrimed[app:pid()] = true
    pcall(function() ax:setAttributeValue("AXManualAccessibility", true) end)
  end
  local ok, el = pcall(function() return ax:elementAtPosition(pos.x, pos.y) end)
  if not ok or not el then return nil end
  local depth = 0
  while el and depth < 8 do
    local role = el:attributeValue("AXRole")
    if EDITABLE_ROLES[role] then return true end
    if role == "AXWebArea" or role == "AXWindow" or role == "AXApplication" then return false end
    el = el:attributeValue("AXParent")
    depth = depth + 1
  end
  return false
end

-- Returns the selected text and whether it can be edited (true / false).
-- Reads via Accessibility when possible; otherwise a silent copy that restores the clipboard.
local function isEditableElement(el)
  if not el then return false end
  local role = el:attributeValue("AXRole")
  if EDITABLE_ROLES[role] then return true end
  local settable = false
  pcall(function() settable = el:isAttributeSettable("AXValue") end)
  return settable and role ~= "AXStaticText" and role ~= "AXWebArea"
end

local function inFrame(p, f, pad)
  pad = pad or 0
  return p and f and f.w and p.x >= f.x - pad and p.x <= f.x + f.w + pad and p.y >= f.y - pad and p.y <= f.y + f.h + pad
end

-- Returns the selected text and whether it sits in an input box (true / false).
-- An input box counts if any of these hold:
--   · the element under the mouse-up or mouse-down point is an input box
--   · the keyboard-focused element is an input box and has this text selected
--   · the keyboard-focused input box (±12px) contains the mouse-up or mouse-down point
-- Chat composers are often one line tall, so the release point easily lands just outside them.
local function selectedText(up, down)
  local editable = editableAt(up) == true or (down and editableAt(down) == true) or false
  local ok, el = pcall(function()
    return hs.axuielement.systemWideElement():attributeValue("AXFocusedUIElement")
  end)
  local text = nil
  local focusEditable = ok and el and isEditableElement(el)
  if ok and el then
    local ok2, sel = pcall(function() return el:attributeValue("AXSelectedText") end)
    if ok2 and type(sel) == "string" and not sel:match("^%s*$") then
      text = sel
      if focusEditable then editable = true end
    end
  end
  if not editable and focusEditable then
    local f = el:attributeValue("AXFrame")
    if inFrame(up, f, 12) or inFrame(down, f, 12) then editable = true end
  end
  if not text then
    local saved
    text, saved = grabText(false)
    restoreClipboard(saved)
  end
  log("  editable=" .. tostring(editable) .. " focusEditable=" .. tostring(focusEditable) .. " text=" .. short(text))
  return text, editable
end

local function worthShowing(text)
  if not text then return false end
  local t = text:gsub("^%s+", ""):gsub("%s+$", "")
  if utf8.len(t) == nil or utf8.len(t) < 2 or #t > 20000 then return false end
  -- only numbers / IPs / punctuation → skip
  if not t:find("%a") and not t:find("[\128-\255]") then return false end
  -- skip URLs and emails
  if t:match("^%S+://%S+$") or t:match("^[%w%._%-]+@[%w%.%-]+$") then return false end
  return true
end

local chooseLanguage -- defined below

local showToolbar -- defined below

local function actionKey(id, sel)
  if id == "read" then return readKey(sel.text)
  elseif id == "en" then return writeKey("English", sel.text)
  elseif id == "last" then return writeKey(lastLanguage, sel.text)
  elseif id == "polish" then return writeKey(nil, sel.text) end
  return nil
end

-- Start the request as soon as the mouse is over a button, so clicking feels instant.
local function prefetch(id, sel)
  log("prefetch " .. tostring(id))
  if #sel.text > 8000 and id ~= "read" then return end
  if id == "read" then request(readKey(sel.text), readFile(READ_PROMPT_FILE), sel.text, MODEL_READ)
  elseif id == "en" then request(writeKey("English", sel.text), writeSystem("English"), sel.text)
  elseif id == "last" then request(writeKey(lastLanguage, sel.text), writeSystem(lastLanguage), sel.text)
  elseif id == "polish" then request(writeKey(nil, sel.text), writeSystem(nil), sel.text) end
end

local function toolbarAction(id, sel)
  if id == "expand" then showToolbar({ text = sel.text, editable = true, pos = sel.pos, expanded = true }, sel.pos)
  elseif id == "read" then readText(sel.text)
  elseif id == "en" then run("English", sel)
  elseif id == "last" then run(lastLanguage, sel)
  elseif id == "more" then chooseLanguage(sel)
  elseif id == "polish" then run(nil, sel)
  elseif id == "copy" then
    hs.pasteboard.setContents(sel.text)
    showAlert("已复制", 1)
  end
end

showToolbar = function(sel, pos)
  hideToolbar()
  toolbarSel = sel
  toolbarButtons = {}

  local buttons = { { id = "read", label = "翻译" } }
  if sel.editable ~= false then
    table.insert(buttons, { id = "en", label = "译成英文" })
    if lastLanguage ~= "English" then
      table.insert(buttons, { id = "last", label = "译成" .. (LANG_ZH[lastLanguage] or lastLanguage) })
    end
    table.insert(buttons, { id = "more", label = "其他语言" })
    table.insert(buttons, { id = "polish", label = "润色" })
  end
  table.insert(buttons, { id = "copy", label = "复制" })
  if sel.editable == false then table.insert(buttons, { id = "expand", label = "更多" }) end

  local dark = hs.host.interfaceStyle() == "Dark"
  local function hex(h, a)
    return { red = tonumber(h:sub(2, 3), 16) / 255, green = tonumber(h:sub(4, 5), 16) / 255,
             blue = tonumber(h:sub(6, 7), 16) / 255, alpha = a or 1 }
  end
  local bg = dark and hex("#262624", 0.98) or hex("#FAF9F5", 0.98)
  local border = dark and hex("#3D3D3A") or hex("#E8E6DC")
  local fg = dark and hex("#FAF9F5") or hex("#3D3929")
  local hover = dark and hex("#30302E") or hex("#F0EEE6")
  local sep = dark and hex("#3D3D3A") or hex("#E8E6DC")
  local accent = dark and hex("#D97757") or hex("#C96442")

  local fontSize, padX, h, gap = 13, 11, 34, 2
  local widths, total = {}, 6
  for i, b in ipairs(buttons) do
    local size = hs.drawing.getTextDrawingSize(b.label, { size = fontSize })
    widths[i] = math.ceil(size.w) + padX * 2
    total = total + widths[i] + gap
  end
  total = total + 4

  local screen = hs.mouse.getCurrentScreen():frame()
  local x = math.min(math.max(pos.x - total / 2, screen.x + 6), screen.x + screen.w - total - 6)
  local y = pos.y - h - 14
  if y < screen.y + 4 then y = pos.y + 18 end

  toolbar = hs.canvas.new({ x = x, y = y, w = total, h = h })
  toolbar:level(hs.canvas.windowLevels.popUpMenu)
  toolbar:clickActivating(false)
  toolbar:appendElements({
    type = "rectangle", action = "strokeAndFill", fillColor = bg, strokeColor = border, strokeWidth = 1, id = "bg",
    roundedRectRadii = { xRadius = 10, yRadius = 10 },
    withShadow = true, shadow = { blurRadius = 10, color = { alpha = 0.18 }, offset = { h = -3, w = 0 } },
  })
  local cx = 5
  local hitIndex = {}
  for i, b in ipairs(buttons) do
    if i > 1 then
      toolbar:appendElements({ type = "rectangle", action = "fill", fillColor = sep,
        frame = { x = cx - 1, y = 9, w = 1, h = h - 18 } })
    end
    toolbar:appendElements({
      type = "rectangle", action = "fill", fillColor = { alpha = 0 }, id = b.id,
      roundedRectRadii = { xRadius = 6, yRadius = 6 },
      frame = { x = cx + 1, y = 3, w = widths[i] - 2, h = h - 6 },
      trackMouseDown = true, trackMouseEnterExit = true,
    })
    hitIndex[b.id] = #toolbar
    toolbarButtons[#toolbarButtons + 1] = { id = b.id, label = b.label, x = x + cx + widths[i] / 2, y = y + h / 2 }
    toolbar:appendElements({
      type = "text", text = b.label, textSize = fontSize, textAlignment = "center",
      textColor = (b.id == "read") and accent or fg,
      frame = { x = cx, y = (h - fontSize - 4) / 2, w = widths[i], h = fontSize + 6 },
    })
    cx = cx + widths[i] + gap
  end

  toolbar:mouseCallback(function(c, message, id)
    local idx = hitIndex[id]
    if not idx then return end
    if message == "mouseEnter" then
      c[idx].fillColor = hover
      if toolbarSel then prefetch(id, toolbarSel) end
    elseif message == "mouseExit" then c[idx].fillColor = { alpha = 0 }
    elseif message == "mouseDown" then
      local s = toolbarSel
      hideToolbar(s and actionKey(id, s))
      if s then later(0.02, function() toolbarAction(id, s) end) end
    end
  end)
  toolbar:show()
  toolbarTimer = later(8, hideToolbar)
end

local EXCLUDED_APPS = { ["org.hammerspoon.Hammerspoon"] = true, ["com.apple.finder"] = true }

local function onMouseUp(e)
  local up = hs.mouse.absolutePosition()
  local down = mouseDownPos
  local clicks = e:getProperty(hs.eventtap.event.properties.mouseEventClickState) or 1
  local dragged = down and (math.abs(up.x - down.x) + math.abs(up.y - down.y) > 8)
  if not dragged and clicks < 2 then return end
  if toolbar and pointIn(up, toolbar:frame()) then return end
  local front = hs.application.frontmostApplication()
  local bid = front and front:bundleID() or "?"
  log(string.format("mouseUp app=%s dragged=%s clicks=%d", bid, tostring(dragged), clicks))
  if EXCLUDED_APPS[bid] then return end
  later(0.15, function()
    local text, editable = selectedText(up, down)
    local worth = worthShowing(text)
    log("  worth=" .. tostring(worth))
    if worth then showToolbar({ text = text, editable = editable, pos = up }, up) end
  end)
end

local function startAutoIcon()
  if mouseTap then mouseTap:stop() end
  -- drag handle for the popup: update position while left button is held
  local dragTap
  dragTap = hs.eventtap.new({ hs.eventtap.event.types.leftMouseDragged, hs.eventtap.event.types.leftMouseUp },
    function(ev)
      if not dragging or not popup then dragTap:stop() dragging = nil return false end
      if ev:getType() == hs.eventtap.event.types.leftMouseUp then
        dragTap:stop(); dragging = nil
      else
        local m = hs.mouse.absolutePosition()
        local f = popup:frame()
        f.x = m.x - dragging.dx; f.y = m.y - dragging.dy
        popup:frame(f)
      end
      return false
    end)
  local origStartDrag = startDrag
  startDrag = function()
    origStartDrag()
    dragTap:start()
  end

  mouseTap = hs.eventtap.new(
    { hs.eventtap.event.types.leftMouseDown, hs.eventtap.event.types.leftMouseUp,
      hs.eventtap.event.types.keyDown, hs.eventtap.event.types.scrollWheel },
    function(e)
      local t = e:getType()
      if t == hs.eventtap.event.types.leftMouseDown then
        local p = hs.mouse.absolutePosition()
        mouseDownPos = p
        if toolbar and not pointIn(p, toolbar:frame()) then hideToolbar() end
        if popup and not popupPinned and not pointIn(p, popup:frame()) then closePopup() end
      elseif t == hs.eventtap.event.types.leftMouseUp then
        if toolbarEnabled then onMouseUp(e) end
      elseif t == hs.eventtap.event.types.keyDown or t == hs.eventtap.event.types.scrollWheel then
        if toolbar then hideToolbar() end
      end
      return false
    end)
  mouseTap:start()
end

local function toggleAutoIcon()
  toolbarEnabled = not toolbarEnabled
  hs.settings.set("claudeReplace.autoIcon", toolbarEnabled)
  if not toolbarEnabled then hideToolbar() end
  showAlert(toolbarEnabled and "小宁翻译：划词工具条已开启" or "小宁翻译：划词工具条已关闭", 1.5)
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
    showPopup("识别翻译中…", "（截图已发送给 Claude）", false, true, nil)
    local content = {
      { type = "image", source = { type = "base64", media_type = "image/png", data = hs.base64.encode(data) } },
      { type = "text", text = "Translate the text in this screenshot." },
    }
    callClaude(readFile(READ_PROMPT_FILE), content, function(result, err)
      if not popup then return end
      if result then showPopup("截图译文", result, true, false, nil)
      else js("setStatus","出错了",false); js("setErr", err or "出错了") end
    end)
  end, { "-i", "-x", path }):start()
end

-- ---------------------------------------------------------------- language picker & start

local activeChooser = nil
chooseLanguage = function(sel)
  local chooser = hs.chooser.new(function(choice)
    if not choice then return end
    lastLanguage = choice.lang
    hs.settings.set("claudeReplace.lastLanguage", lastLanguage)
    later(0.2, function() run(lastLanguage, sel) end)
  end)
  local choices = {}
  for _, lang in ipairs(LANGUAGES) do
    table.insert(choices, { text = LANG_ZH[lang] .. "  " .. lang, lang = lang })
  end
  chooser:choices(choices)
  chooser:placeholderText("小宁翻译 · 翻译润色成哪种语言？（可输入搜索）")
  activeChooser = chooser
  chooser:show()
end

function M.start()
  -- load extensions up front so nothing gets lazily loaded inside event callbacks
  local _ = { hs.canvas, hs.axuielement, hs.mouse, hs.eventtap, hs.window, hs.webview, hs.webview.usercontent, hs.drawing, hs.styledtext, hs.settings, hs.alert, hs.timer, hs.hotkey,
    hs.pasteboard, hs.http, hs.json, hs.chooser, hs.task, hs.base64, hs.host, hs.screen, hs.application }
  hs.hotkey.bind({ "ctrl", "alt" }, "S", readScreenshot)
  hs.hotkey.bind({ "ctrl", "alt" }, "T", toggleAutoIcon)
  startAutoIcon()
  if not authToken() then
    hs.alert.show("小宁翻译还没有 API Key\n请打开 " .. DIR .. "/config.lua 填写 apiKey\n然后点菜单栏小锤子 → Reload Config", ALERT_STYLE, hs.screen.mainScreen(), 12)
  end
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

M.paths = function() return { dir = DIR, write = PROMPT_FILE, read = READ_PROMPT_FILE, endpoint = ENDPOINT, model = MODEL_WRITE, readModel = MODEL_READ, hasKey = authToken() ~= nil } end

M.toolbarButtons = function() return toolbar and toolbarButtons or {} end

M._test = { readText = function(t) return readText(t) end, setPinned = function(v) return setPinned(v) end, pinned = function() return popupPinned end, request = function(...) return request(...) end, readKey = function(...) return readKey(...) end, writeKey = function(...) return writeKey(...) end, writeSystem = function(...) return writeSystem(...) end, readPrompt = function() return readFile(READ_PROMPT_FILE) end, editableAt = function(p) return editableAt(p) end, listen = function(...) return listen(...) end }

M.debugState = function()
  return { icon = toolbar ~= nil, iconFrame = toolbar and toolbar:frame(), iconText = toolbarSel and toolbarSel.text, editable = toolbarSel and toolbarSel.editable, popup = popup ~= nil, popupFrame = popup and popup:frame(), popupVisible = popup and popup:isVisible(), tap = mouseTap and mouseTap:isEnabled(), auto = toolbarEnabled }
end

return M
