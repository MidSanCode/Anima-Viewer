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

| 名称 | 作用 |
| --- | --- |
| `ENGINE_WINDOWS_URL` | `anima.dll`，或内含它的 `.zip` 直链 |
| `ENGINE_LINUX_URL` | `libanima.so`，或内含它的 `.tar.gz` / `.zip` 直链 |
| `ENGINE_MACOS_URL` | `libanima.dylib`，或内含它的 `.tar.gz` / `.zip` 直链 |

引擎放在**另一个仓库**里。不配的话，产物中不含引擎动态库，应用会自动降级
到内置实现（功能完整、不崩溃，见 `lib/core/engine/engine_bootstrap.dart`）。
压缩包会被自动解开并在里面找对应的动态库，找不到就报错。

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
