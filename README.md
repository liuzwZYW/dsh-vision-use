# Vision Use · DSH Computer Use

[English](README_EN.md) | 中文

> 仓库：`dsh-vision-use`（fork 自 [zzy6-a/vision-use](https://github.com/zzy6-a/vision-use)）· 包名 / 插件 id：`@liuzw/dsh-vision`
>
> 让 DeepSeek Harness 的 Agent **真正看见你的屏幕、并动手操作 Windows 桌面** —— 带 Codex computer use 风格的红色操作覆盖层（按 **Esc** 随时中止）。
>
> 本 fork 修复了高 DPI（系统缩放 ≠ 100%）下的两个问题：**截图/点击坐标漂移**、**覆盖层只铺满屏幕一角且发虚** —— 见 [DPI 与坐标](#dpi-与坐标高缩放必读)。

[![Download](https://img.shields.io/badge/Download-fork-2e7d32?style=flat&logo=github&logoColor=white)](https://github.com/liuzwZYW/dsh-vision-use)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![dsh-plugin](https://img.shields.io/badge/topic-dsh--plugin-2f6fed)](https://github.com/topics/dsh-plugin)

---

## 它能做什么

| 能力 | 工具 | 说明 |
|---|---|---|
| 👁 **看** | `view_screen` | 截 Windows 全屏 → 直接进入模型视觉通道（不是 OCR，是真·看图）|
| 👁 **看** | `view_image` | 把任意图片文件送进视觉通道（Linux / Windows 路径都行）|
| 🖱 **动** | `computer_move` | 光标平滑滑行到 (x,y) |
| 🖱 **动** | `computer_click` | 左/右/双击，带点击涟漪 |
| ⌨️ **动** | `computer_type` | 输入文字（默认 **VK 真实按键逐键注入**，零剪贴板；中文走输入法：`computer_key` 发拼音 → `space`/数字上屏）|
| ⌨️ **动** | `computer_key` | 组合键（`ctrl+t` / `enter` / `alt+f4` …）|
| 🎛 **控** | `computer_overlay` | 启停操作覆盖层（start/stop/status，可设空闲自动关）|
| 📊 **控** | `computer_status` | 覆盖层状态 / ESC 标志 / 当前模式 / 光标位置 / 解释器 |
| 🎬 **动** | `computer_sequence` | 一串 move/click/type/key 顺序执行，中途按 Esc 即停 |
| 🧭 **定** | `uia_windows` / `uia_tree` | 列窗口 / 导出控件树（类型、名称、矩形、可用 pattern）|
| 🧭 **定** | `uia_find` / `uia_locate` | 按名字找控件 / 回一张以控件为中心的近景图 |
| 🧭 **定** | `uia_click` | 按名字点：优先走 UIA pattern（不移动鼠标），退化才用坐标 |

### 视觉反馈（Codex 风格）

```
┌───────────────────────────────────────────────┐
│  ╔═════════════════════════════════════════╗  │ ← 红色柔光边框（逐像素 Alpha）
│  ║   ● DeepSeek Harness 正在操作  [Esc] 取消 ║  │ ← 顶部状态徽章
│  ║                                         ║  │
│  ║         打字 → 红色光环 + 竖线           ║  │
│  ║         点击 → 0.7s 涟漪（钉在点击处）    ║  │
│  ║         移动 → 光环淡入跟随；静置 1s 淡出 ║  │
│  ╚═════════════════════════════════════════╝  │
└───────────────────────────────────────────────┘
```

- **整套光标**（箭头 / I 形 / 手指）都是统一的红白渐变风格，且**保留 Windows 原生语境切换**
- **强制覆盖层**：所有 hands 操作（move/click/type/key）都会先强制拉起覆盖层，不存在“静默操作”
- **ESC 中止**：按下即写取消标志 → 覆盖层退出 → 后续所有动作被拒绝
- **任务级保活**：只要本回合 agent 还在工作（思考 / 执行其他工具），覆盖层就不会收；回合结束后约 4 秒收起。覆盖层自身仍有空闲兜底（`idle_seconds`，默认 600，0 = 关闭兜底）
- **输入框下方的状态胶囊**：彩色圆点 + `CU 待命/移动/输入/点击` + 「停止」按钮

---

## 安装

### 方式一：git 源（本 fork，推荐）

```bash
dsh plugin --profile web add github:liuzwZYW/dsh-vision-use
```

### 方式二：本地目录

```bash
dsh plugin --profile web add /path/to/dsh-vision-use
```

> 插件 id 就是 npm 包名 `@liuzw/dsh-vision`（`dsh.plugin.json` 的 `id` 与 `package.json` 的 `name` 必须一致）。
> 早期版本把 `id` 写成了 GitHub 仓库名 `liuzwZYW/dsh-vision-use`，插件管理面板卸载时会拼出
> `pnpm remove liuzwZYW/dsh-vision-use` 并失败；从 v0.3.0 起已修正。

装完**重启 DSH**（`client.js` 半边需要启动时注册），浏览器刷新后输入框下方会出现状态胶囊。

---

## 快速开始

对 Agent 说：

> 看一下我的屏幕

> 帮我在必应搜索 DeepSeek 官网并打开

> 打开记事本打一段字

Agent 会自动：起覆盖层 → `view_screen` 看 → `computer_*` 动手 → 再看验证。你随时可以按 **Esc** 喊停。

---

## DPI 与坐标（高缩放必读）

Windows 会把「没有声明 DPI 感知」的进程偷偷虚拟化：`SystemInformation.VirtualScreen` 只报告**逻辑分辨率**（物理 ÷ 缩放），`CopyFromScreen` 也只给你**物理屏幕左上 1/缩放**那一块。于是原来会出现：

| 症状 | 原因 |
|---|---|
| Agent 只能看到屏幕左上角一小块，右下角的内容永远看不见 | 截图被限制在物理屏的左上 `1/scale` 区域（实测：3072×1920 的屏幕只截到 1536×960，且与物理像素逐点相同 = 纯裁剪，不是缩放）|
| 覆盖层蓝框只围住屏幕左上角，线条/字号还偏细 | 边框位图按逻辑尺寸渲染，在 200% 缩放下只有设计大小的一半 |
| 光环、涟漪位置与光标对不上，看着"糊" | 覆盖层窗口/位图在虚拟化坐标系里被系统拉伸或错位 |

本 fork 的处理：`scripts/dpi.ps1` 让**所有**桌面侧 PowerShell 进程声明 **Per-Monitor-V2 DPI 感知**（逐级降级到 PMv1 / shcore / `SetProcessDPIAware`），于是

- `VirtualScreen` = 真实物理分辨率，截图 **1:1 物理像素**（3072×1920 就是 3072×1920）；
- `GetCursorPos` / `SetCursorPos` 本来就是物理像素 → **截图坐标与点击坐标同一套**；
- 覆盖层改为「位图按物理像素分配 + 绘制沿用 96dpi 逻辑坐标（`ScaleTransform` 放大）」→ 边框铺满整屏，线条/文字/光环按物理分辨率矢量渲染，**高缩放下不再发虚**。

### 传给 computer_click / computer_move 的坐标

这两个工具收的是**屏幕物理像素**。而 `view_screen` 默认把截图缩到 `max_width`（默认 1600），所以图上量到的坐标**不是**屏幕坐标。两种正确做法：

1. 用返回文本给的系数换算（`view_screen` 会明确写出）：
   `screen_x = image_x × k`，`screen_y = image_y × k`（例：3072 宽的屏、1600 宽的图 → k = 1.92）
2. 直接把图坐标原样传进去，并带上截图宽度：
   `computer_click(x: 700, y: 380, image_width: 1600)` —— 插件会用 `physicalScreen` 自动换算
3. `window` / `region` / `hwnd` 截图还要带区域原点，否则只有缩放没有偏移：
   `computer_click(x: 320, y: 90, image_width: 1600, image_region: "400,60,2560,1440")`
   （`view_screen` 返回文本里的 `<coords>` 会直接给出可复制的 `image_width` 与 `image_region`）

自检：`computer_status` 会打印 `SCREEN 3072x1920 ORIGIN 0,0 DPI 192 SCALE 2`，或用 `cu.ps1 -Action screen` 单独查。

---

## v0.3.0 · UIA 定位能力（2026-10-27）

这一版补的是**「不用算坐标也能点」**。灵感来自生态里几个成熟实现，具体借鉴点：

| 借鉴来源 | 借鉴的东西 | 落到哪里 |
| --- | --- | --- |
| [Yu-tao-Li/dsh-computer-use-win](https://github.com/Yu-tao-Li/dsh-computer-use-win) | 用 UI Automation 控件树定位而不是纯坐标；Electron/Chromium 需要先唤醒无障碍层 | `uia_tree` / `uia_find` + `Wake-Uia`（WM_GETOBJECT） |
| [STARDUSTLC666/deepseek-computer-use](https://github.com/STARDUSTLC666/deepseek-computer-use) | 操作后要求重新观察；会话级授权与审计 | `uia_click` 的前后指纹对比 + `~/.dsh/vision/audit-*.jsonl` |
| [sxwsc667/dsh-use-computer](https://github.com/sxwsc667/dsh-use-computer) | 「坐标不进对话」：只回以目标为中心的近景图 | `uia_locate` |
| [rayadesune/DSH-computer-use](https://github.com/rayadesune/DSH-computer-use) | 截图带坐标网格标尺；干跑模式 | `view_screen` 的 `grid` / `marker_x` / `marker_y`；`-DryRun` |
| 原生 Win32 | `PrintWindow(PW_RENDERFULLCONTENT)` 截被遮挡窗口 | `view_screen` / `uia_locate` 的 `hwnd` 参数 |

### 新工具

| 工具 | 作用 | 是否需要鼠标 |
| --- | --- | --- |
| `uia_windows` | 列顶层窗口：标题 / pid / class / rect / center / 前台标记 | 否 |
| `uia_tree` | 一个窗口的控件树：类型 / 名称 / AutomationId / 矩形 / pattern 列表 | 否 |
| `uia_find` | 按名字模糊找控件（也匹配 AutomationId / ClassName），返回候选清单 | 否 |
| `uia_locate` | 找到控件 → 回一张以它为中心的**近景图**，不带坐标 | 否 |
| `uia_click` | 按名字点：优先 invoke / toggle / select / expand pattern，退化才用坐标 | **否**（pattern 命中时） |

`uia_click` 的回执示例：

```
clicked: Button "加粗(Ctrl+B)" @450,112 via toggle-pattern (no mouse movement)
toggle state now: On
ui changed: NO  fingerprint 42D94E5ECD7F -> 42D94E5ECD7F
window now: "无标题 - Notepad"  focused: Button "更多选项"
```

### `view_screen` 增强

```js
view_screen({ hwnd: 1641304, region: "400,60,700,320", grid: 100, marker_x: 450, marker_y: 112 })
```

- `hwnd`：走 PrintWindow，**窗口被遮挡也能截到真实内容**（实测 Win11 + Chromium 156 有效）
- `region`：只截一块，越界自动夹到桌面边界
- `grid`：画坐标标尺，左上/左侧标注**全局坐标**
- `marker_x/y`：在目标点画红十字，用来确认「这是不是我要点的那个」

### 已知边界

- **Chromium / Electron 自绘界面**：UIA 树很多时候只有几个 `Chrome_RenderWidgetHostHWND` 节点。已加 `WM_GETOBJECT` 唤醒，但应用自己不开 accessibility 就拿不到控件 —— 这类目标退回 `view_screen` + 坐标。
- **PrintWindow 黑图**：部分应用（老式 OpenGL / 某类游戏）不支持，此时 `view_screen` 自动退回屏幕捕获。
- **坐标点击兜底会移动鼠标**，`uia_click` 的回执里会写明 `via mouse-click`，据此区分。

### 审计日志

每次 `uia_click` / `uia_locate` / `view_screen` 追加一行到 `~/.dsh/vision/audit-YYYY-MM-DD.jsonl`：

```json
{"ts":1793101196129,"tool":"uia_click","name":"加粗","how":"toggle-pattern","matched":"加粗(Ctrl+B)","changed":true,"fpBefore":"42D94E5ECD7F","fpAfter":"763BB639F94C"}
```

---

## 系统要求

| 项 | 要求 |
|---|---|
| 宿主（自动识别） | **Windows 原生** 或 **Windows + WSL2**；插件自动识别 DSH 所在环境并选择对应路径/子进程方案 |
| WSL 时的互操作 | WSL interop 开启（`/proc/sys/fs/binfmt_misc/WSLInterop` = enabled）；插件自动走 `\\wsl.localhost\<distro>` UNC 路径 |
| Windows 侧 | **PowerShell 7（`pwsh`）优先，自动回退系统自带 PowerShell 5.1**；GDI+/WinForms（`System.Drawing`）|
| DSH | `>= 0.1.5-rc.1` |
| Node | 插件本身零运行时依赖（纯 ESM + 子进程调 PowerShell）|
| Linux / macOS | 不支持桌面控制；`view_screen` 与 hands 工具会明确报错，`view_image` 仍可用 |

### PowerShell 解释器选择

插件启动时按 `pwsh.exe`（PowerShell 7）→ `powershell.exe`（5.1）顺序探测并缓存结果，`computer_status` 会报当前实际使用的解释器：

| 用途 | 行为 |
|---|---|
| `view_screen` 截图脚本、`cu.ps1`（鼠标/键盘）| 用 pwsh 7（进程启动更快）；pwsh 不存在时用 5.1 |
| `overlay-v2.ps1`（覆盖层）| 优先 pwsh 7（C# 引擎在 .NET 与 .NET Framework 上都能编译）；若该 pwsh 环境缺 WinForms / ref 程序集导致起不来，会自动改用 5.1 重试一次 |

---

## 架构

```
vision-use/
├── lib/index.js        host 半边：14 个工具 + 2 条 API 路由 + systemPrompt 能力宣告
├── lib/client.js       browser 半边：composer-dock 状态胶囊
├── cordis.patch.yml    bundle 层：把插件行插入 profile 树
├── dsh.plugin.json     插件清单（dsh-market / 插件管理 UI 用）
└── scripts/            Windows 侧工具链（自包含，随包发布）
    ├── dpi.ps1         DPI 感知（Per-Monitor-V2）：截图/光标/覆盖层统一到物理像素
    ├── cu.ps1          鼠标/键盘执行器 + 截图 + ESC 守卫
    ├── uia.ps1         UI Automation 定位/pattern 点击/前后指纹
    ├── overlay-v2.ps1  覆盖层：边框/徽章/光环/涟漪 + C# 60fps 动画引擎
    └── TOOLKIT.md      工具链详细文档 + 10 条实战纪律
```

### 环境自动识别

插件启动时检测 `process.platform`、`WSL_DISTRO_NAME` / `WSL_INTEROP` 与 `/proc/version`：

| 检测结果 | 行为 |
|---|---|
| Windows 原生 | 直接调 `powershell.exe`；flag/state/heartbeat 写 `%TEMP%` |
| WSL + Windows | 调 `powershell.exe` interop；flag/state/heartbeat 写 `/tmp`，并自动转成 `\\wsl.localhost\<distro>\tmp` 供 PowerShell 读写 |
| Linux / macOS | 桌面工具给出明确不支持错误；`view_image` 不受影响 |

子进程统一通过 `DSH_VISION_FLAG_DIR` 环境变量获知跨端 flag 目录（WSL 下会自动加入 `WSLENV` 透传）。

**视觉原理**：图片以 `content: [{type:'image', attachment}]` 形式返回，宿主 `collectImageRefs()` 递归收集后随下一次请求发给模型 —— 这是 DSH 官方的图片通道，因此**截图会正常计入模型视觉 token**（DeepSeek 官方路由对单图约 369 tokens，上限 384）。

**动画原理**：覆盖层用 `UpdateLayeredWindow` 逐像素 Alpha 实现真正的柔光；热路径全部在编译好的 C# 里跑（PowerShell 只敲节拍），单核占用约 8.8%。

---

## 配置

| 参数 | 默认 | 说明 |
|---|---|---|
| `computer_overlay start idle_seconds` | `600` | 覆盖层自身的空闲兜底秒数；任务进行中插件会持续续心跳，不会在思考时消失（0 = 关闭兜底）|
| `-MaxSeconds` | `0` | 覆盖层最长存活时间（0 = 不限）|
| `-NoCursorChange` | 关 | 不安装红色光标套装（保留系统默认光标）|

隐私相关：截屏会作为图片附件进入当前会话上下文（与手动粘贴图片等价）。

---

## 计费与隐私

- **插件本身零网络请求**：不调用任何 API，只把截图存进本地附件库并把图片块交给宿主
- 图片最终**发给当前会话选中的模型路由**（DSH 的模型适配器负责发请求）
- **完全跟随你选择的模型**：插件不选路由、不改路由，截图始终随会话发给**当前模型选择器里选中的模型**
  （选 opencode-go 就走 opencode-go，选官方就走官方）
- **识图能力检查**：若选中的模型未声明图片输入能力，`view_screen` / `view_image` 会明确报错并提示切换模型
- 走官方路由时单图视觉计费约 **369 tokens**（DSH 上限 384）；走自建/订阅路由则按该路由口径

## 已知限制

- **Chromium 忽略 `KEYEVENTF_UNICODE` 注入**：往 Edge/Chrome/微信打字用 `typevk`（真实 VK 按键，跨应用通用）
- **中文/非 ASCII 优先走输入法**：`computer_key` 依次发拼音字母（如 `n,i,h,a,o`）→ `computer_key` `space`（或数字键选候选）上屏
- **`computer_type` 的 `auto` 策略**：纯 ASCII 短文本走真实 VK 按键（零剪贴板）；含中文/非 ASCII 或超过 120 字符时才走剪贴板，且**会保存并还原**用户原剪贴板。显式 `method: 'vk'` 时非 ASCII 会被丢弃而不是静默改道
- **WinUI（记事本等）不认注入的 Ctrl 组合键**：`computer_key` 对这类应用可能无效
- **自绘 UI 的 UIA 坐标不可信**（Edge 标签栏、Win11 记事本标签页会返回 ∞ 或错位）：请先 `view_screen` 肉眼定位再点
- **高 DPI（缩放 ≠ 100%）**：本 fork 已把截图 / 光标 / 覆盖层统一到**物理像素**；但 `view_screen` 仍会按 `max_width` 缩图，点击前请按返回文本给出的系数换算，或直接传 `image_width`（区域截图再加 `image_region`）
- **带自绘光标的软件**（游戏、部分 Electron 应用）无法被系统级光标替换覆盖
- **Linux / macOS 宿主**：当前只支持 Windows 原生与 WSL + Windows；其他系统下 `view_image` 可用，桌面工具会明确报错

---

## 相关项目

- [dsh-upgrade-guard](https://github.com/zzy6-a/dsh-upgrade-guard) —— DSH 升级兼容性守卫（同作者的配套插件）

## Contributors / 致谢

- [zzy6-a](https://github.com/zzy6-a) — 原作者
- [liuzwZYW](https://github.com/liuzwZYW) — 本 fork：修复高 DPI 坐标漂移与覆盖层模糊
- DeepSeek V4.1 — 架构设计、实现、测试与发布流程

## 开发提醒：改完 lib/index.js 别热重载

改了这个插件的 `lib/index.js` 之后，**不要用 `dev_reload_package` 热重载** —— 实测两次都把 DSH 主进程带崩（端口从 13493 → 18168 → 57914）。正确做法：

```powershell
# 免重启：先卸载再注入
dev_uninject_plugin  match=dsh-vision
dev_inject_plugin    dir=C:\Users\19827\.dsh\plugins\dsh-vision
# 或者干脆重启 DSH（插件已在 profile bundles 里，重启即按磁盘加载）
```

---

## 许可证

MIT © 2026 zzy6-a
