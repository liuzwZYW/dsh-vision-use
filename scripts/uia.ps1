# uia.ps1 — UI Automation layer for dsh-vision
# 借鉴：Yu-tao-Li/dsh-computer-use-win（UIA 控件树定位）、STARDUSTLC666（操作后重新观察）、
#       rayadesune/dsh-ui（坐标映射与审计）、sxwsc667（坐标不进对话）
#
# 输出协议：每行一个 JSON（JSONL），由 lib/index.js 解析。
# 除 Action=invoke 外全部只读。

param(
  [Parameter(Mandatory=$true)]
  [ValidateSet('windows','tree','find','invoke','point','fingerprint','focus')]
  [string]$Action,
  [string]$Name = '',
  [string]$Window = '',
  [int]$Handle = 0,
  [int]$Index = -1,
  [int]$MaxDepth = 5,
  [int]$MaxItems = 150,
  [int]$X = -1,
  [int]$Y = -1,
  [string]$ControlType = '',
  [switch]$EnabledOnly,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$FlagDir = if ($env:DSH_VISION_FLAG_DIR) { $env:DSH_VISION_FLAG_DIR } else { $env:TEMP }
$cancelFlag = Join-Path $FlagDir 'dsh_agent_cancel.flag'
if ($Action -eq 'invoke' -and -not $DryRun) {
  if (Test-Path -LiteralPath $cancelFlag) {
    @{ ok = $false; cancelled = $true; error = 'Esc pressed, operation cancelled' } | ConvertTo-Json -Compress
    exit 9
  }
}

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms

try {
  Add-Type -Namespace Win32 -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, System.UIntPtr e);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr SendMessage(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, System.IntPtr lParam);
'@
} catch { }

$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$CT = [System.Windows.Automation.ControlType]
$walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker

$PID_INVOKE = 10000
$PID_SELECTIONITEM = 10010
$PID_EXPANDCOLLAPSE = 10005
$PID_VALUE = 10002
$PID_TOGGLE = 10015
$PID_TEXT = 10014

function Emit($obj) { [Console]::Out.WriteLine(($obj | ConvertTo-Json -Compress -Depth 6)) }

function Get-Rect($el) {
  try {
    $r = $el.Current.BoundingRectangle
    if ($r.IsEmpty) { return $null }
    if ([double]::IsInfinity($r.X) -or [double]::IsInfinity($r.Y) -or
        [double]::IsInfinity($r.Width) -or [double]::IsInfinity($r.Height)) { return $null }
    if ($r.Width -le 0 -or $r.Height -le 0) { return $null }
    return [ordered]@{
      x  = [int]$r.X
      y  = [int]$r.Y
      w  = [int]$r.Width
      h  = [int]$r.Height
      cx = [int]($r.X + $r.Width / 2)
      cy = [int]($r.Y + $r.Height / 2)
    }
  } catch { return $null }
}

function Get-Patterns($el) {
  $out = @()
  try {
    foreach ($p in $el.GetSupportedPatterns()) {
      switch ($p.Id) {
        $PID_INVOKE { $out += 'invoke' }
        $PID_SELECTIONITEM { $out += 'select' }
        $PID_EXPANDCOLLAPSE { $out += 'expand' }
        $PID_VALUE { $out += 'value' }
        $PID_TOGGLE { $out += 'toggle' }
        $PID_TEXT { $out += 'text' }
      }
    }
  } catch { }
  return $out
}

function Get-ElInfo($el, [int]$depth = 0) {
  try {
    $c = $el.Current
    $h = [ordered]@{
      depth     = $depth
      type      = ($c.ControlType.ProgrammaticName -replace '^ControlType\.', '')
      name      = [string]$c.Name
      autoId    = [string]$c.AutomationId
      cls       = [string]$c.ClassName
      enabled   = [bool]$c.IsEnabled
      offscreen = [bool]$c.IsOffscreen
    }
    $r = Get-Rect $el
    if ($r) { $h.rect = $r }
    $pats = Get-Patterns $el
    if ($pats.Count -gt 0) { $h.patterns = $pats }
    return $h
  } catch { return $null }
}

