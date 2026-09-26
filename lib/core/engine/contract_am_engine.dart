/// 契约适配器：把编辑器/查看器的 UI 方法面翻译到引擎真实契约
/// （engine/docs/ffi-contract.md，引擎 0.1.0 / amproj v1）。
///
/// UI 层（controllers/panels）按 tasks.md §3 的方法面调用引擎；
/// 真引擎的方法面是 `project.load` / `doc.command` / `runtime.advance` /
/// `runtime.scene` / `motion.*`。本类负责双向翻译：
///
/// * 打开工程：`project.open` → `project.load`，并解析 spec 层；
/// * 结构编辑：`doc.command` → `doc.command`（形状一致，直接透传）；
/// * 运行时：`runtime.step` → `runtime.advance` + 自动效果在宿主侧模拟；
/// * 场景：`runtime.scene`（引擎 JSON）→ [AmScene]（降级画布直接绘制）。
///
/// 引擎不可用时不走本类 —— [engine_bootstrap.dart] 会降级到
/// `LocalAmEngine`（内置实现，方法面与 UI 完全一致）。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'am_engine.dart';
import 'am_scene_provider.dart';
import 'am_types.dart';
import 'local_eval.dart';

/// 契约适配引擎。
class ContractAmEngine implements AmEngine, AmSceneProvider {
  ContractAmEngine(this._ffi);

  final AmEngine _ffi;

  /// 引擎侧文档状态（`doc.model` 的缓存）。
  Map<String, Object?> _model = <String, Object?>{};
  Map<String, Object?> _specSettings = <String, Object?>{};
  Map<String, Object?> _specConfig = <String, Object?>{};
  List<Object?> _motions = <Object?>[];
  List<Object?> _expressions = <Object?>[];
  List<Object?> _physics = <Object?>[];
  List<Object?> _pose = <Object?>[];
  String? _projectPath;
  String? _projectName;
  String? _displayName;

  // 运行时状态（引擎时钟推进，自动效果由宿主模拟）。
  final Map<String, double> _params = <String, double>{};
  double _clock = 0;
  String? _playingMotion;
  bool _motionPlaying = false;
  double _motionTime = 0;
  String? _expression;
  bool _blinkEnabled = true;
  bool _breathEnabled = true;
  bool _lipsyncEnabled = false;
  double _lipsyncAmplitude = 0;
  double _blinkTimer = 0;
  double _blinkPhase = -1;
  bool _physicsEnabled = true;

  AmViewState _view = const AmViewState();
  List<double> _background = <double>[0, 0, 0, 0];

  final StreamController<AmEvent> _events =
      StreamController<AmEvent>.broadcast();
  bool _disposed = false;

  // ---------------------------------------------------------------------------
  // AmEngine
  // ---------------------------------------------------------------------------

  @override
  AmEngineBackend get backend => AmEngineBackend(
    'ffi',
    'engine.backend.ffi',
    detail: _ffi.capabilities.sdk,
  );

  @override
  AmCapabilities get capabilities => _ffi.capabilities;

