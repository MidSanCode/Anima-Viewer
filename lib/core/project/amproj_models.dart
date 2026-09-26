/// `.amproj` 工程格式的数据模型（tasks.md §1.1）。
///
/// Dart 侧实现，供编辑器/查看器在**引擎不可用时**仍能打开、查看与校验工程。
/// 引擎就绪后，权威读写由 `am-engine` 负责；这里的实现保持与
/// `temp/example` + 参考 SDK 完全一致的字段与问题码。
library;

import 'dart:convert';

import '../engine/am_types.dart';

/// 格式标识。
const String kAmprojFormat = 'amproj';

/// 导出包扩展名。
const String kAmprojExtension = 'amproj';

/// 当前 Anima SDK 版本（`min_sdk` 门槛用）。
///
/// 契约（engine/schemas/format.schema.json）：`min_sdk` 是整数 ≥ 1，
/// 表示 amproj 格式版本（不是点分 SDK 号）。
const int kAmSdkVersion = 1;

/// 永远不导出的目录。
const Set<String> kAmprojNeverExport = <String>{'work', 'dist'};

/// 导出/导入涉及的前缀。
const List<String> kAmprojEntryPrefixes = <String>[
  'info.json',
  'registry.json',
  'assets/',
  'metadata/',
  'spec/',
];

final RegExp kAmprojNamePattern = RegExp(r'^[a-z0-9_-]+$');
final RegExp kAmSha256Pattern = RegExp(r'^[0-9a-f]{64}$');

/// 版本比较：支持 `1`、`0.1.0`、`1.2` 等写法。
class AmVersion implements Comparable<AmVersion> {
  AmVersion(String raw) : parts = _parse(raw);

  final List<int> parts;

  static List<int> _parse(String raw) {
    final cleaned = raw.trim();
    if (cleaned.isEmpty) return const <int>[0];
    return cleaned
        .split(RegExp(r'[.\-+]'))
        .map((e) => int.tryParse(e) ?? 0)
        .toList(growable: false);
  }

  @override
  int compareTo(AmVersion other) {
    final length = parts.length > other.parts.length
        ? parts.length
        : other.parts.length;
    for (var i = 0; i < length; i++) {
      final a = i < parts.length ? parts[i] : 0;
      final b = i < other.parts.length ? other.parts[i] : 0;
      if (a != b) return a.compareTo(b);
    }
    return 0;
  }

  bool operator >(AmVersion other) => compareTo(other) > 0;

  bool operator <(AmVersion other) => compareTo(other) < 0;

  bool operator >=(AmVersion other) => compareTo(other) >= 0;

  @override
  String toString() => parts.join('.');
}

/// `info.json`。
class AmprojInfo {
  AmprojInfo({
    this.format = kAmprojFormat,
    this.minSdk = kAmSdkVersion,
    required this.name,
    this.displayName = '',
    this.description = '',
    this.author = '',
    this.authorSign,
    this.license = '',
    this.tags = const <String>[],
    this.createdTime = 0,
    this.lastUpdateTime = 0,
    this.version = 1,
    this.extra = const <String, Object?>{},
  });

  final String format;

  /// amproj 格式版本（整数 ≥ 1，schema: `min_sdk: integer, minimum: 1`）。
  final int minSdk;
  final String name;
  final String displayName;
  final String description;
  final String author;
  final Object? authorSign;
  final String license;
  final List<String> tags;
  final int createdTime;
  final int lastUpdateTime;
  final int version;
  final Map<String, Object?> extra;

  /// 未知字段自动收纳，避免往返丢失（与参考 SDK 行为一致）。
  static const Set<String> knownKeys = <String>{
    'format',
    'min_sdk',
    'name',
    'display_name',
    'description',
    'author',
    'author_sign',
    'license',
    'tags',
    'created_time',
    'last_update_time',
    'version',
    'extra',
  };

  factory AmprojInfo.fromJson(Map<String, Object?> json) {
    final extra = <String, Object?>{...asJsonMap(json['extra'])};
    for (final entry in json.entries) {
      if (!knownKeys.contains(entry.key)) extra[entry.key] = entry.value;
    }
    return AmprojInfo(
      format: '${json['format'] ?? ''}',
      // 兼容老文件：点分字符串 "0.1.0" → 主版本号整数。
      minSdk: _parseMinSdk(json['min_sdk']),
      name: '${json['name'] ?? ''}',
      displayName: '${json['display_name'] ?? ''}',
      description: '${json['description'] ?? ''}',
      author: '${json['author'] ?? ''}',
      authorSign: json['author_sign'],
      license: '${json['license'] ?? ''}',
      tags: asJsonList(json['tags']).map((e) => '$e').toList(),
      createdTime: asInt(json['created_time']),
      lastUpdateTime: asInt(json['last_update_time']),
      version: asInt(json['version'], 1),
      extra: extra,
    );
  }

