/// 文件系统抽象（原生实现）。
///
/// 编辑器/查看器所有磁盘访问都走这里；Web 端由 `amproj_fs_stub.dart` 提供
/// 同一套 API，磁盘能力返回 `UNSUPPORTED_PLATFORM`，界面据此降级为
/// “Web 端仅支持 `.amproj` 包模式”。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../engine/am_types.dart';

/// 磁盘访问门面。
class AmFileSystem {
  const AmFileSystem._();

  /// 当前平台是否支持直接读写目录（工程本体）。
  static bool get supportsDirectories => true;

  /// 当前平台是否支持在任意路径写文件（导出）。
  static bool get supportsSaveAs => true;

  static Future<bool> exists(String path) => File(
    path,
  ).exists().then((value) => value || Directory(path).existsSync());

  static Future<bool> isDirectory(String path) => Directory(path).exists();

  static Future<bool> isFile(String path) => File(path).exists();

  static Future<void> ensureDirectory(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  static Future<String> readText(String path) =>
      File(path).readAsString(encoding: utf8);

  static Future<Uint8List> readBytes(String path) => File(path).readAsBytes();

  static Future<void> writeText(String path, String text) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    // 契约要求 JSON 一律 UTF-8 无 BOM。
    await file.writeAsString(text, encoding: utf8, flush: true);
  }

  static Future<void> writeBytes(String path, List<int> bytes) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  /// 递归列出目录下的**文件**，返回以 `/` 分隔的相对路径（升序）。
  static Future<List<String>> listFiles(String directory) async {
    final root = Directory(directory);
    if (!await root.exists()) return const <String>[];
    final result = <String>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = entity.path
          .substring(directory.length)
          .replaceAll(r'\', '/')
          .replaceFirst(RegExp('^/+'), '');
      result.add(relative);
    }
    result.sort();
    return result;
  }

  static Future<void> copyFile(String from, String to) async {
    final target = File(to);
    await target.parent.create(recursive: true);
    await File(from).copy(to);
  }

  static Future<void> deleteRecursive(String path) async {
    final dir = Directory(path);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      return;
    }
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  static Future<int> fileSize(String path) => File(path).length();

  static Future<void> movePath(String from, String to) async {
    final dir = Directory(from);
    if (await dir.exists()) {
      await dir.rename(to);
      return;
    }
    await File(from).rename(to);
  }
}

/// 平台不支持磁盘操作时抛出的错误。
Never throwUnsupportedPlatform(String operation) {
  throw AmException(
    'UNSUPPORTED_PLATFORM',
    'filesystem operation "$operation" is not available on this platform',
  );
}