  @override
  bool get isAvailable => _ffi.isAvailable && !_disposed;

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
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _ffi.dispose();
    if (!_events.isClosed) await _events.close();
  }

  /// 引擎调用 + 事件转发。
  Future<Map<String, Object?>> _call(
    String method, [
    Map<String, Object?>? params,
  ]) async {
    try {
      return await _ffi.call(method, params);
    } on AmException {
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // UI 方法面 → 引擎方法面
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
      // ----- system -----
      case 'system.version':
        return _call('system.version');
      case 'system.capabilities':
        return <String, Object?>{
          'engine': capabilities.engine,
          'sdk': capabilities.sdk,
          'format': capabilities.format,
          'min_sdk': capabilities.minSdk,
          'methods': capabilities.methods.toList()..sort(),
          'platform': capabilities.platform,
        };

      // ----- project -----
      case 'project.create':
        return _projectCreate(p);
      case 'project.open':
        return _projectOpen(p);
      case 'project.close':
        _projectPath = null;
        return const <String, Object?>{};
      case 'project.save':
        return _projectSave(p);
      case 'project.info':
        return _projectInfo();
      case 'project.validate':
        return _call('project.validate');
      case 'project.export':
        // 真引擎没有包导出：先落盘，包导出由宿主（amproj 层）完成。
        await _projectSave(const <String, Object?>{});
        throw const AmException(
          'UNSUPPORTED',
          'archive export is host-side; use project.save + amproj writer',
        );
      case 'project.import':
        throw const AmException(
          'UNSUPPORTED',
          'archive import is host-side; use project.open on extracted dir',
        );

      // ----- doc -----
      case 'doc.command':
        return _docCommand(p);
      case 'doc.undo':
        return _docUndoRedo('doc.undo');
      case 'doc.redo':
        return _docUndoRedo('doc.redo');
      case 'doc.history':
        return _call('doc.history');
      case 'doc.model':
        return _call('doc.model');
      case 'doc.revision':
        return <String, Object?>{'revision': _revision()};
      case 'doc.query':
        return _docQuery(p);

      // ----- runtime -----
      case 'runtime.set_param':
        final id = '${p['param'] ?? p['id'] ?? ''}';
        return _applyParams(<String, Object?>{id: p['value']});
      case 'runtime.set_params':
        return _applyParams(asJsonMap(p['params']));
      case 'runtime.params':
        return <String, Object?>{'params': _params};
      case 'runtime.step':
        return _step(asDouble(p['dt'], 1 / 60));
      case 'runtime.seek':
        _motionTime = asDouble(p['time']);
        await _call('runtime.set_time', <String, Object?>{
          'time': _motionTime,
        });
        await _syncFromEngine();
        return <String, Object?>{
          'time': _motionTime,
          'params': _params,
          'playing': _motionPlaying,
        };
      case 'runtime.reset':
        await _call('runtime.reset_params');
        _clock = 0;
        _motionPlaying = false;
        _playingMotion = null;
        _motionTime = 0;
        _expression = null;
        await _syncFromEngine();
        return <String, Object?>{'params': _params};
      case 'runtime.play_motion':
        return _playMotion(p);
      case 'runtime.stop_motion':
        await _call('motion.stop');
        _motionPlaying = false;
        return const <String, Object?>{};
      case 'runtime.set_expression':
        return _setExpression(p['name'] == null ? null : '${p['name']}');
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

      // ----- physics -----
      case 'physics.query':
        return <String, Object?>{'settings': _physics};
      case 'physics.set':
        if (p['enabled'] != null) _physicsEnabled = asBool(p['enabled']);
        return <String, Object?>{'enabled': _physicsEnabled};

      // ----- motion（编辑走 doc.command 的 spec 层替换）-----
      case 'motion.load':
        final name = '${p['motion'] ?? ''}';
        return <String, Object?>{'motion': _findMotion(name)};
      case 'motion.record.begin':
      case 'motion.record.writes':
      case 'motion.record.end':
        throw const AmException(
          'UNSUPPORTED',
          'motion recording requires a spec rewrite; not yet bridged',
        );

      // ----- renderer（引擎渲染路径：真实帧留给纹理桥；宿主绘制用场景）-----
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
        await _call('renderer.resize', <String, Object?>{
          'width': _view.canvasWidth.round(),
          'height': _view.canvasHeight.round(),
        });
        return <String, Object?>{
          'width': _view.canvasWidth,
          'height': _view.canvasHeight,
        };
      case 'renderer.destroy':
        return const <String, Object?>{};
      case 'renderer.frame':
        return <String, Object?>{
          'presented': false,
          'revision': _revision(),
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
        return _rendererView(p);
      case 'renderer.pick':
        return _rendererPick(p);
      case 'renderer.measure':
        return <String, Object?>{'points': _measure(p)};

      // ----- diagnostics -----
      case 'diagnostics.stats':
        return _stats();

      default:
        // 其余方法（expression.create 等编辑命令）本类不认识 —— 但它们都
        // 是 `doc.command` 的 op，UI 应该走 doc.command；直接报不支持。
        throw AmException('UNSUPPORTED', 'method not supported: $method');
    }
  }

  // ---------------------------------------------------------------------------
  // 工程
  // ---------------------------------------------------------------------------

  Future<Map<String, Object?>> _projectCreate(Map<String, Object?> p) async {
    // 引擎没有 project.create：宿主写一个空 spec，然后 project.load。
    final dir = '${p['dir'] ?? ''}';
    if (dir.isEmpty) {
      throw const AmException('BAD_COMMAND', 'project.create needs dir');
    }
    throw const AmException(
      'UNSUPPORTED',
      'project scaffolding is host-side; use amproj writer then project.open',
    );
  }

  Future<Map<String, Object?>> _projectOpen(Map<String, Object?> p) async {
    final path = '${p['path'] ?? p['source'] ?? ''}';
    if (path.isEmpty) {
      throw const AmException('BAD_COMMAND', 'project.open needs path');
    }
    final result = await _call('project.load', <String, Object?>{
      'path': path,
    });
    _projectPath = path;
    await _reloadSpec();
    // 引擎的 project.load 不返回名字；从 spec.model.name 取。
    _projectName = '${_model['name'] ?? _specSettings['display_name'] ?? ''}';
    _displayName = _projectName;
    await _syncFromEngine();
    return <String, Object?>{
      'path': path,
      'name': _projectName,
      'display_name': _displayName,
      'is_archive': false,
      'files': asInt(result['nodes']) + asInt(result['parameters']),
      'revision': _revision(),
    };
  }

  /// 拉取 spec 层（motions/expressions/physics/pose/settings/config）。
  Future<void> _reloadSpec() async {
    final spec = await _call('project.spec');
    final model = asJsonMap(spec['model']);
    _model = <String, Object?>{
      ...model,
      // LocalDocument 期望的映射形状。
      'nodes': <String, Object?>{
        for (final raw in asJsonList(model['nodes']))
          if (asJsonMap(raw)['id'] != null)
            '${asJsonMap(raw)['id']}': asJsonMap(raw),
      },
      'parameters': <String, Object?>{
        for (final raw in asJsonList(model['parameters']))
          if (asJsonMap(raw)['id'] != null)
            '${asJsonMap(raw)['id']}': asJsonMap(raw),
      },
      'root': _rootIdFrom(model),
    };
    // 动作归一化：UI 期望 name/loop/curves[].param；引擎给 looping/parameter。
    _motions = <Object?>[
      for (final raw in asJsonList(spec['motions'])) _normalizeMotion(raw),
    ];
    // 表情归一化：UI 期望 name/params；引擎给 id/parameters[]。
    _expressions = <Object?>[
      for (final raw in asJsonList(spec['expressions']))
        _normalizeExpression(raw),
    ];
    final physicsSpec = asJsonMap(spec['physics']);
    _physics = asJsonList(physicsSpec['settings']);
    final poseSpec = asJsonMap(spec['pose']);
    _pose = asJsonList(poseSpec['groups']);
    _specSettings = asJsonMap(spec['settings']);
    _specConfig = asJsonMap(spec['config']);
  }

  Map<String, Object?> _normalizeMotion(Object? raw) {
    final motion = asJsonMap(raw);
    return <String, Object?>{
      'id': '${motion['id'] ?? motion['name']}',
      'name': '${motion['name'] ?? motion['id'] ?? 'motion'}',
      'duration': asDouble(motion['duration'], 0),
      'loop': asBool(motion['looping'], true),
      'fps': asDouble(motion['fps'], 60),
      'fade_in': asDouble(motion['fade_in'], 0),
      'fade_out': asDouble(motion['fade_out'], 0),
      'curves': <Object?>[
        for (final rawCurve in asJsonList(motion['curves']))
          <String, Object?>{
            'param': '${asJsonMap(rawCurve)['parameter'] ?? asJsonMap(rawCurve)['param'] ?? ''}',
            'keys': <Object?>[
              for (final rawKey in asJsonList(asJsonMap(rawCurve)['keys']))
                <String, Object?>{
                  'time': asDouble(asJsonMap(rawKey)['time']),
                  'value': asDouble(asJsonMap(rawKey)['value']),
                  'interp': '${asJsonMap(rawKey)['interp'] ?? 'linear'}',
                  'in_tangent': asDouble(asJsonMap(rawKey)['in_tangent'], 0),
                  'out_tangent': asDouble(asJsonMap(rawKey)['out_tangent'], 0),
                },
            ],
          },
      ],
    };
  }

  Map<String, Object?> _normalizeExpression(Object? raw) {
    final expression = asJsonMap(raw);
    final parameters = <String, Object?>{};
    for (final rawEntry in asJsonList(expression['parameters'])) {
      final entry = asJsonMap(rawEntry);
      parameters['${entry['parameter'] ?? entry['param']}'] = asDouble(
        entry['value'],
      );
    }
    return <String, Object?>{
      'id': '${expression['id'] ?? expression['name']}',
      'name': '${expression['name'] ?? expression['id'] ?? 'expression'}',
      'fade_in': asDouble(expression['fade_in'], 0),
      'fade_out': asDouble(expression['fade_out'], 0),
      'params': parameters,
    };
  }

  String? _rootIdFrom(Map<String, Object?> model) {
    // 引擎的节点用 parent 指针表达树；root 是没有 parent 的 part。
    for (final raw in asJsonList(model['nodes'])) {
      final node = asJsonMap(raw);
      if (node['parent'] == null) return '${node['id']}';
    }
    return null;
  }

  Future<void> _syncFromEngine() async {
    final params = await _call('runtime.params');
    _params
      ..clear()
      ..addAll({
        for (final entry in asJsonMap(params['params']).entries)
          entry.key: asDouble(entry.value),
      });
    final state = await _call('runtime.state');
    _clock = asDouble(state['time']);
    _motionPlaying = asBool(state['paused']) == false &&
        '${state['motion'] ?? ''}'.isNotEmpty;
    _playingMotion = '${state['motion'] ?? ''}'.isEmpty
        ? null
        : '${state['motion']}';
  }

  Future<Map<String, Object?>> _projectSave(Map<String, Object?> p) async {
    final saveAs = p['save_as'] == null ? null : '${p['save_as']}';
    final target = (saveAs == null || saveAs.isEmpty) ? _projectPath : saveAs;
    if (target == null) {
      throw const AmException(
        'PROJECT_NOT_OPEN',
        'no directory-mode project is open; use save_as',
      );
    }
    final result = await _call('project.save', <String, Object?>{
      'path': target,
    });
    if (saveAs != null && saveAs.isNotEmpty) _projectPath = saveAs;
    return <String, Object?>{
      'path': '${result['path'] ?? target}',
      'revision': _revision(),
    };
  }

  Future<Map<String, Object?>> _projectInfo() async {
    return <String, Object?>{
      'open': _projectPath != null,
      'path': _projectPath,
      'name': _projectName,
      'revision': _revision(),
      'spec_files': const <Object?>[],
    };
  }

  // ---------------------------------------------------------------------------
  // doc
  // ---------------------------------------------------------------------------

  int _revision() {
    // 引擎在 doc.history 里有 revision。
    return _cachedRevision;
  }

  int _cachedRevision = 0;

  Future<Map<String, Object?>> _docCommand(Map<String, Object?> p) async {
    final command = asJsonMap(p['command'] ?? p);
    final result = await _call('doc.command', <String, Object?>{
      'command': command,
    });
    _cachedRevision = asInt(result['revision'], _cachedRevision + 1);
    // 结构变化后刷新 spec 缓存（motions/expressions 等也可能被改）。
    await _reloadSpec();
    return <String, Object?>{'revision': _cachedRevision};
  }

  /// undo/redo 会改变模型结构，必须像 doc.command 一样刷新 spec 缓存，
  /// 否则后续 doc.query hierarchy 仍返回旧的节点表。
  Future<Map<String, Object?>> _docUndoRedo(String method) async {
    final result = await _call(method);
    _cachedRevision = asInt(result['revision'], _cachedRevision);
    await _reloadSpec();
    return <String, Object?>{
      ...result,
      'revision': _cachedRevision,
    };
  }

  Map<String, Object?> _docQuery(Map<String, Object?> p) {
    final path = '${p['path'] ?? ''}';
    switch (path) {
      case 'hierarchy':
        return <String, Object?>{
          'revision': _cachedRevision,
          'root': _model['root'],
          'nodes': _model['nodes'],
        };
      case 'node':
        final id = '${p['id'] ?? ''}';
        final nodes = asJsonMap(_model['nodes']);
        return <String, Object?>{
          'revision': _cachedRevision,
          'node': nodes[id],
        };
      case 'parameters':
        return <String, Object?>{
          'revision': _cachedRevision,
          'parameters': _model['parameters'],
        };
      case 'keyforms':
        final id = '${p['id'] ?? ''}';
        final node = asJsonMap(asJsonMap(_model['nodes'])[id]);
        return <String, Object?>{
          'revision': _cachedRevision,
          'keyforms': asJsonMap(node['keyforms']),
        };
      case 'mesh':
        final id = '${p['id'] ?? ''}';
        final node = asJsonMap(asJsonMap(_model['nodes'])[id]);
        return <String, Object?>{
          'revision': _cachedRevision,
          'mesh': asJsonMap(node['drawable'])['mesh'],
        };
      case 'physics':
        return <String, Object?>{'physics': _physics};
      case 'motions':
        return <String, Object?>{'motions': _motions};
      case 'expressions':
        return <String, Object?>{'expressions': _expressions};
      case 'settings':
        return <String, Object?>{'settings': _specSettings};
      case 'config':
        return <String, Object?>{'config': _specConfig};
      case 'pose':
        return <String, Object?>{'pose': _pose};
      case 'atlas':
        return <String, Object?>{
          'atlas': asJsonList(asJsonMap(_model)['textures']),
        };
      default:
        throw AmException('UNKNOWN_QUERY', 'unknown doc.query path: $path');
    }
  }

  // ---------------------------------------------------------------------------
  // 运行时
  // ---------------------------------------------------------------------------

  Future<Map<String, Object?>> _applyParams(
    Map<String, Object?> values,
  ) async {
    for (final entry in values.entries) {
      if (entry.key.isEmpty) continue;
      final result = await _call('runtime.set_param', <String, Object?>{
        'id': entry.key,
        'value': asDouble(entry.value),
      });
      _params['${result['id'] ?? entry.key}'] = asDouble(result['value']);
    }
    unawaited(refreshScene());
    return <String, Object?>{'params': _params};
  }

  Future<Map<String, Object?>> _step(double dt) async {
    final clamped = dt.clamp(0.0, 0.25);
    _clock += clamped;

    // 引擎推进（动作 + 物理 + 时钟）。
    final result = await _call('runtime.advance', <String, Object?>{
      'dt': clamped,
    });
    _clock = asDouble(result['time'], _clock);
    await _syncFromEngine();

    // 自动效果：引擎不内置，宿主模拟（与 LocalAmEngine 行为一致）。
    await _applyAutoEffects(clamped);

    // 场景缓存：供降级画布同步 buildScene。
    await refreshScene();
    return <String, Object?>{
      'time': _clock,
      'params': _params,
      'playing': _motionPlaying,
      'revision': _cachedRevision,
    };
  }

  Future<void> _applyAutoEffects(double dt) async {
    if (_blinkEnabled) {
      final interval = asDouble(
        asJsonMap(_specSettings['blink'])['interval'],
        4,
      );
      if (_blinkPhase < 0) {
        _blinkTimer += dt;
        if (_blinkTimer >= math.max(0.6, interval)) {
          _blinkTimer = 0;
          _blinkPhase = 0;
        }
      } else {
        _blinkPhase += dt;
        const duration = 0.18;
        if (_blinkPhase >= duration) {
          _blinkPhase = -1;
          await _applyParamByName(<String>['EyeOpen', 'eye_open'], 1.0);
        } else {
          final t = _blinkPhase / duration;
          final openness = (math.cos(t * math.pi * 2) + 1) / 2;
          await _applyParamByName(<String>['EyeOpen', 'eye_open'], openness);
        }
      }
    }
    if (_breathEnabled) {
      final period = asDouble(
        asJsonMap(_specSettings['breath'])['period'],
        3.5,
      );
      final value = math.sin(_clock / math.max(0.5, period) * math.pi * 2);
      await _applyParamByName(<String>['Breath', 'breath'], value);
    }
    if (_lipsyncEnabled) {
      await _applyParamByName(<String>['MouthOpen', 'mouth_open'],
          _lipsyncAmplitude);
    }
  }

  Future<void> _applyParamByName(List<String> names, double value) async {
    final parameters = asJsonMap(_model['parameters']);
    for (final entry in parameters.entries) {
      final name = '${asJsonMap(entry.value)['name']}';
      if (names.contains(name)) {
        await _applyParams(<String, Object?>{entry.key: value});
        return;
      }
    }
  }

  Future<Map<String, Object?>> _playMotion(Map<String, Object?> p) async {
    final name = '${p['motion'] ?? p['name'] ?? ''}';
    final motion = _findMotion(name);
    if (motion == null) {
      throw AmException('BAD_COMMAND', 'motion not found: $name');
    }
    await _call('motion.play', <String, Object?>{
      'id': '${motion['id'] ?? motion['name']}',
      if (p['loop'] != null) 'looping': asBool(p['loop']),
      if (p['speed'] != null) 'speed': asDouble(p['speed']),
    });
    _playingMotion = name;
    _motionPlaying = true;
    _motionTime = 0;
    return <String, Object?>{'motion': name, 'loop': asBool(p['loop'])};
  }

  Map<String, Object?>? _findMotion(String name) {
    for (final motion in _motions) {
      final item = asJsonMap(motion);
      if ('${item['name']}' == name) return item;
    }
    return null;
  }

  Future<Map<String, Object?>> _setExpression(String? name) async {
    _expression = name;
    if (name == null) {
      await _call('runtime.reset_params');
      await _syncFromEngine();
      return <String, Object?>{'expression': null, 'params': _params};
    }
    for (final expression in _expressions) {
      final item = asJsonMap(expression);
      if ('${item['name']}' != name) continue;
      await _call('expression.set', <String, Object?>{
        'id': '${item['id'] ?? item['name']}',
        'weight': 1.0,
      });
      await _syncFromEngine();
      break;
    }
    return <String, Object?>{'expression': name, 'params': _params};
  }

  // ---------------------------------------------------------------------------
  // renderer
  // ---------------------------------------------------------------------------

  Map<String, Object?> _rendererView(Map<String, Object?> p) {
    Offset? pan;
    final rawPan = asJsonList(p['pan']);
    if (rawPan.length == 2) {
      pan = Offset(asDouble(rawPan[0]), asDouble(rawPan[1]));
    }
    _view = _view.copyWith(
      pan: pan,
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
    // 同步给引擎渲染器（失败不影响宿主绘制）。
    unawaited(
      _call('renderer.set_view', <String, Object?>{
        if (pan != null) 'center': <Object?>[pan.dx, pan.dy],
        if (p['zoom'] != null) 'zoom': asDouble(p['zoom'], 1),
      }).catchError((Object _) => const <String, Object?>{}),
    );
    return <String, Object?>{'view': _view.toJson()};
  }

  Map<String, Object?> _rendererPick(Map<String, Object?> p) {
    final space = '${p['space'] ?? 'screen'}';
    final offset = Offset(asDouble(p['x']), asDouble(p['y']));
    final world = space == 'world' ? offset : _view.screenToWorld(offset);
    final id = hitTestScene(buildScene(), world);
    return <String, Object?>{'id': id, 'node': id};
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
  // AmSceneProvider（降级画布）：把引擎 runtime.scene 转成 AmScene
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

  AmScene? _sceneCache;

  @override
  AmScene buildScene({
    bool includeHidden = false,
    List<int> selectedVertices = const <int>[],
    String? selectedNode,
  }) {
    return _sceneFromJson();
  }

  @override
  AmScene buildSceneWith({
    required Map<String, double> params,
    bool includeHidden = false,
    String? selectedNode,
  }) {
    // 引擎路径不支持"虚拟参数求值"：直接返回当前场景（预览用）。
    return _sceneFromJson();
  }

  AmScene _sceneFromJson() {
    // runtime.scene 是同步求值需要 async —— 用最近一次缓存，
    // 由 [refreshScene] 在 runtime 调用后异步更新。
    final cached = _sceneCache;
    if (cached != null) return cached;
    return AmScene(
      drawables: const <AmSceneDrawable>[],
      deformers: const <AmSceneDeformer>[],
      parts: const <String, List<Offset>>{},
      bounds: const <double>[0, 0, 0, 0],
    );
  }

  /// 异步刷新场景缓存（在 runtime.step / set_param 之后调用）。
  Future<void> refreshScene() async {
    final scene = await _call('runtime.scene');
    _sceneCache = _parseScene(scene);
  }

  AmScene _parseScene(Map<String, Object?> scene) {
    final canvas = asJsonMap(scene['canvas']);
    final drawables = <AmSceneDrawable>[];
    for (final raw in asJsonList(scene['drawables'])) {
      final d = asJsonMap(raw);
      if (!asBool(d['visible'], true) ) continue;
      drawables.add(
        AmSceneDrawable(
          id: '${d['node'] ?? d['name']}',
          name: '${d['name'] ?? ''}',
          vertices: <Offset>[
            for (final v in asJsonList(d['vertices']))
              Offset(
                asDouble(asJsonMap(v)['x']),
                asDouble(asJsonMap(v)['y']),
              ),
          ],
          uvs: <Offset>[
            for (final v in asJsonList(d['uvs']))
              Offset(asDouble(asJsonMap(v)['x']), asDouble(asJsonMap(v)['y'])),
          ],
          indices: <int>[for (final i in asJsonList(d['indices'])) asInt(i)],
          opacity: asDouble(d['opacity'], 1),
          blend: AmBlendMode.parse('${d['blend'] ?? 'normal'}'),
          texture: null,
          drawOrder: asInt(d['draw_order']),
          visible: true,
          locked: false,
          mask: <String>[
            for (final m in asJsonList(d['masks'])) '$m',
          ],
          selectedVertexIds: const <int>[],
        ),
      );
    }
    final parts = <String, List<Offset>>{};
    final deformers = <AmSceneDeformer>[];
    final nodes = asJsonMap(scene['nodes']);
    for (final entry in nodes.entries) {
      final node = asJsonMap(entry.value);
      final kind = '${node['kind'] ?? 'part'}';
      final affine = asJsonMap(node['world_affine']);
      final tx = asDouble(affine['tx']);
      final ty = asDouble(affine['ty']);
      final a = asDouble(affine['a'], 1);
      final b = asDouble(affine['b']);
      final c = asDouble(affine['c']);
      final dd = asDouble(affine['d'], 1);
      final box = <Offset>[
        Offset(tx, ty),
        Offset(tx + a * 100, ty + b * 100),
        Offset(tx + a * 100 + c * 100, ty + b * 100 + dd * 100),
        Offset(tx + c * 100, ty + dd * 100),
      ];
      if (kind == 'drawable' || kind == 'part') {
        parts[entry.key] = box;
      } else {
        deformers.add(
          AmSceneDeformer(
            id: entry.key,
            name: '${node['name'] ?? ''}',
            kind: kind == 'warp_deformer'
                ? AmNodeKind.warpDeformer
                : AmNodeKind.rotationDeformer,
            controlPoints: const <Offset>[],
            pivot: Offset(tx, ty),
            angle: 0,
            scaleX: 1,
            scaleY: 1,
            rows: 0,
            cols: 0,
            visible: asBool(node['visible'], true),
            locked: false,
          ),
        );
      }
    }
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (final drawable in drawables) {
      for (final v in drawable.vertices) {
        minX = math.min(minX, v.dx);
        minY = math.min(minY, v.dy);
        maxX = math.max(maxX, v.dx);
        maxY = math.max(maxY, v.dy);
      }
    }
    if (drawables.isEmpty) {
      return AmScene(
        drawables: drawables,
        deformers: deformers,
        parts: parts,
        bounds: <double>[
          0,
          0,
          asDouble(canvas['width'], 1280),
          asDouble(canvas['height'], 720),
        ],
      );
    }
    return AmScene(
      drawables: drawables,
      deformers: deformers,
      parts: parts,
      bounds: <double>[minX, minY, maxX, maxY],
    );
  }

  // ---------------------------------------------------------------------------
  // stats
  // ---------------------------------------------------------------------------

  Map<String, Object?> _stats() {
    final nodes = asJsonMap(_model['nodes']);
    var drawables = 0;
    var vertices = 0;
    for (final entry in nodes.entries) {
      final node = asJsonMap(entry.value);
      final kind = '${node['kind'] ?? node['type'] ?? ''}';
      if (kind == 'drawable') {
        drawables++;
        final mesh = asJsonMap(asJsonMap(node['drawable'])['mesh']);
        vertices += asJsonList(mesh['vertices']).length;
      }
    }
    return <String, Object?>{
      'nodes': nodes.length,
      'drawables': drawables,
      'vertices': vertices,
      'parameters': asJsonMap(_model['parameters']).length,
      'motions': _motions.length,
      'expressions': _expressions.length,
      'physics_settings': _physics.length,
      'textures': asJsonList(_model['textures']).length,
      'frame': _clock,
      'fallback': false,
    };
  }
}
