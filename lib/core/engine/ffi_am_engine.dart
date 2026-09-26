/// 条件导出：原生平台走 `dart:ffi`，Web 走占位实现。
///
/// 上层只允许 `import 'ffi_am_engine.dart'`，绝不直接 import 具体实现，
/// 否则 Web 构建会因 `dart:ffi` 不可用而失败。
library;

export 'ffi_am_engine_stub.dart' if (dart.library.ffi) 'ffi_am_engine_io.dart';
