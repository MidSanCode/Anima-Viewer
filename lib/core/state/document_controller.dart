/// 文档层：`doc.query` 缓存 + `doc.command` 唯一写入口 + 撤销/重做。
///
/// AE1-4：所有派生数据都按 `doc.revision` 失效，避免全量重查。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/am_types.dart';
import 'engine_providers.dart';
import 'ui_controllers.dart';

/// 文档快照。
class DocumentState {
  const DocumentState({
    this.revision = 0,
    this.rootId,
    this.nodes = const <String, Map<String, Object?>>{},
    this.parameters = const <String, Map<String, Object?>>{},
    this.artPath = const <String>[],
    this.motions = const <Object?>[],
    this.expressions = const <Object?>[],
    this.physics = const <Object?>[],
    this.pose = const <Object?>[],
    this.settings = const <String, Object?>{},
    this.config = const <String, Object?>{},
    this.atlas = const <Object?>[],
    this.canUndo = false,
    this.canRedo = false,
    this.history = const <String>[],
    this.loaded = false,
  });

  final int revision;
  final String? rootId;
  final Map<String, Map<String, Object?>> nodes;
  final Map<String, Map<String, Object?>> parameters;
  final List<String> artPath;
  final List<Object?> motions;
  final List<Object?> expressions;
  final List<Object?> physics;
  final List<Object?> pose;
  final Map<String, Object?> settings;
  final Map<String, Object?> config;
  final List<Object?> atlas;
  final bool canUndo;
  final bool canRedo;
  final List<String> history;
  final bool loaded;

  /// 层级树根节点 id 的稳定排序（预序遍历由 `children` 决定）。
  Map<String, Object?>? node(String? id) => id == null ? null : nodes[id];

  List<String> childrenOf(String id) =>
      asJsonList(nodes[id]?['children']).map((e) => '$e').toList();

  /// 所有部件/可绘制节点（预序遍历）。
  List<String> flatten() {
    final result = <String>[];
    void walk(String id) {
      result.add(id);
      for (final child in childrenOf(id)) {
        walk(child);
      }
    }

    final root = rootId;
    if (root != null && nodes.containsKey(root)) walk(root);
    return result;
  }

  /// 某节点可用的参数分组。
  Map<String, List<String>> get parameterGroups {
    final groups = <String, List<String>>{};
    for (final entry in parameters.entries) {
      final group = '${entry.value['group'] ?? 'ParamGroup'}';
      groups.putIfAbsent(group, () => <String>[]).add(entry.key);
    }
    return groups;
  }
}

/// 文档控制器。
class DocumentController extends Notifier<DocumentState> {
  @override
  DocumentState build() => const DocumentState();

  /// 从引擎加载全部摘要（打开工程 / 撤销重做后调用）。
  Future<void> load() async {
    final engine = ref.read(engineProvider);
    try {
      final hierarchy = await engine.call('doc.query', <String, Object?>{
        'path': 'hierarchy',
      });
      final parameters = await engine.call('doc.query', <String, Object?>{
        'path': 'parameters',
      });
      final motions = await engine.call('doc.query', <String, Object?>{
        'path': 'motions',
      });
      final expressions = await engine.call('doc.query', <String, Object?>{
        'path': 'expressions',
      });
      final settings = await engine.call('doc.query', <String, Object?>{
        'path': 'settings',
      });
      final config = await engine.call('doc.query', <String, Object?>{
        'path': 'config',
      });
      final pose = await engine.call('doc.query', <String, Object?>{
        'path': 'pose',
      });
      final physics = await engine.call('doc.query', <String, Object?>{
        'path': 'physics',
      });
      final atlas = await engine.call('doc.query', <String, Object?>{
        'path': 'atlas',
      });
      final history = await engine.call('doc.history');
      final revision = await engine.call('doc.revision');

      final rawNodes = asJsonMap(hierarchy['nodes']);
      state = DocumentState(
        revision: asInt(revision['revision']),
        rootId: hierarchy['root'] as String?,
        nodes: <String, Map<String, Object?>>{
          for (final entry in rawNodes.entries)
            entry.key: asJsonMap(entry.value),
        },
        parameters: <String, Map<String, Object?>>{
          for (final entry in asJsonMap(parameters['parameters']).entries)
            entry.key: asJsonMap(entry.value),
        },
        artPath: asJsonList(hierarchy['art_path']).map((e) => '$e').toList(),
        motions: asJsonList(motions['motions']),
        expressions: asJsonList(expressions['expressions']),
        physics: asJsonList(physics['physics']),
        pose: asJsonList(pose['pose']),
        settings: asJsonMap(settings['settings']),
        config: asJsonMap(config['config']),
        atlas: asJsonList(atlas['atlas']),
        canUndo: asBool(history['can_undo']),
        canRedo: asBool(history['can_redo']),
        history: asJsonList(history['entries']).map((e) => '$e').toList(),
        loaded: true,
      );
    } on AmException catch (error) {
      ref
          .read(notificationsProvider.notifier)
          .error(
            'notice.error.engineCall',
            args: <String, String>{'code': error.code, 'method': 'doc.query'},
            detail: error.message,
          );
    }
  }

