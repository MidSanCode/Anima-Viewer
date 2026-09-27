/// `pubspec.yaml` 的 `version:` 与 `lib/core/platform/app_info.dart` 中
/// 的版本/构建常量必须一致。
///
/// Dart 侧拿不到 `package_info_plus`（不在离线 pub 缓存里），也不希望为了
/// 一个版本号引入平台插件，所以版本常量是手写的；这个测试就是防漂移的守卫：
/// 只改 `pubspec.yaml` 会在这里失败。
library;

import 'dart:io';

import 'package:anima_viewer/core/platform/app_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('app_info 常量与 pubspec.yaml 的 version 保持一致', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*(\S+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);

    expect(match, isNotNull, reason: 'pubspec.yaml 中找不到 version: 行');
    final declared = match!.group(1)!;
    final parts = declared.split('+');
    final expectedVersion = parts.first;
    final expectedBuild = parts.length > 1 ? parts[1] : '';

    // CI 用 `--dart-define=BUILD_VERSION/BUILD_NUMBER` 覆盖时不比对（见
    // `app_info.dart`）：那种情况下构建号来自 CI，而 pubspec 仍是仓库内的
    // 值，两者本就该不同。`flutter test` 不传这些 define，所以日常仍会守卫。
    const injected = String.fromEnvironment('BUILD_VERSION');
    if (injected.isEmpty) {
      expect(kAppVersion, expectedVersion);
    }
    const injectedBuild = String.fromEnvironment('BUILD_NUMBER');
    if (injected.isEmpty && injectedBuild.isEmpty) {
      expect(kAppBuildNumber, expectedBuild);
      expect(kAppVersionWithBuild, declared);
    }
  });
}
