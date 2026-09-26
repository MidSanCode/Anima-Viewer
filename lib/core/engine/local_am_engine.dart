/// 内置降级引擎：完整实现 tasks.md §3 的调用契约，但**不渲染到纹理**。
///
/// 用途：引擎（`engine/` 仓库）交付前，编辑器与查看器的全部功能都可跑通：
/// * 文档命令 / 撤销重做 / 修订号；
/// * 工程新建、打开、保存、校验、导出、导入（Dart 侧 `.amproj` 实现）；
/// * 参数求值、关键形、变形器级联（见 `local_eval.dart`）；
/// * 命中测试、网格点屏幕坐标、动作播放、物理预览、自动眨眼/呼吸/口型。
///
/// 画布：纹理桥不可用时由 `AmSceneProvider` 提供场景给降级画家。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import '../project/amproj_fs.dart';
import '../project/amproj_models.dart';
import '../project/amproj_reader.dart';
import '../project/amproj_writer.dart';
import 'am_engine.dart';
import 'am_scene_provider.dart';
import 'am_types.dart';
import 'local_document.dart';
import 'local_eval.dart';

/// 内置实现声明支持的方法（供 `system.capabilities` 返回）。
const List<String> kLocalEngineMethods = <String>[
  'system.version',
  'system.capabilities',
  'renderer.create',
  'renderer.resize',
  'renderer.destroy',
  'renderer.frame',
  'renderer.background',
  'renderer.view',
  'renderer.pick',
  'renderer.measure',
  'project.create',
  'project.open',
  'project.close',
  'project.save',
  'project.info',
  'project.validate',
  'project.export',
  'project.import',
  'doc.command',
  'doc.undo',
  'doc.redo',
  'doc.history',
  'doc.revision',
  'doc.query',
  'runtime.set_param',
  'runtime.set_params',
  'runtime.params',
  'runtime.step',
  'runtime.seek',
  'runtime.reset',
  'runtime.play_motion',
  'runtime.stop_motion',
  'runtime.set_expression',
  'runtime.blink',
  'runtime.breath',
  'runtime.lipsync',
  'physics.query',
  'physics.set',
  'motion.load',
  'motion.record.begin',
  'motion.record.writes',
  'motion.record.end',
  'diagnostics.stats',
];

/// 内置引擎。
class LocalAmEngine implements AmEngine, AmSceneProvider {
  LocalAmEngine({
    Map<String, Object?>? initialDocument,
    bool demo = false,
    this.projectDir,
  }) : document = LocalDocument.fromJson(
         initialDocument ??
             (demo ? demoAnimaDocument() : defaultAnimaDocument()),
       ) {
    _params = defaultParams();
    document.applyDrawOrder();
  }

  /// 文档（UI 不直接依赖，仅降级场景构建使用）。
  final LocalDocument document;

  /// 已打开的工程目录（目录模式）。
  String? projectDir;

  final StreamController<AmEvent> _events =
      StreamController<AmEvent>.broadcast();

  final Map<String, double> _runtime = <String, double>{};
  late Map<String, double> _params;
  AmViewState _view = const AmViewState();
  List<double> _background = <double>[0, 0, 0, 0];

  // 动作播放
  String? _playingMotion;
  double _motionTime = 0;
  bool _motionLoop = false;
  bool _motionPlaying = false;

  // 表情
  String? _expression;

  // 自动效果
  bool _blinkEnabled = true;
  bool _breathEnabled = true;
  bool _lipsyncEnabled = false;
  double _lipsyncAmplitude = 0;
  double _blinkTimer = 0;
  double _blinkPhase = -1;
  double _clock = 0;

  // 物理
  final Map<String, List<double>> _physicsState = <String, List<double>>{};
  bool physicsEnabled = true;

  // 录制
  Map<String, Object?>? _recording;
  final List<Map<String, Object?>> _recordedWrites = <Map<String, Object?>>[];

  bool _available = true;
  bool _disposed = false;

  @override
  AmEngineBackend get backend => const AmEngineBackend(
    'local',
    'engine.backend.local',
    detail: 'built-in evaluator',
  );

  @override
  AmCapabilities get capabilities => AmCapabilities(
    engine: 'anima-local',
    sdk: '0.1.0',
    format: kAmprojFormat,
    minSdk: '$kAmSdkVersion',
    methods: kLocalEngineMethods.toSet(),
    platform: <String, Object?>{
      'texture_bridge': false,
      'wasm': false,
      'local_fallback': true,
      'filesystem': AmFileSystem.supportsDirectories,
    },
  );

  @override
  bool get isAvailable => _available && !_disposed;

  @override
  Stream<AmEvent> get events => _events.stream;

  @override
  AmTextureInfo? get textureInfo => null;

