/// 条件导出：原生平台用 `dart:io`，Web 用占位实现。
library;

export 'amproj_fs_stub.dart' if (dart.library.io) 'amproj_fs_io.dart';
