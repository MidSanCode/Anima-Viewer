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
        'op': 'part.create',
        'name': 'PartA',
      },
    });
    final afterCreate = await engine!.call('doc.query', {'path': 'hierarchy'});
    expect(
      asJsonMap(
        afterCreate['nodes'],
      ).values.map((n) => '${asJsonMap(n)['name']}'),
      contains('PartA'),
    );
    // 引擎确实收到了这次编辑（doc.model 是引擎的原始模型视图）。
    expect(
      asJsonList((await engine!.call('doc.model'))['nodes']).map(
        (n) => '${asJsonMap(n)['name']}',
      ),
      contains('PartA'),
    );

    // 撤销由影子文档负责（引擎侧每次 set_spec 都会清空自己的撤销栈）。
    await engine!.call('doc.undo');
    final afterUndo = await engine!.call('doc.query', {'path': 'hierarchy'});
    expect(
      asJsonMap(
        afterUndo['nodes'],
      ).values.map((n) => '${asJsonMap(n)['name']}'),
      isNot(contains('PartA')),
    );

    // doc.model 是引擎原始模型视图，必须可直达。
    final model = await engine!.call('doc.model');
    expect(model['nodes'], isNotNull);
  });

  /// 回归：物理设置 / 表情的编辑过去会被透传给引擎的 `doc.command`，而引擎
  /// 只认下划线 op 且没有这些编辑命令，于是报「命令无法解析」。
  test('物理设置 / 表情 / 姿势 / 设置 的编辑都能落地', () async {
    if (engine == null) return;
    final dir = Directory.systemTemp.createTempSync('am-effects-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    await AmprojWriter.createDirectory(
      dir.path,
      info: AmprojWriter.freshInfo(name: 'effects'),
    );
    // 引擎的 read_spec 要求 spec/model.json；给一份最小合法模型。
    await AmprojWriter.writeModel(dir.path, <String, Object?>{
      'id': 'model_effects',
      'name': 'effects',
      'canvas': <String, Object?>{'width': 512.0, 'height': 512.0},
      'textures': <Object?>[],
      'nodes': <Object?>[
        <String, Object?>{
          'id': 'node_root',
          'name': 'root',
          'kind': 'part',
          'parent': null,
        },
      ],
      'parameters': <Object?>[
        <String, Object?>{
          'id': 'p_angle',
          'name': 'AngleX',
          'min': -30.0,
          'max': 30.0,
          'default': 0.0,
        },
      ],
    });
    await engine!.call('project.open', {'path': dir.path});

    await engine!.call('doc.command', {
      'command': <String, Object?>{
        'op': 'physics.add_setting',
        'name': 'physics1',
        'inputs': <Object?>[],
        'outputs': <Object?>[],
      },
    });
    final created = asJsonList(
      (await engine!.call('doc.query', {'path': 'physics'}))['physics'],
    );
    expect(created, hasLength(1));
    final settingId = '${asJsonMap(created.first)['id']}';
    await engine!.call('doc.command', {
      'command': <String, Object?>{
        'op': 'physics.set_property',
        'id': settingId,
        'path': 'pendulum',
        'value': <String, Object?>{'length': 24.0, 'frequency': 1.5},
      },
    });
    final physics = asJsonList(
      (await engine!.call('doc.query', {'path': 'physics'}))['physics'],
    );
    expect(
      asDouble(asJsonMap(asJsonMap(physics.first)['pendulum'])['length']),
      24.0,
    );

    await engine!.call('doc.command', {
      'command': <String, Object?>{
        'op': 'expression.create',
        'name': 'smile',
        'params': <String, Object?>{},
      },
    });
    await engine!.call('doc.command', {
      'command': <String, Object?>{
        'op': 'expression.set_param',
        'name': 'smile',
        'param': 'AngleX',
        'value': 12.0,
      },
    });
    expect(
      asJsonList(
        (await engine!.call('doc.query', {'path': 'expressions'}))['expressions'],
      ),
      hasLength(1),
    );
    expect((await engine!.call('project.validate'))['ok'], isTrue);

    while (asBool((await engine!.call('doc.history'))['can_undo'], false)) {
      await engine!.call('doc.undo');
    }
  });

  /// 工程落盘再打开，宿主文档必须**逐字段**回来。
  ///
  /// 引擎的 `Spec` 表达不了宿主的 `bounds` / `pendulum.{length,frequency,damping}` /
  /// `in_tangent` / `art_path` 等字段；它们全靠 `spec/config.json` 的
  /// `__host.doc` 扩展通道往返（`ProjectConfig` 是 `#[serde(flatten)]`，
  /// 未知键原样保留）。这条测试就是那个假设的守门人。
  test('保存 → 重新打开：宿主文档无损往返', () async {
    if (engine == null) return;
    final tmp = await Directory.systemTemp.createTemp('anima-roundtrip-');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    final dir = '${tmp.path}${Platform.pathSeparator}roundtrip';

    await engine!.call('project.create', <String, Object?>{
      'dir': dir,
      'name': 'roundtrip',
    });
    // 造一组引擎表达不了的宿主数据。
    await engine!.call('doc.command', {
      'command': <String, Object?>{
        'op': 'param.create',
        'name': 'AngleX',
        'group': 'Head',
        'min': -30.0,
        'max': 30.0,
        'default': 0.0,
      },
    });
    final params = asJsonMap(
      (await engine!.call('doc.query', {'path': 'parameters'}))['parameters'],
    );
    final angleId = params.keys.firstWhere(
      (id) => '${asJsonMap(params[id])['name']}' == 'AngleX',
    );
    // `bounds` 是典型的宿主持有字段（引擎 warp 只有 rest_rect）。
    await engine!.call('doc.command', {
      'command': <String, Object?>{
        'op': 'deformer.create_warp',
        'name': 'warp',
        'rows': 2,
        'cols': 2,
        // 面板就是这么传 bounds 的：四元列表。
        'bounds': <Object?>[-100.0, -100.0, 200.0, 200.0],
      },
    });
    await engine!.call('doc.command', {
      'command': <String, Object?>{
        'op': 'physics.add_setting',
        'name': 'physics1',
      },
    });
    final settings = asJsonList(
      (await engine!.call('doc.query', {'path': 'physics'}))['physics'],
    );
    final physicsId = '${asJsonMap(settings.first)['id']}';
    await engine!.call('doc.command', {
      'command': <String, Object?>{
        'op': 'physics.set_property',
        'id': physicsId,
        'path': 'pendulum',
        'value': <String, Object?>{'length': 33.0, 'frequency': 2.5, 'damping': 0.4},
      },
    });
    await engine!.call('doc.command', {
      'command': <String, Object?>{
        'op': 'motion.create',
        'name': 'wave',
        'duration': 2.5,
      },
    });
    await engine!.call('doc.command', {
      'command': <String, Object?>{
        'op': 'motion.set_key',
        'name': 'wave',
        'param': angleId,
        'time': 1.0,
        'value': 15.0,
        // 切线与插值都是宿主的表达，引擎 Spec 里没有对应字段。
        // 宿主插值词汇是 linear|step|bezier（见 AmInterpolation）；`bezier`
        // 在引擎侧展开成 cubic_bezier，回读时还原成 `bezier`。
        'interp': 'bezier',
        'in_tangent': -1.5,
        'out_tangent': 0.5,
      },
    });

    final before = await engine!.call('doc.query', {'path': 'hierarchy'});
    final beforePhysics = asJsonList(
      (await engine!.call('doc.query', {'path': 'physics'}))['physics'],
    );
    final beforeMotions = asJsonList(
      (await engine!.call('doc.query', {'path': 'motions'}))['motions'],
    );

    // 落盘 → 重新打开（走真实的 project.save / project.load）。
    await engine!.call('project.save');
    await engine!.call('project.close');
    await engine!.call('project.open', {'path': dir});

    // 节点结构与 warp 的 bounds。
    final after = await engine!.call('doc.query', {'path': 'hierarchy'});
    expect(
      asJsonMap(after['nodes']).keys.toSet(),
      asJsonMap(before['nodes']).keys.toSet(),
    );
    for (final entry in asJsonMap(before['nodes']).entries) {
      final b = asJsonMap(entry.value);
      final a = asJsonMap(asJsonMap(after['nodes'])[entry.key]);
      expect(a['name'], b['name'], reason: '节点 ${entry.key} 名字变了');
      expect(a['type'], b['type']);
      if (b['type'] == 'warp_deformer') {
        expect(a['bounds'], b['bounds'], reason: 'warp bounds 丢失');
        expect(a['rows'], b['rows']);
        expect(a['cols'], b['cols']);
      }
    }

    // 物理的 pendulum（引擎侧没有 length/frequency/damping）。
    final afterPhysics = asJsonList(
      (await engine!.call('doc.query', {'path': 'physics'}))['physics'],
    );
    expect(afterPhysics, hasLength(beforePhysics.length));
    final bPen = asJsonMap(asJsonMap(beforePhysics.first)['pendulum']);
    final aPen = asJsonMap(asJsonMap(afterPhysics.first)['pendulum']);
    expect(asDouble(aPen['length']), asDouble(bPen['length']));
    expect(asDouble(aPen['frequency']), asDouble(bPen['frequency']));
    expect(asDouble(aPen['damping']), asDouble(bPen['damping']));

    // 动作：duration / 曲线 / 关键帧的 interp 与切线。
    final afterMotions = asJsonList(
      (await engine!.call('doc.query', {'path': 'motions'}))['motions'],
    );
    expect(afterMotions, hasLength(beforeMotions.length));
    final bMotion = asJsonMap(beforeMotions.first);
    final aMotion = asJsonMap(afterMotions.first);
    expect(aMotion['name'], bMotion['name']);
    expect(asDouble(aMotion['duration']), asDouble(bMotion['duration']));
    final bKeys = asJsonList(
      asJsonMap(asJsonList(bMotion['curves']).first)['keys'],
    );
    final aKeys = asJsonList(
      asJsonMap(asJsonList(aMotion['curves']).first)['keys'],
    );
    expect(aKeys, hasLength(bKeys.length));
    expect(asDouble(asJsonMap(aKeys.first)['value']), 15.0);
    expect('${asJsonMap(aKeys.first)['interp']}', 'bezier');
    expect(asDouble(asJsonMap(aKeys.first)['in_tangent']), -1.5);
    expect(asDouble(asJsonMap(aKeys.first)['out_tangent']), 0.5);

    // 参数的范围/分组（引擎有 min/max/default/group，group 是字符串）。
    final afterParams = asJsonMap(
      (await engine!.call('doc.query', {'path': 'parameters'}))['parameters'],
    );
    expect(asDouble(asJsonMap(afterParams[angleId])['min']), -30.0);
    expect(asDouble(asJsonMap(afterParams[angleId])['max']), 30.0);
  });

  test('project.create：宿主落盘后真引擎能装载', () async {
    if (engine == null) return;
    final tmp = await Directory.systemTemp.createTemp('am-create-');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    final dir = '${tmp.path}${Platform.pathSeparator}my_model';

    final created = await engine!.call('project.create', <String, Object?>{
      'dir': dir,
      'name': 'my_model',
      'display_name': '我的模型',
      'author': 'tester',
    });
    expect(created['path'], dir);
    expect(created['name'], 'my_model');
    expect(created['display_name'], '我的模型');

    // 骨架必须齐全：引擎 project.load 要求 info.json + registry.json，
    // read_spec 要求 spec/model.json。
    for (final rel in <String>[
      'info.json',
      'registry.json',
      'spec/model.json',
    ]) {
      final path =
          '$dir${Platform.pathSeparator}'
          '${rel.replaceAll('/', Platform.pathSeparator)}';
      expect(File(path).existsSync(), isTrue, reason: '缺少 $rel');
    }

    // 引擎确实装载了这份新工程。
    final model = await engine!.call('doc.model');
    expect(model['name'], 'my_model');
    final nodes = asJsonList(model['nodes']);
    expect(nodes, isNotEmpty, reason: '新工程应带一个根节点');
    expect(asJsonMap(nodes.first)['name'], 'root');

    // 落盘的必须是**引擎可解析**的 spec：节点带 kind、且是数组（不是宿主的
    // id 索引映射）。宿主文档整体挂在 config 的扩展通道里无损往返。
    final raw = await File(
      '$dir${Platform.pathSeparator}spec${Platform.pathSeparator}model.json',
    ).readAsString();
    expect(raw, contains('"kind"'));

    // 重新从磁盘打开：证明真的落盘了，而不是只在内存里。
    final reopened = await engine!.call('project.open', <String, Object?>{
      'path': dir,
    });
    expect(reopened['name'], 'my_model');
    final reopenedModel = await engine!.call('doc.model');
    expect(
      asJsonList(reopenedModel['nodes']),
      isNotEmpty,
      reason: '根节点必须持久化到 spec/model.json',
    );

    // 新建出来的工程必须是**有效**工程，而不是只有文件架子。
    final validation = await engine!.call('project.validate');
    expect(validation['ok'], isNot(false), reason: '新工程校验不应失败：$validation');

    // 引擎的统计口径也要认得这份工程。
    final stats = await engine!.call('diagnostics.stats');
    expect(asInt(stats['nodes']), greaterThan(0));
    expect(stats['fallback'], isNot(true));
  });

  test('project.create：目录里已有工程时拒绝覆盖', () async {
    if (engine == null) return;
    final tmp = await Directory.systemTemp.createTemp('am-create-dup-');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    final dir = '${tmp.path}${Platform.pathSeparator}dup';

    await engine!.call('project.create', <String, Object?>{
      'dir': dir,
      'name': 'dup',
    });
    // 第二次必须被拒绝 —— 覆盖 info.json / registry.json / spec/ 不可逆。
    await expectLater(
      engine!.call('project.create', <String, Object?>{
        'dir': dir,
        'name': 'dup',
      }),
      throwsA(
        isA<AmException>().having((e) => e.code, 'code', 'PROJECT_EXISTS'),
      ),
    );
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