  /// 解析 `min_sdk`：整数原样；字符串取主版本号（"0.1.0" → 0 → 仍按 ≥1
  /// 钳制，老格式文件视为 v1）。
  static int _parseMinSdk(Object? raw) {
    if (raw is int) return raw < 1 ? 1 : raw;
    if (raw is num) return raw.toInt() < 1 ? 1 : raw.toInt();
    final text = '$raw'.trim();
    if (text.isEmpty) return kAmSdkVersion;
    final major = int.tryParse(text.split('.').first);
    if (major == null || major < 1) return 1;
    return major;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'format': format,
    'min_sdk': minSdk,
    'name': name,
    'display_name': displayName,
    'description': description,
    'author': author,
    if (authorSign != null) 'author_sign': authorSign,
    'license': license,
    'tags': tags,
    'created_time': createdTime,
    'last_update_time': lastUpdateTime,
    'version': version,
    if (extra.isNotEmpty) 'extra': extra,
  };

  AmprojInfo copyWith({
    String? name,
    String? displayName,
    String? description,
    String? author,
    String? license,
    List<String>? tags,
    int? lastUpdateTime,
    int? version,
  }) => AmprojInfo(
    format: format,
    minSdk: minSdk,
    name: name ?? this.name,
    displayName: displayName ?? this.displayName,
    description: description ?? this.description,
    author: author ?? this.author,
    authorSign: authorSign,
    license: license ?? this.license,
    tags: tags ?? this.tags,
    createdTime: createdTime,
    lastUpdateTime: lastUpdateTime ?? this.lastUpdateTime,
    version: version ?? this.version,
    extra: extra,
  );

  /// 签名载荷：键排序、无空白的 JSON（tasks.md §1.1）。
  String signPayload(List<String> registeredFiles) {
    final sorted = [...registeredFiles]..sort();
    return jsonEncode(<String, Object?>{
      'format': format,
      'min_sdk': minSdk,
      'name': name,
      'registered_files': sorted,
      'version': version,
    });
  }
}

/// `registry.json`。
class AmprojRegistry {
  const AmprojRegistry({
    this.registeredFiles = const <String>[],
    this.assetCount,
    this.timestampSign,
    this.extra = const <String, Object?>{},
  });

  final List<String> registeredFiles;
  final int? assetCount;
  final Object? timestampSign;
  final Map<String, Object?> extra;

  static const Set<String> knownKeys = <String>{
    'registered_files',
    'asset_count',
    'timestamp_sign',
    'extra',
  };

  factory AmprojRegistry.fromJson(Map<String, Object?> json) {
    final extra = <String, Object?>{...asJsonMap(json['extra'])};
    for (final entry in json.entries) {
      if (!knownKeys.contains(entry.key)) extra[entry.key] = entry.value;
    }
    return AmprojRegistry(
      registeredFiles: asJsonList(
        json['registered_files'],
      ).map((e) => '$e').toList(),
      assetCount: json['asset_count'] == null
          ? null
          : asInt(json['asset_count']),
      timestampSign: json['timestamp_sign'],
      extra: extra,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'registered_files': registeredFiles,
    'asset_count': assetCount ?? registeredFiles.length,
    if (timestampSign != null) 'timestamp_sign': timestampSign,
    if (extra.isNotEmpty) 'extra': extra,
  };
}

/// `metadata/<相对路径>.json`。
class AmprojAssetMetadata {
  AmprojAssetMetadata({
    required this.path,
    required this.type,
    required this.mime,
    required this.format,
    required this.size,
    required this.sha256,
    this.hashAlgorithm = 'sha256',
    this.createdTime = 0,
    this.lastUpdateTime = 0,
    this.width,
    this.height,
    this.durationSeconds,
    this.extra = const <String, Object?>{},
  });

  final String path;
  final String type;
  final String mime;
  final String format;
  final int size;
  final String sha256;
  final String hashAlgorithm;
  final int createdTime;
  final int lastUpdateTime;
  final int? width;
  final int? height;
  final double? durationSeconds;
  final Map<String, Object?> extra;

  static const Set<String> knownKeys = <String>{
    'path',
    'type',
    'mime',
    'format',
    'size',
    'sha256',
    'hash_algorithm',
    'created_time',
    'last_update_time',
    'width',
    'height',
    'duration_seconds',
    'extra',
  };

