# 构建与发布

本仓库用 GitHub Actions 构建，配置在 `.github/workflows/build.yml`。
只能在仓库的 **Actions 页面手动触发**（`workflow_dispatch`），没有 push 自动构建。

查看器只有桌面 + Web 工程（没有 `android/` 与 `ios/` 目录），所以平台开关
只有四个。

## 触发开关

| 开关 | 默认 | 产物 |
| --- | --- | --- |
| `build_windows` | ✅ | Windows x64 便携 zip（外加 Inno Setup 安装包，装不上就跳过） |
| `build_linux` | ⬜ | Linux x64 tar.gz |
| `build_macos` | ⬜ | macOS zip（未签名，见「已知限制」） |
| `build_web` | ⬜ | Web zip |
| `run_tests` | ✅ | 先跑 `flutter analyze` + `flutter test`；失败就不打包 |
| `publish_release` | ⬜ | 把**构建成功**的产物发布到 GitHub Releases |

一次全开会烧掉不少 CI 额度，按需勾选即可。同一分支只保留最新一次运行
（`concurrency` + `cancel-in-progress`），旧的排队会被取消。

## 版本号从哪来

只有一个来源：`pubspec.yaml` 的 `version:` 字段，形如 `0.1.0+1`。

- `0.1.0` → 版本号，注入 `--build-name`
- `1` → 构建号，注入 `--build-number`

应用内「关于」读的就是这两个值（`lib/core/platform/app_info.dart`）。
它们通过 `--dart-define-from-file=config.json` 传入，**不改仓库文件**，
所以同一次提交能产出不同构建号的包，而工作区保持干净（`config.json` 已
加进 `.gitignore`）。

## 发布到 Releases

勾选 `publish_release` 后，会多跑一个 `release` 作业：

- **标题与 tag 都是「版本号+构建数字」**，例如 `0.1.0+1`；
  tag 指向本次构建的那个 commit（`--target $GITHUB_SHA`）。
- **已存在的同名资产会跳过上传。** 所以重复发布是幂等的：上一次某个平台
  失败了，把它重新构建一次再勾发布，只会补上缺的那几个。
- 某个平台构建失败**不会**阻止发布 —— 成功的那几个照样发出去
  （失败的作业在运行页本来就是红的，不会看不见）。
- 一个产物都没有时会**响亮报错**，不会建出一个空的 Release。

`release` 是唯一需要写权限的作业（`permissions: contents: write`），
其余作业都只有 `contents: read`。

### Release 上的资产命名

| 平台 | 资产名 |
| --- | --- |
| Windows | `anima-viewer-windows-<版本>-portable.zip`、`anima-viewer-setup-<版本>.exe` |
| Linux | `anima-viewer-linux-<版本>.tar.gz` |
| macOS | `anima-viewer-macos-<版本>.zip` |
| Web | `anima-viewer-web-<版本>.zip` |

## 引擎产物怎么来的

引擎源码在**另一个仓库**里，本仓库的包默认**不含**引擎；此时应用自动降级到内置实现
（功能完整、不崩溃，见 `lib/core/engine/engine_bootstrap.dart`）。

**你什么都不用配。** 构建时会自动去引擎仓库的 Releases 里找本平台产物：

> 从**最新版开始往回**试，最多看 **5 个版本**，取第一个带本平台产物的；
> 那个版本没有本平台产物就继续回退；最近 5 个版本都没有就**跳过注入** ——
> 产物用内置实现，构建不会失败。

这样引擎某个平台临时构建不出来（或那次构建没勾那个平台）时，本仓库会自动落在上一个
能用的版本上，**不需要人工干预**，也不会发一个悄悄退化的包出去。跳过时会在日志里留
一条 `::warning::`，写明看过哪些版本，便于排查。

### 想钉死地址时才配 Variables

Settings → Secrets and variables → Actions → **Variables**。配了就**不再**自动回退，
直接用你给的地址：

| 名称 | 管哪个平台 | 指向什么 |
| --- | --- | --- |
| `ENGINE_WINDOWS_URL` | Windows 桌面 | `anima.dll`，或内含它的 `.zip` 直链 |
| `ENGINE_LINUX_URL` | Linux 桌面 | `libanima.so`，或内含它的 `.tar.gz` / `.zip` 直链 |
| `ENGINE_MACOS_URL` | macOS 桌面 | `libanima.dylib`，或内含它的 `.tar.gz` / `.zip` 直链 |
| `ENGINE_WEB_URL` | Web | wasm-bindgen 产物 `.zip`（`anima_wasm.js` + `anima_wasm_bg.wasm`） |

引擎仓库的资产名固定、不含版本号，所以可以指向「永远最新」：

