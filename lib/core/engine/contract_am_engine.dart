/// 契约适配器：把编辑器/查看器的 UI 方法面翻译到引擎真实契约
/// （engine/docs/ffi-contract.md，引擎 0.1.0 / amproj v1）。
///
/// UI 层（controllers/panels）按 tasks.md §3 的方法面调用引擎；
/// 真引擎的方法面是 `project.load` / `doc.command` / `runtime.advance` /
/// `runtime.scene` / `motion.*`。本类负责双向翻译：
///
/// * 打开工程：`project.open` → `project.load` + `project.spec`，并解析描述层；
/// * 文档编辑：**影子文档**（[LocalDocument]）持有编辑真值，`doc.command`
///   先在影子上生效，再经 [hostDocToEngineSpec] 投影成引擎 `Spec` 用
///   `project.set_spec` 一次性推给引擎求值；
/// * 运行时：`runtime.step` → `runtime.advance` + 自动效果在宿主侧模拟；
/// * 场景：`runtime.scene`（引擎 JSON）→ [AmScene]（降级画布直接绘制）。
///
/// ## 为什么编辑不能直接透传
///
/// 引擎 `doc.command` 的 `op` 是**下划线**形式，而且只覆盖模型结构
/// （`node_create` / `mesh_set` / `keyform_record` / `parameter_add`…）；
/// 物理、动作、表情、姿势、设置**根本没有编辑命令**。UI 用的是点号 op
/// （`physics.add_setting` / `expression.create` / `settings.set`…），
/// 透传只会得到「命令无法解析」。所以：
///
/// * 编辑能力由影子文档提供（它已经实现全部 55 个宿主 op、撤销重做、绘制顺序）；
/// * 影子文档投影成 `Spec` 交给引擎，引擎负责求值、命中测试、动作播放；
/// * 宿主文档整体挂在 `spec/config.json` 的 `__host.doc` 上（`ProjectConfig`
///   是 `#[serde(flatten)]`，未知键原样往返），因此 `bounds` / `pendulum` /
///   `in_tangent` 这类引擎无法表达的信息不会在落盘时丢失。
///
/// 代价：`project.set_spec` 会重建引擎的 `Document`（撤销栈清空、时钟/参数/
/// 表情/物理归零），所以**撤销重做由影子文档负责**，每次推送后本类会把
/// 运行时状态重新压回引擎（见 [_restoreRuntime]）。
///
/// 引擎不可用时不走本类 —— [engine_bootstrap.dart] 会降级到
/// `LocalAmEngine`（内置方法面与 UI 完全一致）。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../project/amproj_reader.dart';
import '../project/amproj_writer.dart';
import 'am_engine.dart';
import 'am_scene_provider.dart';
import 'am_types.dart';
import 'engine_spec_codec.dart';
import 'local_document.dart';
import 'local_eval.dart';

/// 契约适配引擎。
class ContractAmEngine implements AmEngine, AmSceneProvider {
  ContractAmEngine(this._ffi);

  final AmEngine _ffi;

  /// 影子文档：编辑真值。
  ///
  /// 引擎没有物理/动作/表情/姿势/设置的编辑命令，宿主 op 又是点号形式，
  /// 所以编辑先在影子上落地（它实现了全部 55 个宿主 op + 撤销重做 + 绘制
  /// 顺序），再整体投影成 `Spec` 推给引擎求值。
  final LocalDocument _shadow = LocalDocument();

  /// 推送 spec 的串行链尾（见 [_pushSpec]）。
  Future<void> _pushChain = Future<void>.value();

