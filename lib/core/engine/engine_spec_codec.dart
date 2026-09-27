/// 宿主文档 ↔ 引擎 `Spec` 编解码器。
///
/// 背景（`docs/engine-requests.md` §2 / §3 #4）：引擎的编辑方法面只覆盖
/// **模型结构**（`set_canvas` / `node_create` / `mesh_set` / `keyform_record` /
/// `parameter_add` …），**没有**物理、动作、表情、姿势、设置的编辑命令，
/// 而且 `doc.command` 只认 snake_case 的 `op`，宿主 UI 用的是点号 op
/// （`physics.add_setting` / `expression.create` …）。直接透传必然得到
/// 「命令无法解析」。
///
/// 因此 [ContractAmEngine] 用内置的 `LocalDocument` 当**影子文档**作为编辑真值，
/// 由本文件把影子文档投影成引擎能读的 `Spec`，再用 `project.set_spec` 一次性
/// 推给引擎求值。反向投影用于打开「引擎格式」的工程目录。
///
/// 两边的形状差异（逐条对着 Rust 源码核过）：
///
/// | 概念 | 宿主 | 引擎 |
/// | --- | --- | --- |
/// | 节点表 | `{id: node}` 映射，带 `children` | `Vec<Node>`，只有 `parent` |
/// | 节点类型字段 | `type` | `kind`（取值同名） |
/// | 网格顶点 | `[[x, y], …]` | `[{"x":…,"y":…}, …]` |
/// | 绘制对象 | 平铺在节点上 | 嵌套在 `drawable` 里 |
/// | 纹理 | `texture` 是资源路径 | `texture` 是 `textures` 下标 |
/// | 变形器边界 | `bounds` 是 `[x, y, w, h]` | `rest_rect` 是 `{"min","max"}` |
/// | 关键形顶点 | 相对静止网格的**增量** | **绝对**覆盖值 |
/// | 关键形变换 | `transform:{position,angle,scale}` | `rotation:{angle,position,scale,origin}` |
/// | 动作循环 | `loop` | JSON 键也是 `loop`（Rust 字段名 `looping`） |
/// | 动作曲线目标 | `curves[].param` | `curves[].target` |
/// | 动作插值 | `keys[].interp` 字符串 | `keys[].easing` 对象 `{"type":…}` |
/// | 表情参数 | `params: {paramId: value}` | `parameters: [{parameter, value}]` |
/// | 物理设定 | `pendulum` / `vertex` 两个子对象 | `vertices` 顶点链 + `delay`/`gravity` |
/// | 设置 | `blink.interval` / `breath.period` | `auto_blink` / `auto_breath` |
///
/// 引擎**没有** `deny_unknown_fields`，未知键会被忽略且在 `project.spec` 里原样回传，
/// 因此宿主独有的字段（`art_path`、`bounds`、`pendulum`、`blink` …）通过
/// `__host` 附带键无损往返。
library;

import 'am_types.dart';
import 'local_document.dart';

/// 宿主专有数据的挂载点（引擎忽略未知键，读回时原样保留）。
const String kHostExtrasKey = '__host';

// ---------------------------------------------------------------------------
// 基础形状
// ---------------------------------------------------------------------------

/// `[x, y]` 或 `{"x","y"}` → `{"x":…,"y":…}`。
Map<String, Object?> _v2(Object? raw, {double fallback = 0}) {
  final list = asJsonList(raw);
  if (list.length >= 2) {
    return <String, Object?>{'x': asDouble(list[0]), 'y': asDouble(list[1])};
  }
  final map = asJsonMap(raw);
  if (map.isNotEmpty) {
    return <String, Object?>{
      'x': asDouble(map['x'], fallback),
      'y': asDouble(map['y'], fallback),
    };
  }
  return <String, Object?>{'x': fallback, 'y': fallback};
}

/// `{"x","y"}` → `[x, y]`。
List<Object?> _v2List(Object? raw) {
  final map = asJsonMap(raw);
  return <Object?>[asDouble(map['x']), asDouble(map['y'])];
}

/// `[x, y, w, h]` → `{"min":…,"max":…}`。
Map<String, Object?> _rectFromBounds(
  Object? raw, {
  List<double> fallback = const <double>[-100, -100, 200, 200],
}) {
  final list = asJsonList(raw);
  final x = list.isNotEmpty ? asDouble(list[0], fallback[0]) : fallback[0];
  final y = list.length > 1 ? asDouble(list[1], fallback[1]) : fallback[1];
  final w = list.length > 2 ? asDouble(list[2], fallback[2]) : fallback[2];
  final h = list.length > 3 ? asDouble(list[3], fallback[3]) : fallback[3];
  return <String, Object?>{
    'min': <String, Object?>{'x': x, 'y': y},
    'max': <String, Object?>{'x': x + w, 'y': y + h},
  };
}

/// `{"min":…,"max":…}` → `[x, y, w, h]`。
List<Object?> _boundsFromRect(Object? raw) {
  final map = asJsonMap(raw);
  final min = asJsonMap(map['min']);
  final max = asJsonMap(map['max']);
  final x = asDouble(min['x']);
  final y = asDouble(min['y']);
  return <Object?>[x, y, asDouble(max['x']) - x, asDouble(max['y']) - y];
}

/// 宿主插值名 → 引擎 `Easing`。
///
/// 引擎的 `Easing` 是**内部标记**枚举，裸字符串会被拒绝，必须是
/// `{"type":"linear"}` 这种形状。
Map<String, Object?> _easingFromHost(Object? raw) {
  switch ('${raw ?? 'linear'}'.toLowerCase()) {
    case 'step':
      return <String, Object?>{'type': 'step'};
    case 'bezier':
    case 'ease_in_out':
      return <String, Object?>{
        'type': 'cubic_bezier',
        'p1': <String, Object?>{'x': 0.42, 'y': 0.0},
        'p2': <String, Object?>{'x': 0.58, 'y': 1.0},
      };
    case 'ease_in':
      return <String, Object?>{'type': 'ease_in'};
    case 'ease_out':
      return <String, Object?>{'type': 'ease_out'};
    case 'linear':
    default:
      return <String, Object?>{'type': 'linear'};
  }
}

