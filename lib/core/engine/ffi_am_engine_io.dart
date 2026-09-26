/// 通过 `dart:ffi` 直接驱动引擎动态库（engine/docs/ffi-contract.md 的 C ABI）。
///
/// 这是**引擎就绪后的正式路径**。在引擎动态库不存在时
/// [tryCreateFfiEngine] 返回 `null`，由上层降级到内置实现——绝不抛异常、
/// 绝不崩溃。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'am_engine.dart';
import 'am_types.dart';

// ---------------------------------------------------------------------------
// C ABI 声明（engine/crates/am-ffi/bindings/include/anima.h）
// ---------------------------------------------------------------------------

typedef _NewEmptyNative = Pointer<Void> Function();
typedef _NewEmptyDart = Pointer<Void> Function();

typedef _FreeEngineNative = Void Function(Pointer<Void>);
typedef _FreeEngineDart = void Function(Pointer<Void>);

typedef _CallNative =
    Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _CallDart =
    Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);

typedef _FreeStringNative = Void Function(Pointer<Utf8>);
typedef _FreeStringDart = void Function(Pointer<Utf8>);

typedef _FrameCopyNative = Size Function(Pointer<Void>, Pointer<Uint8>, Size);
typedef _FrameCopyDart = int Function(Pointer<Void>, Pointer<Uint8>, int);

typedef _VersionNative = Pointer<Utf8> Function();
typedef _VersionDart = Pointer<Utf8> Function();

/// 引擎动态库的候选文件名（按平台）。
List<String> engineLibraryCandidates() {
  final override = Platform.environment['ANIMA_ENGINE_LIB'];
  final explicit = <String>[
    if (override != null && override.trim().isNotEmpty) override.trim(),
  ];
  if (Platform.isWindows) {
    return explicit + const ['anima.dll'];
  }
  if (Platform.isMacOS) {
    return explicit + const ['libanima.dylib', 'libanima.so'];
  }
  return explicit + const ['libanima.so'];
}

/// 尝试打开引擎动态库；返回 `null` 表示引擎尚未交付。
DynamicLibrary? openEngineLibrary() {
  final sep = Platform.pathSeparator;
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final roots = <String>[
    '',
    Directory.current.path,
    exeDir,
    '$exeDir${sep}data',
    '$exeDir${sep}lib',
    // 引擎仓库的构建产物位置（开发期便利，不影响发布包）。
    '..${sep}engine${sep}target${sep}debug',
    '..${sep}engine${sep}target${sep}release',
  ];

  for (final name in engineLibraryCandidates()) {
    final paths = <String>[
      if (File(name).isAbsolute || name.contains(sep) || name.contains('/'))
        name,
      ...roots.map((root) => root.isEmpty ? name : '$root$sep$name'),
    ];
    for (final path in paths) {
      if (!File(path).existsSync()) continue;
      try {
        return DynamicLibrary.open(path);
      } on Object {
        // 继续尝试下一个候选。
      }
    }
  }

  // 静态链接到宿主进程的情形（iOS / 宿主已加载）。
  try {
    return DynamicLibrary.process();
  } on Object {
    return null;
  }
}

/// 探测引擎是否可用，不做任何副作用（不创建实例）。
AmEngineBackend? probeFfiBackend() {
  final lib = openEngineLibrary();
  if (lib == null) return null;
  try {
    final version = lib.lookupFunction<_VersionNative, _VersionDart>(
      'am_version',
    );
    final ptr = version();
    final text = ptr == nullptr ? '' : ptr.toDartString();
    return AmEngineBackend('ffi', 'engine.backend.ffi', detail: text);
  } on Object {
    return null;
  }
}

/// FFI 实现。
class FfiAmEngine implements AmEngine {
  FfiAmEngine._(
    this._newEmpty,
    this._freeEngine,
    this._call,
    this._freeString,
    this._frameCopy,
  );

  final _NewEmptyDart _newEmpty;
  final _FreeEngineDart _freeEngine;
  final _CallDart _call;
  final _FreeStringDart _freeString;
  final _FrameCopyDart _frameCopy;

  final StreamController<AmEvent> _events =
      StreamController<AmEvent>.broadcast();

