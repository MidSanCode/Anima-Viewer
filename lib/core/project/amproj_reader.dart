/// `.amproj` 只读解析 + 全量校验（tasks.md §1.1 的 9 步）。
///
/// 这是**降级路径**：引擎可用时编辑器优先使用 `project.open` / `project.validate`。
/// 两条路径的问题码完全一致，UI 不需要区分。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import '../engine/am_types.dart';
import '../engine/local_document.dart';
import 'amproj_fs.dart';
import 'amproj_models.dart';

/// 工程数据源（目录模式或压缩包模式）。
abstract class AmprojSource {
  String get label;

  bool get isArchive;

  /// 工程文件清单（以 `/` 分隔的相对路径，升序）。
  Future<List<String>> listFiles();

  Future<Uint8List?> readBytes(String relative);

  Future<String?> readText(String relative);

  Future<bool> has(String relative);

  Future<int?> sizeOf(String relative);
}

/// 目录模式数据源。
class DirectoryAmprojSource implements AmprojSource {
  DirectoryAmprojSource(this.root);

  final String root;

  @override
  String get label => root;

  @override
  bool get isArchive => false;

  @override
  Future<bool> has(String relative) => AmFileSystem.isFile('$root/$relative');

  @override
  Future<List<String>> listFiles() => AmFileSystem.listFiles(root);

  @override
  Future<Uint8List?> readBytes(String relative) async {
    final path = '$root/$relative';
    if (!await AmFileSystem.isFile(path)) return null;
    return AmFileSystem.readBytes(path);
  }

  @override
  Future<String?> readText(String relative) async {
    final bytes = await readBytes(relative);
    if (bytes == null) return null;
    return utf8.decode(bytes, allowMalformed: false);
  }

  @override
  Future<int?> sizeOf(String relative) async {
    final path = '$root/$relative';
    if (!await AmFileSystem.isFile(path)) return null;
    return AmFileSystem.fileSize(path);
  }
}

/// 压缩包模式数据源（内存中解包）。
class MemoryAmprojSource implements AmprojSource {
  MemoryAmprojSource(this.label, Map<String, Uint8List> entries)
    : _entries = Map<String, Uint8List>.unmodifiable(entries);

  @override
  final String label;

  final Map<String, Uint8List> _entries;

  @override
  bool get isArchive => true;

  /// 供“导出后再导出”复用的原始条目。
  Map<String, Uint8List> get entries => _entries;

  @override
  Future<bool> has(String relative) async => _entries.containsKey(relative);

  @override
  Future<List<String>> listFiles() async {
    final files = _entries.keys.toList()..sort();
    return files;
  }

  @override
  Future<Uint8List?> readBytes(String relative) async => _entries[relative];

  @override
  Future<String?> readText(String relative) async {
    final bytes = _entries[relative];
    if (bytes == null) return null;
    return utf8.decode(bytes, allowMalformed: false);
  }

  @override
  Future<int?> sizeOf(String relative) async => _entries[relative]?.length;
}

/// 已打开的工程。
class AmprojProject {
  AmprojProject({
    required this.source,
    required this.info,
    required this.registry,
    required this.assetPaths,
    required this.metadata,
    required this.specTexts,
    required this.files,
  });

  final AmprojSource source;
  final AmprojInfo info;
  final AmprojRegistry registry;

  /// 实际存在的 `assets/**` 文件。
  final List<String> assetPaths;

  /// `assets/xxx` → 元数据。
  final Map<String, AmprojAssetMetadata> metadata;

  /// `spec/**` 文本内容。
  final Map<String, String> specTexts;

  /// 全部文件（含 assets/metadata）。
  final List<String> files;

  String get name => info.name;

  String get displayName =>
      info.displayName.isEmpty ? info.name : info.displayName;

  List<String> get registeredFiles => registry.registeredFiles;

  /// 打开目录模式或压缩包模式工程（自动识别）。
  static Future<AmprojProject> open(String path) async {
    if (await AmFileSystem.isDirectory(path)) {
      return fromSource(DirectoryAmprojSource(path));
    }
    if (await AmFileSystem.isFile(path)) {
      final bytes = await AmFileSystem.readBytes(path);
      return openArchiveBytes(bytes, label: path);
    }
    throw AmException('PROJECT_NOT_FOUND', 'no such path: $path');
  }

  /// 从 `.amproj` 字节流打开（Web 端主要入口）。
  static Future<AmprojProject> openArchiveBytes(
    Uint8List bytes, {
    String label = '<archive>',
  }) async {
    final entries = decodeAmprojArchive(bytes);
    return fromSource(MemoryAmprojSource(label, entries));
  }