  /// 宿主文档本体（`spec/config.json` 里 `__host.doc` 的那份）。
  Map<String, Object?> get _doc => _shadow.data;

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
        // 引擎侧的撤销栈每推送一次 `set_spec` 就被清空，只有影子文档的
        // 历史是连续的 —— UI 的撤销/重做必须读它。
        return <String, Object?>{
          'entries': _shadow.historyLabels,
          'can_undo': _shadow.canUndo,
          'can_redo': _shadow.canRedo,
          'revision': _cachedRevision,
          'dirty': false,
        };
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
        await _call('runtime.set_time', <String, Object?>{'time': _motionTime});
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
        return <String, Object?>{'settings': asJsonList(_doc['physics'])};
      case 'physics.set':
        if (p['enabled'] != null) _physicsEnabled = asBool(p['enabled']);
        return <String, Object?>{'enabled': _physicsEnabled};

      // ----- motion（编辑走 doc.command：物理/动作/表情都在影子文档里）-----
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

  /// 新建工程。
  ///
  /// 引擎的方法面里**没有** `project.create`（`am-format` 有 `Project::create`，
  /// 但 `am_call` 没暴露它），所以：
  ///
  /// 1. 宿主先落 `info.json` / `registry.json` / `spec/` —— 引擎的
  ///    `project.save` 在目标目录已存在时会走 `Project::open`，而它要求
  ///    `info.json` + `registry.json`；
  /// 2. 影子文档重置为默认空工程（带一个根部件，与内置实现一致）；
  /// 3. `project.set_spec` 把投影后的 spec 交给引擎；
  /// 4. `project.save` 把 spec 落盘（含 `spec/model.json`）。
  ///
  /// UI 侧只需照常调 `project.create`，内置实现与真引擎两条路径行为一致。
  Future<Map<String, Object?>> _projectCreate(Map<String, Object?> p) async {
    final dir = '${p['dir'] ?? ''}';
    if (dir.isEmpty) {
      throw const AmException('BAD_COMMAND', 'project.create needs dir');
    }
    final name = '${p['name'] ?? ''}';
    // 目录里已经有工程就拒绝：下面会覆盖 info.json / registry.json / spec/，
    // 那是不可逆的数据丢失（引擎的 Project::create 同样拒绝非空目录）。
    if (await AmprojWriter.isProjectDirectory(dir)) {
      throw const AmException(
        'PROJECT_EXISTS',
        'target directory already contains a project',
      );
    }
    final info = AmprojWriter.freshInfo(
      name: name,
      displayName: '${p['display_name'] ?? ''}',
      author: '${p['author'] ?? ''}',
      description: '${p['description'] ?? ''}',
    );
    // 名字非法时 AmprojWriter 抛 NAME_INVALID，与内置实现一致。
    await AmprojWriter.createDirectory(dir, info: info);
    // 影子文档重置为空工程（与内置实现同一份默认文档）。
    _shadow.data = defaultAnimaDocument();
    _shadow.applyDrawOrder();
    _cachedRevision = 0;
    _projectPath = dir;
    _projectName = name;
    // 引擎的 project.load/save 都不回传 display_name，直接用刚写下的 info。
    _displayName = info.displayName;
    _doc['config'] = <String, Object?>{
      ...asJsonMap(_doc['config']),
      'project': <String, Object?>{
        'name': name,
        'display_name': info.displayName,
        'author': info.author,
        'version': '${info.version}',
      },
    };
    // 先把 spec 交给引擎（否则 project.save 会按旧 spec 落盘），再落盘。
    await _pushSpec();
    await _call('project.save', <String, Object?>{'path': dir});
    await _syncFromEngine();
    return <String, Object?>{
      'path': dir,
      'name': name,
      'display_name': _displayName,
      'is_archive': false,
      'files': 0,
      'revision': _revision(),
    };
  }

