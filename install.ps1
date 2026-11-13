# XiaoNing Translate (小宁翻译) — one-step installer for Windows.
#
# Run in PowerShell (Start menu → search "PowerShell"):
#   irm https://raw.githubusercontent.com/wenluisme/xiaoning-translate/main/install.ps1 | iex
#
# Messages shown during installation are in Chinese for the team this was built for.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo = 'wenluisme/xiaoning-translate'
$Dest = Join-Path $env:LOCALAPPDATA 'xiaoning-translate'
function Say($m) { Write-Host "`n> $m" -ForegroundColor DarkYellow }

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
  Write-Host "需要 Windows 10 (1803) 或更新版本自带的 curl.exe，当前系统没有找到。" -ForegroundColor Red
  return
}

$tmp = Join-Path $env:TEMP ("xn-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null

# 1. Download the app files (keep the user's own config.ini and prompts/*.txt)
Say "下载小宁翻译到 $Dest"
if ($env:XN_SOURCE_DIR) {
  $src = Get-Item $env:XN_SOURCE_DIR          # used by CI to install from the checkout
} else {
  Invoke-WebRequest "https://codeload.github.com/$Repo/zip/refs/heads/main" -OutFile "$tmp\x.zip" -UseBasicParsing
  Expand-Archive "$tmp\x.zip" -DestinationPath "$tmp\x" -Force
  $src = Get-ChildItem "$tmp\x" -Directory | Select-Object -First 1
}
New-Item -ItemType Directory -Path $Dest -Force | Out-Null
Get-ChildItem $src.FullName -Recurse -File | ForEach-Object {
  $rel = $_.FullName.Substring($src.FullName.Length + 1)
  if ($rel -like '.git\*' -or $rel -eq 'config.ini') { return }
  if ($rel -like 'prompts\*.txt' -and $rel -notlike '*.example.txt' -and (Test-Path (Join-Path $Dest $rel))) { return }
  $target = Join-Path $Dest $rel
  New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
  Copy-Item $_.FullName $target -Force
}

# 2. AutoHotkey v2 (free, open source; runs the script) — portable copy, no admin rights needed
$ahkDir = Join-Path $Dest 'AutoHotkey'
$ahkExe = Join-Path $ahkDir 'AutoHotkey64.exe'
if (-not (Test-Path $ahkExe)) {
  Say "下载 AutoHotkey v2（免费开源的 Windows 自动化工具，用来运行小宁翻译）"
  $ahkUrl = $null
  try {
    # official GitHub releases (autohotkey.com sits behind a Cloudflare check that some networks hit)
    $rels = Invoke-RestMethod 'https://api.github.com/repos/AutoHotkey/AutoHotkey/releases?per_page=20' -UseBasicParsing
    $rel = $rels | Where-Object { $_.tag_name -like 'v2.*' -and -not $_.prerelease } | Select-Object -First 1
    $ahkUrl = ($rel.assets | Where-Object { $_.name -like 'AutoHotkey_*.zip' } | Select-Object -First 1).browser_download_url
  } catch {}
  if (-not $ahkUrl) { $ahkUrl = 'https://www.autohotkey.com/download/ahk-v2.zip' }
  Invoke-WebRequest $ahkUrl -OutFile "$tmp\ahk.zip" -UseBasicParsing
  Expand-Archive "$tmp\ahk.zip" -DestinationPath $ahkDir -Force
  if (-not (Test-Path $ahkExe)) { throw "AutoHotkey 下载不完整：$ahkUrl" }
} else {
  Say "已有 AutoHotkey"
}

# 3. API key
$cfg = Join-Path $Dest 'config.ini'
if (-not (Test-Path $cfg)) {
  Say "设置 Claude API Key"
  Write-Host "小宁翻译需要一个 Anthropic（Claude）API Key，形如 sk-ant-...。没有的话直接回车跳过，以后右键托盘图标 → 打开配置文件再填。"
  $quiet = $env:XN_UPDATE -eq '1'   # auto-update runs in a hidden window: never prompt
  if ($env:XN_API_KEY) { $key = $env:XN_API_KEY } elseif ($quiet) { $key = '' } else { $key = Read-Host "API Key" }
  if ($env:XN_ENDPOINT) { $ep = $env:XN_ENDPOINT } elseif ($quiet) { $ep = '' } else { $ep = Read-Host "接口地址（直接回车用官方地址）" }
  if (-not $ep) { $ep = 'https://api.anthropic.com/v1/messages' }
  $ini = "[api]`r`nendpoint=$ep`r`napiKey=$key`r`nmodel=claude-sonnet-5-5`r`n`r`n[state]`r`nlastLanguage=Spanish`r`ntoolbar=1`r`n"
  [IO.File]::WriteAllText($cfg, $ini, (New-Object Text.UnicodeEncoding $false, $true))  # UTF-16 LE with BOM, required by AutoHotkey IniRead
} else {
  Say "已有配置文件 $cfg，保留不动"
}

# 4. Shortcuts: start with Windows, plus Desktop and Start menu icons to (re)start it by hand
$script = Join-Path $Dest 'windows\xiaoning.ahk'
$ico = Join-Path $Dest 'assets\icon\icon.ico'
$ws = New-Object -ComObject WScript.Shell
$links = @(
  (Join-Path ([Environment]::GetFolderPath('Startup')) 'XiaoNing Translate.lnk'),
  (Join-Path ([Environment]::GetFolderPath('Desktop')) '小宁翻译.lnk'),
  (Join-Path ([Environment]::GetFolderPath('Programs')) '小宁翻译.lnk')
)
foreach ($lnk in $links) {
  try {
    $s = $ws.CreateShortcut($lnk)
    $s.TargetPath = $ahkExe
    $s.Arguments = '"' + $script + '"'
    $s.WorkingDirectory = Split-Path $script
    $s.Description = '小宁翻译 XiaoNing Translate'
    if (Test-Path $ico) { $s.IconLocation = "$ico,0" }
    $s.Save()
  } catch { Write-Host "无法创建快捷方式 $lnk：$_" }
}

# 5. (Re)start it
Get-Process -Name AutoHotkey64 -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $ahkExe } | Stop-Process -Force
if ($env:XN_NO_START -ne '1') {
  Say "启动小宁翻译"
  Start-Process -FilePath $ahkExe -ArgumentList ('"' + $script + '"') -WorkingDirectory (Split-Path $script)
}
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "安装完成！小宁翻译已在后台运行（右下角托盘区有橙色对话气泡图标），以后开机会自动启动。" -ForegroundColor Green
Write-Host "如果它没在运行，双击桌面上的「小宁翻译」图标即可重新打开。"
Write-Host "用法：用鼠标选中任意文字，旁边会出现工具条，点「翻译」「译成英文」等按钮即可；Ctrl+Alt+S 截图翻译。"
Write-Host "业务术语提示词（write.txt / read.txt）放到：$Dest\prompts\ ，然后右键托盘图标 → 重新加载。"
