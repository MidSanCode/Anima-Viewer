/// 集成验证：真实引擎 + 真实工程目录。
///
/// 默认用仓库里的 `test/fixtures/amproj-demo`（随提交一起走，CI 上也有）；
/// 想指到别处就用 `--dart-define=ANIMA_DEMO_DIR=<path>`。工程不存在时跳过。
library;

import 'dart:io';

import 'package:anima_viewer/core/engine/am_types.dart';
import 'package:anima_viewer/core/engine/contract_am_engine.dart';
import 'package:anima_viewer/core/engine/ffi_am_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// 示例工程目录（绝对路径）。
///
/// 测试的工作目录就是包根，所以 `test/fixtures/...` 直接可用；不依赖任何
/// 机器上的绝对路径（CI 的检出目录跟本地不一样）。
String demoProjectDir() {
  const override = String.fromEnvironment('ANIMA_DEMO_DIR');
  if (override.isNotEmpty) return override;
  return Directory('test/fixtures/amproj-demo').absolute.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final demoDir = demoProjectDir();
  final demoExists = Directory(demoDir).existsSync();
  if (!demoExists) {
    test('skipped: demo project not found', () {});
    return;
  }

  late ContractAmEngine engine;

  setUpAll(() async {
    final lib = await tryCreateFfiEngine(width: 800, height: 600);
    if (lib == null) fail('anima.dll not found');
    engine = ContractAmEngine(lib);
    await engine.initialize(width: 800, height: 600);
  });

  tearDownAll(() async {
    await engine.dispose();
  });

  test('open demo project through engine', () async {
    final result = await engine.call('project.open', {'path': demoDir});
    expect(result['name'], isNotNull);
    expect(result['is_archive'], false);
  });

  test('doc.query returns spec layers', () async {
    final params = await engine.call('doc.query', {'path': 'parameters'});
    expect(asJsonMap(params['parameters']), isNotEmpty);
    final motions = await engine.call('doc.query', {'path': 'motions'});
    expect(asJsonList(motions['motions']), isA<List>());
  });

  test('runtime scene has drawables', () async {
    await engine.refreshScene();
    final scene = engine.buildScene();
    expect(scene.drawables, isNotEmpty, reason: 'demo 模型应有可绘制对象');
  });

  test('step advances and returns params', () async {
    final step = await engine.call('runtime.step', {'dt': 1 / 60});
    expect(asDouble(step['time']), greaterThan(0));
    expect(asJsonMap(step['params']), isA<Map>());
  });

  test('play motion if present', () async {
    final motions = asJsonList(
      (await engine.call('doc.query', {'path': 'motions'}))['motions'],
    );
    if (motions.isEmpty) return;
    final name = '${asJsonMap(motions.first)['name']}';
    await engine.call('runtime.play_motion', {'motion': name, 'loop': true});
    for (var i = 0; i < 10; i++) {
      final step = await engine.call('runtime.step', {'dt': 1 / 60});
      expect(asDouble(step['time']), greaterThan(0));
    }
    await engine.refreshScene();
    expect(engine.buildScene().drawables, isNotEmpty);
  });
}