/// 引擎 `Easing` → 宿主插值名。
String _easingToHost(Object? raw) {
  switch ('${asJsonMap(raw)['type'] ?? 'linear'}') {
    case 'step':
      return 'step';
    case 'cubic_bezier':
      return 'bezier';
    case 'ease_in':
      return 'ease_in';
    case 'ease_out':
      return 'ease_out';
    case 'ease_in_out':
      return 'ease_in_out';
    case 'linear':
    default:
      return 'linear';
  }
}

/// 宿主混合模式 → 引擎 `BlendType`（取值同名，仅防脏数据）。
String _blendFromHost(Object? raw) {
  final name = '${raw ?? 'normal'}'.toLowerCase();
  const known = <String>{'normal', 'multiply', 'screen', 'additive'};
  return known.contains(name) ? name : 'normal';
}

/// 引擎 `BlendType` → 宿主混合模式（宿主用 `additive` 的别名 `add`）。
String _blendToHost(Object? raw) {
  final name = '${raw ?? 'normal'}'.toLowerCase();
  return name == 'add' ? 'additive' : name;
}

/// 宿主节点类型 → 引擎 `NodeKind`。
String _kindFromHost(Object? raw) {
  final name = '${raw ?? 'part'}'.toLowerCase();
  const known = <String>{
    'part',
    'drawable',
    'warp_deformer',
    'rotation_deformer',
  };
  return known.contains(name) ? name : 'part';
}

/// 引擎 id 是否合法（`am_model::is_valid_id`：ASCII 字母数字 / `_` / `-`，≤128）。
bool isEngineSafeId(String id) {
  if (id.isEmpty || id.length > 128) return false;
  for (final unit in id.codeUnits) {
    final ok =
        (unit >= 0x30 && unit <= 0x39) ||
        (unit >= 0x41 && unit <= 0x5A) ||
        (unit >= 0x61 && unit <= 0x7A) ||
        unit == 0x5F ||
        unit == 0x2D;
    if (!ok) return false;
  }
  return true;
}

/// 把任意名字变成可安全用作文件名的 id。
///
/// 动作/表情在引擎里会落成 `<id>.motion.json` / `<id>.exp.json`，`write_spec`
/// 会用 `is_valid_id` 拒绝非 ASCII 名字，所以这里必须清洗。
String engineSafeIdFrom(String raw, {required String prefix}) {
  if (isEngineSafeId(raw)) return raw;
  final buffer = StringBuffer(prefix);
  for (final unit in raw.codeUnits) {
    final isDigit = unit >= 0x30 && unit <= 0x39;
    final isUpper = unit >= 0x41 && unit <= 0x5A;
    final isLower = unit >= 0x61 && unit <= 0x7A;
    if (isDigit || isUpper || isLower || unit == 0x5F) {
      buffer.writeCharCode(unit);
    } else if (unit == 0x2D || unit == 0x2E || unit == 0x20) {
      buffer.write('_');
    }
  }
  final text = buffer.toString();
  return text.length > 1 ? text : '${prefix}item';
}

/// 宿主动作 → 引擎动作 id（`motion.play` / `motion.seek` 都用它）。
String engineMotionId(Map<String, Object?> motion) => engineSafeIdFrom(
  '${motion['id'] ?? motion['name'] ?? 'motion'}',
  prefix: 'm',
);

/// 宿主表情 → 引擎表情 id（`expression.set` 用它）。
String engineExpressionId(Map<String, Object?> expression) => engineSafeIdFrom(
  '${expression['id'] ?? expression['name'] ?? 'expression'}',
  prefix: 'e',
);

// ---------------------------------------------------------------------------
// 宿主 → 引擎
// ---------------------------------------------------------------------------

/// 把宿主文档投影成引擎 `Spec`（可直接喂给 `project.set_spec`）。
Map<String, Object?> hostDocToEngineSpec(
  Map<String, Object?> host, {
  String projectName = 'model',
}) {
  final config = asJsonMap(host['config']);
  final canvas = asJsonMap(config['canvas']);
  final atlas = asJsonList(host['atlas']);
  final settings = asJsonMap(host['settings']);
  final projectSection = asJsonMap(config['project']);
  final name = '${projectSection['name'] ?? projectName}';

  return <String, Object?>{
    'model': <String, Object?>{
      'version': 1,
      'id': engineSafeIdFrom(
        '${projectSection['display_name'] ?? name}',
        prefix: 'model',
      ),
      'name': name,
      'canvas': <String, Object?>{
        'width': asDouble(canvas['width'], 1280),
        'height': asDouble(canvas['height'], 720),
        'origin': <String, Object?>{'x': 0.0, 'y': 0.0},
        'pixels_per_unit': asDouble(config['device_pixel_ratio'], 1),
      },
      'textures': <Object?>[
        for (final raw in atlas) _textureRef(raw),
      ],
      'nodes': <Object?>[
        for (final entry in asJsonMap(host['nodes']).entries)
          _nodeToEngine(entry.key, asJsonMap(entry.value), atlas),
      ],
      'parameters': <Object?>[
        for (final entry in asJsonMap(host['parameters']).entries)
          _parameterToEngine(entry.key, asJsonMap(entry.value)),
      ],
      'parameter_groups': _parameterGroups(host),
    },
    'physics': _physicsToEngine(host, settings),
    'pose': _poseToEngine(host),
    'settings': _modelSettingsToEngine(settings),
    'motions': <Object?>[
      for (final raw in asJsonList(host['motions'])) _motionToEngine(raw),
    ],
    'expressions': <Object?>[
      for (final raw in asJsonList(host['expressions'])) _expressionToEngine(raw),
    ],
    'config': _projectConfigToEngine(config, name, host),
  };
}