function Get-TopWindows {
  $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Window)
  $wins = $AE::RootElement.FindAll($TS::Children, $cond)
  $fore = $null
  try { $fore = [Win32.Native]::GetForegroundWindow() } catch { }
  $fgVal = if ($fore) { $fore.ToInt64() } else { 0 }
  $list = @()
  foreach ($w in $wins) {
    $r = Get-Rect $w
    if (-not $r) { continue }
    $c = $w.Current
    $hwnd = [int]$c.NativeWindowHandle
    $list += [ordered]@{
      hwnd       = $hwnd
      title      = [string]$c.Name
      pid        = [int]$c.ProcessId
      cls        = [string]$c.ClassName
      rect       = $r
      foreground = ($hwnd -ne 0 -and $fgVal -eq $hwnd)
    }
  }
  return $list
}

function Resolve-TargetWindow {
  $all = Get-TopWindows
  if ($Handle -ne 0) {
    $hit = $all | Where-Object { $_.hwnd -eq $Handle }
    if ($hit) { return $hit }
    try {
      $el = $AE::FromHandle([IntPtr]$Handle)
      return [ordered]@{ hwnd = $Handle; title = $el.Current.Name; pid = $el.Current.ProcessId; cls = $el.Current.ClassName; rect = (Get-Rect $el); foreground = $false }
    } catch { return $null }
  }
  if ($Window -ne '') {
    $hit = $all | Where-Object { $_.title -like "*$Window*" } |
      Sort-Object @{ Expression = { if ($_.foreground) { 0 } else { 1 } } }, @{ Expression = { -1 * ($_.rect.w * $_.rect.h) } } | Select-Object -First 1
    if ($hit) { return $hit }
    return $null
  }
  $fg = $all | Where-Object { $_.foreground } | Select-Object -First 1
  if ($fg) { return $fg }
  return ($all | Sort-Object @{ Expression = { $_.rect.w * $_.rect.h } } -Descending | Select-Object -First 1)
}

# Chromium/Electron 默认不暴露完整 UIA 树：发 WM_GETOBJECT(OBJID_CLIENT) 唤醒无障碍层。
# 来源：Yu-tao-Li/dsh-computer-use-win issue #50 的同类处理。
function Wake-Uia([int]$hwnd) {
  if ($hwnd -eq 0) { return }
  try {
    [Win32.Native]::SendMessage([IntPtr]$hwnd, 0x003D, [IntPtr]::Zero, [IntPtr](-4)) | Out-Null
    Start-Sleep -Milliseconds 320
  } catch { }
}

# 优先用 UIA pattern 操作控件（完全不移动鼠标）；全部不可用时返回 $null，由调用方退化为鼠标点击。
function Invoke-ByPattern($el) {
  try { $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); return 'invoke-pattern' } catch { }
  try { $el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle(); return 'toggle-pattern' } catch { }
  try { $el.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select(); return 'selection-pattern' } catch { }
  try {
    $p = $el.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    if ($p.Current.ExpandCollapseState -eq [System.Windows.Automation.ExpandCollapseState]::Expanded) { $p.Collapse() } else { $p.Expand() }
    return 'expand-pattern'
  } catch { }
  return $null
}
function Match-El($info, [string]$needle) {
  if ([string]::IsNullOrEmpty($needle)) { return $true }
  $n = $needle.ToLower()
  if ($info.name -and $info.name.ToLower().Contains($n)) { return $true }
  if ($info.autoId -and $info.autoId.ToLower().Contains($n)) { return $true }
  if ($info.cls -and $info.cls.ToLower().Contains($n)) { return $true }
  return $false
}

function Walk-Tree($rootEl, [int]$maxDepth, [int]$maxItems) {
  $count = 0
  $stack = New-Object System.Collections.Stack
  $child = $walker.GetFirstChild($rootEl)
  while ($child -ne $null) { $stack.Push(@($child, 1)); $child = $walker.GetNextSibling($child) }
  while ($stack.Count -gt 0 -and $count -lt $maxItems) {
    $pair = $stack.Pop()
    $el = $pair[0]; $d = $pair[1]
    if ($d -gt $maxDepth) { continue }
    $info = Get-ElInfo $el $d
    if ($info) {
      if ((-not $EnabledOnly) -or $info.enabled) {
        if ($ControlType -eq '' -or $info.type -eq $ControlType) { Emit $info; $count++ }
      }
    }
    if ($d -lt $maxDepth) {
      $ch = $walker.GetFirstChild($el)
      while ($ch -ne $null) { $stack.Push(@($ch, $d + 1)); $ch = $walker.GetNextSibling($ch) }
    }
  }
  return $count
}

