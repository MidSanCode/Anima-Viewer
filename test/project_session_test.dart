import 'dart:io';

import 'package:anima_viewer/core/state/engine_providers.dart';
import 'package:anima_viewer/core/state/project_controller.dart';
import 'package:anima_viewer/core/state/settings_controller.dart';
import 'package:anima_viewer/core/state/ui_controllers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 会话 / 生命周期回归测试。
///
/// 守住一条容易踩的线：**改设置绝不能把引擎实例换掉**。引擎一旦被换成新
/// 实例，新实例上没有已打开的工程，下一次「保存」就失败成 `PROJECT_NOT_OPEN`
/// —— 也就是「工程明明开着，却提示没有打开」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    container = ProviderContainer();
    await container.read(engineBootProvider.future);
    tmp = Directory.systemTemp.createTempSync('anima-session-');
  });

  tearDown(() {
    container.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String projDir() => '${tmp.path}${Platform.pathSeparator}proj';

  List<String> noticeKeys() =>
      container.read(notificationsProvider).map((n) => n.messageKey).toList();

  test('写设置不会换掉引擎实例', () async {
    final before = container.read(engineProvider);
    final settings = container.read(settingsProvider.notifier);

    // 「打开 / 保存 / 导出」都会顺手写一次「最近打开」；网格 / 主题 / 语言 /
    // 面板布局同理。这些写入都不该牵动引擎。
    await settings.patch((s) => s.withRecent('/tmp/anima-recent'));
    await settings.patch(
      (s) => s.copyWith(
        showGrid: true,
        themeMode: ThemeMode.light,
        localeCode: 'en-US',
        layoutJson: '{}',
      ),
    );
    // 给 FutureProvider 一个重新解析的机会：若依赖了整份设置，这里就会换实例。
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(identical(before, container.read(engineProvider)), isTrue);
  });

  test('打开工程 → 写设置 → 再保存仍然成功（回归 PROJECT_NOT_OPEN）', () async {
    final dir = projDir();
    expect(
      await container
          .read(projectProvider.notifier)
          .create(directory: dir, name: 'demo'),
      isTrue,
    );
    expect(await container.read(projectProvider.notifier).open(dir), isTrue);

    // `open` / `save` 之后都会走 `_remember()` 写设置。
    await container
        .read(settingsProvider.notifier)
        .patch((s) => s.withRecent(dir));
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final saved = await container.read(projectProvider.notifier).save();
    expect(saved, isTrue);
    expect(File('$dir/spec/model.json').existsSync(), isTrue);
    expect(noticeKeys(), contains('notice.project.saved'));
    expect(noticeKeys(), isNot(contains('notice.error.engineCall')));
  });

  test('没有工程时保存：给的是能照做的提示，而不是英文内部串', () async {
    final saved = await container.read(projectProvider.notifier).save();
    expect(saved, isFalse);

    final last = container.read(notificationsProvider).last;
    expect(last.messageKey, 'notice.project.notOpen');
    // 绝不能把 `no directory-mode project is open` 这种内部串丢给用户。
    expect('${last.detail}', isNot(contains('no directory-mode project')));
  });
}