Map<String, Object?> _textureRef(Object? raw) {
  final map = asJsonMap(raw);
  final asset = '${map['asset'] ?? map['path'] ?? map['id'] ?? ''}';
  return <String, Object?>{
    'id': engineSafeIdFrom('${map['id'] ?? asset}', prefix: 't'),
    'asset': asset,
    'width': asInt(map['width']),
    'height': asInt(map['height']),
    'atlas': asBool(map['atlas'], true),
  };
}

/// 宿主纹理路径 → `Model::textures` 下标（引擎只认下标）。
int? _textureIndex(Object? raw, List<Object?> atlas) {
  final path = '${raw ?? ''}';
  if (path.isEmpty) return null;
  for (var i = 0; i < atlas.length; i++) {
    final item = asJsonMap(atlas[i]);
    final asset = '${item['asset'] ?? item['path'] ?? item['id'] ?? ''}';
    if (asset == path || '${item['id'] ?? ''}' == path) return i;
  }
  return null;
}

Map<String, Object?> _nodeToEngine(
  String id,
  Map<String, Object?> node,
  List<Object?> atlas,
) {
  final kind = _kindFromHost(node['type'] ?? node['kind']);
  final result = <String, Object?>{
    'id': id,
    'name': '${node['name'] ?? id}',
    'visible': asBool(node['visible'], true),
    'locked': asBool(node['locked']),
    'draw_order': asInt(node['draw_order']),
    'kind': kind,
  };
  final parent = node['parent'];
  if (parent != null && '$parent'.isNotEmpty) result['parent'] = '$parent';

  switch (kind) {
    case 'drawable':
      result['drawable'] = _drawableToEngine(node, atlas);
    case 'warp_deformer':
      result['warp'] = <String, Object?>{
        'rows': asInt(node['rows'], 1),
        'cols': asInt(node['cols'], 1),
        'rest_rect': _rectFromBounds(node['bounds']),
        'control_points': <Object?>[
          for (final raw in asJsonList(node['control_points'])) _v2(raw),
        ],
        'show_grid': true,
      };
    case 'rotation_deformer':
      result['rotation'] = <String, Object?>{
        'angle': asDouble(node['angle']),
        'position': _v2(node['position']),
        'scale': _v2(node['scale'], fallback: 1),
        'origin': <String, Object?>{'x': 0.0, 'y': 0.0},
        'handle_length': 40.0,
      };
  }

  final keyforms = _keyformsToEngine(node);
  if (keyforms.isNotEmpty) result['keyforms'] = keyforms;
  return result;
}

Map<String, Object?> _drawableToEngine(
  Map<String, Object?> node,
  List<Object?> atlas,
) {
  final mesh = asJsonMap(node['mesh']);
  final uv = asJsonList(node['uv']);
  final drawable = <String, Object?>{
    'mesh': <String, Object?>{
      'vertices': <Object?>[
        for (final raw in asJsonList(mesh['vertices'])) _v2(raw),
      ],
      'uvs': <Object?>[
        for (final raw in asJsonList(mesh['uvs'])) _v2(raw),
      ],
      'indices': <Object?>[
        for (final raw in asJsonList(mesh['indices'])) asInt(raw),
      ],
    },
    'opacity': asDouble(node['opacity'], 1),
    'blend': _blendFromHost(node['blend_mode']),
    'masks': <Object?>[
      for (final raw in asJsonList(node['mask'])) '$raw',
    ],
    'inverted_mask': false,
    'culling': false,
  };
  final texture = _textureIndex(node['texture'], atlas);
  if (texture != null) drawable['texture'] = texture;
  if (uv.length == 4) {
    // 宿主 uv 是归一化矩形，引擎 `uv_rect` 用同一个 min/max 形状表达。
    drawable['uv_rect'] = <String, Object?>{
      'min': <String, Object?>{'x': asDouble(uv[0]), 'y': asDouble(uv[1])},
      'max': <String, Object?>{
        'x': asDouble(uv[2], 1),
        'y': asDouble(uv[3], 1),
      },
    };
  }
  return drawable;
}

/// 宿主关键形（顶点是**增量**）→ 引擎关键形（顶点是**绝对值**）。
Map<String, Object?> _keyformsToEngine(Map<String, Object?> node) {
  final host = asJsonMap(node['keyforms']);
  if (host.isEmpty) return const <String, Object?>{};
  final rest = <List<double>>[
    for (final raw in asJsonList(asJsonMap(node['mesh'])['vertices']))
      <double>[asDouble(asJsonList(raw).firstOrNull), _second(raw)],
  ];
  final result = <String, Object?>{};
  for (final entry in host.entries) {
    final perParam = asJsonMap(entry.value);
    final blend = _blendFromHost(perParam['blend_type']);
    final keys = <Object?>[];
    for (final rawKey in asJsonList(perParam['keys'])) {
      final key = asJsonMap(rawKey);
      final item = <String, Object?>{
        'value': asDouble(key['value']),
        'blend': blend,
      };
      final deltas = asJsonList(key['vertices']);
      if (deltas.isNotEmpty) {
        item['vertices'] = <Object?>[
          for (var i = 0; i < deltas.length; i++)
            <String, Object?>{
              'x': (i < rest.length ? rest[i][0] : 0) + _first(deltas[i]),
              'y': (i < rest.length ? rest[i][1] : 0) + _second(deltas[i]),
            },
        ];
      }
      final points = asJsonList(key['control_points']);
      if (points.isNotEmpty) {
        item['control_points'] = <Object?>[
          for (final raw in points) _v2(raw),
        ];
      }
      if (key['opacity'] != null) item['opacity'] = asDouble(key['opacity'], 1);
      final transform = asJsonMap(key['transform']);
      if (transform.isNotEmpty) {
        item['rotation'] = <String, Object?>{
          'angle': asDouble(transform['angle']),
          'position': _v2(transform['position']),
          'scale': _v2(transform['scale'], fallback: 1),
          'origin': <String, Object?>{'x': 0.0, 'y': 0.0},
        };
      }
      keys.add(item);
    }
    result[entry.key] = keys;
  }
  return result;
}

