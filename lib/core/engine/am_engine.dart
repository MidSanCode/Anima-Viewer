/// 引擎抽象层：编辑器/查看器只依赖这里的接口，不依赖任何具体实现。
///
/// 三个实现：
/// * [FfiAmEngine] —— 通过 `am_call` 调用原生动态库（引擎就绪后的正式路径）；
/// * `LocalAmEngine` —— 内置降级实现，引擎不可用时保证 UI 完整可用；
/// * 未来 agent1 的 Flutter 插件（外部纹理桥）通过
///   `AnimaEnginePluginBridge` 接入，见 `docs/engine-requests.md`。
library;

import 'dart:async';

import 'am_types.dart';

/// 引擎驱动方式的标签。
class AmEngineBackend {
  const AmEngineBackend(this.id, this.label, {this.detail = ''});

  /// `ffi` / `local` / `plugin`。
  final String id;

  /// 人读的名称（i18n key，例如 `engine.backend.local`）。
  final String label;

  final String detail;

  bool get isLocal => id == 'local';
}

/// 引擎调用入口。
///
/// 契约（tasks.md §3.1）只有一个真正的调用点：`am_call`。所有实现都必须
/// 把失败表达为 [AmException]，**绝不允许把异常抛给 UI 线程导致崩溃**。
abstract class AmEngine {
  /// 驱动方式。
  AmEngineBackend get backend;

  /// `system.capabilities` 的结果；未初始化时返回
  /// [AmCapabilities.unavailable]。
  AmCapabilities get capabilities;

  /// 引擎是否可用（初始化成功）。
  bool get isAvailable;

  /// 事件流（帧呈现 / 脏标记 / 错误 / 进度）。
  Stream<AmEvent> get events;

  /// 原生纹理信息；没有纹理桥时返回 `null`。
  AmTextureInfo? get textureInfo;

  /// 初始化：创建渲染目标并把能力拉回来。
  Future<void> initialize({int width, int height, double devicePixelRatio});

  /// 唯一调用入口。成功返回 `result` 对象，失败抛 [AmException]。
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?>? params,
  ]);

  /// 释放引擎与渲染目标。
  Future<void> dispose();
}

/// 解包契约响应 `{"ok":true,"result":{...}}`。
///
/// 引擎可能返回 `{"ok":true}`（无 result），此时返回空 map。
Map<String, Object?> unwrapAmResponse(String method, Object? decoded) {
  if (decoded is! Map) {
    throw AmException(
      'BAD_RESPONSE',
      'method $method returned a non-object response',
      detail: decoded,
    );
  }
  final map = decoded.map((k, v) => MapEntry('$k', v));
  final ok = map['ok'];
  if (ok == false) {
    final error = asJsonMap(map['error']);
    throw AmException(
      '${error['code'] ?? 'UNKNOWN'}',
      '${error['message'] ?? 'engine call failed'}',
      detail: error,
    );
  }
  final result = map['result'];
  if (result == null) return const <String, Object?>{};
  if (result is Map) return result.map((k, v) => MapEntry('$k', v));
  return <String, Object?>{'value': result};
}

/// 便捷扩展：把 `call` 的结果读成 `result` 里的一个键。
extension AmEngineCallX on AmEngine {
  Future<Map<String, Object?>> callChecked(
    String method, [
    Map<String, Object?>? params,
  ]) async {
    final result = await call(method, params);
    if (result['ok'] == false) {
      final error = asJsonMap(result['error']);
      throw AmException(
        '${error['code'] ?? 'UNKNOWN'}',
        '${error['message'] ?? 'engine call failed'}',
      );
    }
    return result;
  }
}
