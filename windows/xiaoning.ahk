; 小宁翻译 · XiaoNing Translate — Windows 版 (AutoHotkey v2)
;
; 用鼠标选中文字 → 旁边弹出工具条 → 点按钮执行
;   客户消息（不能编辑）→ 翻译 · 复制 · 更多
;   自己的输入框        → 翻译 · 译成英文 · 译成〔上次语言〕· 其他语言 · 润色 · 复制
; Ctrl+Alt+S 截图翻译；Ctrl+Alt+T 开关工具条。托盘图标右键可打开配置 / 重新加载。

#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn VarUnset, Off
Persistent
CoordMode "Mouse", "Screen"
CoordMode "Caret", "Screen"
SetWinDelay -1
SetControlDelay -1

global APP_NAME := "小宁翻译"
global ROOT := DirExist(A_ScriptDir "\..\prompts") ? A_ScriptDir "\.." : A_ScriptDir
global CFG_FILE := ROOT "\config.ini"
global TMP := A_Temp "\xiaoning"
DirCreate(TMP)

global ENDPOINT := CfgRead("api", "endpoint", "https://api.anthropic.com/v1/messages")
global API_KEY := CfgRead("api", "apiKey", "")
global MODEL := CfgRead("api", "model", "claude-sonnet-5-5")
global THINKING := CfgRead("api", "thinking", "")
global TIMEOUT := Integer(CfgRead("api", "timeout", "45"))

global LANGUAGES := [
  ["English", "英语"], ["Spanish", "西班牙语"], ["Russian", "俄语"], ["Portuguese (Brazil)", "葡萄牙语（巴西）"],
  ["French", "法语"], ["German", "德语"], ["Italian", "意大利语"], ["Turkish", "土耳其语"], ["Arabic", "阿拉伯语"],
  ["Vietnamese", "越南语"], ["Indonesian", "印尼语"], ["Thai", "泰语"], ["Japanese", "日语"], ["Korean", "韩语"],
  ["Polish", "波兰语"], ["Ukrainian", "乌克兰语"], ["Persian", "波斯语"], ["Hindi", "印地语"],
  ["Simplified Chinese", "简体中文"], ["Traditional Chinese", "繁体中文"]
]
global lastLanguage := CfgRead("state", "lastLanguage", "Spanish")
global toolbarEnabled := CfgRead("state", "toolbar", "1") = "1"

; Claude-style palette (light)
global C_BG := "FAF9F5", C_FG := "141413", C_TEXT := "3D3929", C_MUTED := "87867F"
global C_BORDER := "E8E6DC", C_HOVER := "F0EEE6", C_ACCENT := "C96442"

; ------------------------------------------------------------ CI: report runtime errors instead of showing a dialog
if (EnvGet("XN_CI") != "" || (A_Args.Length && A_Args[1] = "--selftest"))
  OnError(CiError)
CiError(e, mode) {
  FileAppend("RUNTIME ERROR: " e.Message " (" e.What ") line " e.Line "`n" e.Stack "`n", "**", "UTF-8")
  ExitApp(3)
}

; ------------------------------------------------------------ self-test (used by CI)
if (A_Args.Length && A_Args[1] = "--selftest") {
  ExitApp(SelfTest(A_Args.Length >= 2 ? A_Args[2] : ""))
}

; ------------------------------------------------------------ state
global REQS := Map()
global busy := false
global downX := 0, downY := 0, upX := 0, upY := 0, lastUpTick := 0, lastUpX := -999, lastUpY := -999
global tbGui := "", tbSel := "", tbButtons := Map(), tbHover := "", tbShownTick := 0
global popGui := "", popText := "", popPinned := false, popStatus := "", popBody := "", popPinCtl := "", popBusy := false
global toastGui := ""
global readSeq := 0

SetupTray()
OnMessage(0x200, OnMouseMove)     ; WM_MOUSEMOVE
OnMessage(0x201, OnLButtonDown)   ; WM_LBUTTONDOWN (drag the popup by its header)
SetTimer(Housekeeping, 120)
if (API_KEY = "")
  Toast("小宁翻译还没有 API Key：右键右下角托盘图标 →「打开配置文件」填写 apiKey，再选「重新加载」", 12000)
else
  Toast("小宁翻译已就绪 · 选中文字出现工具条 · Ctrl+Alt+S 截图翻译", 3000)
return

; ============================================================ helpers

CfgRead(section, key, def) {
  try return IniRead(CFG_FILE, section, key, def)
  catch
    return def
}

CfgWrite(section, key, value) {
  try IniWrite(value, CFG_FILE, section, key)
}

S(n) => Round(n * A_ScreenDPI / 96)