double _first(Object? raw) {
  final list = asJsonList(raw);
  return list.isNotEmpty ? asDouble(list[0]) : 0;
}

double _second(Object? raw) {
  final list = asJsonList(raw);
  return list.length > 1 ? asDouble(list[1]) : 0;
}

Map<String, Object?> _parameterToEngine(
  String id,
  Map<String, Object?> param,
) {
  final result = <String, Object?>{
    'id': id,
    'name': '${param['name'] ?? id}',
    'min': asDouble(param['min'], -1),
    'max': asDouble(param['max'], 1),
    'default': asDouble(param['default']),
    'keys': <Object?>[
      for (final raw in asJsonList(param['keys'])) asDouble(raw),
    ],
    'is_blend_shape': asBool(param['is_blend_shape']),
    'repeat': asBool(param['repeat']),
    'auto': asBool(param['auto']),
    'weight': asDouble(param['weight'], 1),
  };
  final group = param['group'];
  if (group != null && '$group'.isNotEmpty) result['group'] = '$group';
  final comment = param['comment'];
  if (comment != null) result['comment'] = '$comment';
  return result;
}

/// 宿主没有独立的参数分组表；按参数上的 `group` 归并出引擎的 `ParameterGroup`。
List<Object?> _parameterGroups(Map<String, Object?> host) {
  final groups = <String, List<Object?>>{};
  for (final entry in asJsonMap(host['parameters']).entries) {
    final group = '${asJsonMap(entry.value)['group'] ?? ''}';
    if (group.isEmpty) continue;
    groups.putIfAbsent(group, () => <Object?>[]).add(entry.key);
  }
  return <Object?>[
    for (final entry in groups.entries)
      <String, Object?>{
        'id': entry.key,
        'name': entry.key,
        'parameters': entry.value,
      },
  ];
}

// ---------------------------------------------------------------------------
// 宿主 → 引擎：物理 / 姿势 / 设置 / 动作 / 表情 / 工程配置
// ---------------------------------------------------------------------------

Map<String, Object?> _normRange(Object? raw, {double min = -1, double max = 1}) {
  final map = asJsonMap(raw);
  final lo = asDouble(map['min'], min);
  final hi = asDouble(map['max'], max);
  return <String, Object?>{
    'min': lo,
    'default': asDouble(map['default'], (lo + hi) / 2),
    'max': hi,
  };
}

Map<String, Object?> _physicsInput(Object? raw) {
  final map = asJsonMap(raw);
  return <String, Object?>{
    'parameter': '${map['parameter'] ?? map['param'] ?? ''}',
    'weight': asDouble(map['weight'], 1),
    'inverted': asBool(map['inverted']),
    'param_type': '${map['param_type'] ?? 'position'}',
    'normalization': _normRange(map['normalization']),
  };
}

Map<String, Object?> _physicsOutput(Object? raw) {
  final map = asJsonMap(raw);
  return <String, Object?>{
    'parameter': '${map['parameter'] ?? map['param'] ?? ''}',
    'weight': asDouble(map['weight'], 1),
    'inverted': asBool(map['inverted']),
    'param_type': '${map['param_type'] ?? 'position'}',
    'scale': asDouble(map['scale'], 1),
    'reflect': asBool(map['reflect']),
    'normalization': _normRange(map['normalization']),
  };
}

Map<String, Object?> _physicsToEngine(
  Map<String, Object?> host,
  Map<String, Object?> settings,
) {
  return <String, Object?>{
    'enabled': asBool(settings['physics_enabled'], true),
    'fps': 60.0,
    'gravity': <String, Object?>{'x': 0.0, 'y': -9.8},
    'wind': <String, Object?>{'x': 0.0, 'y': 0.0},
    'settings': <Object?>[
      for (final raw in asJsonList(host['physics']))
        _physicsSettingToEngine(raw),
    ],
  };
}

Map<String, Object?> _physicsSettingToEngine(Object? raw) {
  final setting = asJsonMap(raw);
  final id = engineSafeIdFrom(
    '${setting['id'] ?? setting['name'] ?? 'physics'}',
    prefix: 'x',
  );
  final vertex = asJsonMap(setting['vertex']);
  final chain = asJsonList(vertex['vertices']);
  final pendulum = asJsonMap(setting['pendulum']);
  final result = <String, Object?>{
    'id': id,
    'name': '${setting['name'] ?? id}',
    'kind': chain.isEmpty ? 'pendulum' : 'vertex',
    'inputs': <Object?>[
      for (final item in asJsonList(setting['inputs'])) _physicsInput(item),
    ],
    'outputs': <Object?>[
      for (final item in asJsonList(setting['outputs'])) _physicsOutput(item),
    ],
    'vertices': <Object?>[
      for (final item in chain)
        <String, Object?>{
          'position': _v2(asJsonMap(item)['position'] ?? item, fallback: -10),
          'mobility': asDouble(asJsonMap(item)['mobility'], 1),
          'delay': asDouble(asJsonMap(item)['delay']),
          'acceleration': asDouble(asJsonMap(item)['acceleration'], 1),
          'radius': asDouble(asJsonMap(item)['radius']),
          'weight': asDouble(asJsonMap(item)['weight'], 1),
        },
    ],
    'delay': asDouble(pendulum['delay']),
    'gravity': asDouble(pendulum['gravity'], 1),
    'enabled': asBool(setting['enabled'], true),
    // 宿主独有的字段原样带上：引擎忽略，读回时用来还原面板（length/frequency/damping）。
    if (pendulum.isNotEmpty || vertex.isNotEmpty)
      kHostExtrasKey: <String, Object?>{
        'pendulum': pendulum,
        'vertex': vertex,
      },
  };
  return result;
}

