/// 应用元信息：版本号与构建号。
///
/// 唯一事实来源是 `pubspec.yaml` 的 `version: 0.1.0+1`（`+` 之前是版本号，
/// 之后是构建号）。`package_info_plus` 不在依赖清单内，因此这里放一份生成
/// 常量，并由 `test/app_info_test.dart` 做漂移守卫：一旦 `pubspec.yaml` 的
/// 版本变了而这里没跟着改，测试会失败。
///
/// CI 可以在**不改动仓库文件**的前提下覆盖版本号 / 构建号，让同一次提交产出
/// 形如 `0.1.0+42` 的包：
///
/// ```sh
/// flutter build windows --build-name=0.1.0 --build-number=42 \
///   --dart-define=BUILD_VERSION=0.1.0 --dart-define=BUILD_NUMBER=42
/// ```
///
/// 未传 `--dart-define` 时（本地开发、`flutter test`）自动退回下面的仓库内
/// 常量，行为与从前完全一致。
library;

/// 仓库内的版本号：`pubspec.yaml` 中 `version` 的 `+` 之前部分。
const String _pubspecVersion = '0.1.0';

/// 仓库内的构建号：`pubspec.yaml` 中 `version` 的 `+` 之后部分。
const String _pubspecBuildNumber = '1';

/// CI 注入的版本号；未注入时为空串（`String.fromEnvironment` 的默认值）。
const String _injectedVersion = String.fromEnvironment('BUILD_VERSION');

/// CI 注入的构建号；未注入时为空串。
const String _injectedBuildNumber = String.fromEnvironment('BUILD_NUMBER');

/// 版本号：CI 注入优先，否则用仓库内常量。
const String kAppVersion = _injectedVersion == ''
    ? _pubspecVersion
    : _injectedVersion;

/// 构建号：CI 注入优先，否则用仓库内常量。
const String kAppBuildNumber = _injectedBuildNumber == ''
    ? _pubspecBuildNumber
    : _injectedBuildNumber;

/// 形如 `0.1.0+1`，用于窗口标题等需要「版本+构建」连写的位置。
const String kAppVersionWithBuild = '$kAppVersion+$kAppBuildNumber';
