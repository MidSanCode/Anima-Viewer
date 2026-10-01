/// 工程层：新建 / 打开 / 保存 / 校验 / 导出 / 导入 / 最近列表 / 脏标记。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/am_engine.dart';
import '../engine/am_types.dart';
import '../project/amproj_fs.dart';
import 'document_controller.dart';
import 'engine_providers.dart';
import 'runtime_controller.dart';
import 'settings_controller.dart';
import 'ui_controllers.dart';

/// 工程状态。
class ProjectState {
  const ProjectState({
    this.path,
    this.name,
    this.displayName,
    this.dirty = false,
    this.busy = false,
    this.progress,
    this.progressKey,
    this.report,
    this.exportPath,
    this.exportSha256,
    this.sourceKind = 'none',
    this.projectDir,
  });

  /// 目录模式工程的根目录；`null` 表示尚未保存。
  final String? path;
  final String? name;
  final String? displayName;

  /// 是否有未保存改动。
  final bool dirty;

  /// 是否正在执行耗时操作。
  final bool busy;

  /// 进度 0..1（不确定时为 `null`）。
  final double? progress;

  /// 进度文案 i18n key。
  final String? progressKey;

  /// 最近一次校验结果。
  final AmValidationReport? report;

  /// 最近一次导出结果。
  final String? exportPath;
  final String? exportSha256;

  /// `none` / `directory` / `archive`。
  final String sourceKind;

  /// 工程本体目录（目录模式）。
  final String? projectDir;

  bool get hasProject => name != null || path != null;

  ProjectState copyWith({
    String? path,
    String? name,
    String? displayName,
    bool? dirty,
    bool? busy,
    double? progress,
    String? progressKey,
    AmValidationReport? report,
    String? exportPath,
    String? exportSha256,
    String? sourceKind,
    String? projectDir,
    bool clearPath = false,
    bool clearExport = false,
  }) => ProjectState(
    path: clearPath ? null : (path ?? this.path),
    name: name ?? this.name,
    displayName: displayName ?? this.displayName,
    dirty: dirty ?? this.dirty,
    busy: busy ?? this.busy,
    progress: progress ?? this.progress,
    progressKey: progressKey ?? this.progressKey,
    report: report ?? this.report,
    exportPath: clearExport ? null : (exportPath ?? this.exportPath),
    exportSha256: clearExport ? null : (exportSha256 ?? this.exportSha256),
    sourceKind: sourceKind ?? this.sourceKind,
    projectDir: projectDir ?? this.projectDir,
  );
}

/// 工程控制器。
class ProjectController extends Notifier<ProjectState> {
  @override
  ProjectState build() {
    // 引擎实例**真的**被换掉时（见 engine_providers.dart：只有「引擎模式」
    // 变化才会走到这里），新实例上什么都没打开。界面这边的工程状态却还在，
    // 于是「保存」会撞上 `PROJECT_NOT_OPEN` —— 看起来像“工程明明开着却说没
    // 开”。这里把已打开的目录工程重新挂到新引擎上，让两边重新一致。
    ref.listen<AmEngine>(engineProvider, (previous, next) {
      if (previous == null || identical(previous, next)) return;
      final current = state;
      final path = current.projectDir;
      if (path == null || current.sourceKind != 'directory') return;
      unawaited(_reattach(path));
    });
    return const ProjectState();
  }

  /// 把已打开的目录模式工程重新装载到当前的引擎实例上。
  Future<void> _reattach(String path) async {
    try {
      await ref.read(engineProvider).call('project.open', <String, Object?>{
        'path': path,
      });
      await ref.read(documentProvider.notifier).load();
      await ref.read(runtimeProvider.notifier).load();
    } on AmException catch (error) {
      _noticeError('project.open', error);
    }
  }

  void markDirty() {
    if (state.dirty) return;
    state = state.copyWith(dirty: true);
  }

  void clearDirty() => state = state.copyWith(dirty: false);

