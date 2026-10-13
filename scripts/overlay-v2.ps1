param(
  [ValidateSet('start','stop','status')][string]$Action = 'start',
  [int]$MaxSeconds = 0,
  [int]$IdleSeconds = 30,
  [switch]$NoCursorChange,
  [int]$HaloSize = 140,
  [int]$IntervalMs = 16
)
$ErrorActionPreference = 'Stop'
$FlagDir = if ($env:DSH_VISION_FLAG_DIR) { $env:DSH_VISION_FLAG_DIR } else { $env:TEMP }
$BOOTLOG = Join-Path $FlagDir 'ov_boot.log'
function BootLog([string]$m) { try { Add-Content -LiteralPath $BOOTLOG -Value ((Get-Date).ToString('HH:mm:ss') + ' ' + $m) -ErrorAction SilentlyContinue } catch {} }
BootLog ("boot action=" + $Action)
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { BootLog ("console-encoding-skip: " + $_.Exception.Message) }
# ---- DPI：覆盖层按物理像素 1:1 绘制（必须在加载 WinForms / 建任何窗口之前）----
# 未声明 DPI 感知时：VirtualScreen 只有物理屏的左上 1/scale，边框只铺满那一小块，
# 线条/字号又按 96dpi 画，合成时被系统拉伸 → 又偏又糊。这里统一到物理像素。
. (Join-Path $PSScriptRoot 'dpi.ps1')
Enable-DshDpi | Out-Null
$DpiScale = Get-DshDpiScale
if ($DpiScale -le 0) { $DpiScale = 1.0 }
BootLog ("dpi scale=" + $DpiScale + " awareness=" + (Get-DshDpiAwareness))
Add-Type -AssemblyName System.Windows.Forms
if ($PSVersionTable.PSEdition -eq 'Core') {
  Add-Type -AssemblyName System.Drawing.Common    # PS7(.NET) 下 GDI+ 的真正实现程序集
} else {
  Add-Type -AssemblyName System.Drawing
}

# ================= C# 动画引擎（热路径全在编译代码里，PowerShell 只敲节拍）=================
$engCode = @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern short GetAsyncKeyState(int v);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetDC(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int ReleaseDC(System.IntPtr h, System.IntPtr dc);
[System.Runtime.InteropServices.DllImport("gdi32.dll")] public static extern System.IntPtr CreateCompatibleDC(System.IntPtr hdc);
[System.Runtime.InteropServices.DllImport("gdi32.dll")] public static extern System.IntPtr SelectObject(System.IntPtr hdc, System.IntPtr o);
[System.Runtime.InteropServices.DllImport("gdi32.dll")] public static extern bool DeleteDC(System.IntPtr hdc);
[System.Runtime.InteropServices.DllImport("gdi32.dll")] public static extern bool DeleteObject(System.IntPtr o);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool UpdateLayeredWindow(System.IntPtr hwnd, System.IntPtr dstDc, ref POINT dst, ref SIZE size, System.IntPtr srcDc, ref POINT src, int key, ref BLENDFUNCTION blend, int flags);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetSystemCursor(System.IntPtr hcur, uint id);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Auto)] public static extern System.IntPtr LoadCursorFromFile(string f);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a, uint b, System.IntPtr c, uint d);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern void keybd_event(byte v, byte s, uint f, System.UIntPtr e);
public struct POINT { public int X; public int Y; }
public struct SIZE { public int cx; public int cy; }
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, Pack=1)]
public struct BLENDFUNCTION { public byte BlendOp; public byte BlendFlags; public byte SourceConstantAlpha; public byte AlphaFormat; }

static System.IntPtr _hwnd = System.IntPtr.Zero;
static int _size = 220;
static float _scale = 1f;
static System.Drawing.Bitmap _bmp;
static System.Drawing.Graphics _g;
static string _mode = "idle";
static int _aR = 220, _aG = 38, _aB = 38;
static int _bR = 252, _bG = 165, _bB = 165;
static int _glow = 150;
static float _rippleT = 0f;
static int[] _keyVks = null;
static int _modeUntil = 0;
static string _autoMode = "idle";
static bool _prevMouse = false;
static float _vis = 0f;
static POINT _lastPos = new POINT();
static int _lastMoveTick = 0;
static bool _visInit = false;
static System.IntPtr _rHwnd = System.IntPtr.Zero;
static System.Drawing.Bitmap _rBmp;
static System.Drawing.Graphics _rG;
static int _rSize = 120;
static float _rScale = 1f;
static int _rX = 0, _rY = 0;
static bool _rShown = false;
static bool _hwndShown = true;
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int n);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
// 把覆盖层窗口重新提到最前：用户可能开着 Always-on-Top 的应用（实测 VS Code 置顶会把整条边框盖掉，
// 徽章因为状态变化时会被重绘才幸存）。SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE，不抢焦点。
public static void Raise(System.IntPtr h) {
  if (h == System.IntPtr.Zero) return;
  SetWindowPos(h, new System.IntPtr(-1), 0, 0, 0, 0, 0x0002u | 0x0001u | 0x0010u);
}