  @override
  Future<void> initialize({
    int width = 1280,
    int height = 720,
    double devicePixelRatio = 1.0,
  }) async {
    _view = _view.copyWith(
      canvasWidth: width.toDouble(),
      canvasHeight: height.toDouble(),
    );
    _available = true;
    _emit('capabilities', <String, Object?>{
      'methods': kLocalEngineMethods,
      'local_fallback': true,
    });
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    if (!_events.isClosed) await _events.close();
  }

  void _emit(String type, Map<String, Object?> data) {
    if (_events.isClosed) return;
    _events.add(AmEvent(type, <String, Object?>{'event': type, ...data}));
  }

  // ---------------------------------------------------------------------------
  // 契约入口
  // ---------------------------------------------------------------------------

  @override
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?>? params,
  ]) async {
    if (_disposed) {
      throw const AmException('ENGINE_DISPOSED', 'engine already disposed');
    }
    final p = params ?? const <String, Object?>{};
    switch (method) {
      case 'system.version':
        return <String, Object?>{
          'engine': 'anima-local',
          'sdk': kAmSdkVersion,
          'format': kAmprojFormat,
          'min_sdk': kAmSdkVersion,
          'fallback': true,
        };
      case 'system.capabilities':
        final capabilities = this.capabilities;
        return <String, Object?>{
          'engine': capabilities.engine,
          'sdk': capabilities.sdk,
          'format': capabilities.format,
          'min_sdk': capabilities.minSdk,
          'methods': capabilities.methods.toList()..sort(),
          'platform': capabilities.platform,
        };
      case 'renderer.create':
        _view = _view.copyWith(
          canvasWidth: asDouble(p['width'], _view.canvasWidth),
          canvasHeight: asDouble(p['height'], _view.canvasHeight),
        );
        return <String, Object?>{
          'width': _view.canvasWidth,
          'height': _view.canvasHeight,
          'texture_id': 0,
          'headless': asBool(p['headless']),
        };
      case 'renderer.resize':
        _view = _view.copyWith(
          canvasWidth: asDouble(p['width'], _view.canvasWidth),
          canvasHeight: asDouble(p['height'], _view.canvasHeight),
        );
        return <String, Object?>{
          'width': _view.canvasWidth,
          'height': _view.canvasHeight,
        };
      case 'renderer.destroy':
        return const <String, Object?>{};
      case 'renderer.frame':
        return <String, Object?>{
          'presented': false,
          'revision': document.revision,
          'fallback': true,
        };
      case 'renderer.background':
        final color = asJsonList(p['color']);
        if (color.length == 4) {
          _background = color.map(asDouble).toList();
        } else if (color.length == 3) {
          _background = <double>[...color.map(asDouble), 1];
        } else if (p['color'] == null) {
          _background = <double>[0, 0, 0, 0];
        }
        return <String, Object?>{'color': _background};
      case 'renderer.view':
        _view = _view.copyWith(
          pan: p['pan'] == null
              ? null
              : Offset(
                  asDouble(
                    asJsonList(p['pan']).isNotEmpty
                        ? asJsonList(p['pan'])[0]
                        : 0,
                  ),
                  asDouble(
                    asJsonList(p['pan']).length > 1
                        ? asJsonList(p['pan'])[1]
                        : 0,
                  ),
                ),
          zoom: p['zoom'] == null ? null : asDouble(p['zoom'], 1),
          flipX: p['flip_x'] == null ? null : asBool(p['flip_x']),
          flipY: p['flip_y'] == null ? null : asBool(p['flip_y']),
          canvasWidth: p['canvas'] == null
              ? null
              : asDouble(
                  asJsonList(p['canvas']).isNotEmpty
                      ? asJsonList(p['canvas'])[0]
                      : _view.canvasWidth,
                ),
          canvasHeight: p['canvas'] == null
              ? null
              : asDouble(
                  asJsonList(p['canvas']).length > 1
                      ? asJsonList(p['canvas'])[1]
                      : _view.canvasHeight,
                ),
        );
        return <String, Object?>{'view': _view.toJson()};
      case 'renderer.pick':
        final space = '${p['space'] ?? 'screen'}';
        final offset = Offset(asDouble(p['x']), asDouble(p['y']));
        final world = space == 'world' ? offset : _view.screenToWorld(offset);
        final scene = buildScene();
        final id = hitTestScene(scene, world);
        return <String, Object?>{'id': id, 'node': id};
      case 'renderer.measure':
        return <String, Object?>{'points': _measure(p)};
      case 'project.create':
        return _projectCreate(p);
      case 'project.open':
        return _projectOpen(p);
      case 'project.close':
        projectDir = null;
        return const <String, Object?>{};
      case 'project.save':
        return _projectSave(p);
      case 'project.info':
        return _projectInfo();
      case 'project.validate':
        final report = await _validateCurrent();
        return <String, Object?>{
          'ok': report.ok,
          'issues': report.issues.map((e) => e.toJson()).toList(),
          'errors': report.errorCount,
          'warnings': report.warningCount,
        };
      case 'project.export':
        return _projectExport(p);
      case 'project.import':
        return _projectImport(p);
      case 'doc.command':
        final command = asJsonMap(p['command'] ?? p);
        final revision = document.applyCommand(command);
        _emit('doc_changed', <String, Object?>{'revision': revision});
        document.applyDrawOrder();
        return <String, Object?>{'revision': revision};
      case 'doc.undo':
        final revision = document.undo();
        _emit('doc_changed', <String, Object?>{'revision': revision});
        return <String, Object?>{'revision': revision};
      case 'doc.redo':
        final revision = document.redo();
        _emit('doc_changed', <String, Object?>{'revision': revision});
        return <String, Object?>{'revision': revision};
      case 'doc.history':
        return <String, Object?>{
          'entries': document.historyLabels,
          'can_undo': document.canUndo,
          'can_redo': document.canRedo,
        };
      case 'doc.revision':
        return <String, Object?>{'revision': document.revision};
      case 'doc.query':
        return _docQuery(p);
      case 'runtime.set_param':
        return _setParams(<String, Object?>{
          '${p['param'] ?? p['id'] ?? ''}': p['value'],
        });
      case 'runtime.set_params':
        return _setParams(asJsonMap(p['params']));
      case 'runtime.params':
        return <String, Object?>{'params': _params};
      case 'runtime.step':
        return _step(asDouble(p['dt'], 1 / 60));
      case 'runtime.seek':
        _motionTime = asDouble(p['time']);
        _applyMotionAt(_motionTime);
        return <String, Object?>{
          'time': _motionTime,
          'params': _params,
          'playing': _motionPlaying,
        };
      case 'runtime.reset':
        _params = defaultParams();
        _playingMotion = null;
        _motionPlaying = false;
        _expression = null;
        _physicsState.clear();
        return <String, Object?>{'params': _params};
      case 'runtime.play_motion':
        final name = '${p['motion'] ?? p['name'] ?? ''}';
        _playingMotion = name.isEmpty ? null : name;
        _motionLoop = asBool(p['loop'], _motionLoopFor(name));
        _motionTime = 0;
        _motionPlaying = _playingMotion != null;
        return <String, Object?>{'motion': _playingMotion, 'loop': _motionLoop};
      case 'runtime.stop_motion':
        _motionPlaying = false;
        return const <String, Object?>{};
      case 'runtime.set_expression':
        _expression = p['name'] == null ? null : '${p['name']}';
        _applyExpression(_expression);
        return <String, Object?>{'expression': _expression, 'params': _params};
      case 'runtime.blink':
        _blinkEnabled = asBool(p['enabled'], true);
        return <String, Object?>{'enabled': _blinkEnabled};
      case 'runtime.breath':
        _breathEnabled = asBool(p['enabled'], true);
        return <String, Object?>{'enabled': _breathEnabled};
      case 'runtime.lipsync':
        if (p['enabled'] != null) _lipsyncEnabled = asBool(p['enabled']);
        if (p['amplitude'] != null) {
          _lipsyncAmplitude = asDouble(p['amplitude']).clamp(0.0, 1.0);
        }
        return <String, Object?>{
          'enabled': _lipsyncEnabled,
          'amplitude': _lipsyncAmplitude,
        };
      case 'physics.query':
        return <String, Object?>{'settings': document.physics};
      case 'physics.set':
        return _physicsSet(p);
      case 'motion.load':
        return <String, Object?>{'motion': _findMotion('${p['motion'] ?? ''}')};
      case 'motion.record.begin':
        _recording = <String, Object?>{
          'name': '${p['name'] ?? 'motion'}',
          'start': _clock,
          'params': <Object?>[...asJsonList(p['params'])],
          'fps': asInt(p['fps'], 60),
        };
        _recordedWrites.clear();
        return const <String, Object?>{'recording': true};
      case 'motion.record.writes':
        for (final write in asJsonList(p['writes'])) {
          _recordedWrites.add(asJsonMap(write));
        }
        return <String, Object?>{'samples': _recordedWrites.length};
      case 'motion.record.end':
        return _recordEnd(p);
      case 'diagnostics.stats':
        return _stats();
      default:
        throw AmException('UNSUPPORTED', 'method not supported: $method');
    }
  }

  // ---------------------------------------------------------------------------
  // 场景（降级画布）
  // ---------------------------------------------------------------------------

  @override
  Map<String, double> get paramValues =>
      Map<String, double>.unmodifiable(_params);

  @override
  AmViewState get view => _view;

  @override
  List<double> get background => _background;

  @override
  String? get playingMotion => _playingMotion;

  @override
  bool get isPlaying => _motionPlaying;

  @override
  String? get expression => _expression;

  @override
  AmScene buildScene({
    bool includeHidden = false,
    List<int> selectedVertices = const <int>[],
    String? selectedNode,
  }) {
    return AmSceneBuilder(document).build(
      params: _params,
      includeHidden: includeHidden,
      selectedVertices: selectedVertices,
      selectedNode: selectedNode,
    );
  }

  @override
  AmScene buildSceneWith({
    required Map<String, double> params,
    bool includeHidden = false,
    String? selectedNode,
  }) {
    return AmSceneBuilder(document).build(
      params: params,
      includeHidden: includeHidden,
      selectedNode: selectedNode,
    );
  }

  /// 参数默认值（含未在文档中声明的中间值）。
  Map<String, double> defaultParams() {
    final builder = AmSceneBuilder(document);
    final defaults = builder.defaultParams();
    final result = <String, double>{..._runtime};
    for (final entry in defaults.entries) {
      result.putIfAbsent(entry.key, () => entry.value);
    }
    return result;
  }

  List<Object?> _measure(Map<String, Object?> p) {
    final nodeId = '${p['node'] ?? p['id'] ?? ''}';
    final scene = buildScene();
    final indices = asJsonList(p['indices']).map(asInt).toList();
    final points = <Object?>[];
    for (final drawable in scene.drawables) {
      if (nodeId.isNotEmpty && drawable.id != nodeId) continue;
      for (var i = 0; i < drawable.vertices.length; i++) {
        if (indices.isNotEmpty && !indices.contains(i)) continue;
        final screen = _view.worldToScreen(drawable.vertices[i]);
        points.add(<Object?>[screen.dx, screen.dy]);
      }
    }
    return points;
  }

  // ---------------------------------------------------------------------------
  // doc.query
  // ---------------------------------------------------------------------------

  Map<String, Object?> _docQuery(Map<String, Object?> p) {
    final path = '${p['path'] ?? ''}';
    switch (path) {
      case 'hierarchy':
        return <String, Object?>{
          'revision': document.revision,
          'root': document.rootId,
          'nodes': document.nodes,
        };
      case 'node':
        final id = '${p['id'] ?? ''}';
        return <String, Object?>{
          'revision': document.revision,
          'node': document.nodes[id],
        };
      case 'parameters':
        return <String, Object?>{
          'revision': document.revision,
          'parameters': document.parameters,
        };
      case 'keyforms':
        final id = '${p['id'] ?? ''}';
        final node = asJsonMap(document.nodes[id]);
        return <String, Object?>{
          'revision': document.revision,
          'keyforms': asJsonMap(node['keyforms']),
        };
      case 'mesh':
        final id = '${p['id'] ?? ''}';
        final node = asJsonMap(document.nodes[id]);
        return <String, Object?>{
          'revision': document.revision,
          'mesh': asJsonMap(node['mesh']),
        };
      case 'physics':
        return <String, Object?>{'physics': document.physics};
      case 'motions':
        return <String, Object?>{'motions': document.motions};
      case 'expressions':
        return <String, Object?>{'expressions': document.expressions};
      case 'settings':
        return <String, Object?>{'settings': document.settings};
      case 'config':
        return <String, Object?>{'config': document.config};
      case 'pose':
        return <String, Object?>{'pose': document.pose};
      case 'atlas':
        return <String, Object?>{'atlas': asJsonList(document.data['atlas'])};
      case 'scene':
        final scene = buildScene(
          includeHidden: asBool(p['include_hidden']),
          selectedNode: p['selected'] == null ? null : '${p['selected']}',
        );
        return <String, Object?>{
          'revision': document.revision,
          'drawables': <Object?>[
            for (final drawable in scene.drawables)
              <String, Object?>{
                'id': drawable.id,
                'vertices': <Object?>[
                  for (final v in drawable.vertices) <Object?>[v.dx, v.dy],
                ],
              },
          ],
        };
      default:
        throw AmException('UNKNOWN_QUERY', 'unknown doc.query path: $path');
    }
  }

  // ---------------------------------------------------------------------------
  // 运行时
  // ---------------------------------------------------------------------------

  Map<String, Object?> _setParams(Map<String, Object?> values) {
    for (final entry in values.entries) {
      if (entry.key.isEmpty) continue;
      // 参数以 id 为键；同时接受参数名作为别名（UI / 脚本都可能用名字）。
      final id = _resolveParamId(entry.key);
      _params[id] = asDouble(entry.value);
      if (_recording != null) {
        _recordedWrites.add(<String, Object?>{
          'param': id,
          'value': asDouble(entry.value),
          'time': _clock - asDouble(_recording!['start']),
        });
      }
    }
    return <String, Object?>{'params': _params};
  }

  /// 把参数名解析成参数 id；已经是 id 或未知键时原样返回。
  String _resolveParamId(String key) {
    if (document.parameters.containsKey(key)) return key;
    for (final entry in document.parameters.entries) {
      if ('${asJsonMap(entry.value)['name']}' == key) return entry.key;
    }
    return key;
  }

  Map<String, Object?> _step(double dt, {bool emit = true}) {
    final clamped = dt.clamp(0.0, 0.25);
    _clock += clamped;

    // 动作求值。
    if (_motionPlaying && _playingMotion != null) {
      final motion = _findMotion(_playingMotion!);
      if (motion != null) {
        final duration = asDouble(motion['duration'], 0);
        _motionTime += clamped;
        if (duration > 0 && _motionTime > duration) {
          if (_motionLoop) {
            _motionTime = _motionTime % duration;
          } else {
            _motionTime = duration;
            _motionPlaying = false;
          }
        }
        _applyMotionAt(_motionTime);
      }
    }

    // 物理（固定步长确定性预览）。
    if (physicsEnabled) {
      final steps = math.max(1, (clamped / (1 / 60)).round());
      for (var i = 0; i < steps; i++) {
        _stepPhysics(1 / 60);
      }
    }

    // 自动眨眼。
    if (_blinkEnabled) {
      final interval = asDouble(
        asJsonMap(document.settings['blink'])['interval'],
        4,
      );
      if (_blinkPhase < 0) {
        _blinkTimer += clamped;
        if (_blinkTimer >= math.max(0.6, interval)) {
          _blinkTimer = 0;
          _blinkPhase = 0;
        }
      } else {
        _blinkPhase += clamped;
        final duration = 0.18;
        if (_blinkPhase >= duration) {
          _blinkPhase = -1;
          _applyParamByName(<String>['EyeOpen', 'eye_open'], 1.0);
        } else {
          final t = _blinkPhase / duration;
          final openness = (math.cos(t * math.pi * 2) + 1) / 2;
          _applyParamByName(<String>['EyeOpen', 'eye_open'], openness);
        }
      }
    }

    // 自动呼吸。
    if (_breathEnabled) {
      final period = asDouble(
        asJsonMap(document.settings['breath'])['period'],
        3.5,
      );
      final value = math.sin(_clock / math.max(0.5, period) * math.pi * 2);
      _applyParamByName(<String>['Breath', 'breath'], value);
    }

    // 口型同步（宿主喂入振幅包络）。
    if (_lipsyncEnabled) {
      _applyParamByName(<String>['MouthOpen', 'mouth_open'], _lipsyncAmplitude);
    }

    if (emit) {
      _emit('tick', <String, Object?>{
        'time': _clock,
        'params': _params,
        'playing': _motionPlaying,
      });
    }
    return <String, Object?>{
      'time': _clock,
      'params': _params,
      'playing': _motionPlaying,
      'revision': document.revision,
    };
  }

  /// 把动作在 [time] 时刻的曲线值写入参数。
  void _applyMotionAt(double time) {
    final name = _playingMotion;
    if (name == null) return;
    final motion = _findMotion(name);
    if (motion == null) return;
    for (final curve in asJsonList(motion['curves'])) {
      final item = asJsonMap(curve);
      final param = '${item['param']}';
      if (param.isEmpty) continue;
      _params[param] = evaluateCurve(
        asJsonList(item['keys']).map(asJsonMap).toList(),
        time,
      );
    }
  }

  void _applyParamByName(List<String> names, double value) {
    for (final entry in document.parameters.entries) {
      final name = '${asJsonMap(entry.value)['name']}';
      if (names.contains(name)) {
        _params[entry.key] = value;
        return;
      }
    }
    // 文档里没有该参数时也保留运行时值，便于查看器显示。
    _params[names.first] = value;
  }

  void _stepPhysics(double dt) {
    for (final setting in document.physics) {
      final item = asJsonMap(setting);
      if (!asBool(item['enabled'], true)) continue;
      final id = '${item['id']}';
      final state = _physicsState.putIfAbsent(id, () => <double>[0, 0]);
      var target = 0.0;
      var weight = 0.0;
      for (final input in asJsonList(item['inputs'])) {
        final map = asJsonMap(input);
        final param = '${map['param']}';
        final w = asDouble(map['weight'], 1);
        target += (_params[param] ?? 0) * w;
        weight += w.abs();
      }
      if (weight > 0) target /= weight;
      final pendulum = asJsonMap(item['pendulum']);
      final stiffness = asDouble(pendulum['stiffness'], 40);
      final damping = asDouble(pendulum['damping'], 6);
      state[1] += ((target - state[0]) * stiffness - state[1] * damping) * dt;
      state[0] += state[1] * dt;
      for (final output in asJsonList(item['outputs'])) {
        final map = asJsonMap(output);
        final param = '${map['param']}';
        final w = asDouble(map['weight'], 1);
        if (param.isNotEmpty) _params[param] = state[0] * w;
      }
    }
  }

  Map<String, Object?> _physicsSet(Map<String, Object?> p) {
    final requested = p['enabled'];
    if (requested != null) {
      physicsEnabled = asBool(requested);
    }
    final id = '${p['id'] ?? ''}';
    if (id.isNotEmpty) {
      document.applyCommand(<String, Object?>{
        'op': 'physics.set_property',
        'id': id,
        'path': p['path'],
        'value': p['value'],
      });
    }
    return <String, Object?>{
      'enabled': physicsEnabled,
      'settings': document.physics,
    };
  }

  // ---------------------------------------------------------------------------
  // 动作 / 表情
  // ---------------------------------------------------------------------------

  Map<String, Object?>? _findMotion(String name) {
    for (final motion in document.motions) {
      final item = asJsonMap(motion);
      if ('${item['name']}' == name) return item;
    }
    return null;
  }

  bool _motionLoopFor(String name) =>
      asBool(asJsonMap(_findMotion(name))['loop']);

  void _applyExpression(String? name) {
    if (name == null) return;
    for (final expression in document.expressions) {
      final item = asJsonMap(expression);
      if ('${item['name']}' != name) continue;
      for (final entry in asJsonMap(item['params']).entries) {
        _params[entry.key] = asDouble(entry.value);
      }
    }
  }

  Map<String, Object?> _recordEnd(Map<String, Object?> p) {
    final recording = _recording;
    _recording = null;
    if (recording == null) {
      throw const AmException('NO_RECORDING', 'no recording in progress');
    }
    final fps = asInt(recording['fps'], 60);
    final duration = math.max(
      asDouble(p['duration'], _clock - asDouble(recording['start'])),
      1 / fps,
    );
    final name = '${p['name'] ?? recording['name']}';
    final curves = <String, Map<String, Object?>>{};
    for (final write in _recordedWrites) {
      final param = '${write['param']}';
      if (param.isEmpty) continue;
      final curve = curves.putIfAbsent(
        param,
        () => <String, Object?>{'param': param, 'keys': <Object?>[]},
      );
      final keys = curve['keys']! as List<Object?>;
      final time = asDouble(write['time']).clamp(0.0, duration);
      final value = asDouble(write['value']);
      final existing = keys.indexWhere(
        (e) => asDouble(asJsonMap(e)['time']) == time,
      );
      final key = <String, Object?>{
        'time': time,
        'value': value,
        'interp': 'linear',
        'in_tangent': 0.0,
        'out_tangent': 0.0,
      };
      if (existing >= 0) {
        keys[existing] = key;
      } else {
        keys.add(key);
      }
    }
    for (final curve in curves.values) {
      final keys = curve['keys']! as List<Object?>;
      keys.sort(
        (a, b) => asDouble(
          asJsonMap(a)['time'],
        ).compareTo(asDouble(asJsonMap(b)['time'])),
      );
    }
    document.applyCommand(<String, Object?>{
      'op': 'motion.create',
      'name': name,
      'duration': duration,
      'loop': asBool(p['loop'], false),
    });
    final motion = _findMotion(name);
    if (motion != null) {
      motion['curves'] = curves.values.toList();
    }
    return <String, Object?>{
      'name': name,
      'duration': duration,
      'curves': curves.length,
      'samples': _recordedWrites.length,
    };
  }

  // ---------------------------------------------------------------------------
  // 工程
  // ---------------------------------------------------------------------------

  Future<Map<String, Object?>> _projectCreate(Map<String, Object?> p) async {
    final dir = '${p['dir'] ?? ''}';
    if (dir.isEmpty) {
      throw const AmException('BAD_COMMAND', 'project.create needs dir');
    }
    // 与契约适配器一致：不覆盖已有工程（不可逆的数据丢失）。
    if (await AmprojWriter.isProjectDirectory(dir)) {
      throw const AmException(
        'PROJECT_EXISTS',
        'target directory already contains a project',
      );
    }
    final info = AmprojWriter.freshInfo(
      name: '${p['name'] ?? 'project'}',
      displayName: '${p['display_name'] ?? ''}',
      author: '${p['author'] ?? ''}',
      description: '${p['description'] ?? ''}',
    );
    await AmprojWriter.createDirectory(dir, info: info);
    projectDir = dir;
    // 新工程默认带一份空模型结构。
    await AmprojWriter.writeModel(dir, document.data);
    await _writeSpecLayers(dir);
    return <String, Object?>{
      'path': dir,
      'name': info.name,
      'display_name': info.displayName,
    };
  }

  Future<Map<String, Object?>> _projectOpen(Map<String, Object?> p) async {
    final path = '${p['path'] ?? p['source'] ?? ''}';
    if (path.isEmpty) {
      throw const AmException('BAD_COMMAND', 'project.open needs path');
    }
    final project = await AmprojProject.open(path);
    _loadProject(project);
    projectDir = project.source.isArchive ? null : project.source.label;
    return <String, Object?>{
      'path': project.source.label,
      'name': project.info.name,
      'display_name': project.displayName,
      'is_archive': project.source.isArchive,
      'files': project.files.length,
      'revision': document.revision,
    };
  }

  void _loadProject(AmprojProject project) {
    final loaded = project.toLocalDocument();
    document.data = loaded.data;
    // 描述层的独立文件合并回文档。
    final motions = <Object?>[];
    final expressions = <Object?>[];
    for (final entry in project.specTexts.entries) {
      if (entry.key.startsWith('spec/motions/') &&
          entry.key.endsWith('.json')) {
        motions.add(asJsonMap(jsonDecode(entry.value)));
      } else if (entry.key.startsWith('spec/expressions/') &&
          entry.key.endsWith('.json')) {
        expressions.add(asJsonMap(jsonDecode(entry.value)));
      }
    }
    if (motions.isNotEmpty) document.data['motions'] = motions;
    if (expressions.isNotEmpty) document.data['expressions'] = expressions;
    final physics = project.specJson('spec/physics.json');
    if (physics != null && physics.isNotEmpty) {
      document.data['physics'] = asJsonList(physics['settings']);
    }
    final pose = project.specJson('spec/pose.json');
    if (pose != null && pose.isNotEmpty) {
      document.data['pose'] = asJsonList(pose['pose']);
    }
    final settings = project.specJson('spec/model.settings.json');
    if (settings != null && settings.isNotEmpty) {
      document.data['settings'] = settings;
    }
    final config = project.specJson('spec/config.json');
    if (config != null && config.isNotEmpty) {
      document.data['config'] = config;
    }
    document.applyDrawOrder();
    _runtime.clear();
    _params = defaultParams();
    _emit('project_opened', <String, Object?>{
      'name': project.info.name,
      'path': project.source.label,
    });
  }

  Future<Map<String, Object?>> _projectSave(Map<String, Object?> p) async {
    final saveAs = p['save_as'] == null ? null : '${p['save_as']}';
    if (saveAs != null && saveAs.isNotEmpty) {
      await AmprojWriter.createDirectory(
        saveAs,
        info: AmprojWriter.freshInfo(name: _nameFromPath(saveAs)),
      );
      projectDir = saveAs;
    }
    final dir = projectDir;
    if (dir == null) {
      throw const AmException(
        'PROJECT_NOT_OPEN',
        'no directory-mode project is open; use save_as',
      );
    }
    document.applyDrawOrder();
    await AmprojWriter.writeModel(dir, _modelLayer());
    await _writeSpecLayers(dir);
    final existing = await AmprojProject.open(dir);
    final info = existing.info.copyWith(
      lastUpdateTime: AmprojWriter.nowSeconds(),
      name: existing.info.name,
    );
    await AmprojWriter.writeInfo(dir, info);
    await AmprojWriter.rebuildRegistry(
      dir,
      timestampSign: existing.registry.timestampSign,
    );
    _emit('project_saved', <String, Object?>{'path': dir});
    return <String, Object?>{
      'path': dir,
      'revision': document.revision,
      'info': info.toJson(),
    };
  }

  String _nameFromPath(String path) {
    final cleaned = path.replaceAll(r'\', '/');
    final name = cleaned.split('/').last.toLowerCase();
    final normalized = name.replaceAll(RegExp('[^a-z0-9_-]'), '_');
    return normalized.isEmpty ? 'project' : normalized;
  }

  /// 模型结构本体（`spec/model.json` 只放结构，列表类另存）。
  Map<String, Object?> _modelLayer() => <String, Object?>{
    'root': document.rootId,
    'nodes': document.nodes,
    'art_path': asJsonList(document.data['art_path']),
    'parameters': document.parameters,
    'atlas': asJsonList(document.data['atlas']),
  };

  Future<void> _writeSpecLayers(String dir) async {
    await AmprojWriter.writeSpecFile(
      dir,
      'spec/config.json',
      AmprojWriter.encodeJson(document.config),
    );
    await AmprojWriter.writeSpecFile(
      dir,
      'spec/physics.json',
      AmprojWriter.encodeJson(<String, Object?>{'settings': document.physics}),
    );
    await AmprojWriter.writeSpecFile(
      dir,
      'spec/pose.json',
      AmprojWriter.encodeJson(<String, Object?>{'pose': document.pose}),
    );
    await AmprojWriter.writeSpecFile(
      dir,
      'spec/model.settings.json',
      AmprojWriter.encodeJson(document.settings),
    );
    for (final motion in document.motions) {
      final name = '${asJsonMap(motion)['name']}';
      if (name.isEmpty) continue;
      await AmprojWriter.writeSpecFile(
        dir,
        'spec/motions/$name.motion.json',
        AmprojWriter.encodeJson(motion),
      );
    }
    for (final expression in document.expressions) {
      final name = '${asJsonMap(expression)['name']}';
      if (name.isEmpty) continue;
      await AmprojWriter.writeSpecFile(
        dir,
        'spec/expressions/$name.exp.json',
        AmprojWriter.encodeJson(expression),
      );
    }
  }

  Future<AmValidationReport> _validateCurrent() async {
    final dir = projectDir;
    if (dir == null) {
      return AmValidationReport(<AmValidationIssue>[
        const AmValidationIssue(
          code: 'PROJECT_NOT_OPEN',
          path: '',
          message: 'no directory-mode project is open',
          severity: 'warning',
        ),
      ]);
    }
    final project = await AmprojProject.open(dir);
    return project.validate();
  }

  Future<Map<String, Object?>> _projectInfo() async {
    final dir = projectDir;
    if (dir == null) {
      return <String, Object?>{
        'name': null,
        'open': false,
        'revision': document.revision,
        'nodes': document.nodes.length,
      };
    }
    final project = await AmprojProject.open(dir);
    return <String, Object?>{
      'open': true,
      'path': dir,
      'info': project.info.toJson(),
      'registry': project.registry.toJson(),
      'config': project.specJson('spec/config.json'),
      'spec_files': project.specTexts.keys.toList(),
      'revision': document.revision,
    };
  }

  Future<Map<String, Object?>> _projectExport(Map<String, Object?> p) async {
    final dir = projectDir;
    if (dir == null) {
      throw const AmException('PROJECT_NOT_OPEN', 'no project is open');
    }
    // 导出前先落盘，保证 .amproj 与编辑内容一致。
    await _projectSave(const <String, Object?>{});
    return AmprojWriter.exportArchive(
      dir,
      outPath: p['out_path'] == null ? null : '${p['out_path']}',
      skipValidation: asBool(p['skip_validation']),
    );
  }

  Future<Map<String, Object?>> _projectImport(Map<String, Object?> p) async {
    final source = '${p['source'] ?? ''}';
    final dest = '${p['dest'] ?? ''}';
    if (source.isEmpty || dest.isEmpty) {
      throw const AmException(
        'BAD_COMMAND',
        'project.import needs source and dest',
      );
    }
    final result = await AmprojWriter.importArchive(source, dest);
    final project = await AmprojProject.open(dest);
    _loadProject(project);
    projectDir = dest;
    return result;
  }

  Map<String, Object?> _stats() {
    var vertices = 0;
    var triangles = 0;
    var drawables = 0;
    var warp = 0;
    var rotation = 0;
    var deformerControlPoints = 0;
    for (final entry in document.nodes.entries) {
      final node = asJsonMap(entry.value);
      switch (AmNodeKind.parse(node['type'])) {
        case AmNodeKind.drawable:
          drawables++;
          final mesh = asJsonMap(node['mesh']);
          vertices += asJsonList(mesh['vertices']).length;
          triangles += asJsonList(mesh['indices']).length ~/ 3;
        case AmNodeKind.warpDeformer:
          warp++;
          deformerControlPoints += asJsonList(node['control_points']).length;
        case AmNodeKind.rotationDeformer:
          rotation++;
          deformerControlPoints++;
        case AmNodeKind.part:
        case AmNodeKind.unknown:
          break;
      }
    }
    final atlas = asJsonList(document.data['atlas']);
    return <String, Object?>{
      'nodes': document.nodes.length,
      'drawables': drawables,
      'vertices': vertices,
      'triangles': triangles,
      'warp_deformers': warp,
      'rotation_deformers': rotation,
      'deformer_control_points': deformerControlPoints,
      'parameters': document.parameters.length,
      'motions': document.motions.length,
      'expressions': document.expressions.length,
      'physics_settings': document.physics.length,
      'textures': atlas.length,
      'atlas_bytes': atlas.length * 0,
      'frame_ms': 16.6,
      'fallback': true,
    };
  }

  /// 供查看器/编辑器导出运行时包使用：当前文档的 JSON。
  Uint8List exportDocumentBytes() =>
      Uint8List.fromList(utf8.encode(document.snapshotJson()));
}
