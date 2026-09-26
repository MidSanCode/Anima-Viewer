/// `.amproj` 工程写入 / 打包 / 解包（tasks.md §1.1）。
///
/// 与 [AmprojProject] 一样属于**降级路径**：引擎可用时改走
/// `project.create/save/export/import`。编码规范严格对齐契约：
/// UTF-8 无 BOM、缩进 Tab、键名 `snake_case`、路径 `/` 分隔。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../engine/am_types.dart';
import 'amproj_fs.dart';
import 'amproj_models.dart';
import 'amproj_reader.dart';

/// 工程写入器。
class AmprojWriter {
  const AmprojWriter._();

  /// 契约要求的 JSON 文本形态：UTF-8 无 BOM、Tab 缩进、末尾换行。
  static String encodeJson(Object? value) =>
      '${const JsonEncoder.withIndent('\t').convert(value)}\n';

  static int nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// 新工程的 info.json。
  static AmprojInfo freshInfo({
    required String name,
    String displayName = '',
    String description = '',
    String author = '',
    String license = '',
    List<String> tags = const <String>[],
    int minSdk = kAmSdkVersion,
  }) {
    final now = nowSeconds();
    return AmprojInfo(
      name: name,
      displayName: displayName.isEmpty ? name : displayName,
      description: description,
      author: author,
      license: license,
      tags: tags,
      minSdk: minSdk,
      createdTime: now,
      lastUpdateTime: now,
      version: 1,
    );
  }

  /// 创建目录模式工程（含必填四层）。
  static Future<void> createDirectory(
    String directory, {
    required AmprojInfo info,
  }) async {
    if (!kAmprojNamePattern.hasMatch(info.name)) {
      throw AmException(
        'NAME_INVALID',
        'project name must match ^[a-z0-9_-]+\$ (got "${info.name}")',
      );
    }
    await AmFileSystem.ensureDirectory(directory);
    for (final sub in <String>['assets', 'metadata', 'spec']) {
      await AmFileSystem.ensureDirectory('$directory/$sub');
    }
    await writeInfo(directory, info);
    await writeRegistry(directory, const AmprojRegistry());
    await writeSpecFile(
      directory,
      'spec/overview.md',
      '# ${info.displayName}\n\n'
          '${info.description}\n\n'
          '- format: $kAmprojFormat\n'
          '- version: ${info.version}\n'
          '- author: ${info.author}\n',
    );
    await writeSpecFile(
      directory,
      'spec/config.json',
      encodeJson(<String, Object?>{
        'project': <String, Object?>{'name': info.name},
        'canvas': <String, Object?>{'width': 1280, 'height': 720, 'unit': 'px'},
        'settings': <String, Object?>{
          'language': 'zh-CN',
          'render_quality': 'high',
        },
      }),
    );
  }

  /// 目标目录是否已经是一个工程（存在 `info.json`）。
  ///
  /// 新建工程前用它兜底：覆盖别人的 `info.json` / `registry.json` / `spec/`
  /// 是不可逆的数据丢失，宁可报错让用户另选目录。
  static Future<bool> isProjectDirectory(String directory) =>
      AmFileSystem.isFile('$directory/info.json');

  static Future<void> writeInfo(String directory, AmprojInfo info) =>
      AmFileSystem.writeText('$directory/info.json', encodeJson(info.toJson()));

  static Future<void> writeRegistry(
    String directory,
    AmprojRegistry registry,
  ) => AmFileSystem.writeText(
    '$directory/registry.json',
    encodeJson(registry.toJson()),
  );

  static Future<void> writeSpecFile(
    String directory,
    String relative,
    String text,
  ) => AmFileSystem.writeText('$directory/$relative', text);

  /// 元数据相对路径：`assets/images/a.png` → `metadata/images/a.png.json`。
  static String metadataRelative(String assetRelative) =>
      'metadata/${assetRelative.substring('assets/'.length)}.json';

  /// 写入（或替换）一个资源，并同步元数据；返回元数据。
  static Future<AmprojAssetMetadata> writeAsset(
    String directory,
    String assetRelative,
    List<int> bytes, {
    String? type,
    String? mime,
    String? format,
    Map<String, Object?> extra = const <String, Object?>{},
  }) async {
    if (!assetRelative.startsWith('assets/')) {
      throw const AmException(
        'NOT_UNDER_ASSETS',
        'asset path must live under assets/',
      );
    }
    final now = nowSeconds();
    await AmFileSystem.writeBytes('$directory/$assetRelative', bytes);
    final digest = sha256.convert(bytes).toString();
    final metadata = AmprojAssetMetadata(
      path: assetRelative,
      type: type ?? AmMime.guessType(assetRelative),
      mime: mime ?? AmMime.guessMime(assetRelative),
      format: format ?? (AmMime.formatOf(assetRelative) ?? ''),
      size: bytes.length,
      sha256: digest,
      createdTime: now,
      lastUpdateTime: now,
      extra: extra,
    );
    await AmFileSystem.writeText(
      '$directory/${metadataRelative(assetRelative)}',
      encodeJson(metadata.toJson()),
    );
    // 注册表必须与 assets/ 保持一致，否则工程校验会报 UNREGISTERED_ASSET。
    await rebuildRegistry(directory);
    return metadata;
  }