  static Future<AmprojProject> fromSource(AmprojSource source) async {
    final files = await source.listFiles();
    final infoText = await source.readText('info.json');
    if (infoText == null) {
      throw const AmException('MISSING_INFO', 'info.json not found');
    }
    final AmprojInfo info;
    try {
      info = AmprojInfo.fromJson(asJsonMap(jsonDecode(infoText)));
    } on FormatException catch (error) {
      throw AmException('BAD_INFO_JSON', 'info.json parse failed: $error');
    }

    AmprojRegistry registry = const AmprojRegistry();
    final registryText = await source.readText('registry.json');
    if (registryText != null) {
      try {
        registry = AmprojRegistry.fromJson(asJsonMap(jsonDecode(registryText)));
      } on FormatException {
        registry = const AmprojRegistry();
      }
    }

    final assetPaths = files
        .where((f) => f.startsWith('assets/'))
        .toList(growable: false);

    final metadata = <String, AmprojAssetMetadata>{};
    for (final file in files) {
      if (!file.startsWith('metadata/') || !file.endsWith('.json')) continue;
      final text = await source.readText(file);
      if (text == null) continue;
      try {
        final meta = AmprojAssetMetadata.fromJson(asJsonMap(jsonDecode(text)));
        metadata[meta.path.isEmpty
                ? 'assets/${file.substring('metadata/'.length, file.length - 5)}'
                : meta.path] =
            meta;
      } on FormatException {
        // 坏元数据交给校验阶段报告。
      }
    }

    final specTexts = <String, String>{};
    for (final file in files) {
      if (!file.startsWith('spec/')) continue;
      final text = await source.readText(file);
      if (text != null) specTexts[file] = text;
    }

    return AmprojProject(
      source: source,
      info: info,
      registry: registry,
      assetPaths: assetPaths,
      metadata: metadata,
      specTexts: specTexts,
      files: files,
    );
  }

  /// 描述层 JSON（解析失败返回 `null`）。
  Map<String, Object?>? specJson(String relative) {
    final text = specTexts[relative];
    if (text == null) return null;
    try {
      return asJsonMap(jsonDecode(text));
    } on FormatException {
      return null;
    }
  }

  /// 描述层的模型结构；缺失时返回默认空文档。
  Map<String, Object?> modelDocument() {
    final model = specJson('spec/model.json');
    if (model == null || model.isEmpty) return defaultAnimaDocument();
    return model;
  }

  /// 组装为内置文档（降级编辑用）。
  LocalDocument toLocalDocument() => LocalDocument.fromJson(modelDocument());

