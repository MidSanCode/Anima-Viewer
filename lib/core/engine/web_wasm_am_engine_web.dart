/// Web 端通过引擎的 wasm-bindgen 产物驱动引擎。
///
/// 与 C ABI 完全同构：仍然是「方法名 + JSON 参数 → JSON 信封」，所以这里和
/// `ffi_am_engine_io.dart` 的调用面一模一样，上层 `ContractAmEngine` 不用改。
///
/// 产物从哪来：CI 把引擎仓库的 `anima-engine-web.zip` 解到 `web/anima_engine/`，
/// 并在 `web/index.html` 里挂上 `loader.js`。loader 是 ES module，初始化完成后
/// 会把 `{ create, version }` 挂到 `window.AnimaEngine`；本文件就读这个全局。
///
/// 引擎不在（未配置 `ENGINE_WEB_URL`，或 wasm 加载失败）时，这里恒返回 `null`，
/// 应用自动降级到内置实现 —— 与原生平台同一套「绝不崩溃」约定。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'am_engine.dart';
import 'am_types.dart';

/// `window.AnimaEngine`（loader.js 注入；未就绪时为 `undefined`）。
///
/// 用可空 getter 而不是直接当对象用：wasm 还没加载完时这个全局不存在，
/// 可空 getter 会安全地给出 `null`，避免在空引用上取属性。
@JS('AnimaEngine')
external JSObject? get _factoryOrNull;

/// `window.AnimaEngineError`（加载失败时的原因，便于诊断）。
@JS('AnimaEngineError')
external String? get _animaEngineError;

/// `window.AnimaEngineLoader`：`undefined` 表示本构建没带引擎；
/// `'pending'` 表示正在加载，`'done'` / `'error'` 表示已出结果。
@JS('AnimaEngineLoader')
external String? get _loaderState;

/// 等待 `anima-engine-ready` 事件（loader.js 无论成败都会派发）。
Future<void> _waitForReady() {
  final completer = Completer<void>();
  final handler = (JSAny? _) {
    if (!completer.isCompleted) completer.complete();
  }.toJS;
  _window.addEventListener('anima-engine-ready', handler);
  return completer.future;
}

@JS('window')
external _Window get _window;

extension type _Window(JSObject _) implements JSObject {
  external void addEventListener(String type, JSFunction listener);
}

/// 等 wasm 有结果；上限 [timeout] 以免页面卡住。
///
/// * 全局 `undefined` → 本构建没带引擎，立即返回（不等，避免无谓延迟）；
/// * 已是 `done` / `error` → 立即返回；
/// * 否则等事件，最多 [timeout]。
Future<void> _awaitLoader({
  Duration timeout = const Duration(seconds: 15),
}) async {
  final state = _loaderState;
  if (state == null || state == 'done' || state == 'error') return;
  try {
    await _waitForReady().timeout(timeout);
  } on Object {
    // 超时也放行：下面读全局时会自然得到 null 并降级。
  }
}

/// wasm 侧的 `Engine` 实例。
extension type _WasmEngine(JSObject _) implements JSObject {
  /// 调用一个方法，返回 JSON 信封字符串（引擎 `call`）。
  external String call(String method, String paramsJson);
}

/// wasm 侧的模块导出对象（loader 包装后的 `{ create, version }`）。
extension type _WasmFactory(JSObject _) implements JSObject {
  external _WasmEngine create();
  external String version();
}

/// wasm 实现。
class WebWasmAmEngine implements AmEngine {
  WebWasmAmEngine._(this._factory) : _engine = _factory.create();

  final _WasmFactory _factory;
  final _WasmEngine _engine;

  final StreamController<AmEvent> _events =
      StreamController<AmEvent>.broadcast();

  AmCapabilities _capabilities = AmCapabilities.unavailable;
  bool _available = false;
  bool _disposed = false;
  String _version = '';

  @override
  AmEngineBackend get backend => AmEngineBackend(
    'wasm',
    'engine.backend.wasm',
    detail: _version.isEmpty ? 'anima_wasm' : _version,
  );

  @override
  AmCapabilities get capabilities => _capabilities;

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
    if (_disposed) return;
    try {
      _version = _factory.version();
      // 先放行，才能调 system.capabilities；失败再收回。
      _available = true;
      final raw = await call('system.capabilities');
      // 引擎给的值优先；它没报 sdk 版本时，才用模块自己的 version 兜底。
      final merged = <String, Object?>{
        'engine': 'anima',
        'format': 'amproj',
        ...raw,
      };
      merged.putIfAbsent('sdk', () => _version);
      _capabilities = AmCapabilities.fromJson(merged);
    } on Object {
      _available = false;
    }
  }

  @override
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?>? params,
  ]) async {
    if (_disposed) {
      throw const AmException('ENGINE_DISPOSED', 'engine already disposed');
    }
    if (!_available) {
      throw const AmException('NO_ENGINE', 'engine instance is not created');
    }
    String raw;
    try {
      raw = _engine.call(
        method,
        jsonEncode(params ?? const <String, Object?>{}),
      );
    } on Object catch (error) {
      throw AmException('CALL_FAILED', '$error');
    }
    return unwrapAmResponse(method, _tryDecode(raw));
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _available = false;
    if (!_events.isClosed) await _events.close();
  }
}

/// 解码引擎返回的 JSON；失败时原样返回字符串，便于诊断。
Object? _tryDecode(String text) {
  if (text.isEmpty) return null;
  try {
    return jsonDecode(text);
  } on FormatException {
    return text;
  }
}

/// 浏览器端 wasm 引擎工厂；`null` 表示 wasm 产物尚未就绪或加载失败。
Future<AmEngine?> tryCreateWebWasmEngine({
  int width = 1280,
  int height = 720,
  double devicePixelRatio = 1.0,
}) async {
  await _awaitLoader();
  final global = _factoryOrNull;
  if (global == null) return null;
  try {
    final engine = WebWasmAmEngine._(_WasmFactory(global));
    await engine.initialize(
      width: width,
      height: height,
      devicePixelRatio: devicePixelRatio,
    );
    if (!engine.isAvailable) {
      await engine.dispose();
      return null;
    }
    return engine;
  } on Object {
    return null;
  }
}

/// 探测 wasm 引擎是否可用，不做任何副作用（不创建实例）。
AmEngineBackend? probeWebWasmBackend() {
  final global = _factoryOrNull;
  if (global == null) return null;
  try {
    final version = _WasmFactory(global).version();
    return AmEngineBackend('wasm', 'engine.backend.wasm', detail: version);
  } on Object {
    return null;
  }
}

/// 加载失败原因（诊断面板展示）；没有失败时为 `null`。
String? webWasmEngineError() => _animaEngineError;
