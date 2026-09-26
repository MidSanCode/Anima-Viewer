/// 契约适配器冒烟测试：真实 anima.dll（engine/target/release）。
///
/// 引擎库不存在时跳过引擎相关断言（只验证"库缺失也绝不崩溃"）。
/// 可用 `--dart-define=ANIMA_DEMO_DIR=<path>` 指定示例工程目录。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anima_viewer/core/engine/am_types.dart';
import 'package:anima_viewer/core/engine/contract_am_engine.dart';
import 'package:anima_viewer/core/engine/ffi_am_engine.dart';
import 'package:anima_viewer/core/project/amproj_writer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ContractAmEngine? engine;

  setUpAll(() async {
    final ffi = await tryCreateFfiEngine(width: 800, height: 600);
    if (ffi == null) return;
    final contract = ContractAmEngine(ffi);
    await contract.initialize(width: 800, height: 600);
    engine = contract;
  });

  tearDownAll(() async {
    await engine?.dispose();
  });

  test('engine library loads or degrades silently', () async {
    // 无引擎 → setUpAll 留空，本断言只证明加载路径不崩。
    if (engine == null) return;
    expect(engine!.isAvailable, isTrue);
  });

  test('system.version / capabilities', () async {
    if (engine == null) return;
    final version = await engine!.call('system.version');
    expect(version['format'], 'amproj');
    expect(engine!.capabilities.methods, contains('runtime.scene'));
  });

  test('runtime params + step + auto effects', () async {
    if (engine == null) return;
    final params = await engine!.call('runtime.params');
    expect(params['params'], isA<Map>());
    final step = await engine!.call('runtime.step', {'dt': 1 / 60});
    expect(asDouble(step['time']), greaterThan(0));
  });

  test('scene build through adapter', () async {
    if (engine == null) return;
    await engine!.refreshScene();
    final scene = engine!.buildScene();
    // 空引擎无工程：drawables 可以为空，但结构必须有效。
    expect(scene.bounds, hasLength(4));
  });

  test('doc.command / doc.undo / doc.model 往返（真实引擎）', () async {
    if (engine == null) return;
    // 宿主侧写一个最小合法工程，再交给引擎加载（生产路径）。
    final dir = Directory.systemTemp.createTempSync('am-contract-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final info = AmprojWriter.freshInfo(name: 'contract-test');
    await AmprojWriter.createDirectory(dir.path, info: info);
    await AmprojWriter.writeModel(dir.path, <String, Object?>{
      'version': 1,
      'id': 'model-contract-test',
      'name': 'contract-test',
      'canvas': <String, Object?>{
        'width': 512.0,
        'height': 512.0,
        'origin': <String, Object?>{'x': 0.0, 'y': 0.0},
        'pixels_per_unit': 1.0,
      },
      'textures': <Object?>[],
      'nodes': <Object?>[
        <String, Object?>{
          'id': 'node-root',
          'name': 'Root',
          'parent': null,
          'visible': true,
          'locked': false,
          'draw_order': 0,
          'kind': 'part',
          'drawable': null,
          'warp': null,
          'rotation': null,
          'keyforms': <String, Object?>{},
        },
      ],
      'parameters': <Object?>[],
      'parameter_groups': <Object?>[],
    });

    final opened = await engine!.call('project.open', {'path': dir.path});
    expect(opened['name'], 'contract-test');

    await engine!.call('doc.command', {
      'command': <String, Object?>{
        'op': 'node_create',
        'kind': 'part',
        'name': 'PartA',
      },
    });
    final afterCreate = await engine!.call('doc.query', {'path': 'hierarchy'});
    expect(
      asJsonMap(afterCreate['nodes']).values
          .map((n) => '${asJsonMap(n)['name']}'),
      contains('PartA'),
    );

    // 撤销必须同时刷新适配器缓存，否则 hierarchy 会返回旧节点表。
    await engine!.call('doc.undo');
    final afterUndo = await engine!.call('doc.query', {'path': 'hierarchy'});
    expect(
      asJsonMap(afterUndo['nodes']).values
          .map((n) => '${asJsonMap(n)['name']}'),
      isNot(contains('PartA')),
    );

    // doc.model 是引擎原始模型视图，必须可直达。
    final model = await engine!.call('doc.model');
    expect(model['nodes'], isNotNull);
  });

  test('unsupported methods raise AmException, not crash', () async {
    if (engine == null) return;
    try {
      await engine!.call('project.import', {'source': 'x', 'dest': 'y'});
      fail('expected AmException');
    } on AmException catch (error) {
      expect(error.code, 'UNSUPPORTED');
    }
  });
}