  Pointer<Void> _handle = nullptr;
  AmCapabilities _capabilities = AmCapabilities.unavailable;
  bool _available = false;
  bool _disposed = false;
  String? _versionText;

  /// 绑定符号；任一必需符号缺失即视为不可用。
  static FfiAmEngine? bind(DynamicLibrary lib) {
    try {
      return FfiAmEngine._(
        lib.lookupFunction<_NewEmptyNative, _NewEmptyDart>('am_engine_new'),
        lib.lookupFunction<_FreeEngineNative, _FreeEngineDart>(
          'am_engine_free',
        ),
        lib.lookupFunction<_CallNative, _CallDart>('am_call'),
        lib.lookupFunction<_FreeStringNative, _FreeStringDart>(
          'am_string_free',
        ),
        lib.lookupFunction<_FrameCopyNative, _FrameCopyDart>('am_frame_copy'),
      );
    } on Object {
      return null;
    }
  }

  @override
  AmEngineBackend get backend => AmEngineBackend(
    'ffi',
    'engine.backend.ffi',
    detail: _versionText ?? 'am_call',
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
    // 空引擎：宿主用 contract adapter 打开工程。
    _handle = _newEmpty();
    if (_handle == nullptr) {
      _available = false;
      return;
    }
    Map<String, Object?> versionInfo = const <String, Object?>{};
    try {
      versionInfo = await call('system.version');
      _versionText = '${versionInfo['version'] ?? ''}';
    } on Object {
      _versionText = null;
    }
    try {
      final raw = await call('system.capabilities');
      // 引擎的 capabilities 不带名字/格式，从 system.version 补齐。
      _capabilities = AmCapabilities.fromJson(<String, Object?>{
        ...raw,
        'engine': '${versionInfo['name'] ?? versionInfo['version'] ?? 'anima'}',
        'sdk': '${versionInfo['version'] ?? ''}',
        'format': '${versionInfo['format'] ?? 'amproj'}',
        'min_sdk': '${versionInfo['format_version'] ?? '1'}',
      });
      _available = true;
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
    if (_handle == nullptr) {
      throw const AmException('NO_ENGINE', 'engine instance is not created');
    }

    final methodPtr = method.toNativeUtf8();
    final paramsPtr = _encode(params ?? const <String, Object?>{});
    Pointer<Utf8> resultPtr = nullptr;
    try {
      resultPtr = _call(_handle, methodPtr, paramsPtr);
    } on Object catch (error) {
      throw AmException('CALL_FAILED', '$error');
    } finally {
      calloc.free(methodPtr);
      calloc.free(paramsPtr);
    }

    if (resultPtr == nullptr) {
      throw AmException('CALL_FAILED', 'am_call($method) returned NULL');
    }
    try {
      return unwrapAmResponse(method, _tryDecode(resultPtr.toDartString()));
    } finally {
      _freeString(resultPtr);
    }
  }

  /// 拷贝最近渲染帧（RGBA8，预乘 alpha，第 0 行在顶部）。
  Uint8List? copyFrame() {
    if (_handle == nullptr) return null;
    final capacity = _frameCopy(_handle, nullptr, 0);
    if (capacity == 0) return null;
    final buffer = calloc<Uint8>(capacity);
    try {
      final written = _frameCopy(_handle, buffer, capacity);
      return Uint8List.fromList(
        buffer.asTypedList(written == 0 ? capacity : written),
      );
    } on Object {
      return null;
    } finally {
      calloc.free(buffer);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_handle != nullptr) {
      try {
        _freeEngine(_handle);
      } on Object {
        // 忽略析构异常。
      }
      _handle = nullptr;
    }
    _available = false;
    if (!_events.isClosed) await _events.close();
  }

  Pointer<Utf8> _encode(Object? value) =>
      jsonEncode(value ?? const <String, Object?>{}).toNativeUtf8();
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

/// FFI 引擎工厂；`null` 表示动态库不可用。
Future<AmEngine?> tryCreateFfiEngine({
  int width = 1280,
  int height = 720,
  double devicePixelRatio = 1.0,
}) async {
  final lib = openEngineLibrary();
  if (lib == null) return null;
  final engine = FfiAmEngine.bind(lib);
  if (engine == null) return null;
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
}