  /// 全量校验（9 步）。
  Future<AmValidationReport> validate() async {
    final issues = <AmValidationIssue>[];
    void add(
      String code,
      String path,
      String message, {
      String severity = 'error',
    }) {
      issues.add(
        AmValidationIssue(
          code: code,
          path: path,
          message: message,
          severity: severity,
        ),
      );
    }

    // 1. 识别。
    if (info.format != kAmprojFormat) {
      add(
        'FORMAT_MISMATCH',
        'info.json',
        "format should be '$kAmprojFormat', got '${info.format}'",
      );
    }
    if (!kAmprojNamePattern.hasMatch(info.name)) {
      add('NAME_INVALID', 'info.json', 'invalid name: ${info.name}');
    }
    if (info.lastUpdateTime < info.createdTime) {
      add(
        'TIME_ORDER',
        'info.json',
        'last_update_time earlier than created_time',
      );
    }

    // 2. min_sdk 门槛（整数格式版本，schema: integer ≥ 1）。
    final required = info.minSdk;
    final current = kAmSdkVersion;
    if (required > current) {
      add(
        'SDK_TOO_OLD',
        'info.json',
        'requires format version >= $required, current $current',
      );
    }

    // 3. 注册表。
    if (!await source.has('registry.json')) {
      add('MISSING_REGISTRY', 'registry.json', 'registry.json not found');
      return AmValidationReport(issues);
    }
    final registered = registry.registeredFiles;
    if (registered.toSet().length != registered.length) {
      add('DUP_REGISTERED', 'registry.json', 'duplicated entries');
    }
    for (final rel in registered) {
      if (!rel.startsWith('assets/')) {
        add('NOT_UNDER_ASSETS', rel, 'registered path must live under assets/');
      }
    }
    if (registry.assetCount != null &&
        registry.assetCount != registered.length) {
      add(
        'ASSET_COUNT_MISMATCH',
        'registry.json',
        'asset_count=${registry.assetCount} vs ${registered.length}',
      );
    }

    // 4. 资源与元数据一一核对（含哈希/大小/UTF-8）。
    final bytesCache = <String, Uint8List>{};
    for (final rel in registered) {
      final bytes = await source.readBytes(rel);
      if (bytes == null) {
        add('MISSING_ASSET', rel, 'registered asset is missing');
        continue;
      }
      bytesCache[rel] = bytes;
      final meta = metadata[rel];
      if (meta == null) {
        add('NO_METADATA', rel, 'metadata file is missing');
        continue;
      }
      if (meta.path != rel) {
        add(
          'PATH_FIELD_MISMATCH',
          'metadata/${rel.substring('assets/'.length)}.json',
          "metadata path='${meta.path}' vs registry '$rel'",
        );
      }
      final digest = sha256.convert(bytes).toString();
      if (!kAmSha256Pattern.hasMatch(meta.sha256)) {
        add(
          'BAD_SHA256_FORMAT',
          'metadata/$rel.json',
          'sha256 is not 64 lowercase hex',
        );
      } else if (digest != meta.sha256) {
        add(
          'HASH_MISMATCH',
          rel,
          'actual ${digest.substring(0, 12)}... differs',
        );
      }
      if (bytes.length != meta.size) {
        add(
          'SIZE_MISMATCH',
          rel,
          'actual ${bytes.length} vs size=${meta.size}',
        );
      }
      if (AmMime.isTextType(meta.type)) {
        try {
          utf8.decode(bytes, allowMalformed: false);
        } on FormatException {
          add('INVALID_UTF8', rel, 'text asset is not valid UTF-8');
        }
      }
    }

    // 5. 双向镜像。
    final assetSet = assetPaths.toSet();
    for (final rel in assetPaths) {
      if (!registered.contains(rel)) {
        add('UNREGISTERED_ASSET', rel, 'asset exists but is not registered');
      }
      final metaRel = 'metadata/${rel.substring('assets/'.length)}.json';
      if (!files.contains(metaRel)) {
        add('NO_METADATA', rel, 'asset has no metadata');
      }
    }
    for (final file in files) {
      if (!file.startsWith('metadata/') || !file.endsWith('.json')) continue;
      final assetRel =
          'assets/${file.substring('metadata/'.length, file.length - 5)}';
      if (!assetSet.contains(assetRel)) {
        add('ORPHAN_METADATA', file, 'metadata has no matching asset');
      }
    }

    // 6. 签名（保留语义：存在则必须验通；Dart 降级只做格式检查）。
    if (info.authorSign != null) {
      final sign = asJsonMap(info.authorSign);
      if (sign.isEmpty ||
          sign['algorithm'] == null ||
          sign['signature'] == null) {
        add('BAD_SIGNATURE', 'info.json', 'author_sign malformed');
      } else {
        add(
          'SIGNATURE_UNVERIFIED',
          'info.json',
          'author_sign present; verification requires the engine',
          severity: 'warning',
        );
      }
    }
    if (registry.timestampSign != null) {
      add(
        'TIMESTAMP_UNVERIFIED',
        'registry.json',
        'timestamp_sign present; RFC 3161 verification requires the engine',
        severity: 'warning',
      );
    }

    // 7. 描述层解析。
    for (final entry in specTexts.entries) {
      if (!entry.key.endsWith('.json')) continue;
      try {
        jsonDecode(entry.value);
      } on FormatException catch (error) {
        add('SPEC_PARSE_ERROR', entry.key, 'spec JSON parse failed: $error');
      }
    }

    return AmValidationReport(issues);
  }

  /// 计算整包 SHA-256（伴生 `.sha256` 的内容）。
  Future<String> archiveDigest() async {
    if (source is MemoryAmprojSource) {
      final entries = (source as MemoryAmprojSource).entries;
      final bytes = encodeAmprojArchive(entries);
      return sha256.convert(bytes).toString();
    }
    return '';
  }
}

/// 解包 `.amproj`（ZIP + Deflate），带 zip-slip 防护。
Map<String, Uint8List> decodeAmprojArchive(Uint8List bytes) {
  if (bytes.length < 4 ||
      bytes[0] != 0x50 ||
      bytes[1] != 0x4B ||
      bytes[2] != 0x03 ||
      bytes[3] != 0x04) {
    throw const AmException('BAD_ARCHIVE', 'not a ZIP archive (bad magic)');
  }
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } on Object catch (error) {
    throw AmException('BAD_ARCHIVE', 'zip decode failed: $error');
  }
  final entries = <String, Uint8List>{};
  for (final file in archive.files) {
    if (!file.isFile) continue;
    final raw = file.name.replaceAll(r'\', '/');
    if (raw.startsWith('/') || RegExp(r'^[a-zA-Z]:').hasMatch(raw)) {
      throw AmException('ZIP_SLIP', 'absolute path in archive: $raw');
    }
    final segments = <String>[];
    for (final segment in raw.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        throw AmException('ZIP_SLIP', 'parent traversal in archive: $raw');
      }
      segments.add(segment);
    }
    final relative = segments.join('/');
    if (relative.isEmpty) continue;
    final data = file.readBytes();
    if (data == null) continue;
    entries[relative] = data;
  }
  return entries;
}

/// 打包为 `.amproj` 字节（ZIP + Deflate）。
Uint8List encodeAmprojArchive(Map<String, Uint8List> entries) {
  final archive = Archive();
  final names = entries.keys.toList()..sort();
  for (final name in names) {
    // ZipEncoder 默认对条目使用 Deflate（契约要求 ZIP + Deflate）。
    archive.add(ArchiveFile.bytes(name, entries[name]!));
  }
  return ZipEncoder().encodeBytes(archive);
}