  /// 打开工程。
  ///
  /// `project.load` 让引擎装载 spec（校验、求值都由它负责），随后
  /// `project.spec` 把描述层取回来还原影子文档。宿主扩展通道
  /// （`config.__host.doc`）存在时直接用原件，保证引擎表达不了的信息不丢。
  Future<Map<String, Object?>> _projectOpen(Map<String, Object?> p) async {
    final path = '${p['path'] ?? p['source'] ?? ''}';
    if (path.isEmpty) {
      throw const AmException('BAD_COMMAND', 'project.open needs path');
    }
    final result = await _call('project.load', <String, Object?>{'path': path});
    _projectPath = path;
    // 目录模式工程的 info.json 里有 display_name，引擎不返回它。
    String? displayName;
    try {
      final project = await AmprojProject.open(path);
      displayName = project.displayName;
    } on Object {
      // 非 amproj 目录（引擎原生工程）没有 info.json，不是错误。
    }
    await _adoptSpec();
    // 引擎的 project.load 不返回名字；从宿主文档的 config 里取。
    final projectSection = asJsonMap(asJsonMap(_doc['config'])['project']);
    final loadedName = '${projectSection['name'] ?? ''}';
    _projectName = loadedName.isNotEmpty
        ? loadedName
        : '${_doc['project_name'] ?? ''}';
    _displayName = displayName ?? _projectName;
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

  /// 从引擎取回描述层并重建影子文档。
  Future<void> _adoptSpec() async {
    final spec = await _call('project.spec');
    _shadow.data = hostDocFromSpec(spec, projectName: _projectName);
    _shadow.applyDrawOrder();
    _cachedRevision = 0;
  }

  /// 把影子文档投影成引擎 `Spec` 并整体替换。
  ///
  /// `project.set_spec` 会重建引擎的 `Document`：撤销栈、时钟、动作播放、
  /// 表情全部归零（参数值会保留，见 [_restoreRuntime]）。因此推送之后必须
  /// 调用 [_restoreRuntime]。
  ///
  /// 串行化：并发的推送会互相覆盖（都是「整份替换」），所以后到的推送等前
  /// 一个结束再跑 —— 绝不静默丢掉一次编辑。
  Future<void> _pushSpec() {
    final previous = _pushChain;
    final completer = Completer<void>();
    _pushChain = completer.future;
    return previous.then((_) async {
      try {
        await _call('project.set_spec', <String, Object?>{
          'spec': hostDocToEngineSpec(
            _doc,
            projectName: _projectName ?? '${_doc['name'] ?? 'model'}',
          ),
        });
      } finally {
        completer.complete();
      }
    });
  }

  /// 推送 spec 后恢复运行时状态。
  ///
  /// `project.set_spec` 会**保留**存活参数的值（`ParamStore::sync_with_model`
  /// 保留旧值、补默认值、按范围钳制），所以参数不必重放 —— 各面板拖动滑块时
  /// 每次都会推送，重放整张参数表会把开销放大成参数个数倍。
  /// 真正被 `set_spec` 清掉的是时钟、动作播放和表情，这里补回来。
  Future<void> _restoreRuntime() async {
    if (_clock != 0) {
      await _call('runtime.set_time', <String, Object?>{'time': _clock});
    }
    final motion = _playingMotion;
    if (motion != null) {
      final found = _findMotion(motion);
      if (found == null) {
        _playingMotion = null;
        _motionPlaying = false;
      } else {
        try {
          await _call('motion.play', <String, Object?>{
            'id': engineMotionId(found),
            'looping': asBool(found['loop']),
            // 引擎支持从指定时间起播，省掉一次单独 seek。
            if (_motionTime > 0) 'from_time': _motionTime,
          });
        } on AmException {
          _playingMotion = null;
          _motionPlaying = false;
        }
      }
    }
    final expression = _expression;
    if (expression != null) {
      final found = _findExpression(expression);
      if (found == null) {
        _expression = null;
      } else {
        try {
          await _call('expression.set', <String, Object?>{
            'id': engineExpressionId(found),
            'weight': 1.0,
          });
        } on AmException {
          _expression = null;
        }
      }
    }
  }

  /// 推送 spec + 恢复运行时 + 刷新场景（每次编辑后的固定动作）。
  Future<void> _commit() async {
    await _pushSpec();
    await _restoreRuntime();
    await _syncFromEngine();
    await refreshScene();
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
    final motion = asJsonMap(state['motion']);
    final motionId = '${motion['id'] ?? ''}';
    _motionPlaying =
        asBool(state['paused']) == false && asBool(motion['playing']);
    // 引擎给的是引擎 id，换回宿主动作名（UI 用名字）。
    _playingMotion = motionId.isEmpty
        ? null
        : _motionNameForEngineId(motionId);
    _motionTime = asDouble(motion['time'], _motionTime);
    final expressionId = '${state['expression'] ?? ''}';
    if (expressionId.isNotEmpty) {
      _expression = _expressionNameForEngineId(expressionId);
    }
  }

  String? _motionNameForEngineId(String id) {
    for (final raw in asJsonList(_doc['motions'])) {
      final motion = asJsonMap(raw);
      if (engineMotionId(motion) == id) return '${motion['name']}';
    }
    return null;
  }

  String? _expressionNameForEngineId(String id) {
    for (final raw in asJsonList(_doc['expressions'])) {
      final expression = asJsonMap(raw);
      if (engineExpressionId(expression) == id) return '${expression['name']}';
    }
    return null;
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
      'display_name': _displayName,
      'revision': _revision(),
      'spec_files': const <Object?>[],
    };
  }