Map<String, Object?> _poseToEngine(Map<String, Object?> host) {
  // 宿主姿势是扁平的 `[{id, name, group, parts[]}]`；引擎按 group 归并。
  final groups = <String, Map<String, Object?>>{};
  for (final raw in asJsonList(host['pose'])) {
    final item = asJsonMap(raw);
    final group = '${item['group'] ?? 'pose_group'}';
    final bucket = groups.putIfAbsent(
      group,
      () => <String, Object?>{
        'id': engineSafeIdFrom(group, prefix: 'g'),
        'name': group,
        'parts': <Object?>[],
      },
    );
    (bucket['parts'] as List<Object?>).add(<String, Object?>{
      'node': '${item['id'] ?? item['node'] ?? ''}',
      'visible': true,
    });
  }
  return <String, Object?>{'groups': groups.values.toList()};
}

Map<String, Object?> _modelSettingsToEngine(Map<String, Object?> settings) {
  final blink = asJsonMap(settings['blink']);
  final breath = asJsonMap(settings['breath']);
  final lipsync = asJsonMap(settings['lipsync']);
  return <String, Object?>{
    if (settings['display_name'] != null)
      'display_name': '${settings['display_name']}',
    if (settings['default_motion'] != null)
      'default_motion': '${settings['default_motion']}',
    if (settings['default_expression'] != null)
      'default_expression': '${settings['default_expression']}',
    'physics': asBool(settings['physics_enabled'], true),
    'auto_blink': <String, Object?>{
      'enabled': asBool(blink['enabled']),
      'interval': asDouble(blink['interval'], 4),
      'duration': asDouble(blink['duration'], 0.15),
      'min': 0.0,
      'max': 1.0,
      'jitter': asDouble(blink['jitter'], 0.5),
    },
    'auto_breath': <String, Object?>{
      'enabled': asBool(breath['enabled']),
      'interval': asDouble(breath['period'], 3.5),
      'duration': asDouble(breath['duration'], 3),
      'min': -1.0,
      'max': 1.0,
      'jitter': 0.0,
    },
    'lip_sync': <String, Object?>{
      'enabled': asBool(lipsync['enabled']),
      'amplify': asDouble(lipsync['gain'], 1),
      'smoothing': 0.05,
    },
  };
}

Map<String, Object?> _motionToEngine(Object? raw) {
  final motion = asJsonMap(raw);
  final name = '${motion['name'] ?? 'motion'}';
  return <String, Object?>{
    'id': engineMotionId(motion),
    'name': name,
    'duration': asDouble(motion['duration'], 0),
    // 引擎 Rust 字段叫 `looping`，但 JSON 键是 `loop`。
    'loop': asBool(motion['loop']),
    'fps': asDouble(motion['fps'], 60),
    'fade_in': asDouble(motion['fade_in'], 0),
    'fade_out': asDouble(motion['fade_out'], 0),
    'curves': <Object?>[
      for (final rawCurve in asJsonList(motion['curves']))
        _motionCurveToEngine(rawCurve),
    ],
  };
}

Map<String, Object?> _motionCurveToEngine(Object? raw) {
  final curve = asJsonMap(raw);
  return <String, Object?>{
    'target': '${curve['param'] ?? curve['target'] ?? ''}',
    'kind': 'parameter',
    'keys': <Object?>[
      for (final rawKey in asJsonList(curve['keys']))
        <String, Object?>{
          'time': asDouble(asJsonMap(rawKey)['time']),
          'value': asDouble(asJsonMap(rawKey)['value']),
          'easing': _easingFromHost(
            asJsonMap(rawKey)['interp'] ?? asJsonMap(rawKey)['interpolation'],
          ),
        },
    ],
  };
}

Map<String, Object?> _expressionToEngine(Object? raw) {
  final expression = asJsonMap(raw);
  final name = '${expression['name'] ?? 'expression'}';
  return <String, Object?>{
    'id': engineExpressionId(expression),
    'name': name,
    'fade_in': asDouble(expression['fade_in'], 0),
    'fade_out': asDouble(expression['fade_out'], 0),
    'parameters': <Object?>[
      for (final entry in asJsonMap(expression['params']).entries)
        <String, Object?>{
          'parameter': entry.key,
          'value': asDouble(entry.value),
          'blend': 'normal',
          'weight': 1.0,
        },
    ],
  };
}

Map<String, Object?> _projectConfigToEngine(
  Map<String, Object?> config,
  String fallbackName,
  Map<String, Object?> host,
) {
  final project = asJsonMap(config['project']);
  final name = '${project['name'] ?? fallbackName}';
  return <String, Object?>{
    'project': <String, Object?>{
      'name': name,
      if (project['display_name'] != null)
        'display_name': '${project['display_name']}',
      if (project['author'] != null) 'author': '${project['author']}',
      if (project['version'] != null) 'version': '${project['version']}',
    },
    'engine': <String, Object?>{'name': 'anima', 'version': '0.1.0'},
    'settings': <String, Object?>{
      'quality': '${config['render_quality'] ?? 'high'}',
      'canvas_width': asDouble(asJsonMap(config['canvas'])['width'], 1280),
      'canvas_height': asDouble(asJsonMap(config['canvas'])['height'], 720),
      'language': '${config['default_language'] ?? 'zh-CN'}',
      'volume': 1.0,
    },
    // 宿主专有数据：`ProjectConfig` 有 `#[serde(flatten)]`，未知键会原样保留，
    // 因此这里是引擎**支持**的宿主扩展通道，`project.save` 落盘、`project.load`
    // 读回都不会丢。`doc` 是完整宿主文档，保证 `bounds` / `pendulum` /
    // `in_tangent` 这类引擎没有对应物的字段无损往返。
    kHostExtrasKey: <String, Object?>{
      'unit': '${asJsonMap(config['canvas'])['unit'] ?? 'px'}',
      'device_pixel_ratio': asDouble(config['device_pixel_ratio'], 1),
      'doc': host,
    },
  };
}