public static void Init(System.IntPtr hwnd, int size, float scale) {
  _hwnd = hwnd; _size = size;
  _scale = (scale <= 0f) ? 1f : scale;
  // 位图按物理像素分配，绘制沿用 96dpi 逻辑坐标并由变换放大 —— 与 DPI 一致且不发虚
  int px = (int)System.Math.Ceiling(size * _scale);
  _bmp = new System.Drawing.Bitmap(px, px, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
  _bmp.SetResolution(96f, 96f);   // 与逻辑坐标系一致（否则 DPI 感知进程里 DpiY=192，将来在光环上画字会大一倍）
  _g = System.Drawing.Graphics.FromImage(_bmp);
  _g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
  _g.ScaleTransform(_scale, _scale);
  _g.Clear(System.Drawing.Color.Transparent);
  SetMode("idle");
}
public static void SetMode(string m) {
  _mode = m;
  if (m == "typing") { _aR = 239; _aG = 68; _aB = 68; _bR = 254; _bG = 202; _bB = 202; _glow = 165; }
  else if (m == "clicking") { _aR = 185; _aG = 28; _aB = 28; _bR = 252; _bG = 165; _bB = 165; _glow = 190; }
  else { _aR = 220; _aG = 38; _aB = 38; _bR = 252; _bG = 165; _bB = 165; _glow = 150; }
}
public static void Ripple(int x, int y) { _rX = x; _rY = y; _rippleT = 1f; }
public static void Tick() {
  int now = System.Environment.TickCount;
  POINT p; GetCursorPos(out p);
  if (!_visInit) { _lastPos = p; _lastMoveTick = now; _visInit = true; }
  if (p.X != _lastPos.X || p.Y != _lastPos.Y) { _lastPos = p; _lastMoveTick = now; }
  if (_keyVks == null) {
    var list = new System.Collections.Generic.List<int>();
    for (int vk = 0x41; vk <= 0x5A; vk++) list.Add(vk);
    for (int vk = 0x30; vk <= 0x39; vk++) list.Add(vk);
    foreach (int vk in new int[] { 0x20, 0x08, 0x0D, 0x09, 0x10, 0x11, 0x12, 0x14, 0x2E, 0x25, 0x26, 0x27, 0x28, 0xBC, 0xBE, 0xBD, 0x6E, 0x6A, 0x6B, 0x6D, 0x6F, 0xBA, 0xBB, 0xDB, 0xDD, 0xDC }) list.Add(vk);
    _keyVks = list.ToArray();
  }
  // ---- 鼠标按下：点击态 + 在点击位置生成涟漪 ----
  bool mdown = ((GetAsyncKeyState(0x01) & 0x8000) != 0) || ((GetAsyncKeyState(0x02) & 0x8000) != 0);
  if (mdown) {
    if (!_prevMouse) { _rX = p.X; _rY = p.Y; _rippleT = 1f; }
    _modeUntil = now + 360; _autoMode = "clicking";
  }
  _prevMouse = mdown;
  // ---- 键盘按下：输入态 ----
  bool typed = false;
  for (int i = 0; i < _keyVks.Length; i++) { if ((GetAsyncKeyState(_keyVks[i]) & 0x8000) != 0) { typed = true; break; } }
  if (typed) { _modeUntil = now + 800; _autoMode = "typing"; }
  if (now > _modeUntil) _autoMode = "idle";
  if (_autoMode != _mode) SetMode(_autoMode);
  // ---- 涟漪窗口：独立生命周期，钉在点击位置，不受光标移动影响 ----
  if (_rippleT > 0f) {
    if (!_rShown) { ShowWindow(_rHwnd, 4); _rShown = true; }
    RenderRippleWindow();
    _rippleT -= 0.024f;
    if (_rippleT <= 0f) { _rippleT = 0f; if (_rShown) { ShowWindow(_rHwnd, 0); _rShown = false; } }
  } else if (_rShown) { ShowWindow(_rHwnd, 0); _rShown = false; }
  // ---- 光环可见度：模式非 idle 或鼠标刚动过 -> 显示；静置 1s -> 淡出 ----
  bool active = _autoMode != "idle" || (now - _lastMoveTick < 1000);
  _vis += ((active ? 1f : 0f) - _vis) * 0.14f;
  if (_vis < 0.02f) _vis = 0f;
  if (_vis <= 0f) { if (_hwndShown) { _hwndShown = false; ShowWindow(_hwnd, 0); } return; }
  if (!_hwndShown) { _hwndShown = true; ShowWindow(_hwnd, 4); }
  // ---- 渲染光环 ----
  float cx = _size / 2f, cy = _size / 2f;
  _g.Clear(System.Drawing.Color.Transparent);
  using (var gp = new System.Drawing.Drawing2D.GraphicsPath()) {
    gp.AddEllipse(0, 0, _size, _size);
    using (var pg = new System.Drawing.Drawing2D.PathGradientBrush(gp)) {
      pg.CenterPoint = new System.Drawing.PointF(cx, cy);
      pg.CenterColor = System.Drawing.Color.FromArgb((int)(_glow * _vis), _aR, _aG, _aB);
      pg.SurroundColors = new System.Drawing.Color[] { System.Drawing.Color.FromArgb(0, _aR, _aG, _aB) };
      _g.FillPath(pg, gp);
    }
  }
  float pulse = (float)((System.Math.Sin(now * 0.0047) + 1.0) / 2.0);
  float rr = 7.5f + pulse * 0.8f;
  using (var pen = new System.Drawing.Pen(System.Drawing.Color.FromArgb((int)(215 * _vis), _bR, _bG, _bB), 2.0f))
    _g.DrawEllipse(pen, cx - rr, cy - rr, rr * 2, rr * 2);
  if (_mode == "typing") {
    using (var pen = new System.Drawing.Pen(System.Drawing.Color.FromArgb((int)(240 * _vis), 255, 255, 255), 2.0f))
      _g.DrawLine(pen, cx, cy - 3.5f, cx, cy + 3.5f);
  } else {
    using (var b = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb((int)(242 * _vis), 255, 255, 255)))
      _g.FillEllipse(b, cx - 1.4f, cy - 1.4f, 2.8f, 2.8f);
  }
  PushFrame(p.X - (int)System.Math.Round(_size * _scale / 2f), p.Y - (int)System.Math.Round(_size * _scale / 2f));
}
static void PushFrame(int x, int y) {
  System.IntPtr sdc = GetDC(System.IntPtr.Zero);
  System.IntPtr mdc = CreateCompatibleDC(sdc);
  System.IntPtr hb = _bmp.GetHbitmap(System.Drawing.Color.FromArgb(0));
  System.IntPtr ob = SelectObject(mdc, hb);
  SIZE sz = new SIZE(); sz.cx = _bmp.Width; sz.cy = _bmp.Height;
  POINT src = new POINT(); src.X = 0; src.Y = 0;
  POINT dst = new POINT(); dst.X = x; dst.Y = y;
  BLENDFUNCTION bf = new BLENDFUNCTION(); bf.BlendOp = 0; bf.BlendFlags = 0; bf.SourceConstantAlpha = 255; bf.AlphaFormat = 1;
  UpdateLayeredWindow(_hwnd, sdc, ref dst, ref sz, mdc, ref src, 0, ref bf, 2);
  SelectObject(mdc, ob); DeleteObject(hb); DeleteDC(mdc); ReleaseDC(System.IntPtr.Zero, sdc);
}
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int GetWindowLong(System.IntPtr h, int i);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int SetWindowLong(System.IntPtr h, int i, int v);
public static int GetWindowLongSafe(System.IntPtr h) { return GetWindowLong(h, -20); }
public static int SetWindowLongSafe(System.IntPtr h, int ex) { return SetWindowLong(h, -20, ex | 0x00080000 | 0x00000020 | 0x08000000 | 0x00000080); }
public static bool PushRaw(System.IntPtr hwnd, System.IntPtr hb, int w, int h, int x, int y) {
  System.IntPtr sdc = GetDC(System.IntPtr.Zero);
  System.IntPtr mdc = CreateCompatibleDC(sdc);
  System.IntPtr ob = SelectObject(mdc, hb);
  SIZE sz = new SIZE(); sz.cx = w; sz.cy = h;
  POINT src = new POINT(); POINT dst = new POINT(); dst.X = x; dst.Y = y;
  BLENDFUNCTION bf = new BLENDFUNCTION(); bf.BlendOp = 0; bf.BlendFlags = 0; bf.SourceConstantAlpha = 255; bf.AlphaFormat = 1;
  bool ok = UpdateLayeredWindow(hwnd, sdc, ref dst, ref sz, mdc, ref src, 0, ref bf, 2);
  SelectObject(mdc, ob); DeleteDC(mdc); ReleaseDC(System.IntPtr.Zero, sdc);
  return ok;
}
public static void InitRipple(System.IntPtr hwnd, int size, float scale) {
  _rHwnd = hwnd; _rSize = size;
  _rScale = (scale <= 0f) ? 1f : scale;
  int px = (int)System.Math.Ceiling(size * _rScale);
  _rBmp = new System.Drawing.Bitmap(px, px, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
  _rBmp.SetResolution(96f, 96f);
  _rG = System.Drawing.Graphics.FromImage(_rBmp);
  _rG.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
  _rG.ScaleTransform(_rScale, _rScale);
}
static void PushBitmapAt(System.IntPtr hwnd, System.Drawing.Bitmap bmp, int x, int y) {
  System.IntPtr hb = bmp.GetHbitmap(System.Drawing.Color.FromArgb(0));
  PushRaw(hwnd, hb, bmp.Width, bmp.Height, x, y);
  DeleteObject(hb);
}
static void RenderRippleWindow() {
  if (_rBmp == null) return;
  _rG.Clear(System.Drawing.Color.Transparent);
  float c = _rSize / 2f;
  float e = 1f - _rippleT;                       // 0 -> 1
  for (int k = 0; k < 3; k++) {
    float ph = e - k * 0.16f;
    if (ph <= 0f) continue;
    if (ph > 1f) ph = 1f;
    float r = 7f + 35f * ph;
    int a = (int)(235 * (1f - ph) * (1f - ph));
    if (a <= 1) continue;
    using (var pen = new System.Drawing.Pen(System.Drawing.Color.FromArgb(a, 239, 68, 68), 1.4f - k * 0.25f))
      _rG.DrawEllipse(pen, c - r, c - r, r * 2, r * 2);
  }
  float fr = 2.0f + 1.4f * _rippleT;
  using (var b = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb((int)(230 * _rippleT), 254, 202, 202)))
    _rG.FillEllipse(b, c - fr, c - fr, fr * 2, fr * 2);
  PushBitmapAt(_rHwnd, _rBmp, _rX - (int)System.Math.Round(_rSize * _rScale / 2f), _rY - (int)System.Math.Round(_rSize * _rScale / 2f));
}
public static string GetMode() { return _autoMode; }
public static int EscDown() { return (GetAsyncKeyState(0x1B) & 0x8000) != 0 ? 1 : 0; }