  /// 新建工程（需要目录模式；Web 端不可用）。
  Future<bool> create({
    required String directory,
    required String name,
    String displayName = '',
    String author = '',
  }) async {
    if (!AmFileSystem.supportsDirectories) {
      _notice('notice.project.webNoDirectory');
      return false;
    }
    state = state.copyWith(
      busy: true,
      progressKey: 'progress.project.creating',
      progress: null,
    );
    try {
      final engine = ref.read(engineProvider);
      final result = await engine.call('project.create', <String, Object?>{
        'dir': directory,
        'name': name,
        'display_name': displayName,
        'author': author,
      });
      state = ProjectState(
        path: '${result['path']}',
        name: '${result['name']}',
        displayName: '${result['display_name'] ?? name}',
        sourceKind: 'directory',
        projectDir: '${result['path']}',
      );
      await ref.read(documentProvider.notifier).load();
      await ref.read(runtimeProvider.notifier).load();
      await _remember('${result['path']}');
      ref
          .read(notificationsProvider.notifier)
          .success(
            'notice.project.created',
            args: <String, String>{'name': '${result['name']}'},
          );
      return true;
    } on AmException catch (error) {
      // 目录里已有工程时给一条明确的提示，而不是通用的「引擎调用失败」。
      if (error.code == 'PROJECT_EXISTS') {
        _notice('notice.project.exists');
      } else {
        _noticeError('project.create', error);
      }
      state = state.copyWith(busy: false);
      return false;
    }
  }