  // ---------------------------------------------------------------------------
  // doc
  // ---------------------------------------------------------------------------

  int _revision() => _cachedRevision;

  int _cachedRevision = 0;

  /// 执行一条宿主命令。
  ///
  /// 引擎的 `doc.command` 只认下划线 op 且没有物理/动作/表情/姿势/设置编辑，
  /// 所以这里先在**影子文档**上生效（全部 55 个宿主 op + 撤销重做），
  /// 再把结果整体投影成 `Spec` 推给引擎求值。返回影子文档的修订号。
  Future<Map<String, Object?>> _docCommand(Map<String, Object?> p) async {
    final command = asJsonMap(p['command'] ?? p);
    if ('${command['op'] ?? ''}'.isEmpty) {
      throw const AmException('BAD_COMMAND', 'command.op is required');
    }
    // 影子文档负责校验与撤销栈；失败会抛 AmException，状态保持不变。
    _cachedRevision = _shadow.applyCommand(command);
    await _commit();
    return <String, Object?>{'revision': _cachedRevision};
  }

  /// 撤销/重做也由影子文档负责 —— 引擎侧每推送一次 `set_spec` 就会清空
  /// 自己的撤销栈，只有影子文档的历史是连续的。
  Future<Map<String, Object?>> _docUndoRedo(String method) async {
    final label = method == 'doc.undo'
        ? (_shadow.canUndo ? _shadow.history.last : null)
        : null;
    _cachedRevision = method == 'doc.undo' ? _shadow.undo() : _shadow.redo();
    await _commit();
    return <String, Object?>{'label': label, 'revision': _cachedRevision};
  }

  Map<String, Object?> _docQuery(Map<String, Object?> p) {
    final path = '${p['path'] ?? ''}';
    final nodes = asJsonMap(_doc['nodes']);
    switch (path) {
      case 'hierarchy':
        return <String, Object?>{
          'revision': _cachedRevision,
          'root': _doc['root'],
          'nodes': nodes,
          'art_path': asJsonList(_doc['art_path']),
        };
      case 'node':
        return <String, Object?>{
          'revision': _cachedRevision,
          'node': nodes['${p['id'] ?? ''}'],
        };
      case 'parameters':
        return <String, Object?>{
          'revision': _cachedRevision,
          'parameters': asJsonMap(_doc['parameters']),
        };
      case 'keyforms':
        final node = asJsonMap(nodes['${p['id'] ?? ''}']);
        return <String, Object?>{
          'revision': _cachedRevision,
          'keyforms': asJsonMap(node['keyforms']),
        };
      case 'mesh':
        final node = asJsonMap(nodes['${p['id'] ?? ''}']);
        return <String, Object?>{
          'revision': _cachedRevision,
          'mesh': asJsonMap(node['mesh']),
        };
      case 'physics':
        return <String, Object?>{'physics': asJsonList(_doc['physics'])};
      case 'motions':
        return <String, Object?>{'motions': asJsonList(_doc['motions'])};
      case 'expressions':
        return <String, Object?>{'expressions': asJsonList(_doc['expressions'])};
      case 'settings':
        return <String, Object?>{'settings': asJsonMap(_doc['settings'])};
      case 'config':
        return <String, Object?>{'config': asJsonMap(_doc['config'])};
      case 'pose':
        return <String, Object?>{'pose': asJsonList(_doc['pose'])};
      case 'atlas':
        return <String, Object?>{'atlas': asJsonList(_doc['atlas'])};
      default:
        throw AmException('UNKNOWN_QUERY', 'unknown doc.query path: $path');
    }
  }