  /// 执行命令（唯一写入口）。失败时提示并保持状态不变。
  Future<int?> dispatch(
    String op, [
    Map<String, Object?> params = const <String, Object?>{},
  ]) async {
    final engine = ref.read(engineProvider);
    try {
      final result = await engine.call('doc.command', <String, Object?>{
        'command': <String, Object?>{'op': op, ...params},
      });
      await load();
      return asInt(result['revision']);
    } on AmException catch (error) {
      ref
          .read(notificationsProvider.notifier)
          .error(
            'notice.error.commandFailed',
            args: <String, String>{'op': op, 'code': error.code},
            detail: error.message,
          );
      return null;
    }
  }

  Future<void> undo() async {
    final engine = ref.read(engineProvider);
    try {
      await engine.call('doc.undo');
      await load();
    } on AmException catch (error) {
      ref
          .read(notificationsProvider.notifier)
          .warn(
            'notice.error.engineCall',
            args: <String, String>{'code': error.code, 'method': 'doc.undo'},
            detail: error.message,
          );
    }
  }

  Future<void> redo() async {
    final engine = ref.read(engineProvider);
    try {
      await engine.call('doc.redo');
      await load();
    } on AmException catch (error) {
      ref
          .read(notificationsProvider.notifier)
          .warn(
            'notice.error.engineCall',
            args: <String, String>{'code': error.code, 'method': 'doc.redo'},
            detail: error.message,
          );
    }
  }

  /// 批量执行（宏 / 复合操作）。
  Future<void> dispatchAll(List<Map<String, Object?>> commands) async {
    for (final command in commands) {
      final op = '${command['op'] ?? ''}';
      if (op.isEmpty) continue;
      final engine = ref.read(engineProvider);
      try {
        await engine.call('doc.command', <String, Object?>{'command': command});
      } on AmException catch (error) {
        ref
            .read(notificationsProvider.notifier)
            .error(
              'notice.error.commandFailed',
              args: <String, String>{'op': op, 'code': error.code},
              detail: error.message,
            );
        break;
      }
    }
    await load();
  }
}

final documentProvider = NotifierProvider<DocumentController, DocumentState>(
  DocumentController.new,
);

/// 当前文档修订号。
final revisionProvider = Provider<int>(
  (ref) => ref.watch(documentProvider.select((s) => s.revision)),
);

/// 单个节点的完整数据（含 mesh / keyforms）。
final nodeDetailProvider = FutureProvider.family<Map<String, Object?>, String>((
  ref,
  nodeId,
) async {
  ref.watch(revisionProvider);
  final engine = ref.watch(engineProvider);
  try {
    final result = await engine.call('doc.query', <String, Object?>{
      'path': 'node',
      'id': nodeId,
    });
    return asJsonMap(result['node']);
  } on AmException {
    return const <String, Object?>{};
  }
});

/// 网格数据。
final meshProvider = FutureProvider.family<Map<String, Object?>, String>((
  ref,
  nodeId,
) async {
  ref.watch(revisionProvider);
  final engine = ref.watch(engineProvider);
  try {
    final result = await engine.call('doc.query', <String, Object?>{
      'path': 'mesh',
      'id': nodeId,
    });
    return asJsonMap(result['mesh']);
  } on AmException {
    return const <String, Object?>{};
  }
});

/// 关键形数据。
final keyformsProvider = FutureProvider.family<Map<String, Object?>, String>((
  ref,
  nodeId,
) async {
  ref.watch(revisionProvider);
  final engine = ref.watch(engineProvider);
  try {
    final result = await engine.call('doc.query', <String, Object?>{
      'path': 'keyforms',
      'id': nodeId,
    });
    return asJsonMap(result['keyforms']);
  } on AmException {
    return const <String, Object?>{};
  }
});

/// 统计信息（性能面板）。
final statsProvider = FutureProvider<Map<String, Object?>>((ref) async {
  ref.watch(revisionProvider);
  final engine = ref.watch(engineProvider);
  try {
    return await engine.call('diagnostics.stats');
  } on AmException {
    return const <String, Object?>{};
  }
});
