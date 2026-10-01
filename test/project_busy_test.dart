import 'dart:io';

import 'package:anima_viewer/core/state/engine_providers.dart';
import 'package:anima_viewer/core/state/project_controller.dart';
import 'package:anima_viewer/core/state/ui_controllers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `busy` 必须复位的回归测试。
///
/// 之前五个工程方法只在 `on AmException` 里复位 `busy`，任何别的异常
/// （插件未注册、写盘失败、路径不存在）逃逸之后 `busy` 永远是 true，
/// 界面上就是「一直转圈、一直加载」。这里把每条失败路径都钉住。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    container = ProviderContainer();
    await container.read(engineBootProvider.future);
    tmp = Directory.systemTemp.createTempSync('anima-viewer-busy-');
  });

  tearDown(() {
    container.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('open 失败后 busy 复位', () async {
    final missing = '${tmp.path}${Platform.pathSeparator}nope';
    await container.read(projectProvider.notifier).open(missing);
    expect(
      container.read(projectProvider).busy,
      isFalse,
      reason: '打开不存在的工程之后不该卡在加载态',
    );
  });

  test('validate 无工程失败后 busy 复位', () async {
    await container.read(projectProvider.notifier).validate();
    expect(container.read(projectProvider).busy, isFalse);
  });

  test('export 无工程失败后 busy 复位', () async {
    await container.read(projectProvider.notifier).export();
    expect(container.read(projectProvider).busy, isFalse);
  });

  test('import 目标非法失败后 busy 复位', () async {
    await container.read(projectProvider.notifier).importPackage(
          '${tmp.path}${Platform.pathSeparator}missing.amproj',
          '${tmp.path}${Platform.pathSeparator}out',
        );
    expect(container.read(projectProvider).busy, isFalse);
  });

  test('失败时给出可读提示，而不是静默', () async {
    await container
        .read(projectProvider.notifier)
        .open('${tmp.path}${Platform.pathSeparator}nope');
    final keys =
        container.read(notificationsProvider).map((n) => n.messageKey).toList();
    expect(keys, isNotEmpty);
  });
}