// ---------------------------------------------------------------------------
// 引擎 → 宿主
// ---------------------------------------------------------------------------

/// 从引擎 `Spec` 还原宿主文档，**优先**使用随 spec 一起往返的宿主原件。
///
/// `spec/config.json` 里带了 `__host.doc`（`ProjectConfig` 的 `flatten` 会原样
/// 保留未知键），那是编辑器自己写的完整宿主文档，包含引擎无法表达的信息
/// （`bounds`、`pendulum.length`、`in_tangent`…）。只有文件来自别处、没有这个
/// 通道时才退化为按引擎字段重建。
Map<String, Object?> hostDocFromSpec(
  Map<String, Object?> spec, {
  String? projectName,
}) {
  final extras = asJsonMap(asJsonMap(spec['config'])[kHostExtrasKey]);
  final carried = asJsonMap(extras['doc']);
  if (carried.isNotEmpty) return carried;
  return hostSpecToDoc(spec, projectName: projectName);
}

/// 把引擎 `Spec`（`project.spec` 或 `spec/` 目录）还原成宿主文档。
///
/// 输出形状与 [defaultAnimaDocument] 一致：`nodes` 是按 id 键控的映射（带
/// `children`），参数也是映射，`atlas` 存纹理路径。
Map<String, Object?> hostSpecToDoc(
  Map<String, Object?> spec, {
  String? projectName,
}) {
  final model = asJsonMap(spec['model']);
  final textures = asJsonList(model['textures']);
  final doc = defaultAnimaDocument();

  final nodes = <String, Object?>{};
  String? rootId;
  for (final raw in asJsonList(model['nodes'])) {
    final node = asJsonMap(raw);
    final id = '${node['id'] ?? ''}';
    if (id.isEmpty) continue;
    final kind = '${node['kind'] ?? 'part'}';
    final parent = node['parent'] == null ? null : '${node['parent']}';
    if (parent == null && rootId == null) rootId = id;
    final item = <String, Object?>{
      'id': id,
      'name': '${node['name'] ?? id}',
      'type': kind,
      'parent': parent,
      'children': <Object?>[],
      'visible': asBool(node['visible'], true),
      'locked': asBool(node['locked']),
      'draw_order': asInt(node['draw_order']),
    };
    if (kind == 'drawable') {
      item.addAll(_drawableToHost(node, textures));
    } else if (kind == 'warp_deformer') {
      final warp = asJsonMap(node['warp']);
      item['rows'] = asInt(warp['rows'], 1);
      item['cols'] = asInt(warp['cols'], 1);
      item['bounds'] = _boundsFromRect(warp['rest_rect']);
      item['control_points'] = <Object?>[
        for (final rawPoint in asJsonList(warp['control_points']))
          _v2List(rawPoint),
      ];
    } else if (kind == 'rotation_deformer') {
      final rotation = asJsonMap(node['rotation']);
      item['position'] = _v2List(rotation['position']);
      item['scale'] = _v2List(rotation['scale']);
      item['angle'] = asDouble(rotation['angle']);
    }
    final keyforms = _keyformsToHost(node, item);
    if (keyforms.isNotEmpty) item['keyforms'] = keyforms;
    nodes[id] = item;
  }

  // 引擎只有 `parent` 指针；宿主面板要 `children`。
  for (final entry in nodes.entries) {
    final parent = '${asJsonMap(entry.value)['parent'] ?? ''}';
    if (parent.isEmpty || !nodes.containsKey(parent)) continue;
    final target = asJsonMap(nodes[parent]);
    target['children'] = <Object?>[
      ...asJsonList(target['children']),
      entry.key,
    ];
    nodes[parent] = target;
  }

  doc['root'] = rootId ?? doc['root'];
  doc['nodes'] = nodes;
  doc['parameters'] = <String, Object?>{
    for (final raw in asJsonList(model['parameters']))
      if (asJsonMap(raw)['id'] != null)
        '${asJsonMap(raw)['id']}': _parameterToHost(asJsonMap(raw)),
  };
  doc['atlas'] = <Object?>[
    for (final raw in textures)
      <String, Object?>{
        'id': '${asJsonMap(raw)['id'] ?? ''}',
        'asset': '${asJsonMap(raw)['asset'] ?? ''}',
        'path': '${asJsonMap(raw)['asset'] ?? ''}',
        'width': asInt(asJsonMap(raw)['width']),
        'height': asInt(asJsonMap(raw)['height']),
        'atlas': asBool(asJsonMap(raw)['atlas'], true),
      },
  ];

  final canvas = asJsonMap(model['canvas']);
  final config = asJsonMap(spec['config']);
  final configSettings = asJsonMap(config['settings']);
  final configProject = asJsonMap(config['project']);
  final extras = asJsonMap(config[kHostExtrasKey]);
  doc['config'] = <String, Object?>{
    'canvas': <String, Object?>{
      'width': asDouble(canvas['width'], 1280),
      'height': asDouble(canvas['height'], 720),
      // 老工程把 unit 直接写在 config 顶层（宿主的形状），引擎写的是
      // `__host.unit`；两种都认。
      'unit': '${extras['unit'] ?? config['unit'] ?? 'px'}',
    },
    'default_language':
        '${configSettings['language'] ?? config['default_language'] ?? 'zh-CN'}',
    'render_quality':
        '${configSettings['quality'] ?? config['render_quality'] ?? 'high'}',
    'device_pixel_ratio': asDouble(
      extras['device_pixel_ratio'] ?? config['device_pixel_ratio'],
      1,
    ),
    'project': <String, Object?>{
      'name': '${configProject['name'] ?? projectName ?? model['name'] ?? ''}',
      if (configProject['display_name'] != null)
        'display_name': '${configProject['display_name']}',
      if (configProject['author'] != null) 'author': '${configProject['author']}',
      if (configProject['version'] != null)
        'version': '${configProject['version']}',
    },
  };

  doc['physics'] = <Object?>[
    for (final raw in asJsonList(asJsonMap(spec['physics'])['settings']))
      _physicsSettingToHost(raw),
  ];
  doc['pose'] = <Object?>[
    for (final raw in asJsonList(asJsonMap(spec['pose'])['groups']))
      ..._poseGroupToHost(raw),
  ];
  doc['motions'] = <Object?>[
    for (final raw in asJsonList(spec['motions'])) _motionToHost(raw),
  ];
  doc['expressions'] = <Object?>[
    for (final raw in asJsonList(spec['expressions'])) _expressionToHost(raw),
  ];
  doc['settings'] = _modelSettingsToHost(spec, doc);
  return doc;
}