  /// 打开目录模式或压缩包模式工程。
  Future<bool> open(String path) async {
    state = state.copyWith(
      busy: true,
      progressKey: 'progress.project.opening',
      clearExport: true,
    );
    try {
      final engine = ref.read(engineProvider);
      final result = await engine.call('project.open', <String, Object?>{
        'path': path,
      });
      final isArchive = asBool(result['is_archive']);
      state = ProjectState(
        path: path,
        name: '${result['name']}',
        displayName: '${result['display_name'] ?? result['name']}',
        sourceKind: isArchive ? 'archive' : 'directory',
        projectDir: isArchive ? null : path,
      );
      await ref.read(documentProvider.notifier).load();
      await ref.read(runtimeProvider.notifier).load();
      await _remember(path);
      await validate();
      ref
          .read(notificationsProvider.notifier)
          .success(
            'notice.project.opened',
            args: <String, String>{'name': '${result['name']}'},
          );
      return true;
    } on AmException catch (error) {
      _noticeError('project.open', error);
      return false;
    } on Object catch (error) {
      _noticeUnexpected('project.open', error);
      return false;
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  Future<bool> save({String? saveAs}) async {
    if (!AmFileSystem.supportsDirectories && saveAs == null) {
      _notice('notice.project.webNoDirectory');
      return false;
    }
    state = state.copyWith(busy: true, progressKey: 'progress.project.saving');
    try {
      final engine = ref.read(engineProvider);
      final result = await engine.call('project.save', <String, Object?>{
        'save_as': ?saveAs,
      });
      state = state.copyWith(
        busy: false,
        dirty: false,
        path: '${result['path']}',
        projectDir: '${result['path']}',
        sourceKind: 'directory',
      );
      await _remember('${result['path']}');
      ref.read(notificationsProvider.notifier).success('notice.project.saved');
      return true;
    } on AmException catch (error) {
      _noticeError('project.save', error);
      return false;
    } on Object catch (error) {
      _noticeUnexpected('project.save', error);
      return false;
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  Future<AmValidationReport?> validate() async {
    state = state.copyWith(
      busy: true,
      progressKey: 'progress.project.validating',
    );
    try {
      final engine = ref.read(engineProvider);
      final result = await engine.call('project.validate');
      final report = AmValidationReport.fromJson(result);
      state = state.copyWith(busy: false, report: report);
      if (!report.ok) {
        ref
            .read(notificationsProvider.notifier)
            .warn(
              'notice.project.validationIssues',
              args: <String, String>{'count': '${report.errorCount}'},
            );
      }
      return report;
    } on AmException catch (error) {
      _noticeError('project.validate', error);
      return null;
    } on Object catch (error) {
      _noticeUnexpected('project.validate', error);
      return null;
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  Future<Map<String, Object?>?> export({String? outPath}) async {
    state = state.copyWith(
      busy: true,
      progressKey: 'progress.project.exporting',
    );
    try {
      final engine = ref.read(engineProvider);
      final result = await engine.call('project.export', <String, Object?>{
        'out_path': ?outPath,
      });
      state = state.copyWith(
        busy: false,
        dirty: false,
        exportPath: '${result['path']}',
        exportSha256: '${result['sha256']}',
      );
      ref
          .read(notificationsProvider.notifier)
          .success(
            'notice.project.exported',
            args: <String, String>{'path': '${result['path']}'},
          );
      return result;
    } on AmException catch (error) {
      if (error.code == 'VALIDATION_FAILED') {
        ref
            .read(notificationsProvider.notifier)
            .warn('notice.project.exportRejected', detail: error.message);
      } else {
        _noticeError('project.export', error);
      }
      return null;
    } on Object catch (error) {
      _noticeUnexpected('project.export', error);
      return null;
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  Future<bool> importPackage(String source, String destination) async {
    state = state.copyWith(
      busy: true,
      progressKey: 'progress.project.importing',
    );
    try {
      final engine = ref.read(engineProvider);
      final result = await engine.call('project.import', <String, Object?>{
        'source': source,
        'dest': destination,
      });
      state = state.copyWith(busy: false);
      ref
          .read(notificationsProvider.notifier)
          .success(
            'notice.project.imported',
            args: <String, String>{'path': '${result['path']}'},
          );
      await open('${result['path']}');
      return true;
    } on AmException catch (error) {
      _noticeError('project.import', error);
      return false;
    } on Object catch (error) {
      _noticeUnexpected('project.import', error);
      return false;
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  /// 关闭工程（清空引擎文档）。
  Future<void> close() async {
    final engine = ref.read(engineProvider);
    try {
      await engine.call('project.close');
    } on AmException {
      // 忽略。
    }
    ref.read(documentProvider.notifier).load();
    state = const ProjectState();
    await ref.read(runtimeProvider.notifier).load();
  }

  Future<void> _remember(String path) async {
    await ref
        .read(settingsProvider.notifier)
        .patch((current) => current.withRecent(path));
  }

  void _notice(String key) =>
      ref.read(notificationsProvider.notifier).warn(key);

  /// 非引擎异常（插件缺失 / 写盘失败 / 目录取不到）的统一提示。
  ///
  /// 这类错误以前会让 `busy` 卡住且界面毫无反应；现在既有可读提示，
  /// 也用 debugPrint 留下异常内容，便于排查。
  void _noticeUnexpected(String method, Object error) {
    debugPrint('[project.$method] 未预期的异常: $error');
    ref
        .read(notificationsProvider.notifier)
        .error(
          'notice.error.unexpected',
          args: <String, String>{'method': method},
        );
  }

  void _noticeError(String method, AmException error) {
    // `PROJECT_NOT_OPEN` 有专用文案（说清下一步怎么做）；其余走通用提示。
    // 否则用户只会看到「引擎调用 project.save 失败（PROJECT_NOT_OPEN）」。
    if (error.code == 'PROJECT_NOT_OPEN') {
      ref
          .read(notificationsProvider.notifier)
          .warn('notice.project.notOpen', detail: error.message);
      return;
    }
    ref
        .read(notificationsProvider.notifier)
        .error(
          'notice.error.engineCall',
          args: <String, String>{'code': error.code, 'method': method},
          detail: error.message,
        );
  }
}

final projectProvider = NotifierProvider<ProjectController, ProjectState>(
  ProjectController.new,
);

/// 最近打开的工程列表（来自设置）。
final recentProjectsProvider = Provider<List<String>>((ref) {
  return ref.watch(settingsProvider).value?.recentProjects ?? const <String>[];
});