  // ---------------------------------------------------------------------------
  // 运行时
  // ---------------------------------------------------------------------------

  Future<Map<String, Object?>> _applyParams(Map<String, Object?> values) async {
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
    final settings = asJsonMap(_doc['settings']);
    if (_blinkEnabled) {
      final interval = asDouble(asJsonMap(settings['blink'])['interval'], 4);
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
      final period = asDouble(asJsonMap(settings['breath'])['period'], 3.5);
      final value = math.sin(_clock / math.max(0.5, period) * math.pi * 2);
      await _applyParamByName(<String>['Breath', 'breath'], value);
    }
    if (_lipsyncEnabled) {
      await _applyParamByName(<String>[
        'MouthOpen',
        'mouth_open',
      ], _lipsyncAmplitude);
    }
  }

  Future<void> _applyParamByName(List<String> names, double value) async {
    for (final entry in asJsonMap(_doc['parameters']).entries) {
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
      'id': engineMotionId(motion),
      if (p['loop'] != null) 'looping': asBool(p['loop']),
      if (p['speed'] != null) 'speed': asDouble(p['speed']),
    });
    _playingMotion = name;
    _motionPlaying = true;
    _motionTime = 0;
    return <String, Object?>{'motion': name, 'loop': asBool(p['loop'])};
  }

  Map<String, Object?>? _findMotion(String name) {
    for (final raw in asJsonList(_doc['motions'])) {
      final motion = asJsonMap(raw);
      if ('${motion['name']}' == name) return motion;
    }
    return null;
  }

  Map<String, Object?>? _findExpression(String name) {
    for (final raw in asJsonList(_doc['expressions'])) {
      final expression = asJsonMap(raw);
      if ('${expression['name']}' == name) return expression;
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
    final found = _findExpression(name);
    if (found != null) {
      await _call('expression.set', <String, Object?>{
        'id': engineExpressionId(found),
        'weight': 1.0,
      });
      await _syncFromEngine();
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
      if (!asBool(d['visible'], true)) continue;
      drawables.add(
        AmSceneDrawable(
          id: '${d['node'] ?? d['name']}',
          name: '${d['name'] ?? ''}',
          vertices: <Offset>[
            for (final v in asJsonList(d['vertices']))
              Offset(asDouble(asJsonMap(v)['x']), asDouble(asJsonMap(v)['y'])),
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
          mask: <String>[for (final m in asJsonList(d['masks'])) '$m'],
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
    final nodes = asJsonMap(_doc['nodes']);
    var drawables = 0;
    var vertices = 0;
    for (final entry in nodes.entries) {
      final node = asJsonMap(entry.value);
      if ('${node['type']}' == 'drawable') {
        drawables++;
        vertices += asJsonList(asJsonMap(node['mesh'])['vertices']).length;
      }
    }
    return <String, Object?>{
      'nodes': nodes.length,
      'drawables': drawables,
      'vertices': vertices,
      'parameters': asJsonMap(_doc['parameters']).length,
      'motions': asJsonList(_doc['motions']).length,
      'expressions': asJsonList(_doc['expressions']).length,
      'physics_settings': asJsonList(_doc['physics']).length,
      'textures': asJsonList(_doc['atlas']).length,
      'frame': _clock,
      'fallback': false,
    };
  }
}
