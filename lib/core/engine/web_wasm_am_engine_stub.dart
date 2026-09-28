/// 原生平台的占位：Web 引擎只在浏览器里存在。
///
/// 恒返回 `null`，于是原生平台照常走 `dart:ffi`（见 [ffiAmEngine]）。
library;

import 'am_engine.dart';

/// 恒为 `null`：原生平台没有 wasm 运行时。
Future<AmEngine?> tryCreateWebWasmEngine({
  int width = 1280,
  int height = 720,
  double devicePixelRatio = 1.0,
}) async => null;

/// 恒为 `null`。
AmEngineBackend? probeWebWasmBackend() => null;
