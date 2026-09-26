/// Web 端占位：`dart:ffi` 在 Web 上不可用，因此引擎只能通过 wasm 绑定驱动。
///
/// 这里的实现恒为“不可用”，编辑器会自动降级到内置实现，并且仍然可以
/// 打开 / 查看 `.amproj`（纯 Dart 只读解析）。
library;

import 'am_engine.dart';

/// 始终返回 `null`：Web 上没有可加载的原生动态库。
Future<AmEngine?> tryCreateFfiEngine({
  int width = 1280,
  int height = 720,
  double devicePixelRatio = 1.0,
}) async => null;

/// 始终返回 `null`。
AmEngineBackend? probeFfiBackend() => null;
