/// 主题回归测试。
///
/// 背景：曾用 `ThemeData.textTheme.apply(fontSizeFactor: 0.95)` 做全局字号缩放，
/// 而 `ThemeData.textTheme` 在 `ThemeData.localize` 之前 `fontSize` 全为 `null`，
/// 该调用必然触发断言并让 `AppTheme.dark()` 抛异常 —— 应用启动即失败。
/// 这里锁死「主题可构造」与「缩放确实生效」两件事。
library;

import 'package:anima_viewer/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AppTheme.dark / light 可构造且不抛异常', () {
    expect(() => AppTheme.dark(), returnsNormally);
    expect(() => AppTheme.light(), returnsNormally);
    final dark = AppTheme.dark();
    final light = AppTheme.light();
    expect(dark.brightness, Brightness.dark);
    expect(light.brightness, Brightness.light);
    // 令牌必须挂上，否则面板取不到颜色。
    expect(dark.extension<AppTokens>(), isNotNull);
    expect(light.extension<AppTokens>(), isNotNull);
  });

  test('ThemeData.textTheme 在 localize 之前 fontSize 为 null（前提约束）', () {
    // 这个前提是上面那个 bug 的根因；若 Flutter 改了行为，下面的缩放断言需要重审。
    expect(AppTheme.dark().textTheme.bodyMedium?.fontSize, isNull);
  });

  testWidgets('MaterialApp 内字号按 kTextScaleFactor 缩放', (tester) async {
    double? bodyMedium;
    double? labelSmall;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Builder(
          builder: (context) {
            final text = Theme.of(context).textTheme;
            bodyMedium = text.bodyMedium?.fontSize;
            labelSmall = text.labelSmall?.fontSize;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    // Material 2021 的基准值：bodyMedium 14、labelSmall 11。
    expect(bodyMedium, isNotNull);
    expect(labelSmall, isNotNull);
    expect(bodyMedium, closeTo(14.0 * AppTheme.kTextScaleFactor, 0.001));
    expect(labelSmall, closeTo(11.0 * AppTheme.kTextScaleFactor, 0.001));
  });

  testWidgets('浅色主题同样缩放', (tester) async {
    double? bodyMedium;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) {
            bodyMedium = Theme.of(context).textTheme.bodyMedium?.fontSize;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(bodyMedium, closeTo(14.0 * AppTheme.kTextScaleFactor, 0.001));
  });
}
