/// 应用元信息：版本号与构建号。
///
/// 唯一事实来源是 `pubspec.yaml` 的 `version: 0.1.0+1`（`+` 之前是版本号，
/// 之后是构建号）。`package_info_plus` 不在依赖清单内，因此这里放一份
/// 生成常量，并由 `test/app_info_test.dart` 做漂移守卫：
/// 一旦 `pubspec.yaml` 的版本变了而这里没跟着改，测试会失败。
library;

/// 版本号，对应 `pubspec.yaml` 中 `version` 的 `+` 之前部分。
const String kAppVersion = '0.1.0';

/// 构建号，对应 `pubspec.yaml` 中 `version` 的 `+` 之后部分。
const String kAppBuildNumber = '1';

/// 形如 `0.1.0+1`，用于窗口标题等需要「版本+构建」连写的位置。
const String kAppVersionWithBuild = '$kAppVersion+$kAppBuildNumber';
