# dpi.ps1 —— 统一 DPI 语义：截图 / 鼠标 / 覆盖层全部使用同一套「物理像素」
#
# 用法（必须在任何 System.Windows.Forms / System.Drawing / 窗口创建之前）：
#     . (Join-Path $PSScriptRoot 'dpi.ps1')
#     Enable-DshDpi | Out-Null
#     $scale = Get-DshDpiScale        # 例：200% 缩放 => 2.0
#
# 背景（本文件存在的唯一理由）：
#   未声明 DPI 感知的 PowerShell 进程会被 Windows 做 DPI 虚拟化，于是
#     * SystemInformation.VirtualScreen 只报告「逻辑分辨率」(物理 / scale)，
#       CopyFromScreen 也只拿到物理屏幕左上 1/scale 的区域 → Agent 视野缺了一大块，
#       且截图坐标与真实屏幕坐标不是同一套（缩放比 ≠ 1 时必然点偏）；
#     * 覆盖层窗口同样只铺满左上 1/scale，线条/字号还按 96dpi 绘制，
#       合成时被系统拉伸 → 又细、又虚、又偏。
#   声明 Per-Monitor-V2 之后：
#     * VirtualScreen / CopyFromScreen = 真实物理分辨率，1:1 无重采样；
#     * GetCursorPos / SetCursorPos 本来就是物理像素，于是三者对齐，
#       截图上的像素坐标可以直接喂给 computer_click / computer_move。

if (-not ('Dsh.Dpi' -as [type])) {
  Add-Type -Namespace Dsh -Name Dpi -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(System.IntPtr v);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetThreadDpiAwarenessContext();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int GetAwarenessFromDpiAwarenessContext(System.IntPtr c);
[System.Runtime.InteropServices.DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int v);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetDC(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("gdi32.dll")] public static extern int GetDeviceCaps(System.IntPtr dc, int i);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int ReleaseDC(System.IntPtr h, System.IntPtr dc);

// 逐级降级：PMv2 -> PMv1 -> shcore PM -> 系统 DPI 感知
public static bool Enable() {
  try { if (SetProcessDpiAwarenessContext(new System.IntPtr(-4))) return true; } catch { }
  try { if (SetProcessDpiAwarenessContext(new System.IntPtr(-3))) return true; } catch { }
  try { if (SetProcessDpiAwareness(2) == 0) return true; } catch { }
  try { if (SetProcessDPIAware()) return true; } catch { }
  return false;
}

public static int Awareness() {
  try { return GetAwarenessFromDpiAwarenessContext(GetThreadDpiAwarenessContext()); } catch { return -1; }
}

// 系统（主屏）DPI：96 / 120 / 144 / 192 ...
public static int SystemDpi() {
  int dpi = 96;
  try {
    System.IntPtr dc = GetDC(System.IntPtr.Zero);
    dpi = GetDeviceCaps(dc, 88);
    ReleaseDC(System.IntPtr.Zero, dc);
  } catch { }
  if (dpi <= 0) { dpi = 96; }
  return dpi;
}
'@
}

function Enable-DshDpi {
  $ok = $false
  try { $ok = [Dsh.Dpi]::Enable() } catch { $ok = $false }
  return $ok
}

function Get-DshDpiAwareness { try { return [Dsh.Dpi]::Awareness() } catch { return -1 } }

# 逻辑像素 -> 物理像素的倍率（200% 缩放 = 2.0）
function Get-DshDpiScale {
  $dpi = 96
  try { $dpi = [Dsh.Dpi]::SystemDpi() } catch { $dpi = 96 }
  if ($dpi -le 0) { $dpi = 96 }
  return [double]$dpi / 96.0
}
