/// 文件系统抽象（Web 端占位）。
///
/// Web 没有可写目录，工程只能以 `.amproj` 包（字节流）形式打开与导出。
library;

import 'dart:convert';
import 'dart:typed_data';

import '../engine/am_types.dart';

/// 磁盘访问门面（Web）：所有磁盘操作都不支持。
class AmFileSystem {
  const AmFileSystem._();

  static bool get supportsDirectories => false;

  static bool get supportsSaveAs => true;

  static Future<bool> exists(String path) async => false;

  static Future<bool> isDirectory(String path) async => false;

  static Future<bool> isFile(String path) async => false;

  static Future<void> ensureDirectory(String path) async =>
      throwUnsupportedPlatform('ensureDirectory');

  static Future<String> readText(String path) async =>
      throwUnsupportedPlatform('readText');

  static Future<Uint8List> readBytes(String path) async =>
      throwUnsupportedPlatform('readBytes');

  static Future<void> writeText(String path, String text) async =>
      throwUnsupportedPlatform('writeText');

  static Future<void> writeBytes(String path, List<int> bytes) async =>
      throwUnsupportedPlatform('writeBytes');

  static Future<List<String>> listFiles(String directory) async =>
      throwUnsupportedPlatform('listFiles');

  static Future<void> copyFile(String from, String to) async =>
      throwUnsupportedPlatform('copyFile');

  static Future<void> deleteRecursive(String path) async =>
      throwUnsupportedPlatform('deleteRecursive');

  static Future<int> fileSize(String path) async =>
      throwUnsupportedPlatform('fileSize');

  static Future<void> movePath(String from, String to) async =>
      throwUnsupportedPlatform('movePath');
}

/// 平台不支持磁盘操作时抛出的错误。
Never throwUnsupportedPlatform(String operation) {
  throw AmException(
    'UNSUPPORTED_PLATFORM',
    'filesystem operation "$operation" is not available on this platform',
  );
}

/// Web 端把文本按 UTF-8 编码（导出用）。
List<int> encodeUtf8(String text) => utf8.encode(text);
