/// i18n 键完整性回归测试。
///
/// easy_localization 找不到键时**不报错**，而是把键名原样返回。于是界面上会
/// 突然冒出 `settings.theme.dark` 这种内部串：没有异常、没有日志，只有用户看到
/// 下拉框里写着英文键名。
///
/// 查看器就踩过这个坑：`viewer_widgets.dart` 与 `report_panels.dart` 引用了
/// `settings.theme.*` / `settings.quality.*`，但这两族在查看器的语言文件里根本
/// 不存在（编辑器有），主题与渲染质量两个下拉框一直在显示键名。这里把这类问题
/// 变成测试失败，而不是等用户发现。
///
/// 两类引用分开查：
///
/// * **字面量键**（`'settings.showGrid'.tr()`）——必须精确存在。
/// * **插值键**（`'settings.theme.${mode.name}'.tr()`）——运行时才拼出完整键，
///   静态查不到具体值，所以退一步守住「整族缺失」：`$` 之前的静态前缀必须至少
///   匹配到一个键。上面那个真实事故正是整族缺失，这样就能拦住；至于枚举少一个
///   成员这类，留给人工对着枚举值核对。
///
/// 注释行里的 `'key'.tr()` 是文档示例，不算引用。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 语言文件所在目录，相对包根目录。
const String _translationsDir = 'assets/translations';

/// 源码里 `.tr('字面量')` 的形态（含带插值的）。
final RegExp _trLiteral = RegExp(r"'([^'\\\n]+)'\s*\.tr\(");

void main() {
  test('源码里 .tr() 用到的键，在语言文件里都找得到', () {
    final Directory dir = Directory(_translationsDir);
    expect(dir.existsSync(), isTrue, reason: '找不到 $_translationsDir，测试需在包根目录运行');

    final Set<String> locales = <String>{};
    final Map<String, Set<String>> keys = <String, Set<String>>{};

    for (final FileSystemEntity entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final String code = entity.uri.pathSegments.last.replaceAll('.json', '');
      locales.add(code);
      keys[code] = (jsonDecode(entity.readAsStringSync()) as Map<String, dynamic>)
          .keys
          .toSet();
    }

    expect(locales, isNotEmpty, reason: '$_translationsDir 下一个语言文件都没有');

    // 语言文件之间键集必须完全一致，否则一切语言就会露出键名。
    final String reference = locales.first;
    for (final String code in locales) {
      expect(
        keys[code],
        equals(keys[reference]),
        reason: '$code 与 $reference 的键集合不一致（切语言会露出键名）',
      );
    }

    /// 键名 → 缺它的语言。
    final Map<String, Set<String>> missingKeys = <String, Set<String>>{};
    final Map<String, Set<String>> missingFamilies = <String, Set<String>>{};

    for (final FileSystemEntity entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      for (final String line in entity.readAsLinesSync()) {
        if (line.trimLeft().startsWith('//')) continue;
        for (final RegExpMatch match in _trLiteral.allMatches(line)) {
          final String key = match.group(1)!;
          final int dollar = key.indexOf(r'$');

          if (dollar < 0) {
            for (final MapEntry<String, Set<String>> entry in keys.entries) {
              if (!entry.value.contains(key)) {
                missingKeys.putIfAbsent(key, () => <String>{}).add(entry.key);
              }
            }
            continue;
          }

          // 插值键：静态部分为空（形如 '$foo'）时无从判断，跳过。
          final String prefix = key.substring(0, dollar);
          if (prefix.isEmpty) continue;
          for (final MapEntry<String, Set<String>> entry in keys.entries) {
            if (!entry.value.any((String k) => k.startsWith(prefix))) {
              missingFamilies.putIfAbsent(prefix, () => <String>{}).add(entry.key);
            }
          }
        }
      }
    }

    expect(
      missingKeys,
      isEmpty,
      reason: '这些 .tr() 键在语言文件里不存在，界面上会原样显示键名：$missingKeys',
    );
    expect(
      missingFamilies,
      isEmpty,
      reason: '这些插值 .tr() 前缀在语言文件里一个键都没有，整族缺失：$missingFamilies',
    );
  });
}