  /// 从注册表重算 `registered_files` 并写回 `registry.json`。
  static Future<AmprojRegistry> rebuildRegistry(
    String directory, {
    Object? timestampSign,
  }) async {
    final files = await AmFileSystem.listFiles('$directory/assets');
    final registered = files.map((f) => 'assets/$f').toList(growable: false)
      ..sort();
    final registry = AmprojRegistry(
      registeredFiles: registered,
      assetCount: registered.length,
      timestampSign: timestampSign,
    );
    await writeRegistry(directory, registry);
    return registry;
  }

  /// 收集导出条目（`work/`、`dist/` 永不导出）。
  static Future<Map<String, Uint8List>> collectExportEntries(
    String directory,
  ) async {
    final files = await AmFileSystem.listFiles(directory);
    final entries = <String, Uint8List>{};
    for (final relative in files) {
      if (!kAmprojEntryPrefixes.any(relative.startsWith)) continue;
      if (relative.endsWith('.amprojignore')) continue;
      entries[relative] = await AmFileSystem.readBytes('$directory/$relative');
    }
    return entries;
  }

  /// 导出为 `.amproj` + 伴生 `.amproj.sha256`。
  ///
  /// 先全量校验，失败直接拒绝（契约要求）。
  static Future<Map<String, Object?>> exportArchive(
    String directory, {
    String? outPath,
    bool skipValidation = false,
  }) async {
    final project = await AmprojProject.open(directory);
    if (!skipValidation) {
      final report = await project.validate();
      if (!report.ok) {
        throw AmException(
          'VALIDATION_FAILED',
          'export refused: ${report.errorCount} error(s)',
          detail: <String, Object?>{
            'issues': report.issues.map((e) => e.toJson()).toList(),
          },
        );
      }
    }
    final target =
        outPath ?? '$directory/dist/${project.info.name}.$kAmprojExtension';
    final entries = await collectExportEntries(directory);
    final bytes = encodeAmprojArchive(entries);
    await AmFileSystem.writeBytes(target, bytes);
    final digest = sha256.convert(bytes).toString();
    await AmFileSystem.writeBytes('$target.sha256', utf8.encode('$digest\n'));
    return <String, Object?>{
      'path': target,
      'sha256': digest,
      'entry_count': entries.length,
      'bytes': bytes.length,
    };
  }

  /// 从 `.amproj` 解包为目录模式工程；校验失败回滚删除。
  static Future<Map<String, Object?>> importArchive(
    String source,
    String destination,
  ) async {
    if (await AmFileSystem.exists(destination)) {
      final existing = await AmFileSystem.listFiles(destination);
      if (existing.isNotEmpty) {
        throw AmException(
          'DEST_NOT_EMPTY',
          'destination directory is not empty: $destination',
        );
      }
    }
    final bytes = await AmFileSystem.readBytes(source);
    final entries = decodeAmprojArchive(bytes);
    await AmFileSystem.ensureDirectory(destination);
    try {
      for (final entry in entries.entries) {
        if (!kAmprojEntryPrefixes.any(entry.key.startsWith)) continue;
        await AmFileSystem.writeBytes('$destination/${entry.key}', entry.value);
      }
      final project = await AmprojProject.fromSource(
        DirectoryAmprojSource(destination),
      );
      final report = await project.validate();
      if (!report.ok) {
        throw AmException(
          'VALIDATION_FAILED',
          'import rolled back: ${report.errorCount} error(s)',
          detail: <String, Object?>{
            'issues': report.issues.map((e) => e.toJson()).toList(),
          },
        );
      }
      return <String, Object?>{
        'path': destination,
        'name': project.info.name,
        'entry_count': entries.length,
      };
    } on AmException {
      // 解析 / 校验失败一律回滚，绝不留下半成品目录。
      await AmFileSystem.deleteRecursive(destination);
      rethrow;
    } on Object catch (error) {
      await AmFileSystem.deleteRecursive(destination);
      throw AmException('IMPORT_FAILED', '$error');
    }
  }

  /// 把内存中的文档写入 `spec/model.json`。
  static Future<void> writeModel(
    String directory,
    Map<String, Object?> document,
  ) => writeSpecFile(directory, 'spec/model.json', encodeJson(document));

  /// `.amprojignore`（gitignore 语法）附加排除规则。
  static Future<void> writeIgnoreFile(
    String directory,
    List<String> patterns,
  ) => AmFileSystem.writeText(
    '$directory/.amprojignore',
    '${patterns.join('\n')}\n',
  );
}