Map<String, Object?> _drawableToHost(
  Map<String, Object?> node,
  List<Object?> textures,
) {
  final drawable = asJsonMap(node['drawable']);
  final mesh = asJsonMap(drawable['mesh']);
  final uvRect = asJsonMap(drawable['uv_rect']);
  final uvMin = asJsonMap(uvRect['min']);
  final uvMax = asJsonMap(uvRect['max']);
  final hasUv = uvRect.isNotEmpty;
  final textureIndex = drawable['texture'];
  String? asset;
  if (textureIndex != null) {
    final index = asInt(textureIndex, -1);
    if (index >= 0 && index < textures.length) {
      asset = '${asJsonMap(textures[index])['asset'] ?? ''}';
    }
  }
  return <String, Object?>{
    'opacity': asDouble(drawable['opacity'], 1),
    'blend_mode': _blendToHost(drawable['blend']),
    'texture': asset,
    'uv': <Object?>[
      hasUv ? asDouble(uvMin['x']) : 0.0,
      hasUv ? asDouble(uvMin['y']) : 0.0,
      hasUv ? asDouble(uvMax['x'], 1) : 1.0,
      hasUv ? asDouble(uvMax['y'], 1) : 1.0,
    ],
    'mask': <Object?>[
      for (final raw in asJsonList(drawable['masks'])) '$raw',
    ],
    'mesh': <String, Object?>{
      'vertices': <Object?>[
        for (final raw in asJsonList(mesh['vertices'])) _v2List(raw),
      ],
      'uvs': <Object?>[
        for (final raw in asJsonList(mesh['uvs'])) _v2List(raw),
      ],
      'indices': <Object?>[
        for (final raw in asJsonList(mesh['indices'])) asInt(raw),
      ],
    },
  };
}

/// 引擎关键形（顶点是**绝对值**）→ 宿主关键形（顶点是**增量**）。
Map<String, Object?> _keyformsToHost(
  Map<String, Object?> node,
  Map<String, Object?> hostNode,
) {
  final host = asJsonMap(node['keyforms']);
  if (host.isEmpty) return const <String, Object?>{};
  final mesh = asJsonMap(hostNode['mesh']);
  final rest = <List<double>>[
    for (final raw in asJsonList(mesh['vertices']))
      <double>[asDouble(asJsonList(raw).firstOrNull), _second(raw)],
  ];
  final result = <String, Object?>{};
  for (final entry in host.entries) {
    final keys = <Object?>[];
    var blend = 'normal';
    for (final rawKey in asJsonList(entry.value)) {
      final key = asJsonMap(rawKey);
      blend = _blendToHost(key['blend']);
      final vertices = asJsonList(key['vertices']);
      final rotation = asJsonMap(key['rotation']);
      keys.add(<String, Object?>{
        'value': asDouble(key['value']),
        'vertices': <Object?>[
          for (var i = 0; i < vertices.length; i++)
            <Object?>[
              _first(vertices[i]) - (i < rest.length ? rest[i][0] : 0),
              _second(vertices[i]) - (i < rest.length ? rest[i][1] : 0),
            ],
        ],
        'transform': <String, Object?>{
          'position': _v2List(rotation['position']),
          'angle': asDouble(rotation['angle']),
          'scale': _v2List(rotation['scale']),
        },
        'control_points': <Object?>[
          for (final rawPoint in asJsonList(key['control_points']))
            _v2List(rawPoint),
        ],
        if (key['opacity'] != null) 'opacity': asDouble(key['opacity'], 1),
      });
    }
    result[entry.key] = <String, Object?>{
      'blend_type': blend,
      'keys': keys,
    };
  }
  return result;
}

Map<String, Object?> _parameterToHost(Map<String, Object?> param) {
  return <String, Object?>{
    'id': '${param['id'] ?? ''}',
    'name': '${param['name'] ?? param['id'] ?? ''}',
    'group': '${param['group'] ?? 'ParamGroup'}',
    'min': asDouble(param['min'], -1),
    'max': asDouble(param['max'], 1),
    'default': asDouble(param['default']),
    'keys': <Object?>[
      for (final raw in asJsonList(param['keys'])) asDouble(raw),
    ],
    'is_blend_shape': asBool(param['is_blend_shape']),
    'repeat': asBool(param['repeat']),
    'auto': asBool(param['auto']),
    if (param['comment'] != null) 'comment': '${param['comment']}',
  };
}

