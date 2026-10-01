# Anima Viewer 赋灵 查看器

[English](#english) · [中文](#中文)

A cross-platform viewer for **playing back deformable 2D character models** — open an
`.amproj` project and preview its motions, expressions, physics and parameters. Built with
Flutter; runs on Windows, Linux, macOS and the web from one codebase.

面向**可变形 2D 角色模型**的播放与查看工具：打开 `.amproj` 工程，预览动作、表情、
物理与参数。基于 Flutter，同一套代码跑 Windows、Linux、macOS 与 Web。

---

## 中文

### 这是什么

赋灵查看器是这个项目里**负责播放**的一端。它不做模型编辑，只把工程打开、把角色放上
画面，让你试听动作、切表情、拖参数、看物理效果。配套的**编辑器**负责制作，
两者共用同一份引擎契约与同一种工程格式。

它同时兼顾两件事：**给人看**（预览与试听）和**给程序接**（导出运行时包，
生成 C / Dart / JavaScript 的接入代码）。

### 功能

| 面板 | 做什么 |
| --- | --- |
| 动作 | 播放控制、播放头、循环、倍速、淡入淡出、单次播放 |
| 表情 | 表情列表与切换，一键清空 |
| 参数 | 参数实时调值、单项重置 |
| 物理 | 物理开关与参数、自动眨眼、呼吸、参数绑定 |
| 性能 | 引擎后端、引擎版本、统计数字与能力探测 |
| 渲染 | 画质档位（低 / 中 / 高）、像素比、网格与参考线、**截图** |
| 导出 | **运行时包**导出 |
| 集成 | 生成 **C / Dart / JavaScript** 三种接入代码，可一键复制 |

其它：

- **启动页**：打开工程、导入工程、加载示例，以及最近打开列表（可单条遗忘、可清空）。
- **8 个可停靠面板**，可折叠，画布可全屏。
- **中英双语界面**，跟随系统或手动切换。
- **深色优先的主题**，可切换浅色与跟随系统。
- **快捷键**：打开、导出、播放/暂停、前后帧、缩放、翻转、面板切换等。
- **引擎自动降级**：引擎库缺失或加载失败时退回内置实现，界面**不崩溃、不白屏**，
  只在通知栏给出可读提示，并提供重试。

### 平台

Windows · Linux · macOS · Web

Web 版走 wasm 绑定，桌面版走 FFI 动态库；两条路径对上层是同一个接口。

### 快速开始

需要 Flutter 3.44 或更高版本。

```bash
flutter pub get
flutter run -d windows      # 或 linux / macos / chrome
```

构建产物：

```bash
flutter build windows --release
flutter build web --release
```

生成一个示例工程来试：

```bash
dart run tool/make_demo_project.dart
```

### 工程格式

查看器读的是编辑器写出的 `.amproj`，两种形态都支持：

- **目录模式**：`info.json`、`registry.json`、`assets/`、`metadata/`、`spec/`。
- **归档模式**：ZIP + Deflate，条目限定在白名单前缀内。

导入时先解包再校验，校验不过**回滚**删除目标目录。校验同时核对
`<名称>.amproj.sha256`，哈希不符会拒绝并给出提示。

### 引擎

查看器通过 `AmEngine.call(method, params)` 这一个入口访问引擎，**没有第二个调用通道**。
后端按平台自动选择：

| 平台 | 后端 |
| --- | --- |
| 桌面 | FFI 动态库（`anima.dll` / `libanima.so` / `libanima.dylib`） |
| Web | wasm 绑定 |
| 兜底 | 内置实现（引擎不可用时） |

引擎库从哪来，有两条路：

- **什么都不配**（推荐）：构建时自动去引擎仓库的 Releases 里找本平台产物 ——
  从最新版往回找，最多看 5 个版本，取第一个带本平台产物的；都没有就跳过注入，
  产物退回内置实现，构建**不会失败**。
- **钉死地址**：配 `ENGINE_<平台>_URL` 环境变量，就只用这个地址，不再自动回退。

细节见 [`docs/build-and-release.md`](docs/build-and-release.md)。

### 开发

```bash
dart format lib test
flutter analyze
flutter test
```

i18n 键完整性校验（界面不许露出内部键名）：

```powershell
& .\tool\check_translations.ps1
```

仓库结构见 [`docs/architecture.md`](docs/architecture.md)。

### 已知限制

- macOS 产物**未签名、未公证**，在别的机器上会被 Gatekeeper 拦下。
- 当前引擎 ABI 未导出共享纹理句柄，画布实际走降级画家（`CustomPaint`），
  而非零拷贝的 `Texture` 路径。
- 引擎地址需为**可匿名下载的直链**，私有仓库尚未支持。
- 查看器只读工程，**不做编辑**；要改模型请用配套的编辑器。

### 许可

GNU Affero General Public License v3.0，见 [`LICENSE`](LICENSE)。

---

## English

### What it is

Anima Viewer is the **playback** half of this project. It does no model editing: it opens a
project, puts the character on screen, and lets you audition motions, switch expressions,
drag parameters, and watch the physics. The companion **editor** handles authoring; both
share one engine contract and one project format.

It serves two audiences at once: **humans** (previewing and auditioning) and **programs**
(exporting a runtime package and generating C / Dart / JavaScript integration code).

### Features

| Panel | What it does |
| --- | --- |
| Motions | Playback control, playhead, looping, speed, cross-fade, once-through |
| Expressions | Expression list and switching, with a one-click clear |
| Parameters | Live parameter adjustment and per-parameter reset |
| Physics | Physics toggle and settings, auto-blink, breathing, parameter bindings |
| Performance | Engine backend, engine version, statistics and capability probing |
| Render | Quality tiers (low / medium / high), pixel ratio, grid and guides, **screenshot** |
| Export | **Runtime package** export |
| Integration | Generated **C / Dart / JavaScript** snippets, copyable in one click |

Also:

- **Start page**: open a project, import one, load a sample, plus a recent-files list
  (forget a single entry or clear the list).
- **8 dockable panels**, collapsible, with a fullscreen canvas.
- **Bilingual UI** (Chinese and English), following the system or set manually.
- **Dark-first theme** with light and follow-system options.
- **Shortcuts** for open, export, play/pause, previous/next frame, zoom, flip, panel
  switching and more.
- **Automatic engine fallback**: if the engine library is missing or fails to load, the app
  drops back to a built-in implementation — the UI never crashes and never goes blank,
  showing a readable notice with an option to retry.

### Platforms

Windows · Linux · macOS · Web

The web build uses the wasm binding; desktop builds use the FFI dynamic library. Both paths
present the same interface upward.

### Getting started

Requires Flutter 3.44 or later.

```bash
flutter pub get
flutter run -d windows      # or linux / macos / chrome
```

Release builds:

```bash
flutter build windows --release
flutter build web --release
```

Generate a sample project to try:

```bash
dart run tool/make_demo_project.dart
```

### Project format

The viewer reads the `.amproj` projects written by the editor, in both shapes:

- **Directory mode**: `info.json`, `registry.json`, `assets/`, `metadata/`, `spec/`.
- **Archive mode**: ZIP + DEFLATE, with entries confined to a whitelist of prefixes.

Import unpacks first and validates second, **rolling back** by deleting the target directory
on failure. Validation also checks the companion `<name>.amproj.sha256`; a hash mismatch is
rejected with a notice.

### The engine

The viewer reaches the engine through exactly one entry point, `AmEngine.call(method, params)`
— there is **no second channel**. The backend is selected automatically per platform:

| Platform | Backend |
| --- | --- |
| Desktop | FFI dynamic library (`anima.dll` / `libanima.so` / `libanima.dylib`) |
| Web | wasm binding |
| Fallback | Built-in implementation (when the engine is unavailable) |

There are two ways to supply the engine library:

- **Configure nothing** (recommended): the build automatically looks for this platform's
  artifact in the engine repository's Releases — walking back from the newest release at
  most 5 versions and taking the first one that has this platform's artifact. If none does,
  injection is skipped and the build **still succeeds**, falling back to the built-in
  implementation.
- **Pin an address**: set an `ENGINE_<PLATFORM>_URL` environment variable and only that
  address is used, with no automatic fallback.

See [`docs/build-and-release.md`](docs/build-and-release.md) for details.

### Development

```bash
dart format lib test
flutter analyze
flutter test
```

i18n key completeness check (the UI must never leak internal key names):

```powershell
& .\tool\check_translations.ps1
```

Repository layout: [`docs/architecture.md`](docs/architecture.md).

### Known limitations

- macOS artifacts are **unsigned and unnotarized**, so Gatekeeper blocks them on other machines.
- The current engine ABI does not export a shared texture handle, so the canvas actually
  uses the fallback painter (`CustomPaint`) rather than the zero-copy `Texture` path.
- The engine address must be an **anonymously downloadable direct link**; private
  repositories are not supported yet.
- The viewer is read-only with respect to projects — it does **no editing**. Use the
  companion editor to change a model.

### License

GNU Affero General Public License v3.0 — see [`LICENSE`](LICENSE).
