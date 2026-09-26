/// 统一主题：暗色为默认（A0-6），并提供紧凑的编辑工具视觉密度。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 设计令牌（颜色/尺寸/动效）。
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    required this.panelBackground,
    required this.panelHeader,
    required this.canvasBackground,
    required this.divider,
    required this.selectionFill,
    required this.selectionStroke,
    required this.handleFill,
    required this.handleStroke,
    required this.accentSecondary,
    required this.warning,
    required this.danger,
    required this.gridLine,
    required this.guideLine,
    required this.panelRadius,
    required this.gap,
  });

  final Color panelBackground;
  final Color panelHeader;
  final Color canvasBackground;
  final Color divider;
  final Color selectionFill;
  final Color selectionStroke;
  final Color handleFill;
  final Color handleStroke;
  final Color accentSecondary;
  final Color warning;
  final Color danger;
  final Color gridLine;
  final Color guideLine;
  final double panelRadius;
  final double gap;

  static const AppTokens dark = AppTokens(
    panelBackground: Color(0xFF1B1D21),
    panelHeader: Color(0xFF23262B),
    canvasBackground: Color(0xFF121316),
    divider: Color(0xFF32363D),
    selectionFill: Color(0x3334A6FF),
    selectionStroke: Color(0xFF61B5FF),
    handleFill: Color(0xFFF2F4F8),
    handleStroke: Color(0xFF3C4250),
    accentSecondary: Color(0xFF8C7BFF),
    warning: Color(0xFFE0A93B),
    danger: Color(0xFFE5544B),
    gridLine: Color(0x1FFFFFFF),
    guideLine: Color(0x66FF7AC6),
    panelRadius: 6,
    gap: 2,
  );

  static const AppTokens light = AppTokens(
    panelBackground: Color(0xFFF3F4F7),
    panelHeader: Color(0xFFE7E9EF),
    canvasBackground: Color(0xFFDFE2E8),
    divider: Color(0xFFC6CAD3),
    selectionFill: Color(0x3334A6FF),
    selectionStroke: Color(0xFF1F7BD4),
    handleFill: Color(0xFFFFFFFF),
    handleStroke: Color(0xFF5A6272),
    accentSecondary: Color(0xFF6C5CE7),
    warning: Color(0xFFB57E15),
    danger: Color(0xFFC43D34),
    gridLine: Color(0x22000000),
    guideLine: Color(0x66D63384),
    panelRadius: 6,
    gap: 2,
  );

  @override
  AppTokens copyWith({
    Color? panelBackground,
    Color? panelHeader,
    Color? canvasBackground,
    Color? divider,
    Color? selectionFill,
    Color? selectionStroke,
    Color? handleFill,
    Color? handleStroke,
    Color? accentSecondary,
    Color? warning,
    Color? danger,
    Color? gridLine,
    Color? guideLine,
    double? panelRadius,
    double? gap,
  }) => AppTokens(
    panelBackground: panelBackground ?? this.panelBackground,
    panelHeader: panelHeader ?? this.panelHeader,
    canvasBackground: canvasBackground ?? this.canvasBackground,
    divider: divider ?? this.divider,
    selectionFill: selectionFill ?? this.selectionFill,
    selectionStroke: selectionStroke ?? this.selectionStroke,
    handleFill: handleFill ?? this.handleFill,
    handleStroke: handleStroke ?? this.handleStroke,
    accentSecondary: accentSecondary ?? this.accentSecondary,
    warning: warning ?? this.warning,
    danger: danger ?? this.danger,
    gridLine: gridLine ?? this.gridLine,
    guideLine: guideLine ?? this.guideLine,
    panelRadius: panelRadius ?? this.panelRadius,
    gap: gap ?? this.gap,
  );

  @override
  AppTokens lerp(covariant ThemeExtension<AppTokens>? other, double t) {
    if (other is! AppTokens) return this;
    return AppTokens(
      panelBackground: Color.lerp(panelBackground, other.panelBackground, t)!,
      panelHeader: Color.lerp(panelHeader, other.panelHeader, t)!,
      canvasBackground: Color.lerp(
        canvasBackground,
        other.canvasBackground,
        t,
      )!,
      divider: Color.lerp(divider, other.divider, t)!,
      selectionFill: Color.lerp(selectionFill, other.selectionFill, t)!,
      selectionStroke: Color.lerp(selectionStroke, other.selectionStroke, t)!,
      handleFill: Color.lerp(handleFill, other.handleFill, t)!,
      handleStroke: Color.lerp(handleStroke, other.handleStroke, t)!,
      accentSecondary: Color.lerp(accentSecondary, other.accentSecondary, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      gridLine: Color.lerp(gridLine, other.gridLine, t)!,
      guideLine: Color.lerp(guideLine, other.guideLine, t)!,
      panelRadius: panelRadius,
      gap: gap,
    );
  }
}

