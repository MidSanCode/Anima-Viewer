/// 本地化基建：支持的语言、语言解析与切换（A0-2）。
///
/// 规则：UI **不得出现硬编码文案**，一律 `'key'.tr()`；
/// 默认跟随系统语言，用户可手动切换并持久化（见 `SettingsController`）。
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../state/settings_controller.dart';

/// 支持的语言。
class L10n {
  const L10n._();

  static const List<Locale> supportedLocales = <Locale>[
    Locale('zh', 'CN'),
    Locale('en', 'US'),
  ];

  static const Locale fallbackLocale = Locale('zh', 'CN');

  /// 语言显示名（用语言自身书写，不参与翻译）。
  static String displayName(Locale locale) {
    switch (locale.languageCode) {
      case 'zh':
        return '简体中文';
      case 'en':
        return 'English';
      default:
        return locale.toString();
    }
  }

  /// 把设置里的 `system` / `zh-CN` 解析为 Locale。
  static Locale resolve(String code, Locale systemLocale) {
    if (code.isEmpty || code == kLocaleSystem) {
      for (final locale in supportedLocales) {
        if (locale.languageCode == systemLocale.languageCode) return locale;
      }
      return fallbackLocale;
    }
    final parts = code.split(RegExp(r'[-_]'));
    if (parts.length >= 2) return Locale(parts[0], parts[1]);
    return Locale(parts[0]);
  }

  /// 语言 code（`zh-CN` 形式）。
  static String codeOf(Locale locale) =>
      locale.countryCode == null || locale.countryCode!.isEmpty
      ? locale.languageCode
      : '${locale.languageCode}-${locale.countryCode}';
}

/// 便捷翻译扩展：`context.t('key', args: {...})`。
extension L10nContext on BuildContext {
  /// 翻译一个 key（支持 `{name}` 占位符）。
  String t(String key, {Map<String, String>? args}) =>
      key.tr(context: this, namedArgs: args);
}

/// 数字/日期格式（AE5-4 的复数与日期格式）。
class Fmt {
  const Fmt._();

  static String decimal(double value, {int digits = 2}) =>
      value.toStringAsFixed(digits);

  static String percent(double value, {int digits = 0}) =>
      '${(value * 100).toStringAsFixed(digits)}%';

  static String duration(double seconds) {
    final total = seconds.abs();
    final minutes = total ~/ 60;
    final rest = total - minutes * 60;
    return '${minutes.toString().padLeft(2, '0')}:'
        '${rest.toStringAsFixed(2).padLeft(5, '0')}';
  }

  static String bytes(int value) {
    const units = <String>['B', 'KB', 'MB', 'GB'];
    var size = value.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  /// 相对时间（用于“最近打开”）。
  static String relativeTime(DateTime time, {DateTime? now}) {
    final reference = now ?? DateTime.now();
    final diff = reference.difference(time);
    if (diff.inMinutes < 1) return 'time.justNow'.tr();
    if (diff.inHours < 1) {
      return 'time.minutesAgo'.tr(
        namedArgs: <String, String>{'count': '${diff.inMinutes}'},
      );
    }
    if (diff.inDays < 1) {
      return 'time.hoursAgo'.tr(
        namedArgs: <String, String>{'count': '${diff.inHours}'},
      );
    }
    if (diff.inDays < 30) {
      return 'time.daysAgo'.tr(
        namedArgs: <String, String>{'count': '${diff.inDays}'},
      );
    }
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-'
        '${time.day.toString().padLeft(2, '0')}';
  }
}
