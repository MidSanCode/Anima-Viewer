/// 外壳渲染回归测试。
///
/// 覆盖启动页的 RenderFlex 溢出（标题 Row 右溢、动作卡片固定高度下溢）。
/// 外壳本身有 Scaffold（Material 祖先齐备），这里同时守住这一点，
/// 避免以后被改成无 Material 的裸容器而回归。
///
/// 注意：easy_localization 是全局单例，同一测试进程里起多个
/// AnimaViewerApp 实例会互相干扰，因此本文件只放这一个测试。
library;

import 'package:anima_viewer/app.dart';
import 'package:anima_viewer/core/i18n/l10n.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 反复 pump 直到 [ready] 成立，避免依赖固定时长而空过断言。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() ready, {
  int maxFrames = 60,
}) async {
  for (var i = 0; i < maxFrames; i++) {
    if (ready()) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // easy_localization 的 ensureInitialized / saveLocale 会走
    // shared_preferences，测试环境没有插件实现，这里给个空的内存实现。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/shared_preferences'),
          (MethodCall call) async =>
              call.method == 'getAll' ? <String, Object>{} : null,
        );
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('外壳渲染无异常，InkWell 都有 Material 祖先', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        child: EasyLocalization(
          supportedLocales: L10n.supportedLocales,
          path: 'assets/translations',
          fallbackLocale: L10n.fallbackLocale,
          useOnlyLangCode: false,
          child: const AnimaViewerApp(),
        ),
      ),
    );

    // 等引擎启动与首帧稳定。
    await _pumpUntil(tester, () => find.byType(InkWell).evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 500));

    final error = tester.takeException();
    expect(error, isNull, reason: '外壳渲染出现异常：$error');

    final inkWells = find.byType(InkWell).evaluate().toList();
    expect(inkWells, isNotEmpty, reason: '没有找到任何 InkWell —— 断言会空过，说明页面没渲染出来');
    for (final element in inkWells) {
      expect(
        element.findAncestorWidgetOfExactType<Material>(),
        isNotNull,
        reason: '${element.widget} 缺少 Material 祖先',
      );
    }
  });
}
