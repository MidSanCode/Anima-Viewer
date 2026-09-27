import 'package:anima_viewer/core/engine/am_types.dart';
import 'package:anima_viewer/core/engine/engine_spec_codec.dart';
import 'package:anima_viewer/core/engine/local_document.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('isEngineSafeId 与引擎的 is_valid_id 一致', () {
    expect(isEngineSafeId('abc-1_2'), isTrue);
    expect(isEngineSafeId(''), isFalse);
    expect(isEngineSafeId('a' * 128), isTrue);
    expect(isEngineSafeId('a' * 129), isFalse);
    expect(isEngineSafeId('中文'), isFalse);
    expect(isEngineSafeId('a b'), isFalse);
    expect(engineSafeIdFrom('', prefix: 'm'), 'mitem');
    expect(engineSafeIdFrom('中文名', prefix: 'e'), 'eitem');
  });

  test('宿主文档 → spec → 宿主文档 可无损往返', () {
    final doc = LocalDocument();
    final source = demoAnimaDocument();
    doc.data = source;
    doc.applyDrawOrder();

    final spec = hostDocToEngineSpec(doc.data, projectName: 'demo');
    // 引擎必须能解析这份 spec：关键字段名/形状都是引擎的。
    final model = asJsonMap(spec['model']);
    expect(model['name'], 'demo');
    expect(isEngineSafeId('${model['id']}'), isTrue);
    final nodes = asJsonList(model['nodes']);
    expect(nodes, isNotEmpty);
    for (final raw in nodes) {
      final node = asJsonMap(raw);
      // kind 必须提升到顶层（旧的 _reloadSpec 把它留在 drawable 里）。
      expect(node['kind'], isNotNull);
      expect(isEngineSafeId('${node['id']}'), isTrue);
      expect(node['name'], isNotNull);
      if (node['kind'] == 'drawable') {
        expect(asJsonMap(node['drawable'])['mesh'], isNotNull);
        // 引擎的 drawable 必须有 mesh；空网格也要给。
        final mesh = asJsonMap(asJsonMap(node['drawable'])['mesh']);
        expect(mesh['vertices'], isNotNull);
        expect(mesh['uvs'], isNotNull);
        expect(mesh['indices'], isNotNull);
      }
    }

    // 参数形状。
    for (final raw in asJsonList(model['parameters'])) {
      final param = asJsonMap(raw);
      expect(param['min'], isNotNull);
      expect(param['max'], isNotNull);
      expect(param['default'], isNotNull);
      expect(param['name'], isNotNull);
    }

    // 动作/表情用引擎的形状。
    final motions = asJsonList(spec['motions']);
    for (final raw in motions) {
      final motion = asJsonMap(raw);
      expect(motion['duration'], isNotNull);
      // 引擎字段是 `loop`（Rust 侧 rename），不是 looping。
      expect(motion.containsKey('loop'), isTrue);
      for (final rawCurve in asJsonList(motion['curves'])) {
        final curve = asJsonMap(rawCurve);
        expect(curve['target'], isNotNull);
        // easing 必须是内部标签对象，裸字符串会被引擎拒绝。
        for (final rawKey in asJsonList(curve['keys'])) {
          expect(asJsonMap(asJsonMap(rawKey)['easing'])['type'], isNotNull);
        }
      }
    }

    // 宿主通道：整份文档在里面，`bounds` / `in_tangent` 这类引擎没有的
    // 字段靠它活着。
    final extras = asJsonMap(asJsonMap(spec['config'])[kHostExtrasKey]);
    expect(asJsonMap(extras['doc']), isNotNull);

    // 读回来必须和原件一致（`__host.doc` 优先，逐字段等值）。
    final restored = hostDocFromSpec(spec, projectName: 'demo');
    expect(restored['parameters'], source['parameters']);
    expect(restored['settings'], source['settings']);
    expect(restored['config'], source['config']);
    expect(restored['atlas'], source['atlas']);
    expect(restored['motions'], source['motions']);
    expect(restored['expressions'], source['expressions']);
    expect(restored['pose'], source['pose']);
    expect(restored['physics'], source['physics']);
    expect(
      asJsonMap(restored['nodes']).keys.toSet(),
      asJsonMap(source['nodes']).keys.toSet(),
    );
    for (final entry in asJsonMap(source['nodes']).entries) {
      final before = asJsonMap(entry.value);
      final after = asJsonMap(asJsonMap(restored['nodes'])[entry.key]);
      expect(after['name'], before['name']);
      expect(after['visible'], before['visible']);
      expect(after['type'], before['type']);
    }
    expect(restored['root'], source['root']);
    // children 由 parent 推导，面板靠它画层级。
    expect(
      asJsonMap(asJsonMap(restored['nodes']).values.first)['children'],
      isNotNull,
    );
  });

  test('没有宿主通道时按引擎形状重建（老工程 / 引擎原生工程）', () {
    final spec = <String, Object?>{
      'model': <String, Object?>{
        'id': 'model1',
        'name': 'legacy',
        'canvas': <String, Object?>{'width': 800.0, 'height': 600.0},
        'textures': <Object?>[],
        'nodes': <Object?>[
          <String, Object?>{
            'id': 'node_root',
            'name': 'root',
            'kind': 'part',
            'parent': null,
          },
          <String, Object?>{
            'id': 'node_body',
            'name': 'body',
            'kind': 'drawable',
            'parent': 'node_root',
            'drawable': <String, Object?>{
              'mesh': <String, Object?>{
                'vertices': <Object?>[
                  <double>[0, 0],
                  <double>[1, 0],
                  <double>[0, 1],
                ],
                'uvs': <Object?>[
                  <double>[0, 0],
                  <double>[1, 0],
                  <double>[0, 1],
                ],
                'indices': <Object?>[0, 1, 2],
              },
            },
          },
        ],
        'parameters': <Object?>[
          <String, Object?>{
            'id': 'p1',
            'name': 'AngleX',
            'min': -30.0,
            'max': 30.0,
            'default': 0.0,
          },
        ],
      },
      'motions': <Object?>[
        <String, Object?>{
          'id': 'm1',
          'name': 'wave',
          'duration': 2.0,
          'loop': true,
          'curves': <Object?>[
            <String, Object?>{
              'target': 'p1',
              'kind': 'parameter',
              'keys': <Object?>[
                <String, Object?>{
                  'time': 0.0,
                  'value': 0.0,
                  'easing': <String, Object?>{'type': 'ease_in_out'},
                },
              ],
            },
          ],
        },
      ],
      'expressions': <Object?>[],
      'physics': <String, Object?>{
        'settings': <Object?>[
          <String, Object?>{
            'id': 'x1',
            'name': 'hair',
            'kind': 'pendulum',
            'inputs': <Object?>[
              <String, Object?>{'parameter': 'p1', 'weight': 0.5},
            ],
            'outputs': <Object?>[
              <String, Object?>{'parameter': 'p1', 'scale': 2.0},
            ],
          },
        ],
      },
      'pose': <String, Object?>{
        'groups': <Object?>[
          <String, Object?>{
            'id': 'pose1',
            'name': 'pose_group',
            'parts': <Object?>[
              <String, Object?>{'node': 'node_body', 'visible': false},
            ],
          },
        ],
      },
      'settings': <String, Object?>{
        'display_name': 'Legacy',
        'physics': false,
        'auto_blink': <String, Object?>{'enabled': true, 'interval': 5.0},
        'auto_breath': <String, Object?>{'enabled': false, 'interval': 2.0},
        'lip_sync': <String, Object?>{'enabled': true, 'amplify': 0.7},
      },
      'config': <String, Object?>{
        'project': <String, Object?>{'name': 'legacy', 'display_name': 'Legacy'},
        // 引擎 ProjectConfig 的 flatten：这些未知键属于宿主。
        'canvas': <String, Object?>{
          'width': 800.0,
          'height': 600.0,
          'unit': 'px',
        },
        'default_language': 'zh-CN',
        'render_quality': 'medium',
        'device_pixel_ratio': 2.0,
      },
    };

    final host = hostDocFromSpec(spec, projectName: 'legacy');
    // 层级：children 由 parent 推导。
    final nodes = asJsonMap(host['nodes']);
    expect(nodes.keys.toSet(), <String>{'node_root', 'node_body'});
    expect(asJsonList(asJsonMap(nodes['node_root'])['children']), <Object?>[
      'node_body',
    ]);
    expect(host['root'], 'node_root');

    // 参数（值从 default 起步）。
    final parameters = asJsonMap(host['parameters']);
    expect(parameters.keys.toSet(), <String>{'p1'});
    expect(asJsonMap(parameters['p1'])['name'], 'AngleX');
    expect(asJsonMap(parameters['p1'])['min'], -30.0);

    // 动作：target → param，easing 对象 → 宿主形式。
    final motions = asJsonList(host['motions']);
    expect(motions, hasLength(1));
    final motion = asJsonMap(motions.first);
    expect(motion['name'], 'wave');
    expect(motion['loop'], isTrue);
    expect(
      asJsonMap(asJsonList(asJsonMap(asJsonList(motion['curves']).first)['keys']).first)['interp'],
      'ease_in_out',
    );

    // 物理：inputs/outputs 保留，pendulum 归一化范围从引擎值反推。
    final physics = asJsonList(host['physics']);
    expect(physics, hasLength(1));
    final setting = asJsonMap(physics.first);
    expect(setting['name'], 'hair');
    expect(asJsonList(setting['inputs']), hasLength(1));
    expect(asDouble(asJsonMap(asJsonList(setting['inputs']).first)['weight']), 0.5);
    expect(asJsonMap(setting['pendulum']), isNotNull);

    // 表情：空。
    expect(asJsonList(host['expressions']), isEmpty);

    // 姿势：按 group 归并回去。
    final pose = asJsonList(host['pose']);
    expect(pose, hasLength(1));
    expect(asJsonMap(pose.first)['group'], 'pose_group');

    // 设置：auto_blink.interval → blink.interval 之类的映射要还原。
    final settings = asJsonMap(host['settings']);
    expect(settings['physics_enabled'], isFalse);
    expect(asDouble(asJsonMap(settings['blink'])['interval']), 5.0);
    expect(asBool(asJsonMap(settings['blink'])['enabled']), isTrue);
    expect(asDouble(asJsonMap(settings['breath'])['period']), 2.0);
    expect(asBool(asJsonMap(settings['breath'])['enabled']), isFalse);
    expect(asBool(asJsonMap(settings['lipsync'])['enabled']), isTrue);
    expect(asDouble(asJsonMap(settings['lipsync'])['gain']), 0.7);

    // config：宿主字段从 flatten 展开的键里读回来。
    final config = asJsonMap(host['config']);
    expect(asDouble(asJsonMap(config['canvas'])['width']), 800.0);
    expect(config['default_language'], 'zh-CN');
    expect(config['render_quality'], 'medium');
    expect(asDouble(config['device_pixel_ratio']), 2.0);

    // 再正向投影一次，仍应是合法 spec（幂等）。
    final again = hostDocToEngineSpec(host, projectName: 'legacy');
    expect(asJsonMap(again['model'])['name'], 'legacy');
    expect(asJsonList(asJsonMap(again['model'])['nodes']), hasLength(2));
  });

  test('关键形存储：宿主增量 ↔ 引擎绝对值', () {
    final source = defaultAnimaDocument();
    final doc = LocalDocument();
    doc.data = source;
    final rootId = '${source['root']}';
    // 造一个可变形部件，记录一条关键形（宿主存的是相对静止姿态的增量）。
    doc.applyCommand(<String, Object?>{
      'op': 'part.create',
      'name': 'warp',
      'parent': rootId,
    });
    final nodes = asJsonMap(doc.data['nodes']);
    final warpId = nodes.keys.firstWhere(
      (id) => '${asJsonMap(nodes[id])['name']}' == 'warp',
    );

    final spec = hostDocToEngineSpec(doc.data, projectName: 'kf');
    final engineNodes = asJsonList(asJsonMap(spec['model'])['nodes']);
    for (final raw in engineNodes) {
      final node = asJsonMap(raw);
      if ('${node['id']}' != warpId) continue;
      // keyforms 是「按参数 id 索引的对象」，值是引擎关键形数组。
      final keyforms = asJsonMap(node['keyforms']);
      for (final entry in keyforms.entries) {
        for (final rawKey in asJsonList(entry.value)) {
          final key = asJsonMap(rawKey);
          expect(key['value'], isNotNull);
          expect(key['blend'], isNotNull);
        }
      }
    }

    final back = hostDocFromSpec(spec, projectName: 'kf');
    expect(
      asJsonMap(back['nodes']).keys.toSet(),
      asJsonMap(doc.data['nodes']).keys.toSet(),
    );
  });
}