/// 主题工厂。
class AppTheme {
  const AppTheme._();

  static ThemeData dark() => _build(Brightness.dark, AppTokens.dark);

  static ThemeData light() => _build(Brightness.light, AppTokens.light);

  static ThemeData _build(Brightness brightness, AppTokens tokens) {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF34A6FF),
          brightness: brightness,
        ).copyWith(
          secondary: tokens.accentSecondary,
          error: tokens.danger,
          surface: tokens.panelBackground,
          surfaceContainerHighest: tokens.panelHeader,
          outlineVariant: tokens.divider,
        );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      visualDensity: VisualDensity.compact,
      extensions: <ThemeExtension<dynamic>>[tokens],
      fontFamily: null,
      typography: _compactTypography(kTextScaleFactor),
    );

    return base.copyWith(
      scaffoldBackgroundColor: tokens.panelBackground,
      dividerTheme: DividerThemeData(
        color: tokens.divider,
        thickness: 1,
        space: 1,
      ),
      cardTheme: CardThemeData(
        color: tokens.panelBackground,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.panelRadius),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: tokens.panelHeader,
        elevation: 0,
        centerTitle: false,
        toolbarHeight: 40,
        titleTextStyle: base.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: tokens.panelHeader,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: tokens.divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: tokens.divider),
        ),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
      ),
      tabBarTheme: TabBarThemeData(
        labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 12),
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 500),
        textStyle: const TextStyle(fontSize: 12),
        decoration: BoxDecoration(
          color: tokens.panelHeader,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: tokens.divider),
        ),
      ),
    );
  }

  /// 全局字号缩放（正文整体略小，编辑工具信息密度更高）。
  static const double kTextScaleFactor = 0.95;

  /// 构造缩放后的 [Typography]。
  ///
  /// **必须缩放 geometry 层**（`englishLike` / `dense` / `tall`）：
  /// `ThemeData.textTheme` 在 `ThemeData.localize` 之前 `fontSize` 全为
  /// `null`，对它调用 `apply(fontSizeFactor:)` 会直接触发断言
  /// `fontSize != null || (fontSizeFactor == 1.0 && fontSizeDelta == 0.0)`，
  /// 导致整个主题构造失败、应用起不来。
  ///
  /// `Theme.of(context)` 最终取的是
  /// `theme.typography.geometryThemeFor(scriptCategory)`，
  /// 所以缩放 geometry 既不会触发断言，又能真正生效。
  static Typography _compactTypography(double factor) {
    final base = Typography.material2021(platform: defaultTargetPlatform);
    return Typography.material2021(
      platform: defaultTargetPlatform,
      englishLike: base.englishLike.apply(fontSizeFactor: factor),
      dense: base.dense.apply(fontSizeFactor: factor),
      tall: base.tall.apply(fontSizeFactor: factor),
    );
  }

  /// 便捷读取令牌。
  static AppTokens of(BuildContext context) =>
      Theme.of(context).extension<AppTokens>() ?? AppTokens.dark;
}