LangZh(lang) {
  for pair in LANGUAGES
    if (pair[1] = lang)
      return pair[2]
  return lang
}

PromptPath(name) {
  own := ROOT "\prompts\" name ".txt"
  return FileExist(own) ? own : ROOT "\prompts\" name ".example.txt"
}

ReadPrompt(name) {
  p := PromptPath(name)
  return FileExist(p) ? FileRead(p, "UTF-8") : ""
}

JsonStr(s) {
  s := StrReplace(s, "\", "\\")
  s := StrReplace(s, '"', '\"')
  s := StrReplace(s, "`r", "\r")
  s := StrReplace(s, "`n", "\n")
  s := StrReplace(s, "`t", "\t")
  ; any remaining control characters
  while RegExMatch(s, "[\x00-\x1F]", &m)
    s := StrReplace(s, m[0], Format("\u{:04x}", Ord(m[0])))
  return '"' s '"'
}

JsonUnescape(s) {
  out := "", i := 1, n := StrLen(s)
  while (i <= n) {
    ch := SubStr(s, i, 1)
    if (ch != "\") {
      out .= ch, i += 1
      continue
    }
    nx := SubStr(s, i + 1, 1)
    switch nx, true {
      case "n": out .= "`n"
      case "r": out .= "`r"
      case "t": out .= "`t"
      case "b": out .= Chr(8)
      case "f": out .= Chr(12)
      case "u":
        code := Integer("0x" SubStr(s, i + 2, 4))
        if (code >= 0xD800 && code <= 0xDBFF && SubStr(s, i + 6, 2) = "\u") {
          lo := Integer("0x" SubStr(s, i + 8, 4))
          code := 0x10000 + ((code - 0xD800) << 10) + (lo - 0xDC00)
          i += 6
        }
        out .= Chr(code)
        i += 4
      default: out .= nx
    }
    i += 2
  }
  return out
}

; Sonnet/Opus 5.x think before answering by default; "between_tools" skips that for plain translation.
BuildBody(system, contentJson, stream) {
  th := THINKING
  if (th = "" && (InStr(MODEL, "sonnet") || InStr(MODEL, "opus")))
    th := "between_tools"
  body := '{"model":' JsonStr(MODEL) ',"max_tokens":2048,"system":' JsonStr(system)
    . ',"messages":[{"role":"user","content":' contentJson '}]'
  if stream
    body .= ',"stream":true'
  if (th != "" && th != "default")
    body .= ',"thinking":{"type":' JsonStr(th) '}'
  return body "}"
}

; Parse server-sent events. Returns {text, err, consumed}: text deltas joined, first error message, chars consumed.
ParseSSE(raw) {
  text := "", err := "", consumed := 0, pos := 1
  while (nl := InStr(raw, "`n", , pos)) {
    line := RTrim(SubStr(raw, pos, nl - pos), "`r")
    pos := nl + 1
    consumed := nl
    if (SubStr(line, 1, 5) != "data:")
      continue
    if InStr(line, '"text_delta"') {
      if RegExMatch(line, '"text"\s*:\s*"((?:[^"\\]|\\.)*)"', &m)
        text .= JsonUnescape(m[1])
    } else if (InStr(line, '"type":"error"') || InStr(line, '"type": "error"')) {
      if (err = "" && RegExMatch(line, '"message"\s*:\s*"((?:[^"\\]|\\.)*)"', &m))
        err := JsonUnescape(m[1])
    }
  }
  return { text: text, err: err, consumed: consumed }
}

ErrorFromBody(raw) {
  if RegExMatch(raw, '"message"\s*:\s*"((?:[^"\\]|\\.)*)"', &m)
    return JsonUnescape(m[1])
  return SubStr(Trim(raw), 1, 160)
}

; ============================================================ streaming requests (curl.exe, Windows 10+)

class Req {
  __New(key, system, contentJson) {
    this.key := key, this.text := "", this.done := false, this.err := "", this.listeners := []
    this.consumed := 0, this.acc := "", this.pid := 0
    id := A_TickCount "_" Random(1000, 99999)
    this.bodyFile := TMP "\" id ".json"
    this.hdrFile := TMP "\" id ".hdr"
    this.outFile := TMP "\" id ".out"
    this.errFile := TMP "\" id ".err"
    if (API_KEY = "" || system = "") {
      this.Finish("", "读取配置失败：没有 API Key（右键托盘图标 → 打开配置文件填写 apiKey），或缺少提示词文件")
      return
    }
    FileAppend(BuildBody(system, contentJson, true), this.bodyFile, "UTF-8-RAW")
    ; headers in a file so the key doesn't show up in the process list
    FileAppend("content-type: application/json`nx-api-key: " API_KEY "`nanthropic-version: 2023-06-01`n", this.hdrFile, "UTF-8-RAW")
    cmd := 'curl.exe -sS -N --max-time ' TIMEOUT ' "' ENDPOINT '" -H "@' this.hdrFile '" --data-binary "@' this.bodyFile
      . '" -o "' this.outFile '" --stderr "' this.errFile '"'
    try {
      Run(cmd, TMP, "Hide", &pid)
      this.pid := pid
    } catch as e {
      this.Finish("", "无法启动 curl：" e.Message)
      return
    }
    this.timer := ObjBindMethod(this, "Poll")
    SetTimer(this.timer, 80)
  }

  Poll() {
    if this.done
      return
    alive := ProcessExist(this.pid)
    raw := ""
    try raw := FileRead(this.outFile, "UTF-8")
    if (raw != "") {
      res := ParseSSE(raw)
      if (res.err != "") {
        this.Finish("", "出错了：" res.err)
        return
      }
      if (res.text != this.text) {
        this.text := res.text
        for l in this.listeners
          if l.d
            l.d.Call(this.text)
      }
    }
    if !alive {
      t := Trim(this.text, " `t`r`n")
      if (t != "") {
        this.Finish(t, "")
      } else {
        e := ""
        try e := FileRead(this.errFile, "UTF-8")
        this.Finish("", "出错了：" ErrorFromBody(raw != "" ? raw : e))
      }
    }
  }

  Finish(result, err) {
    if this.done
      return
    this.done := true, this.err := err
    if (result != "")
      this.text := result
    if this.HasOwnProp("timer")
      SetTimer(this.timer, 0)
    this.Cleanup()
    ls := this.listeners
    this.listeners := []
    for l in ls
      l.f.Call(err = "" ? this.text : "", err)
  }

  Cancel() {
    if this.done
      return
    this.done := true
    if this.HasOwnProp("timer")
      SetTimer(this.timer, 0)
    if this.pid
      try ProcessClose(this.pid)
    this.Cleanup()
  }

  Cleanup() {
    for f in [this.bodyFile, this.hdrFile, this.outFile, this.errFile]
      try FileDelete(f)
  }
}

Request(key, system, contentJson) {
  if REQS.Has(key)
    return REQS[key]
  r := Req(key, system, contentJson)
  REQS[key] := r
  return r
}

Listen(r, onDelta, onDone) {
  if r.done {
    onDone.Call(r.err = "" ? r.text : "", r.err)
    return
  }
  if (onDelta && r.text != "")
    onDelta.Call(r.text)
  r.listeners.Push({ d: onDelta, f: onDone })
}

; cancel unfinished requests nobody waits for (except keepKey)
DropRequests(keepKey := "") {
  keys := []
  for k, r in REQS
    if (k != keepKey && (r.done || r.listeners.Length = 0))
      keys.Push(k)
  for k in keys {
    REQS[k].Cancel()
    REQS.Delete(k)
  }
}

WriteSystem(target) {
  tpl := ReadPrompt("write")
  if (target != "")
    task := "Translate and polish the draft into " target ". If the draft is already in " target ", just polish it."
  else
    task := "Polish the draft in the same language it is written in. Do not translate it."
  return StrReplace(tpl, "{{TASK}}", task)
}

WriteKey(target, text) => "write:" target ":" text
ReadKey(text) => "read:" text

; ============================================================ toast

Toast(msg, ms := 2000) {
  global toastGui
  if toastGui
    try toastGui.Destroy()
  g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000 -DPIScale")
  g.BackColor := "D97757"
  g.MarginX := S(16), g.MarginY := S(10)
  g.SetFont("s10 cFFFFFF", "Microsoft YaHei UI")
  g.AddText(, msg)
  g.Show("Hide AutoSize")
  g.GetPos(, , &w, &h)
  MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
  g.Show("x" (l + (r - l - w) // 2) " y" (b - h - S(80)) " NoActivate")
  Round_(g.Hwnd)
  toastGui := g
  SetTimer(HideToast, -ms)
}

HideToast() {
  global toastGui
  if toastGui
    try toastGui.Destroy()
  toastGui := ""
}

; rounded corners + border colour on Windows 11 (ignored on Windows 10)
Round_(hwnd, borderHex := "") {
  try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "int", 33, "int*", 2, "int", 4)
  if (borderHex != "") {
    c := Integer("0x" borderHex)
    bgr := ((c & 0xFF) << 16) | (c & 0xFF00) | ((c >> 16) & 0xFF)
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "int", 34, "int*", bgr, "int", 4)
  }
}

MonitorFromPoint(x, y, &l, &t, &r, &b) {
  Loop MonitorGetCount() {
    MonitorGetWorkArea(A_Index, &l, &t, &r, &b)
    if (x >= l && x < r && y >= t && y < b)
      return
  }
  MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
}

; ============================================================ selection detection

~LButton:: {
  global downX, downY
  MouseGetPos(&downX, &downY)
  if (tbGui && !OverGui(tbGui))
    HideToolbar()
  if (popGui && !popPinned && !OverGui(popGui))
    HidePopup()
}

~LButton Up:: {
  global upX, upY, lastUpTick, lastUpX, lastUpY
  MouseGetPos(&x, &y, &win)
  dragged := Abs(x - downX) + Abs(y - downY) > 8
  dbl := (A_TickCount - lastUpTick < DllCall("GetDoubleClickTime") && Abs(x - lastUpX) + Abs(y - lastUpY) < 6)
  lastUpTick := A_TickCount, lastUpX := x, lastUpY := y
  if !toolbarEnabled || !(dragged || dbl)
    return
  if (tbGui && win = tbGui.Hwnd) || (popGui && win = popGui.Hwnd)
    return
  try {
    cls := WinGetClass("ahk_id " win)
    exe := WinGetProcessName("ahk_id " win)
    if (exe = "explorer.exe" || cls = "Shell_TrayWnd" || cls = "Progman" || cls = "WorkerW")
      return
  }
  upX := x, upY := y
  SetTimer(CheckSelection, -150)
}

~WheelUp::
~WheelDown:: {
  if tbGui
    HideToolbar()
}

OverGui(g) {
  if !g
    return false
  MouseGetPos(, , &win)
  return win = g.Hwnd
}

; The caret sits at the end of a selection only inside an input box; in message text there is no caret.
IsEditableHere() {
  try {
    if CaretGetPos(&cx, &cy)
      return Abs(cy - upY) < S(60) || Abs(cy - downY) < S(60)
  }
  return false
}

CopySelection() {
  saved := ClipboardAll()
  A_Clipboard := ""
  Send("^c")
  text := ClipWait(0.45) ? A_Clipboard : ""
  A_Clipboard := saved
  return text
}

WorthShowing(text) {
  t := Trim(text, " `t`r`n")
  n := StrLen(t)
  if (n < 2 || n > 20000)
    return false
  if !RegExMatch(t, "\p{L}")           ; only numbers / IPs / punctuation
    return false
  if RegExMatch(t, "^\S+://\S+$") || RegExMatch(t, "^[\w.\-]+@[\w.\-]+$")
    return false
  return true
}

CheckSelection() {
  editable := IsEditableHere()
  text := CopySelection()
  if WorthShowing(text)
    ShowToolbar({ text: text, editable: editable, x: upX, y: upY })
}

; ============================================================ toolbar

ShowToolbar(sel) {
  global tbGui, tbSel, tbButtons, tbHover, tbShownTick
  HideToolbar()
  tbSel := sel
  buttons := [["read", "翻译"]]
  if sel.editable {
    buttons.Push(["en", "译成英文"])
    if (lastLanguage != "English")
      buttons.Push(["last", "译成" LangZh(lastLanguage)])
    buttons.Push(["more", "其他语言"], ["polish", "润色"])
  }
  buttons.Push(["copy", "复制"])
  if !sel.editable
    buttons.Push(["expand", "更多"])

  g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000 -DPIScale +Border")
  g.BackColor := C_BG
  g.MarginX := S(4), g.MarginY := S(4)
  g.SetFont("s10 c" C_TEXT, "Microsoft YaHei UI")
  tbButtons := Map()
  x := S(4), h := S(28)
  for i, b in buttons {
    if (i > 1) {
      g.AddText("x" x " y" S(10) " w1 h" S(16) " Background" C_BORDER)
      x += 1 + S(2)
    }
    opt := "x" x " y" S(4) " h" h " +0x200 Center Background" C_BG (b[1] = "read" ? " c" C_ACCENT : "")
    ctl := g.AddText(opt, "   " b[2] "   ")
    ctl.OnEvent("Click", ToolbarClick.Bind(b[1]))
    tbButtons[ctl.Hwnd] := b[1]
    ctl.GetPos(&cx, , &cw)
    x := cx + cw + S(2)
  }
  g.Show("Hide AutoSize")
  g.GetPos(, , &w, &hh)
  MonitorFromPoint(sel.x, sel.y, &l, &t, &r, &bm)
  px := Max(l + 4, Min(sel.x - w // 2, r - w - 4))
  py := sel.y - hh - S(14)
  if (py < t + 4)
    py := sel.y + S(18)
  g.Show("x" px " y" py " NoActivate")
  Round_(g.Hwnd, C_BORDER)
  tbGui := g, tbHover := "", tbShownTick := A_TickCount
  SetTimer(HideToolbarTimeout, -8000)
}

HideToolbarTimeout() => HideToolbar()

HideToolbar(keepKey := "") {
  global tbGui, tbSel, tbButtons, tbHover
  SetTimer(HideToolbarTimeout, 0)
  if tbGui
    try tbGui.Destroy()
  tbGui := "", tbSel := "", tbButtons := Map(), tbHover := ""
  DropRequests(keepKey)
}

ActionKey(id, sel) {
  switch id {
    case "read": return ReadKey(sel.text)
    case "en": return WriteKey("English", sel.text)
    case "last": return WriteKey(lastLanguage, sel.text)
    case "polish": return WriteKey("", sel.text)
  }
  return ""
}

; start the request while the mouse is over a button, so clicking feels instant
Prefetch(id, sel) {
  if (id != "read" && StrLen(sel.text) > 8000)
    return
  switch id {
    case "read": Request(ReadKey(sel.text), ReadPrompt("read"), JsonStr(sel.text))
    case "en": Request(WriteKey("English", sel.text), WriteSystem("English"), JsonStr(sel.text))
    case "last": Request(WriteKey(lastLanguage, sel.text), WriteSystem(lastLanguage), JsonStr(sel.text))
    case "polish": Request(WriteKey("", sel.text), WriteSystem(""), JsonStr(sel.text))
  }
}

ToolbarClick(id, *) {
  sel := tbSel
  if !sel
    return
  HideToolbar(ActionKey(id, sel))
  switch id {
    case "expand": ShowToolbar({ text: sel.text, editable: true, x: sel.x, y: sel.y })
    case "read": ReadText(sel.text)
    case "en": RunWrite("English", sel)
    case "last": RunWrite(lastLanguage, sel)
    case "more": ChooseLanguage(sel)
    case "polish": RunWrite("", sel)
    case "copy":
      A_Clipboard := sel.text
      Toast("已复制", 1000)
  }
}

OnMouseMove(wParam, lParam, msg, hwnd) {
  global tbHover
  if !tbGui || !tbButtons.Has(hwnd)
    return
  id := tbButtons[hwnd]
  if (id = tbHover)
    return
  SetHover(id)
  if tbSel
    Prefetch(id, tbSel)
}

SetHover(id) {
  global tbHover
  tbHover := id
  for h, bid in tbButtons {
    ctl := GuiCtrlFromHwnd(h)
    if ctl {
      ctl.Opt("Background" (bid = id ? C_HOVER : C_BG))
      ctl.Redraw()
    }
  }
}

Housekeeping() {
  ; typing hides the toolbar; leaving it clears the hover highlight
  if tbGui {
    if (A_TimeIdleKeyboard < 150 && A_TickCount - tbShownTick > 300)
      HideToolbar()
    else if (tbHover != "" && !OverGui(tbGui))
      SetHover("")
  }
  ; blink the status dot while busy
  if (popGui && popBusy)
    try popStatus.Opt("c" (Mod(A_TickCount // 500, 2) ? C_ACCENT : "E8B9A6")), popStatus.Redraw()
}

; ============================================================ popup (小宁翻译 card)

EnsurePopup() {
  global popGui, popStatus, popBody, popPinCtl
  if popGui
    return
  W := S(440)
  g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000 -DPIScale +Border")
  g.BackColor := C_BG
  g.MarginX := 0, g.MarginY := 0
  g.SetFont("s12 c" C_ACCENT, "Segoe UI Symbol")
  g.AddText("x" S(14) " y" S(10) " h" S(24) " +0x200 vHead1", "✦")
  g.SetFont("s10 Bold c" C_FG, "Microsoft YaHei UI")
  g.AddText("x+" S(6) " yp h" S(24) " +0x200 vHead2", APP_NAME)
  g.SetFont("s9 Norm c" C_MUTED, "Microsoft YaHei UI")
  popStatus := g.AddText("x+" S(8) " yp h" S(24) " w" S(180) " +0x200 vHead3", "")
  g.SetFont("s10 c" C_MUTED, "Segoe MDL2 Assets")
  popPinCtl := g.AddText("x" (W - S(102)) " y" S(8) " w" S(30) " h" S(28) " Center +0x200 Background" C_BG, Chr(0xE718))
  popPinCtl.OnEvent("Click", (*) => SetPinned(!popPinned))
  cp := g.AddText("x+" S(2) " yp w" S(30) " h" S(28) " Center +0x200 Background" C_BG, Chr(0xE8C8))
  cp.OnEvent("Click", PopupCopy)
  cl := g.AddText("x+" S(2) " yp w" S(30) " h" S(28) " Center +0x200 Background" C_BG, Chr(0xE8BB))
  cl.OnEvent("Click", (*) => HidePopup())
  g.SetFont("s10 Norm c" C_FG, "Microsoft YaHei UI")
  popBody := g.AddEdit("x" S(16) " y" S(44) " w" (W - S(32)) " h" S(60) " ReadOnly Multi -E0x200 -VScroll Background" C_BG)
  MouseGetPos(&mx, &my)
  MonitorFromPoint(mx, my, &l, &t, &r, &b)
  x := Max(l + 4, Min(mx - S(20), r - W - 4))
  y := Max(t + 4, Min(my + S(18), b - S(300)))
  g.Show("x" x " y" y " w" W " h" S(120) " NoActivate")
  Round_(g.Hwnd, C_BORDER)
  popGui := g
}

; height follows the text (rough estimate: CJK ≈ 1 em, latin ≈ 0.55 em)
FitPopup(text) {
  if !popGui
    return
  avail := S(440) - S(40), em := S(14), lines := 0
  for para in StrSplit(StrReplace(text, "`r"), "`n") {
    w := 0
    Loop Parse para
      w += (Ord(A_LoopField) > 0x2E80) ? em : em * 0.55
    lines += Max(1, Ceil(w / avail))
  }
  bodyH := Min(Max(lines, 1) * S(22) + S(8), S(420))
  popBody.Move(, , , bodyH)
  popBody.Opt(lines * S(22) > S(420) ? "+VScroll" : "-VScroll")
  popGui.GetPos(, , &gw)
  popGui.Move(, , gw, S(44) + bodyH + S(16))
}

ShowPopup(status, body, isText, busyFlag) {
  global popText, popBusy
  EnsurePopup()
  popText := isText ? body : ""
  popBusy := busyFlag
  popStatus.Value := (busyFlag ? "● " : "") status
  popStatus.Opt("c" C_MUTED)
  popBody.Opt("c" (isText || busyFlag ? C_FG : C_ACCENT))
  popBody.Value := body
  FitPopup(body)
  SetPinned(popPinned)
}

PopupStream(text) {
  global popText
  if !popGui
    return
  popText := text
  popBody.Value := text
  FitPopup(text)
}

PopupCopy(*) {
  if (popText != "") {
    A_Clipboard := popText
    Toast("已复制", 1000)
  }
}

SetPinned(on) {
  global popPinned
  popPinned := on
  if popPinCtl {
    popPinCtl.Opt("c" (on ? C_ACCENT : C_MUTED) " Background" (on ? "F6E6DF" : C_BG))
    popPinCtl.Redraw()
  }
}

HidePopup() {
  global popGui, popPinned, popBusy
  if popGui
    try popGui.Destroy()
  popGui := "", popPinned := false, popBusy := false
}

; drag the card by its header
OnLButtonDown(wParam, lParam, msg, hwnd) {
  if !popGui
    return
  if (hwnd = popGui.Hwnd) {
    PostMessage(0xA1, 2, , , "ahk_id " popGui.Hwnd)   ; WM_NCLBUTTONDOWN, HTCAPTION
    return 0
  }
  try {
    ctl := GuiCtrlFromHwnd(hwnd)
    if (ctl && ctl.Gui = popGui && InStr(ctl.Name, "Head")) {
      PostMessage(0xA1, 2, , , "ahk_id " popGui.Hwnd)
      return 0
    }
  }
}

#HotIf popGui && !popPinned
Esc:: HidePopup()
#HotIf

; ============================================================ read (translate into Chinese)

ReadText(text) {
  global readSeq
  if (StrLen(text) > 20000)
    text := SubStr(text, 1, 20000)
  readSeq += 1
  mySeq := readSeq
  key := ReadKey(text)
  r := Request(key, ReadPrompt("read"), JsonStr(text))
  ShowPopup(r.done ? "译文" : "翻译中…", r.text, r.done, !r.done)
  onDelta(t) {
    if (popGui && mySeq = readSeq)
      PopupStream(t)
  }
  onDone(result, err) {
    if REQS.Has(key)
      REQS.Delete(key)
    if (!popGui || mySeq != readSeq)
      return
    if (result != "")
      ShowPopup("译文", result, true, false)
    else
      ShowPopup("出错了", err != "" ? err : "出错了", false, false)
  }
  Listen(r, onDelta, onDone)
}

; ============================================================ write (translate + polish, replace)

RunWrite(target, sel) {
  global busy
  if busy {
    Toast("上一条还在处理中…")
    return
  }
  srcWin := WinExist("A")
  text := sel.text
  if (StrLen(text) > 8000) {
    Toast("选中的文字太长（可能连邮件历史也选上了），请只选中你要发的那段", 4000)
    return
  }
  busy := true
  key := WriteKey(target, text)
  r := Request(key, WriteSystem(target), JsonStr(text))
  if !r.done
    Toast("⏳ " (target != "" ? "翻译润色 → " LangZh(target) : "润色中") "…", TIMEOUT * 1000)
  onDone(result, err) {
    global busy
    busy := false
    if REQS.Has(key)
      REQS.Delete(key)
    HideToast()
    if (result = "") {
      Toast(err != "" ? err : "出错了", 5000)
      return
    }
    if !sel.editable {
      ShowPopup("结果", result, true, false)
      return
    }
    if (WinExist("A") != srcWin) {
      A_Clipboard := result
      Toast("你已切换到别的窗口，结果已复制到剪贴板，Ctrl+V 粘贴即可", 4000)
      return
    }
    saved := ClipboardAll()
    A_Clipboard := result
    ClipWait(0.5)
    Send("^v")
    restore() {
      A_Clipboard := saved
    }
    SetTimer(restore, -700)
    Toast("✅ 已替换（Ctrl+Z 撤销）", 1200)
  }
  Listen(r, 0, onDone)
}

; ============================================================ language picker

ChooseLanguage(sel) {
  srcWin := WinExist("A")
  g := Gui("+AlwaysOnTop -MinimizeBox -DPIScale", APP_NAME " · 翻译润色成哪种语言？")
  g.BackColor := C_BG
  g.SetFont("s10 c" C_FG, "Microsoft YaHei UI")
  search := g.AddEdit("w" S(300))
  items := []
  for pair in LANGUAGES
    items.Push(pair[2] "  " pair[1])
  lb := g.AddListBox("w" S(300) " r12", items)
  lb.Choose(1)
  pick(*) {
    global lastLanguage
    choice := lb.Text
    if (choice = "")
      return
    for pair in LANGUAGES
      if (pair[2] "  " pair[1] = choice)
        lastLanguage := pair[1]
    CfgWrite("state", "lastLanguage", lastLanguage)
    g.Destroy()
    try WinActivate("ahk_id " srcWin)
    go() {
      RunWrite(lastLanguage, sel)
    }
    SetTimer(go, -200)
  }
  filter(*) {
    q := search.Value, shown := []
    for it in items
      if (q = "" || InStr(it, q))
        shown.Push(it)
    lb.Delete()
    if shown.Length {
      lb.Add(shown)
      lb.Choose(1)
    }
  }
  search.OnEvent("Change", filter)
  lb.OnEvent("DoubleClick", pick)
  ok := g.AddButton("Default w" S(300), "确定")
  ok.OnEvent("Click", pick)
  g.OnEvent("Escape", (*) => g.Destroy())
  g.OnEvent("Close", (*) => g.Destroy())
  g.Show()
  search.Focus()
}

; ============================================================ screenshot translate (Ctrl+Alt+S)

^!s:: ScreenshotTranslate()
^!t:: ToggleToolbar()

ToggleToolbar() {
  global toolbarEnabled
  toolbarEnabled := !toolbarEnabled
  CfgWrite("state", "toolbar", toolbarEnabled ? "1" : "0")
  if !toolbarEnabled
    HideToolbar()
  Toast(toolbarEnabled ? "小宁翻译：划词工具条已开启" : "小宁翻译：划词工具条已关闭", 1500)
}

ScreenshotTranslate() {
  saved := ClipboardAll()
  A_Clipboard := ""
  Send("#+s")                         ; Windows snipping (Win+Shift+S) copies to the clipboard
  start := A_TickCount, got := false
  while (A_TickCount - start < 30000) {
    if (DllCall("IsClipboardFormatAvailable", "uint", 2) || DllCall("IsClipboardFormatAvailable", "uint", 8)) {
      got := true
      break
    }
    Sleep(150)
  }
  if !got {
    A_Clipboard := saved
    return
  }
  png := TMP "\shot.png", b64 := TMP "\shot.b64"
  try FileDelete(png)
  try FileDelete(b64)
  ps := "Add-Type -AssemblyName System.Windows.Forms,System.Drawing; $i=[System.Windows.Forms.Clipboard]::GetImage(); "
    . "if($i){$i.Save('" png "',[System.Drawing.Imaging.ImageFormat]::Png); "
    . "[IO.File]::WriteAllText('" b64 "',[Convert]::ToBase64String([IO.File]::ReadAllBytes('" png "')))}"
  RunWait('powershell.exe -NoProfile -STA -WindowStyle Hidden -Command "' ps '"', , "Hide")
  A_Clipboard := saved
  if !FileExist(b64) {
    Toast("没有读到截图", 2000)
    return
  }
  data := Trim(FileRead(b64), " `r`n")
  content := '[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"' data '"}},'
    . '{"type":"text","text":"Translate the text in this screenshot."}]'
  ShowPopup("识别翻译中…", "（截图已发送给 Claude）", false, true)
  key := "shot:" A_TickCount
  r := Request(key, ReadPrompt("read"), content)
  onDelta(t) {
    if popGui
      PopupStream(t)
  }
  onDone(result, err) {
    if REQS.Has(key)
      REQS.Delete(key)
    if !popGui
      return
    if (result != "")
      ShowPopup("截图译文", result, true, false)
    else
      ShowPopup("出错了", err != "" ? err : "出错了", false, false)
  }
  Listen(r, onDelta, onDone)
}

; ============================================================ tray

SetupTray() {
  A_IconTip := APP_NAME " · XiaoNing Translate"
  m := A_TrayMenu
  m.Delete()
  m.Add("打开配置文件", (*) => Run('notepad.exe "' CFG_FILE '"'))
  m.Add("打开提示词文件夹", (*) => Run('explorer.exe "' ROOT '\prompts"'))
  m.Add("开关划词工具条（Ctrl+Alt+T）", (*) => ToggleToolbar())
  m.Add()
  m.Add("重新加载", (*) => Reload())
  m.Add("退出", (*) => ExitApp())
}

; ============================================================ self-test (CI)

SelfTest(mockUrl) {
  fails := []
  check(name, got, want) {
    if (got !== want)
      fails.Push(name ": got [" got "] want [" want "]")
  }
  check("json basic", JsonStr('a"b\c'), '"a\"b\\c"')
  check("json newline", JsonStr("x`ny`tz"), '"x\ny\tz"')
  check("json ctrl", JsonStr("a" Chr(1) "b"), '"a\u0001b"')
  check("json chinese", JsonStr("你好"), '"你好"')
  check("unescape", JsonUnescape('line1\nline2 \"q\" \\ 你好'), "line1`nline2 `"q`" \ 你好")
  check("unescape emoji", JsonUnescape('\ud83d\ude00 \u4f60'), Chr(0x1F600) " 你")
  sse := 'event: content_block_delta`ndata: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}`n'
    . 'data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"你好，"}}`n'
    . 'data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"world\n\"ok\""}}`n'
    . 'data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"partial'
  res := ParseSSE(sse)
  check("sse text", res.text, "你好，world`n`"ok`"")
  check("sse err", res.err, "")
  res2 := ParseSSE('data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}`n')
  check("sse error", res2.err, "Overloaded")
  check("error body", ErrorFromBody('{"error":{"message":"No available accounts"}}'), "No available accounts")
  global MODEL := "claude-sonnet-5-5", THINKING := ""
  body := BuildBody("sys", JsonStr("hi"), true)
  check("body thinking", InStr(body, '"thinking":{"type":"between_tools"}') > 0, true)
  check("body stream", InStr(body, '"stream":true') > 0, true)
  check("worth url", WorthShowing("https://example.com/x"), false)
  check("worth ip", WorthShowing("1.2.3.4:5555"), false)
  check("worth text", WorthShowing("Is my proxy active?"), true)
  check("worth zh", WorthShowing("好的"), true)
  check("prompt example", FileExist(PromptPath("write")) != "", true)
  check("write system", InStr(WriteSystem("English"), "{{TASK}}"), 0)

  ; end-to-end streaming against a local mock server
  if (mockUrl != "") {
    global ENDPOINT := mockUrl, API_KEY := "test-key", TIMEOUT := 20
    result := "", errMsg := "", deltas := 0, finished := false
    onD(t) {
      deltas += 1
    }
    onF(r, e) {
      result := r, errMsg := e, finished := true
    }
    r := Request("t1", "system prompt", JsonStr("hello"))
    Listen(r, onD, onF)
    start := A_TickCount
    while (!finished && A_TickCount - start < 20000)
      Sleep(50)
    check("stream finished", finished, true)
    check("stream result", result, "你好，世界！`nLine 2")
    check("stream error", errMsg, "")
    check("stream deltas", deltas >= 2, true)
    ; error path
    finished := false
    r2 := Request("t2", "system prompt", JsonStr("error please"))
    Listen(r2, onD, onF)
    start := A_TickCount
    while (!finished && A_TickCount - start < 20000)
      Sleep(50)
    check("stream error path", InStr(errMsg, "No available accounts") > 0, true)
  }

  out := fails.Length ? "FAIL`n" : "PASS`n"
  for f in fails
    out .= f "`n"
  FileAppend(out, "*", "UTF-8")
  return fails.Length ? 1 : 0
}
