/// 系统文件对话框封装（桌面为主，Web 自动降级）。
///
/// 面板只依赖这里的返回值，不直接触碰平台 API，方便在 Web 上退化为内存模式。
library;

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// 选中的文件。
class PickedFile {
  const PickedFile({this.path, this.bytes, required this.name});

  /// 本地绝对路径（Web / 内容 URI 上为 `null`）。
  final String? path;

  /// 文件内容（懒读取，`pickFiles` 时已按需载入）。
  final Uint8List? bytes;

  final String name;

  bool get hasBytes => bytes != null && bytes!.isNotEmpty;
}

/// 文件对话框服务。
class FileService {
  const FileService._();

  /// 选择一个文件（多选时返回全部）。
  static Future<List<PickedFile>> pickFiles({
    List<String> extensions = const <String>[],
    String? dialogTitle,
  }) async {
    try {
      final files = await FilePicker.pickFiles(
        dialogTitle: dialogTitle,
        type: extensions.isEmpty ? FileType.any : FileType.custom,
        allowedExtensions: extensions.isEmpty ? null : extensions,
      );
      return <PickedFile>[
        for (final file in files)
          PickedFile(
            path: file.path,
            bytes: await _tryRead(file),
            name: file.name,
          ),
      ];
    } on Object {
      return const <PickedFile>[];
    }
  }

  /// 选择目录（Web 不支持）。
  static Future<String?> pickDirectory({String? dialogTitle}) async {
    try {
      return await FilePicker.getDirectoryPath(dialogTitle: dialogTitle);
    } on Object {
      return null;
    }
  }

  /// 保存对话框：写入字节并返回目标路径（Web 上返回 `null`）。
  static Future<String?> saveBytes({
    required String suggestedName,
    required Uint8List bytes,
    String mimeType = 'application/octet-stream',
  }) async {
    try {
      final uri = await FilePicker.saveFile(
        fileName: suggestedName,
        bytes: bytes,
        mimeType: mimeType,
        dialogTitle: suggestedName,
      );
      if (uri == null) return null;
      return uri.scheme == 'file' ? uri.toFilePath() : uri.toString();
    } on Object {
      return null;
    }
  }

  static Future<Uint8List?> _tryRead(PlatformFile file) async {
    try {
      return await file.readAsBytes();
    } on Object {
      return null;
    }
  }
}