  factory AmprojAssetMetadata.fromJson(Map<String, Object?> json) {
    final extra = <String, Object?>{...asJsonMap(json['extra'])};
    for (final entry in json.entries) {
      if (!knownKeys.contains(entry.key)) extra[entry.key] = entry.value;
    }
    return AmprojAssetMetadata(
      path: '${json['path'] ?? ''}',
      type: '${json['type'] ?? 'binary'}',
      mime: '${json['mime'] ?? 'application/octet-stream'}',
      format: '${json['format'] ?? ''}',
      size: asInt(json['size']),
      sha256: '${json['sha256'] ?? ''}',
      hashAlgorithm: '${json['hash_algorithm'] ?? 'sha256'}',
      createdTime: asInt(json['created_time']),
      lastUpdateTime: asInt(json['last_update_time']),
      width: json['width'] == null ? null : asInt(json['width']),
      height: json['height'] == null ? null : asInt(json['height']),
      durationSeconds: json['duration_seconds'] == null
          ? null
          : asDouble(json['duration_seconds']),
      extra: extra,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'type': type,
    'mime': mime,
    'format': format,
    'size': size,
    'sha256': sha256,
    'hash_algorithm': hashAlgorithm,
    'created_time': createdTime,
    'last_update_time': lastUpdateTime,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (durationSeconds != null) 'duration_seconds': durationSeconds,
    if (extra.isNotEmpty) 'extra': extra,
  };
}

/// 扩展名 → 分类 / MIME / 格式标识（对齐参考 SDK `mime.py`）。
class AmMime {
  const AmMime._();

  static const Map<String, String> _extType = <String, String>{
    'jpg': 'image',
    'jpeg': 'image',
    'png': 'image',
    'svg': 'image',
    'webp': 'image',
    'gif': 'image',
    'bmp': 'image',
    'ico': 'image',
    'mp3': 'audio',
    'wav': 'audio',
    'ogg': 'audio',
    'flac': 'audio',
    'm4a': 'audio',
    'aac': 'audio',
    'opus': 'audio',
    'mp4': 'video',
    'webm': 'video',
    'mkv': 'video',
    'mov': 'video',
    'obj': 'model',
    'gltf': 'model',
    'glb': 'model',
    'fbx': 'model',
    'blend': 'model',
    'stl': 'model',
    'txt': 'text',
    'md': 'text',
    'json': 'text',
    'xml': 'text',
    'yaml': 'text',
    'yml': 'text',
    'csv': 'text',
  };

  static const Map<String, String> _extMime = <String, String>{
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'svg': 'image/svg+xml',
    'webp': 'image/webp',
    'gif': 'image/gif',
    'bmp': 'image/bmp',
    'ico': 'image/x-icon',
    'mp3': 'audio/mpeg',
    'wav': 'audio/wav',
    'ogg': 'audio/ogg',
    'flac': 'audio/flac',
    'm4a': 'audio/mp4',
    'aac': 'audio/aac',
    'opus': 'audio/ogg',
    'mp4': 'video/mp4',
    'webm': 'video/webm',
    'mkv': 'video/x-matroska',
    'mov': 'video/quicktime',
    'obj': 'text/plain',
    'gltf': 'model/gltf+json',
    'glb': 'model/gltf-binary',
    'fbx': 'application/octet-stream',
    'blend': 'application/octet-stream',
    'stl': 'model/stl',
    'txt': 'text/plain',
    'md': 'text/markdown',
    'json': 'application/json',
    'xml': 'application/xml',
    'yaml': 'application/yaml',
    'yml': 'application/yaml',
    'csv': 'text/csv',
  };

  static const Map<String, String> _formatAlias = <String, String>{
    'jpg': 'jpeg',
    'yml': 'yaml',
  };

  static const String defaultMime = 'application/octet-stream';

  /// 小写扩展名（不含点）。
  static String extensionOf(String relativePath) {
    final name = relativePath.split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  static String guessType(String relativePath) =>
      _extType[extensionOf(relativePath)] ?? 'binary';

  static String guessMime(String relativePath) =>
      _extMime[extensionOf(relativePath)] ?? defaultMime;

  /// 规范格式名；无扩展名返回 `null`。
  static String? formatOf(String relativePath) {
    final ext = extensionOf(relativePath);
    if (ext.isEmpty) return null;
    return _formatAlias[ext] ?? ext;
  }

  /// 该分类是否应做 UTF-8 校验。
  static bool isTextType(String type) => type == 'text';
}