Map<String, Object?> _physicsSettingToHost(Object? raw) {
  final setting = asJsonMap(raw);
  final extras = asJsonMap(setting[kHostExtrasKey]);
  final vertices = asJsonList(setting['vertices']);
  // 宿主的 pendulum 是面板直接读写的对象；优先用带上来的原值。
  final pendulum = extras['pendulum'] == null
      ? <String, Object?>{
          'length': vertices.isEmpty
              ? 20.0
              : asDouble(
                  asJsonMap(asJsonMap(vertices.first)['position'])['y'],
                  -20,
                ).abs(),
          'frequency': 1.2,
          'damping': asDouble(setting['gravity'], 1),
        }
      : asJsonMap(extras['pendulum']);
  return <String, Object?>{
    'id': '${setting['id'] ?? ''}',
    'name': '${setting['name'] ?? setting['id'] ?? 'physics'}',
    'inputs': <Object?>[
      for (final item in asJsonList(setting['inputs']))
        <String, Object?>{
          'parameter': '${asJsonMap(item)['parameter'] ?? ''}',
          'weight': asDouble(asJsonMap(item)['weight'], 1),
          'inverted': asBool(asJsonMap(item)['inverted']),
          'param_type': '${asJsonMap(item)['param_type'] ?? 'position'}',
        },
    ],
    'outputs': <Object?>[
      for (final item in asJsonList(setting['outputs']))
        <String, Object?>{
          'parameter': '${asJsonMap(item)['parameter'] ?? ''}',
          'weight': asDouble(asJsonMap(item)['weight'], 1),
          'inverted': asBool(asJsonMap(item)['inverted']),
          'scale': asDouble(asJsonMap(item)['scale'], 1),
          'reflect': asBool(asJsonMap(item)['reflect']),
        },
    ],
    'pendulum': pendulum,
    'vertex': extras['vertex'] == null
        ? <String, Object?>{}
        : asJsonMap(extras['vertex']),
    'enabled': asBool(setting['enabled'], true),
  };
}

List<Object?> _poseGroupToHost(Object? raw) {
  final group = asJsonMap(raw);
  final name = '${group['name'] ?? group['id'] ?? 'pose'}';
  final parts = asJsonList(group['parts']);
  return <Object?>[
    for (var i = 0; i < parts.length; i++)
      <String, Object?>{
        'id': '${asJsonMap(parts[i])['node'] ?? ''}',
        'name': parts.length > 1 ? '$name ${i + 1}' : name,
        'group': name,
        'parts': <Object?>[
          <String, Object?>{
            'node': '${asJsonMap(parts[i])['node'] ?? ''}',
            'visible': asBool(asJsonMap(parts[i])['visible'], true),
          },
        ],
      },
  ];
}

Map<String, Object?> _motionToHost(Object? raw) {
  final motion = asJsonMap(raw);
  return <String, Object?>{
    'id': '${motion['id'] ?? ''}',
    'name': '${motion['name'] ?? motion['id'] ?? 'motion'}',
    'duration': asDouble(motion['duration'], 0),
    'loop': asBool(motion['loop']),
    'fps': asDouble(motion['fps'], 60),
    'fade_in': asDouble(motion['fade_in'], 0),
    'fade_out': asDouble(motion['fade_out'], 0),
    'curves': <Object?>[
      for (final rawCurve in asJsonList(motion['curves']))
        <String, Object?>{
          'param': '${asJsonMap(rawCurve)['target'] ?? ''}',
          'keys': <Object?>[
            for (final rawKey in asJsonList(asJsonMap(rawCurve)['keys']))
              <String, Object?>{
                'time': asDouble(asJsonMap(rawKey)['time']),
                'value': asDouble(asJsonMap(rawKey)['value']),
                'interp': _easingToHost(asJsonMap(rawKey)['easing']),
              },
          ],
        },
    ],
  };
}

Map<String, Object?> _expressionToHost(Object? raw) {
  final expression = asJsonMap(raw);
  final params = <String, Object?>{};
  for (final item in asJsonList(expression['parameters'])) {
    final entry = asJsonMap(item);
    params['${entry['parameter'] ?? ''}'] = asDouble(entry['value']);
  }
  return <String, Object?>{
    'id': '${expression['id'] ?? ''}',
    'name': '${expression['name'] ?? expression['id'] ?? 'expression'}',
    'fade_in': asDouble(expression['fade_in'], 0),
    'fade_out': asDouble(expression['fade_out'], 0),
    'params': params,
  };
}

Map<String, Object?> _modelSettingsToHost(
  Map<String, Object?> spec,
  Map<String, Object?> doc,
) {
  final settings = asJsonMap(spec['settings']);
  final blink = asJsonMap(settings['auto_blink']);
  final breath = asJsonMap(settings['auto_breath']);
  final lipsync = asJsonMap(settings['lip_sync']);
  final base = asJsonMap(doc['settings']);
  return <String, Object?>{
    ...base,
    'default_motion': settings['default_motion'],
    'default_expression': settings['default_expression'],
    'physics_enabled': asBool(settings['physics'], true),
    'blink': <String, Object?>{
      'enabled': asBool(blink['enabled']),
      'interval': asDouble(blink['interval'], 4),
    },
    'breath': <String, Object?>{
      'enabled': asBool(breath['enabled']),
      'period': asDouble(breath['interval'], 3.5),
    },
    'lipsync': <String, Object?>{
      'enabled': asBool(lipsync['enabled']),
      'gain': asDouble(lipsync['amplify'], 1),
    },
  };
}
