# Vision Use · DSH Computer Use

English | [中文](README.md)

> Repo: `dsh-vision-use` (fork of [zzy6-a/vision-use](https://github.com/zzy6-a/vision-use)) · Package: `dsh-vision`
>
> Let the DeepSeek Harness agent **actually see your screen and operate the Windows desktop** — with a Codex computer-use style red overlay (press **Esc** to abort at any time).
>
> This fork fixes two high-DPI problems (display scaling ≠ 100%): **coordinate drift between screenshot and click** and **an overlay that only covers a corner of the screen and looks blurry** — see [DPI and coordinates](#dpi-and-coordinates-read-this-on-high-dpi).

[![Download](https://img.shields.io/badge/Download-fork-2e7d32?style=flat&logo=github&logoColor=white)](https://github.com/liuzwZYW/dsh-vision-use)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![dsh-plugin](https://img.shields.io/badge/topic-dsh--plugin-2f6fed)](https://github.com/topics/dsh-plugin)

---

## What it does

| Capability | Tool | Description |
|---|---|---|
| 👁 **See** | `view_screen` | Capture the whole Windows screen → straight into the model's vision channel (real pixels, not OCR) |
| 👁 **See** | `view_image` | Push any image file (Linux or Windows path) into the vision channel |
| 🖱 **Act** | `computer_move` | Glide the cursor smoothly to (x, y) |
| 🖱 **Act** | `computer_click` | Left / right / double click with a click ripple |
| ⌨️ **Act** | `computer_type` | Type text (default: **real VK keystrokes**, zero clipboard; for Chinese use the IME route: `computer_key` pinyin → `space`/digit to commit) |
| ⌨️ **Act** | `computer_key` | Key combinations (`ctrl+t`, `enter`, `alt+f4`, …) |
| 🎛 **Control** | `computer_overlay` | Start / stop / status the overlay (configurable idle auto-close) |
| 📊 **Control** | `computer_status` | Overlay state / Esc flag / current mode / cursor position |

### Visual feedback (Codex style)

```
┌───────────────────────────────────────────────┐
│  ╔═════════════════════════════════════════╗  │ ← soft red border (per-pixel alpha)
│  ║  ● DeepSeek Harness is operating  [Esc]  ║  │ ← top status badge
│  ║                                         ║  │
│  ║         typing → red ring + caret       ║  │
│  ║         click  → 0.7s ripple (pinned)    ║  │
│  ║         move   → ring follows; fades 1s  ║  │
│  ╚═════════════════════════════════════════╝  │
└───────────────────────────────────────────────┘
```

- **One cursor set** (arrow / I-beam / hand) in a unified red-and-white gradient, while **keeping Windows' native context switching**
- **Overlay always on**: every hands operation (move/click/type/key) is forced to bring up the overlay first — no silent control
- **Esc abort**: the keypress writes a cancel flag → the overlay exits → every subsequent action is rejected
- **Task-level keep-alive**: while the agent is still working in this turn (thinking or running other tools), the overlay stays up; it packs up about 4 seconds after the turn ends. The overlay's own idle timeout remains as a fallback (`idle_seconds`, default 30, 0 = disable fallback)
- **Status pill under the composer**: colored dot + `CU idle/move/type/click` + a Stop button

---

## Install

### Option 1: git source (this fork, recommended)

```bash
dsh plugin --profile web add github:liuzwZYW/dsh-vision-use
```

### Option 2: local directory

```bash
dsh plugin --profile web add /path/to/dsh-vision-use
```

After installing, **restart DSH** (the `client.js` half registers at boot). Refresh the browser and the status pill appears below the composer.

---

## Quick start

Just tell the agent:

> Take a look at my screen

> Search for the DeepSeek website in Bing and open it

> Open Notepad and type something

The agent will automatically: start the overlay → `view_screen` to look → `computer_*` to act → look again to verify. You can press **Esc** to stop it at any moment.

---

## DPI and coordinates (read this on high DPI)

Windows silently virtualizes any process that has not declared DPI awareness: `SystemInformation.VirtualScreen` reports only the **logical** resolution (physical ÷ scale) and `CopyFromScreen` hands back only the **top-left `1/scale` of the physical screen**. The original symptoms were:

| Symptom | Cause |
|---|---|
| The agent can only see the top-left corner; anything in the lower right is invisible | Capture was limited to the top-left `1/scale` region (measured: a 3072×1920 screen yielded 1536×960, pixel-identical to the physical top-left corner = pure crop, not a downscale) |
| The red frame only surrounds the top-left corner, with thin lines/text | The border bitmap was rendered at logical size, so at 200% scaling it was half the intended visual size |
| Ring/ripple did not line up with the cursor and looked blurry | Overlay windows/bitmaps were positioned and stretched in the virtualized coordinate space |

How this fork fixes it: `scripts/dpi.ps1` makes **every** desktop-side PowerShell process declare **Per-Monitor-V2 DPI awareness** (falling back through PMv1 / shcore / `SetProcessDPIAware`), so:

- `VirtualScreen` is the real physical resolution and screenshots are **1:1 physical pixels** (3072×1920 really is 3072×1920);
- `GetCursorPos` / `SetCursorPos` were always physical → **screenshot pixels and click pixels are now the same space**;
- the overlay allocates bitmaps at physical size while drawing in 96-dpi logical coordinates via `ScaleTransform` → the frame covers the whole screen and lines/text/ring are rendered as vectors at physical resolution, **no more blur at high scaling**.

### Coordinates for computer_click / computer_move

These tools take **physical screen pixels**. `view_screen` downscales the image to `max_width` (default 1600), so pixels measured on that image are *not* screen pixels. Two correct options:

1. Convert with the factor printed in the tool result: `screen_x = image_x × k` (e.g. a 3072-wide screen with a 1600-wide image → k = 1.92)
2. Pass image pixels as-is together with the image width: `computer_click(x: 700, y: 380, image_width: 1600)` — the plugin converts using the real screen size

Self-check: `computer_status` prints `SCREEN 3072x1920 ORIGIN 0,0 DPI 192 SCALE 2`, or run `cu.ps1 -Action screen`.

---

## Requirements

| Item | Requirement |
|---|---|
| Host (auto-detected) | **Windows native** or **Windows + WSL2**; the plugin detects where DSH runs and picks the matching path/subprocess strategy |
| Interop when on WSL | WSL interop enabled (`/proc/sys/fs/binfmt_misc/WSLInterop` = enabled); the plugin uses `\\wsl.localhost\<distro>` UNC paths automatically |
| Windows side | **PowerShell 7 (`pwsh`) preferred, falling back to the built-in PowerShell 5.1**; GDI+/WinForms (`System.Drawing`) |
| DSH | `>= 0.1.5-rc.1` |
| Node | The plugin itself has zero runtime dependencies (pure ESM + PowerShell child processes) |
| Linux / macOS | Desktop control is unsupported; `view_screen` and hands tools fail with a clear error, while `view_image` still works |

### PowerShell interpreter selection

At startup the plugin probes `pwsh.exe` (PowerShell 7) first, then `powershell.exe` (5.1), and caches the result. `computer_status` reports which interpreter is actually in use:

| Purpose | Behavior |
|---|---|
| `view_screen` capture script, `cu.ps1` (mouse/keyboard) | Uses pwsh 7 (faster process startup); falls back to 5.1 when pwsh is absent |
| `overlay-v2.ps1` (overlay) | Prefers pwsh 7 (the C# engine compiles on both .NET and .NET Framework); if that pwsh lacks WinForms / ref assemblies and the overlay fails to come up, it retries once with 5.1 |

---

## Architecture

```
vision-use/
├── lib/index.js        host half: 8 tools + 2 API routes + systemPrompt capability declaration
├── lib/client.js       browser half: composer-dock status pill
├── cordis.patch.yml    bundle layer: inserts the plugin row into the profile tree
├── dsh.plugin.json     plugin manifest (for dsh-market / the plugin manager UI)
└── scripts/            Windows-side toolkit (self-contained, shipped with the package)
    ├── dpi.ps1         DPI awareness (Per-Monitor-V2): screenshot/cursor/overlay all in physical pixels
    ├── cu.ps1          mouse/keyboard executor + Esc sentinel
    ├── overlay-v2.ps1  overlay: border / badge / ring / ripple + C# 60fps animation engine
    └── TOOLKIT.md      toolkit documentation + 10 field-tested rules
```

### Environment auto-detection

At startup the plugin inspects `process.platform`, `WSL_DISTRO_NAME` / `WSL_INTEROP`, and `/proc/version`:

| Detected | Behavior |
|---|---|
| Windows native | calls `powershell.exe` directly; flags/state/heartbeat go to `%TEMP%` |
| WSL + Windows | calls `powershell.exe` through interop; flags/state/heartbeat go to `/tmp` and are exposed as `\\wsl.localhost\<distro>\tmp` for PowerShell |
| Linux / macOS | desktop tools return a clear unsupported error; `view_image` keeps working |

PowerShell children learn the cross-boundary flag directory through the `DSH_VISION_FLAG_DIR` env var (automatically added to `WSLENV` on WSL).

**Vision**: images are returned as `content: [{type:'image', attachment}]`; the host's `collectImageRefs()` recursively collects them and sends them with the next request — this is DSH's official image channel, so **screenshots count as normal model vision tokens** (on the DeepSeek official route, roughly 369 tokens per image, capped at 384).

**Animation**: the overlay uses `UpdateLayeredWindow` for true per-pixel alpha glow; the hot path runs entirely in compiled C# (PowerShell only keeps the beat), at about 8.8% of a single core.

---

## Configuration

| Parameter | Default | Description |
|---|---|---|
| `computer_overlay start idle_seconds` | `30` | Overlay idle-timeout fallback; during an active task the plugin keeps refreshing the heartbeat, so it will not vanish while the agent is thinking (0 = disable fallback) |
| `-MaxSeconds` | `0` | Maximum overlay lifetime (0 = unlimited) |
| `-NoCursorChange` | off | Do not install the red cursor set (keep the system default) |

Privacy note: screenshots enter the current session context as image attachments (equivalent to pasting an image manually).

---

## Billing & privacy

- **The plugin itself makes zero network requests**: it calls no API; it only stores screenshots in the local attachment store and hands the image blocks to the host
- Images are ultimately **sent to the model route selected for the current session** (DSH's model adapter performs the request)
- **It fully follows the model you choose**: the plugin does not choose or change routes; screenshots always go to **the model selected in your model picker**
  (pick opencode-go and it goes to opencode-go; pick the official route and it goes to the official route)
- **Vision-capability check**: if the selected model does not declare image-input support, `view_screen` / `view_image` fail with a clear error instead of letting the request die halfway
- On the official route, vision billing is about **369 tokens per image** (DSH caps at 384); self-hosted / subscription routes follow their own terms

## Known limitations

- **Chromium ignores `KEYEVENTF_UNICODE` injection**: type into Edge/Chrome/WeChat with `typevk` (real VK keystrokes, works across apps)
- **Chinese / non-ASCII goes through the IME**: `computer_key` with pinyin letters (e.g. `n,i,h,a,o`) then `computer_key` `space` (or a digit) to commit; the default `computer_type` path **rejects** non-ASCII on purpose instead of silently falling back to the clipboard
- **Clipboard mode is opt-in**: only enabled via `method: 'clipboard'` (note: it overwrites the user's clipboard content)
- **WinUI (Notepad, etc.) does not accept injected Ctrl combinations**: `computer_key` may not work in those apps
- **UIA coordinates are unreliable in custom-drawn UIs** (Edge tab bar, Windows 11 Notepad tabs return ∞ or wrong offsets): use `view_screen` to locate targets visually first
- **High DPI (scaling ≠ 100%)**: this fork unifies screenshot / cursor / overlay on **physical pixels**, but `view_screen` still downscales to `max_width`, so convert measured image pixels with the factor in the tool result — or just pass `image_width`
- **Software with its own drawn cursor** (games, some Electron apps) cannot be overridden by the system-level cursor replacement
- **Linux / macOS hosts**: only Windows native and WSL + Windows are supported; `view_image` still works, desktop tools fail clearly

---

## Related projects

- [dsh-upgrade-guard](https://github.com/zzy6-a/dsh-upgrade-guard) — DSH upgrade compatibility guard (companion plugin by the same author)

## Contributors

- [zzy6-a](https://github.com/zzy6-a) — original author
- [liuzwZYW](https://github.com/liuzwZYW) — this fork: fixed high-DPI coordinate drift and overlay blur
- DeepSeek V4.1 — architecture, implementation, testing, and release workflow

## License

[MIT](LICENSE)