// ==================== 边缘柔光（贴边矩形距离场）====================
// 光晕直接贴住屏幕边缘：不留内侧空白，也没有单独的最亮描边线。
//   d = 到最近屏幕边缘的距离（矩形距离场，直角天然正确，四角与四边等浓度）
//   alpha = peak * exp(-d^2 / (2*sigma^2))
// 完全平滑（没有叠线造成的条纹），整屏 3072x1920 约 200-300ms。
public static System.Drawing.Bitmap RenderFrame(int w, int h, float scale, bool cancelled) {
  System.Drawing.Bitmap bmp = new System.Drawing.Bitmap(w, h, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
  bmp.SetResolution(96f, 96f);
  System.Drawing.Rectangle rect = new System.Drawing.Rectangle(0, 0, w, h);
  System.Drawing.Imaging.BitmapData data = bmp.LockBits(rect, System.Drawing.Imaging.ImageLockMode.WriteOnly, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
  try {
    int stride = data.Stride;
    byte[] buf = new byte[stride * h];
    float sigma = 15f * scale;                 // 向内衰减宽度（逻辑 15px）
    float peak = 158f;                         // 贴边处的峰值 alpha
    float inv2s2 = 1f / (2f * sigma * sigma);
    // 边缘形状 = "贴住屏幕边缘的圆角矩形"距离场：四条直边贴边，四角以 cornerRadius 圆弧过渡。
    float cornerRadius = 40f * scale;          // 四角圆角半径（逻辑 40px）
    float ccx = w * 0.5f, ccy = h * 0.5f;
    float hx = ccx - cornerRadius, hy = ccy - cornerRadius;
    // 圆角把屏幕角切到了轮廓之外（角点 d≈0.41R），只按几何走会让角部光带变窄变淡。
    // 因此对靠近角的像素把有效距离按比例压小（乘性）：角部光带整体加厚、向屏幕内侧扩展，
    // 直边 g≈0 完全不受影响。
    float cornerBoost = 0.55f;                 // 角部距离压缩比例
    float cornerSigma = cornerRadius;          // 判定"靠近角"的范围
    float invCorner = 1f / (2f * cornerSigma * cornerSigma);
    // 起始（贴边）颜色：Codex computer-use 风格的红；取消态用琥珀以示区分。向内由 alpha 衰减自然变浅
    int cr = cancelled ? 245 : 185, cg = cancelled ? 158 : 28, cb = cancelled ? 11 : 28;
    for (int y = 0; y < h; y++) {
      float py = y + 0.5f - ccy; if (py < 0f) py = -py;
      float qy = py - hy; float ky = qy > 0f ? qy : 0f;
      float my = y + 0.5f; float my2 = h - (y + 0.5f); if (my2 < my) my = my2;   // 到最近水平边的距离
      int row = y * stride;
      for (int x = 0; x < w; x++) {
        float px = x + 0.5f - ccx; if (px < 0f) px = -px;
        float qx = px - hx; float kx = qx > 0f ? qx : 0f;
        // 标准圆角矩形 SDF：d=0 在轮廓上（直边贴屏幕边缘、四角是半径 cornerRadius 的圆弧）
        float d = (float)System.Math.Sqrt(kx * kx + ky * ky)
                + System.Math.Min(System.Math.Max(qx, qy), 0f) - cornerRadius;
        float mx = x + 0.5f; float mx2 = w - (x + 0.5f); if (mx2 < mx) mx = mx2;   // 到最近垂直边的距离
        float far1 = mx > my ? mx : my;   // 到"较远那条边"的距离：角部小、直边大
        float g = (float)System.Math.Exp(-far1 * far1 * invCorner);
        float dEff = d * (1f - cornerBoost * g);
        float a = peak * (float)System.Math.Exp(-dEff * dEff * inv2s2);
        if (a < 0.6f) continue;
        if (a > 255f) a = 255f;
        int o = row + x * 4;
        buf[o] = (byte)cb;
        buf[o + 1] = (byte)cg;
        buf[o + 2] = (byte)cr;
        buf[o + 3] = (byte)(a + 0.5f);
      }
    }
    System.Runtime.InteropServices.Marshal.Copy(buf, 0, data.Scan0, buf.Length);
  } finally {
    bmp.UnlockBits(data);
  }
  return bmp;
}
'@

# 编译引擎：PS5.1(.NET Framework) 直接引用 System.Drawing；
# PS7(.NET Core) 里 System.Drawing 只是类型转发程序集，需要 .NET 的"引用程序集"包
# ($PSHOME\ref，提供 System.Runtime/System.Collections 等) 再加上 GDI+/WinForms 的实现程序集。
if ($PSVersionTable.PSEdition -eq 'Core') {
  $engRefs = @()
  $refDir = Join-Path $PSHOME 'ref'
  if (Test-Path -LiteralPath $refDir) {
    $engRefs += (Get-ChildItem -LiteralPath $refDir -Filter '*.dll' | Select-Object -ExpandProperty FullName)
  }
  $engRefs += @(
    [System.Drawing.Bitmap].Assembly.Location,
    [System.Drawing.Size].Assembly.Location,
    [System.Windows.Forms.Form].Assembly.Location
  )
  $engRefs = $engRefs | Where-Object { $_ } | Select-Object -Unique
  Add-Type -Namespace CU -Name Eng -ReferencedAssemblies $engRefs -MemberDefinition $engCode
} else {
  Add-Type -Namespace CU -Name Eng -ReferencedAssemblies System.Drawing -MemberDefinition $engCode
}

function FlagPath([string]$k) { return (Join-Path $FlagDir ("dsh_agent_" + $k + ".flag")) }
function SetFlag([string]$k, [string]$c) { Set-Content -LiteralPath (FlagPath $k) -Value $c -Encoding UTF8 -ErrorAction SilentlyContinue }
function ClearFlag([string]$k) { Remove-Item -LiteralPath (FlagPath $k) -Force -ErrorAction SilentlyContinue }
function RestoreCursor { [CU.Eng]::SystemParametersInfo(0x0057, 0, [System.IntPtr]::Zero, 3) | Out-Null }
function Col([int]$r, [int]$g, [int]$b, [int]$a) { return [System.Drawing.Color]::FromArgb($a, $r, $g, $b) }
function StatePath { return (Join-Path $FlagDir 'dsh_cu_state.json') }

if ($Action -eq 'status') {
  foreach ($k in @('active','cancel','stop')) { $p = FlagPath $k; Write-Output ("FLAG " + $k + " exists=" + (Test-Path -LiteralPath $p)) }
  $sp = StatePath
  if (Test-Path -LiteralPath $sp) { Write-Output ("STATE " + ((Get-Content -LiteralPath $sp -Raw) -replace "`r?`n",' ')) }
  exit 0
}
if ($Action -eq 'stop') { SetFlag 'stop' 'by-stop'; Start-Sleep -Milliseconds 900; RestoreCursor; Write-Output 'STOPPED'; exit 0 }

function MakeWindow([int]$x, [int]$y, [int]$w, [int]$h) {
  $f = New-Object System.Windows.Forms.Form
  $f.FormBorderStyle = 'None'; $f.ShowInTaskbar = $false; $f.StartPosition = 'Manual'
  $f.AutoScaleMode = 'None'   # 尺寸全部由我们按物理像素给定，禁止 WinForms 再缩一次
  $f.Bounds = New-Object System.Drawing.Rectangle($x, $y, $w, $h)
  $f.TopMost = $true
  $null = $f.Handle
  $ex = [CU.Eng]::GetWindowLongSafe($f.Handle)
  [CU.Eng]::SetWindowLongSafe($f.Handle, $ex) | Out-Null
  $f.Show()
  return $f
}

# ---- 绘制面板：位图按物理像素分配，坐标系保持 96dpi 逻辑尺寸（由 ScaleTransform 放大）----
# 这样既不用把满屏的尺寸常量都乘一遍 scale，又保证线条/字体是按物理分辨率矢量渲染的，
# 而不是画在低分辨率位图上再被系统拉伸（后者就是覆盖层发虚的原因）。
function New-DrawSurface([int]$logicalW, [int]$logicalH, [double]$scale) {
  if ($scale -le 0) { $scale = 1.0 }
  $pw = [int][Math]::Ceiling($logicalW * $scale)
  $ph = [int][Math]::Ceiling($logicalH * $scale)
  if ($pw -lt 1) { $pw = 1 }
  if ($ph -lt 1) { $ph = 1 }
  $bmp = New-Object System.Drawing.Bitmap($pw, $ph, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  # 关键：DPI 感知进程里 new Bitmap(w,h) 的分辨率会继承屏幕 DPI（200% 缩放 = 192），
  # 于是 Graphics.DpiY=192，10.5pt 字体会按 192dpi 渲染成 28px，再被 ScaleTransform
  # 放大一次 → 文字比胶囊几何大了一倍（表现为"字体很大、上下 padding 很小"）。
  # 必须在 Graphics.FromImage 之前把位图分辨率钉成 96dpi，与逻辑坐标系一致。
  $bmp.SetResolution(96, 96)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.ScaleTransform([float]$scale, [float]$scale)
  return @{ Bmp = $bmp; G = $g }
}

# ---- 边框（静态渲染一次）----
function RoundPath([double]$x, [double]$y, [double]$w, [double]$h, [double]$r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  if ($r -lt 1) { $r = 1 }
  $d = $r * 2
  $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
  $p.CloseFigure(); return $p
}
function Render-Border([int]$w, [int]$h, [bool]$cancelled, [double]$scale = 1.0) {
  # 交给 C# 用"贴边矩形距离场"逐像素渲染（见 RenderFrame）：
  # 光晕贴在屏幕最外圈、向内高斯衰减，没有内侧留白也没有单独的亮线描边；
  # 四边/四角浓度一致（旧版叠 84 条同心圆角线会让四角发淡），且完全没有叠线条纹。
  # $w/$h 是逻辑尺寸，乘 scale 得到物理位图尺寸。
  $pw = [int][Math]::Ceiling($w * $scale)
  $ph = [int][Math]::Ceiling($h * $scale)
  return [CU.Eng]::RenderFrame($pw, $ph, [float]$scale, $cancelled)
}
# ---- 徽章（按模式渲染，切换时才重画）----
function Render-Badge([string]$mode, [bool]$cancelled, [string]$fontName, [double]$scale = 1.0) {
  $txt = if ($cancelled) { '已取消' } else { 'DeepSeek Harness 正在操作' }
  $chip = if ($cancelled) { '' } elseif ($mode -eq 'typing') { '输入中' } elseif ($mode -eq 'clicking') { '点击' } elseif ($mode -eq 'moving') { '移动' } else { '' }
  $accent = if ($cancelled) { (Col 245 158 11 255) } elseif ($mode -eq 'typing') { (Col 248 113 113 255) } elseif ($mode -eq 'clicking') { (Col 251 146 60 255) } else { (Col 239 68 68 255) }
  $font = New-Object System.Drawing.Font($fontName, 10.5)
  $fontEsc = New-Object System.Drawing.Font('Segoe UI', 8.5)
  $fontChip = New-Object System.Drawing.Font($fontName, 9)
  $mb = New-Object System.Drawing.Bitmap(1, 1); $mb.SetResolution(96, 96); $mg = [System.Drawing.Graphics]::FromImage($mb)   # 测量基准同样钉在 96dpi，否则测得的宽度也是 2 倍
  $wText = $mg.MeasureString($txt, $font).Width
  $wEsc = $mg.MeasureString('Esc', $fontEsc).Width
  $wChip = if ($chip) { $mg.MeasureString($chip, $fontChip).Width + 18 } else { 0 }
  $wCancel = if (-not $cancelled) { $mg.MeasureString('取消', $font).Width } else { 0 }
  $bw = [int](16 + 9 + 11 + $wText + 18 + $wChip + $(if (-not $cancelled) { 10 + ($wEsc + 18) + 9 + $wCancel } else { 0 }) + 18)
  $bh = 40
  $surf = New-DrawSurface $bw $bh $scale
  $bmp = $surf.Bmp; $g = $surf.G
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
  $path = RoundPath 1 1 ($bw - 2) ($bh - 2) 19
  $g.FillPath((New-Object System.Drawing.SolidBrush((Col 8 12 24 214))), $path)
  $g.DrawPath((New-Object System.Drawing.Pen((Col ($accent.R) ($accent.G) ($accent.B) 130), 1.2)), $path)
  $cx = 20.5; $cy = $bh / 2.0
  foreach ($i in @(10,8,6,4)) {
    $a = [int](7 * (1 - $i / 10.0) * 1.2); if ($a -le 0) { continue }
    $rr = 3.0 + $i * 0.55
    $g.FillEllipse((New-Object System.Drawing.SolidBrush((Col ($accent.R) ($accent.G) ($accent.B) $a))), ($cx - $rr), ($cy - $rr), ($rr*2), ($rr*2))
  }
  $g.FillEllipse((New-Object System.Drawing.SolidBrush($accent)), ($cx - 3.2), ($cy - 3.2), 6.4, 6.4)
  $brush = New-Object System.Drawing.SolidBrush((Col 233 235 240 255))
  $tx = 36; $ty = ($bh - $font.GetHeight($g)) / 2.0
  $g.DrawString($txt, $font, $brush, $tx, $ty)
  $x2 = $tx + $wText + 18
  if ($chip) {
    $cp = RoundPath $x2 ($bh/2 - 11) $wChip 22 8
    $g.FillPath((New-Object System.Drawing.SolidBrush((Col ($accent.R) ($accent.G) ($accent.B) 46))), $cp)
    $cb = New-Object System.Drawing.SolidBrush($accent)
    $g.DrawString($chip, $fontChip, $cb, ($x2 + 9), ($bh/2 - $fontChip.GetHeight($g)/2))
    $cp.Dispose(); $cb.Dispose()
    $x2 += $wChip + 10
  }
  if (-not $cancelled) {
    $kx = [int]$x2; $kh = 22; $ky = ($bh - $kh) / 2
    $kp = RoundPath $kx $ky ([int]($wEsc + 18)) $kh 6
    $g.FillPath((New-Object System.Drawing.SolidBrush((Col 255 255 255 24))), $kp)
    $g.DrawPath((New-Object System.Drawing.Pen((Col 255 255 255 65), 1.0)), $kp)
    $kb = New-Object System.Drawing.SolidBrush((Col 254 202 202 255))
    $g.DrawString('Esc', $fontEsc, $kb, ($kx + 9), ($bh/2 - $fontEsc.GetHeight($g)/2))
    $kb2 = New-Object System.Drawing.SolidBrush((Col 148 163 184 255))
    $g.DrawString('取消', $font, $kb2, ($kx + $wEsc + 27), $ty)
    $kp.Dispose(); $kb.Dispose(); $kb2.Dispose()
  }
  $brush.Dispose(); $font.Dispose(); $fontEsc.Dispose(); $fontChip.Dispose(); $mg.Dispose(); $mb.Dispose(); $g.Dispose()
  return $bmp
}
function Push-Bitmap($form, $bmp, [int]$x, [int]$y) {
  if ($null -eq $bmp) { return }
  $hb = $bmp.GetHbitmap([System.Drawing.Color]::FromArgb(0))
  try { [CU.Eng]::PushRaw($form.Handle, $hb, $bmp.Width, $bmp.Height, $x, $y) | Out-Null }
  finally { [CU.Eng]::DeleteObject($hb) | Out-Null }
}

# ---------------- 自定义系统光标 ----------------

# ---------------- 蓝色风格光标套装（箭头/I形/手指）----------------
function New-CuCursor([string]$path, [string]$style, [double]$scale = 1.0) {
  $S = 48                                            # 逻辑设计尺寸（96dpi）
  if ($scale -le 0) { $scale = 1.0 }
  $Sp = [int][Math]::Ceiling($S * $scale)            # 真正写进 .cur 的物理像素尺寸
  if ($Sp -gt 256) { $Sp = 256 }                     # ICO/CUR 单边上限（256 以 0 编码）
  $bmp = New-Object System.Drawing.Bitmap($Sp, $Sp, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.ScaleTransform([float]$scale, [float]$scale)
  $g.Clear([System.Drawing.Color]::Transparent)
  $navy = New-Object System.Drawing.Pen((Col 69 10 10 235), 2.4)
  $navy.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
  $hotX = 5; $hotY = 3
  if ($style -eq 'ibeam') {
    $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
      (New-Object System.Drawing.PointF(16, 4)), (New-Object System.Drawing.PointF(32, 44)),
      (Col 255 255 255 255), (Col 252 165 165 255))
    $g.FillRectangle($lg, 21, 8, 6, 32)
    $g.FillRectangle($lg, 15, 6, 18, 4)
    $g.FillRectangle($lg, 15, 38, 18, 4)
    $pen = New-Object System.Drawing.Pen((Col 69 10 10 235), 1.8)
    $g.DrawRectangle($pen, 21, 8, 6, 32)
    $g.DrawRectangle($pen, 15, 6, 18, 4)
    $g.DrawRectangle($pen, 15, 38, 18, 4)
    $lg.Dispose(); $pen.Dispose()
    $hotX = 24; $hotY = 24
  } elseif ($style -eq 'hand') {
    # 手指光标：圆角造型 + 渐变 + 柔和投影（无生硬方框）
    $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
      (New-Object System.Drawing.PointF(12, 4)), (New-Object System.Drawing.PointF(30, 40)),
      (Col 255 255 255 255), (Col 252 165 165 255))
    $shadow = New-Object System.Drawing.SolidBrush((Col 69 10 10 55))
    $finger = RoundPath 10.5 4.5 8 21 4
    $palm   = RoundPath 9.5 22.5 25 15 6.5
    $thumb  = RoundPath 28.5 17.5 8 13 4
    $sh1 = RoundPath 11.5 5.5 8 21 4
    $sh2 = RoundPath 10.5 23.5 25 15 6.5
    $sh3 = RoundPath 29.5 18.5 8 13 4
    $g.FillPath($shadow, $sh1)
    $g.FillPath($shadow, $sh2)
    $g.FillPath($shadow, $sh3)
    $g.FillPath($lg, $finger)
    $g.FillPath($lg, $palm)
    $g.FillPath($lg, $thumb)
    $sh1.Dispose(); $sh2.Dispose(); $sh3.Dispose()
    $pen = New-Object System.Drawing.Pen((Col 69 10 10 210), 1.7)
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $g.DrawPath($pen, $finger); $g.DrawPath($pen, $palm); $g.DrawPath($pen, $thumb)
    $hl = New-Object System.Drawing.Pen((Col 255 255 255 120), 1.0)
    $g.DrawLine($hl, 13.5, 7, 13.5, 22)
    $lg.Dispose(); $pen.Dispose(); $hl.Dispose(); $shadow.Dispose()
    $finger.Dispose(); $palm.Dispose(); $thumb.Dispose()
    $hotX = 13; $hotY = 5
  } else {
    # 显式声明成 PointF[]：PS7(.NET Core) 的绑定器比 5.1 严格，
    # 传 object[] 给 DrawPolygon/FillPolygon 会直接报"无法转换 points 参数"。
    [System.Drawing.PointF[]]$pts = @(
      (New-Object System.Drawing.PointF(5, 3)), (New-Object System.Drawing.PointF(5, 37)),
      (New-Object System.Drawing.PointF(13, 29)), (New-Object System.Drawing.PointF(19, 43)),
      (New-Object System.Drawing.PointF(26, 40)), (New-Object System.Drawing.PointF(20, 26)),
      (New-Object System.Drawing.PointF(31, 26))
    )
    [System.Drawing.PointF[]]$shadowPts = @($pts | ForEach-Object { New-Object System.Drawing.PointF(($_.X + 1.4), ($_.Y + 1.6)) })
    $g.FillPolygon((New-Object System.Drawing.SolidBrush((Col 69 10 10 60))), $shadowPts)
    $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
      (New-Object System.Drawing.PointF(6, 4)), (New-Object System.Drawing.PointF(28, 42)),
      (Col 255 255 255 255), (Col 252 165 165 255))
    $g.FillPolygon($lg, $pts)
    $g.DrawPolygon($navy, $pts)
    $lg.Dispose()
  }
  $navy.Dispose()
  $g.Dispose()
  $ms = New-Object System.IO.MemoryStream
  $bw = New-Object System.IO.BinaryWriter($ms)
  $bw.Write([UInt16]0); $bw.Write([UInt16]2); $bw.Write([UInt16]1)
  $xor = $Sp * $Sp * 4; $and = [int]($Sp * $Sp / 8); $data = 40 + $xor + $and
  $bw.Write([Byte]($Sp % 256)); $bw.Write([Byte]($Sp % 256)); $bw.Write([Byte]0); $bw.Write([Byte]0)
  $bw.Write([UInt16]([int][Math]::Round($hotX * $scale))); $bw.Write([UInt16]([int][Math]::Round($hotY * $scale)))
  $bw.Write([UInt32]$data); $bw.Write([UInt32]22)
  $bw.Write([UInt32]40); $bw.Write([Int32]$Sp); $bw.Write([Int32]($Sp * 2))
  $bw.Write([UInt16]1); $bw.Write([UInt16]32); $bw.Write([UInt32]0)
  $bw.Write([UInt32]$xor); $bw.Write([Int32]0); $bw.Write([Int32]0); $bw.Write([UInt32]0); $bw.Write([UInt32]0)
  for ($y = $Sp - 1; $y -ge 0; $y--) { for ($x = 0; $x -lt $Sp; $x++) { $c = $bmp.GetPixel($x, $y); $bw.Write([Byte]$c.B); $bw.Write([Byte]$c.G); $bw.Write([Byte]$c.R); $bw.Write([Byte]$c.A) } }
  $z = New-Object byte[] $and; $bw.Write($z, 0, $and); $bw.Flush()
  [System.IO.File]::WriteAllBytes($path, $ms.ToArray())
  $bw.Dispose(); $ms.Dispose(); $bmp.Dispose()
}

# ---------------- 启动 ----------------
# 安装蓝色风格光标套装（保留原生语境切换：箭头 / I形 / 手指）
ClearFlag 'cancel'; ClearFlag 'stop'
SetFlag 'active' ("pid=" + $PID)
BootLog ("flags written pid=" + $PID)
if (-not $NoCursorChange) {
  try {
    $map = @(
      @{ style = 'arrow'; id = 32512; file = (Join-Path $env:TEMP 'dsh_cu_arrow.cur') },
      @{ style = 'ibeam'; id = 32513; file = (Join-Path $env:TEMP 'dsh_cu_ibeam.cur') },
      @{ style = 'hand';  id = 32649; file = (Join-Path $env:TEMP 'dsh_cu_hand.cur') }
    )
    foreach ($m in $map) {
      New-CuCursor $m.file $m.style $DpiScale
      $hc = [CU.Eng]::LoadCursorFromFile($m.file)
      if ($hc -ne [System.IntPtr]::Zero) { [CU.Eng]::SetSystemCursor($hc, [uint32]$m.id) | Out-Null; BootLog ("cursor installed " + $m.style) }
    }
  } catch { BootLog ("cursor install failed: " + $_.Exception.Message) }
}

$fontName = 'Microsoft YaHei UI'
$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen   # DPI 感知后 = 真实物理分辨率
$sc = $DpiScale
$badgeTop = [int]($vs.Y + 16 * $sc)
# Render-Border 接受逻辑尺寸（内部再乘 scale 得到物理位图），这里先换算回逻辑尺寸
$vsLogW = [int][Math]::Ceiling($vs.Width / $sc)
$vsLogH = [int][Math]::Ceiling($vs.Height / $sc)

$borderForm = MakeWindow $vs.X $vs.Y $vs.Width $vs.Height
$badgeBmp = Render-Badge 'idle' $false $fontName $sc
$badgeForm = MakeWindow ([int](($vs.Width - $badgeBmp.Width) / 2 + $vs.X)) $badgeTop $badgeBmp.Width $badgeBmp.Height
$haloSizePx = [int][Math]::Ceiling($HaloSize * $sc)
$rippleSizePx = [int][Math]::Ceiling(120 * $sc)
$haloForm = MakeWindow 0 0 $haloSizePx $haloSizePx
$rippleForm = MakeWindow 0 0 $rippleSizePx $rippleSizePx
$rippleForm.Hide()

$renderSw = [System.Diagnostics.Stopwatch]::StartNew()
$borderBmp = Render-Border $vsLogW $vsLogH $false $sc
Push-Bitmap $borderForm $borderBmp $vs.X $vs.Y
Push-Bitmap $badgeForm $badgeBmp ([int](($vs.Width - $badgeBmp.Width) / 2 + $vs.X)) $badgeTop
$renderSw.Stop()
BootLog ('C# engine ready screen=' + $vs.Width + 'x' + $vs.Height + ' scale=' + $sc + ' frame=' + $renderSw.ElapsedMilliseconds + 'ms')
[CU.Eng]::Init($haloForm.Handle, $HaloSize, [float]$sc)
[CU.Eng]::InitRipple($rippleForm.Handle, 120, [float]$sc)

$script:cancelled = $false
$script:lastMode = 'idle'
$script:lastClickTs = 0
$script:n = 0
$script:startTs = [DateTime]::UtcNow

$tick = New-Object System.Windows.Forms.Timer
$tick.Interval = $IntervalMs
$tick.Add_Tick({
  if ($script:cancelled) { return }
  [CU.Eng]::Tick()
  $script:n++
  if (($script:n % 30) -eq 0) {
    # 防遮挡：用户可能开着 Always-on-Top 的应用（实测 VS Code 置顶会把边框整条盖掉）
    [CU.Eng]::Raise($borderForm.Handle)
    [CU.Eng]::Raise($badgeForm.Handle)
  }
  if (($script:n % 6) -eq 0) {
    $m = [CU.Eng]::GetMode()
    if ($m -ne $script:lastMode) {
      $script:lastMode = $m
      $nb = Render-Badge $m $false $fontName $sc
      Push-Bitmap $badgeForm $nb ([int](($vs.Width - $nb.Width) / 2 + $vs.X)) $badgeTop
      $nb.Dispose()
    }
  }
  if (($script:n % 3) -eq 0) {
    if ([CU.Eng]::EscDown() -eq 1) {
      $script:cancelled = $true
      SetFlag 'cancel' 'esc'
      $cb = Render-Border $vsLogW $vsLogH $true $sc
      Push-Bitmap $borderForm $cb $vs.X $vs.Y; $cb.Dispose()
      $cbb = Render-Badge 'idle' $true $fontName $sc
      Push-Bitmap $badgeForm $cbb ([int](($vs.Width - $cbb.Width) / 2 + $vs.X)) $badgeTop; $cbb.Dispose()
      $haloForm.Hide()
      Start-Sleep -Milliseconds 2200
      [System.Windows.Forms.Application]::Exit()
      return
    }
    if (Test-Path -LiteralPath (FlagPath 'stop')) { [System.Windows.Forms.Application]::Exit(); return }
    if ($IdleSeconds -gt 0 -and ($script:n % 30) -eq 0) {
      $hb1 = Join-Path $FlagDir 'dsh_agent_heartbeat'
      $hb2 = Join-Path $env:TEMP 'dsh_agent_heartbeat'
      $lastUtc = $script:startTs
      foreach ($hb in @($hb1, $hb2)) {
        if (Test-Path -LiteralPath $hb) {
          $t = (Get-Item -LiteralPath $hb).LastWriteTimeUtc
          if ($t -gt $lastUtc) { $lastUtc = $t }
        }
      }
      if (([DateTime]::UtcNow - $lastUtc).TotalSeconds -gt $IdleSeconds) {
        BootLog ("idle-timeout after " + $IdleSeconds + "s -> exit")
        [System.Windows.Forms.Application]::Exit(); return
      }
    }
    if ($MaxSeconds -gt 0 -and ([DateTime]::UtcNow - $script:startTs).TotalSeconds -gt $MaxSeconds) { [System.Windows.Forms.Application]::Exit(); return }
  }
})
BootLog 'timer starting'
$tick.Start()
BootLog 'entering message loop'
[System.Windows.Forms.Application]::Run()
$tick.Stop()
ClearFlag 'active'
RestoreCursor  # 保险：确保系统光标处于默认状态
Write-Output ("OVERLAY_V2_EXIT cancel=" + $script:cancelled)
