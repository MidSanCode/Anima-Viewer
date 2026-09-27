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

    expect(kAppVersion, expectedVersion);
    expect(kAppBuildNumber, expectedBuild);
    expect(kAppVersionWithBuild, declared);
  });
}
