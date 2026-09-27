/// 主题回归测试。
///
/// 背景 1：曾用 `ThemeData.textTheme.apply(fontSizeFactor: 0.95)` 做全局字号缩放，
/// 而 `ThemeData.textTheme` 在 `ThemeData.localize` 之前 `fontSize` 全为 `null`，
/// 该调用必然触发断言并让 `AppTheme.dark()` 抛异常 —— 应用启动即失败。
/// 这里锁死「主题可构造」与「缩放确实生效」两件事。
///
/// 背景 2：暗色主题下图标/小字用了 `tokens.divider`（那是**边框**色，在深色
/// 面板上对比度只有 ~1.2:1），整片 UI 看不见字。这里锁死「前景色必须够亮」。
library;

import 'dart:math' as math;

import 'package:anima_viewer/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG 相对亮度。
double _luminance(Color color) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

/// WCAG 对比度（1:1 ～ 21:1）。
double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

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

  /// 回归：暗色主题里全部文字/图标颜色必须在各自背景上可读。
  ///
  /// 之前 `SmallIconButton`、通知图标、标签图标都用了 `tokens.divider` ——
  /// 它是个**边框**色，放在 `panelBackground` 上对比度只有 ~1.2:1，
  /// 等于整片 UI 看不见。
  test('暗色主题：文字/图标前景色在所有面板背景上都够亮', () {
    final dark = AppTheme.dark();
    final tokens = dark.extension<AppTokens>()!;

    final foregrounds = <String, Color>{
      'text': dark.colorScheme.onSurface,
      'textMuted': tokens.textMuted,
      'primary': dark.colorScheme.primary,
      'secondary': dark.colorScheme.secondary,
      'error': dark.colorScheme.error,
    };
    final backgrounds = <String, Color>{
      'canvasBackground': tokens.canvasBackground,
      'panelBackground': tokens.panelBackground,
      'panelHeader': tokens.panelHeader,
      'surface': dark.colorScheme.surface,
    };

    for (final fg in foregrounds.entries) {
      for (final bg in backgrounds.entries) {
        final ratio = _contrast(fg.value, bg.value);
        // 4.5:1 是 WCAG AA 对正文的要求；小图标至少也要 3:1。
        expect(
          ratio,
          greaterThanOrEqualTo(3.0),
          reason:
              '${fg.key} 在 ${bg.key} 上对比度 ${ratio.toStringAsFixed(2)}:1，太暗看不清',
        );
      }
    }

    expect(
      _contrast(tokens.textMuted, tokens.panelBackground),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      _contrast(tokens.textMuted, tokens.panelHeader),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      _contrast(dark.colorScheme.onSurface, tokens.panelBackground),
      greaterThanOrEqualTo(4.5),
    );
  });

  /// 反向约束：`divider` 是边框色，绝不能再被当成前景色。
  test('暗色主题：divider 是边框色，不能当文字色', () {
    final tokens = AppTheme.dark().extension<AppTokens>()!;
    final asText = _contrast(tokens.divider, tokens.panelBackground);
    expect(
      asText,
      lessThan(3.0),
      reason: 'divider 现在对比度 ${asText.toStringAsFixed(2)}:1；'
          '若它变亮了，说明有人把它当成了前景色',
    );
  });

  test('浅色主题：文字/图标同样可读', () {
    final light = AppTheme.light();
    final tokens = light.extension<AppTokens>()!;
    expect(
      _contrast(tokens.textMuted, tokens.panelBackground),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      _contrast(light.colorScheme.onSurface, tokens.panelBackground),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      _contrast(tokens.textMuted, tokens.canvasBackground),
      greaterThanOrEqualTo(4.5),
    );
  });
}