switch ($Action) {

  'windows' {
    $list = Get-TopWindows
    Emit ([ordered]@{ ok = $true; count = $list.Count; windows = $list })
    break
  }

  'tree' {
    $w = Resolve-TargetWindow
    if (-not $w) { Emit ([ordered]@{ ok = $false; error = 'no matching window' }); exit 0 }
    Emit ([ordered]@{ ok = $true; window = [ordered]@{ hwnd = $w.hwnd; title = $w.title; pid = $w.pid } })
    Wake-Uia $w.hwnd
    $el = $AE::FromHandle([IntPtr]$w.hwnd)
    $n = Walk-Tree $el $MaxDepth $MaxItems
    Emit ([ordered]@{ ok = $true; emitted = $n; maxDepth = $MaxDepth; maxItems = $MaxItems; truncated = ($n -ge $MaxItems) })
    break
  }

  'find' {
    $w = Resolve-TargetWindow
    if (-not $w) { Emit ([ordered]@{ ok = $false; error = 'no matching window' }); exit 0 }
    Wake-Uia $w.hwnd
    $el = $AE::FromHandle([IntPtr]$w.hwnd)
    $hits = @()
    $count = 0
    $stack = New-Object System.Collections.Stack
    $c0 = $walker.GetFirstChild($el)
    while ($c0 -ne $null) { $stack.Push(@($c0, 1)); $c0 = $walker.GetNextSibling($c0) }
    while ($stack.Count -gt 0 -and $count -lt 800) {
      $pair = $stack.Pop(); $e = $pair[0]; $d = $pair[1]
      $count++
      if ($d -le $MaxDepth) {
        $info = Get-ElInfo $e $d
        if ($info -and (Match-El $info $Name)) {
          if ((-not $EnabledOnly) -or $info.enabled) {
            if ($ControlType -eq '' -or $info.type -eq $ControlType) {
              $hits += [ordered]@{
                index     = $hits.Count
                type      = $info.type
                name      = $info.name
                autoId    = $info.autoId
                cls       = $info.cls
                enabled   = $info.enabled
                offscreen = $info.offscreen
                rect      = $info.rect
                patterns  = $(if ($info.patterns) { $info.patterns } else { @() })
              }
            }
          }
        }
        $ch = $walker.GetFirstChild($e)
        while ($ch -ne $null) { $stack.Push(@($ch, $d + 1)); $ch = $walker.GetNextSibling($ch) }
      }
    }
    Emit ([ordered]@{ ok = $true; window = [ordered]@{ hwnd = $w.hwnd; title = $w.title }; scanned = $count; hits = $hits.Count; matches = $hits })
    break
  }

  'point' {
    if ($X -lt 0 -or $Y -lt 0) { Emit ([ordered]@{ ok = $false; error = '-X -Y required' }); exit 0 }
    $pt = New-Object System.Windows.Point($X, $Y)
    try {
      $el = $AE::FromPoint($pt)
      Emit ([ordered]@{ ok = $true; x = $X; y = $Y; element = (Get-ElInfo $el 0) })
    } catch {
      Emit ([ordered]@{ ok = $false; error = $_.Exception.Message })
    }
    break
  }

  'invoke' {
    $w = Resolve-TargetWindow
    if (-not $w) { Emit ([ordered]@{ ok = $false; error = 'no matching window' }); exit 0 }
    Wake-Uia $w.hwnd
    $el0 = $AE::FromHandle([IntPtr]$w.hwnd)
    $cands = @()
    $stack = New-Object System.Collections.Stack
    $c0 = $walker.GetFirstChild($el0)
    while ($c0 -ne $null) { $stack.Push(@($c0, 1)); $c0 = $walker.GetNextSibling($c0) }
    $scanned = 0
    while ($stack.Count -gt 0 -and $scanned -lt 800) {
      $pair = $stack.Pop(); $e = $pair[0]; $d = $pair[1]
      $scanned++
      if ($d -le $MaxDepth) {
        $info = Get-ElInfo $e $d
        if ($info -and (Match-El $info $Name) -and $info.enabled -and $info.rect) {
          $cands += [pscustomobject]@{ el = $e; info = $info }
        }
        $ch = $walker.GetFirstChild($e)
        while ($ch -ne $null) { $stack.Push(@($ch, $d + 1)); $ch = $walker.GetNextSibling($ch) }
      }
    }
    if ($cands.Count -eq 0) {
      Emit ([ordered]@{ ok = $false; error = "no enabled control matching '$Name'"; scanned = $scanned })
      exit 0
    }
    $pickIdx = if ($Index -ge 0 -and $Index -lt $cands.Count) { $Index } else { 0 }
    $pick = $cands[$pickIdx]
    $info = $pick.info
    if ($DryRun) {
      Emit ([ordered]@{ ok = $true; dryRun = $true; would = 'invoke'; matched = $info; candidates = $cands.Count })
      break
    }
    $how = Invoke-ByPattern $pick.el
    if (-not $how) {
      try {
        $cp = New-Object System.Windows.Point($info.rect.cx, $info.rect.cy)
        try { $cp = $pick.el.GetClickablePoint() } catch { }
        [Win32.Native]::SetCursorPos([int]$cp.X, [int]$cp.Y) | Out-Null
        Start-Sleep -Milliseconds 60
        [Win32.Native]::mouse_event(0x0002, 0, 0, 0, [System.UIntPtr]::Zero)
        Start-Sleep -Milliseconds 40
        [Win32.Native]::mouse_event(0x0004, 0, 0, 0, [System.UIntPtr]::Zero)
        $how = 'mouse-click'
      } catch {
        Emit ([ordered]@{ ok = $false; error = "control not invokable: $($_.Exception.Message)"; matched = $info })
        exit 0
      }
    }
    Start-Sleep -Milliseconds 220
    # toggle 类控件（加粗/开关）结构不变，指纹抓不到变化 —— 直接读 ToggleState 作为操作回执
    $toggleState = $null
    try {
      $tp = $pick.el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
      $toggleState = $tp.Current.ToggleState.ToString()
    } catch { }
    $expanded = $null
    try {
      $ep = $pick.el.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
      $expanded = $ep.Current.ExpandCollapseState.ToString()
    } catch { }
    Emit ([ordered]@{ ok = $true; how = $how; matched = $info; candidates = $cands.Count; pickIndex = $pickIdx; toggleState = $toggleState; expandState = $expanded })
    break
  }

  'focus' {
    $w = Resolve-TargetWindow
    if (-not $w) { Emit ([ordered]@{ ok = $false; error = 'no matching window' }); exit 0 }
    try {
      $fe = [System.Windows.Automation.AutomationElement]::FocusedElement
      Emit ([ordered]@{ ok = $true; window = [ordered]@{ hwnd = $w.hwnd; title = $w.title }; focused = $(if ($fe) { Get-ElInfo $fe 0 } else { $null }) })
    } catch {
      Emit ([ordered]@{ ok = $false; error = $_.Exception.Message })
    }
    break
  }

  'fingerprint' {
    $fg = Resolve-TargetWindow
    $focused = $null
    try {
      $fe = [System.Windows.Automation.AutomationElement]::FocusedElement
      if ($fe) { $focused = Get-ElInfo $fe 0 }
    } catch {}
    $interactive = 0
    $names = @()
    if ($fg) {
      try {
        $el = $AE::FromHandle([IntPtr]$fg.hwnd)
        $stack = New-Object System.Collections.Stack
        $c0 = $walker.GetFirstChild($el)
        while ($c0 -ne $null) { $stack.Push(@($c0, 1)); $c0 = $walker.GetNextSibling($c0) }
        $seen = 0
        while ($stack.Count -gt 0 -and $seen -lt 300) {
          $pair = $stack.Pop(); $e = $pair[0]; $d = $pair[1]
          $seen++
          if ($d -le 3) {
            $info = Get-ElInfo $e $d
            if ($info -and $info.patterns -and $info.patterns.Count -gt 0) { $interactive++ }
            if ($info -and $info.name) { $names += $info.name }
            $ch = $walker.GetFirstChild($e)
            while ($ch -ne $null) { $stack.Push(@($ch, $d + 1)); $ch = $walker.GetNextSibling($ch) }
          }
        }
      } catch {}
    }
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $hash = [System.BitConverter]::ToString(
      $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(($names -join '|')))
    ).Replace('-', '').Substring(0, 12)
    Emit ([ordered]@{
        ok          = $true
        ts          = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        window      = $(if ($fg) { [ordered]@{ hwnd = $fg.hwnd; title = $fg.title; pid = $fg.pid } } else { $null })
        focused     = $focused
        interactive = $interactive
        names       = $names.Count
        fingerprint = $hash
      })
    break
  }

  default {
    Emit ([ordered]@{ ok = $false; error = "unknown action: $Action" })
    exit 1
  }
}