```text
ENGINE_WINDOWS_URL = https://github.com/midsancode/anima-engine/releases/latest/download/anima-engine-windows-x64.zip
ENGINE_LINUX_URL   = https://github.com/midsancode/anima-engine/releases/latest/download/anima-engine-linux-x64.tar.gz
ENGINE_MACOS_URL   = https://github.com/midsancode/anima-engine/releases/latest/download/anima-engine-macos-universal.tar.gz
ENGINE_WEB_URL     = https://github.com/midsancode/anima-engine/releases/latest/download/anima-engine-web.zip
```

也可以钉到某个具体版本：把 `latest` 换成 tag（如 `0.1.0+12`，`+` 在 URL 里写成 `%2B`）。

查看器没有 Android / iOS 工程，所以那边也没有对应的注入步骤和变量 —— 引擎的
`anima-engine-android.aar` / `anima-engine-ios.xcframework.zip` 是编辑器用的。

另有两个一般不用配的口子，fork 或自建镜像时才需要：

| 名称 | 作用 |
| --- | --- |
| `ANIMA_ENGINE_REPO` | 换成别的引擎仓库（默认 `midsancode/anima-engine`） |
| `ANIMA_ENGINE_API_BASE` | 换成企业版/代理的 API 基址（默认 `https://api.github.com`） |

### 每个平台注入什么

形态不同，不是「一个动态库通吃」：

| 平台 | 注入方式 |
| --- | --- |
| Windows | 把 `anima.dll` 放到可执行文件旁边 |
| Linux | 把 `libanima.so` 放进 `bundle/lib/` |
| macOS | `libanima.dylib` 同时放进 `Contents/MacOS/` 和 `Contents/Frameworks/` |
| Android | 解出 `.aar` 里的 `jni/<abi>/libanima.so`，放到 `android/app/src/main/jniLibs/<abi>/`，随 APK 打包；应用用 `System.loadLibrary` 那套路径加载 |
| iOS | 解出 `anima.xcframework`，往 `ios/Flutter/{Debug,Release}.xcconfig` 追加 `-force_load`（**静态库必须显式链接**，App Store 不允许内嵌 dylib）；重复注入是幂等的 |
| Web | 解出 `anima_wasm.js` + `anima_wasm_bg.wasm`，放到 `web/anima_engine/`，浏览器端由入库的 `loader.js` 动态 `import` 起来 |

下载到 HTML 错误页之类的东西会被挡下 —— 会先检查魔数。但**钉死地址**时找不到产物是
**报错**（配错了就该响亮地失败）；**自动回退**时找不到是**跳过**（那是正常状态）。

### Web 的引擎是 wasm

Web 端的引擎不走 `dart:ffi`（浏览器里没有），而是走引擎的 wasm-bindgen 产物：
Dart 侧用 `dart:js_interop` 调 JS 导出的 `Engine`，调用面与原生端**同构**
（方法名 + JSON 参数 → JSON 信封），所以上层 UI 代码两份完全一样
（见 `lib/core/engine/web_wasm_am_engine_web.dart`）。

`loader.js` 用**可捕获的动态 `import`** 加载 wasm：未配置 `ENGINE_WEB_URL` 时
产物不存在，动态 import 会失败并被 `catch` 住，页面照常起来、自动降级 —— 
不会因为少一个文件就白屏。


查看器不需要 Android / iOS 的签名 secrets。

> **注意**：`editor/` 与 `viewer/` 是**两个互相独立的 git 仓库**，
> 变量和 secrets 必须在各自仓库里分别配置，不会互相同步。

## 已知限制

- **macOS 产物未签名、未公证**，在别的机器上打开会被 Gatekeeper 拦下。
  要正式分发需要自己补 `codesign` + `notarytool`。
- **Release 不可变性**：若仓库开启了 immutable releases，已发布的 Release
  就不能再补资产，「补齐缺失资产」那套会失败（会响亮报错，不会静默）。此时
  同一版本要么一次发全，要么先删掉 Release 重发。
- **权限**：`release` 作业声明了 `contents: write`。如果运行时遇到 403，
  去 Settings → Actions → General → Workflow permissions 确认默认权限
  没有被锁成只读。
- **引擎地址必须是可匿名下载的直链**（例如 Release 资产直链）。私有仓库需要带
  token 的地址，目前没有支持。
- **自动回退只看 Release**：引擎仓库只发 `draft`（草稿）不发 Release 时，本仓库
  找不到任何版本 —— 会跳过注入。
- **回退有边界（5 个版本）**：超过这个范围引擎还没有某个平台的产物，就跳过注入。
  某个平台长期没有产物的话，该去引擎仓库确认它的构建是不是一直失败。
