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

## 需要配置的仓库变量

**全部可选**：一个都不配也能构建，只是产物更弱（见下）。

### Variables

Settings → Secrets and variables → Actions → **Variables** 标签页。

| 名称 | 管哪个平台 | 指向什么 |
| --- | --- | --- |
| `ENGINE_WINDOWS_URL` | Windows 桌面 | `anima.dll`，或内含它的 `.zip` 直链 |
| `ENGINE_LINUX_URL` | Linux 桌面 | `libanima.so`，或内含它的 `.tar.gz` / `.zip` 直链 |
| `ENGINE_MACOS_URL` | macOS 桌面 | `libanima.dylib`，或内含它的 `.tar.gz` / `.zip` 直链 |
| `ENGINE_WEB_URL` | Web | wasm-bindgen 产物 `.zip`（`anima_wasm.js` + `anima_wasm_bg.wasm`） |

引擎放在**另一个仓库**里，不配的话产物中不含引擎，应用会自动降级到内置实现
（功能完整、不崩溃，见 `lib/core/engine/engine_bootstrap.dart`）。

每个平台注入的产物形态不同，不是「一个动态库通吃」：

| 平台 | 注入方式 |
| --- | --- |
| Windows | 把 `anima.dll` 放到可执行文件旁边 |
| Linux | 把 `libanima.so` 放进 `bundle/lib/` |
| macOS | `libanima.dylib` 同时放进 `Contents/MacOS/` 和 `Contents/Frameworks/` |
| Android | 解出 `.aar` 里的 `jni/<abi>/libanima.so`，放到 `android/app/src/main/jniLibs/<abi>/`，随 APK 打包；应用用 `System.loadLibrary` 那套路径加载 |
| iOS | 解出 `anima.xcframework`，往 `ios/Flutter/{Debug,Release}.xcconfig` 追加 `-force_load`（**静态库必须显式链接**，App Store 不允许内嵌 dylib）；重复注入是幂等的 |
| Web | 解出 `anima_wasm.js` + `anima_wasm_bg.wasm`，放到 `web/anima_engine/`，浏览器端由入库的 `loader.js` 动态 `import` 起来 |

压缩包会被自动解开并在里面找需要的文件，找不到就**报错**（不会静默地发一个
没引擎的包出去）。下载到 HTML 错误页之类的东西也会被挡下 —— 会先检查魔数。

### 引擎产物从哪来

引擎源码在另一个仓库（Rust 工作区，产出 12 个 crate）。那个仓库的 Actions
同样是手动触发，勾 **`publish_release`** 后会把六个平台的引擎产物发成 Release，
资产名**不含版本号**，因此可以直接用「永远指向最新发布」的地址，配一次长期有效：

```text
ENGINE_WINDOWS_URL = https://github.com/midsancode/anima-engine/releases/latest/download/anima-engine-windows-x64.zip
ENGINE_LINUX_URL   = https://github.com/midsancode/anima-engine/releases/latest/download/anima-engine-linux-x64.tar.gz
ENGINE_MACOS_URL   = https://github.com/midsancode/anima-engine/releases/latest/download/anima-engine-macos-universal.tar.gz
ENGINE_ANDROID_URL = https://github.com/midsancode/anima-engine/releases/latest/download/anima-engine-android.aar
ENGINE_IOS_URL     = https://github.com/midsancode/anima-engine/releases/latest/download/anima-engine-ios.xcframework.zip
ENGINE_WEB_URL     = https://github.com/midsancode/anima-engine/releases/latest/download/anima-engine-web.zip
```

用 `latest` 的代价是「引擎更新后，本仓库下次构建就自动换了引擎版本」，这是有
意为之：应用与引擎版本不必手动对齐。要锁死某个版本，把 `latest` 换成具体 tag
（如 `0.1.0+12`，`+` 在 URL 里要写成 `%2B`）。

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
- **`ENGINE_*_URL` 必须是可匿名下载的直链**（例如 Release 资产直链）。
  私有仓库需要带 token 的地址，目前没有支持。
