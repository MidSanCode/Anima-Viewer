/// 引擎与派生能力 Provider。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/am_engine.dart';
import '../engine/am_scene_provider.dart';
import '../engine/am_types.dart';
import '../engine/engine_bootstrap.dart';
import 'settings_controller.dart';

/// 引擎启动结果（异步）。
final engineBootProvider = FutureProvider<EngineBootResult>((ref) async {
  final settings = await ref.watch(settingsProvider.future);
  return bootEngine(forceLocal: settings.engineMode == 'local');
});

/// 已就绪的引擎。**只在启动完成后读取**（外壳负责门控）。
final engineProvider = Provider<AmEngine>((ref) {
  final boot = ref.watch(engineBootProvider);
  return boot.requireValue.engine;
});

/// 启动结果的同步视图（用于错误横幅 / 诊断）。
final engineStatusProvider = Provider<EngineBootResult>((ref) {
  return ref.watch(engineBootProvider).requireValue;
});

/// 引擎能力。
final engineCapabilitiesProvider = Provider<AmCapabilities>((ref) {
  return ref.watch(engineProvider).capabilities;
});

/// 引擎事件流。
final engineEventsProvider = StreamProvider<AmEvent>((ref) {
  return ref.watch(engineProvider).events;
});

/// 降级场景提供者（仅内置引擎实现；否则为 `null`）。
final sceneProviderProvider = Provider<AmSceneProvider?>((ref) {
  final engine = ref.watch(engineProvider);
  if (engine is AmSceneProvider) return engine as AmSceneProvider;
  return null;
});

/// 原生纹理信息（纹理桥可用时画布走 `Texture` widget）。
final engineTextureProvider = Provider<AmTextureInfo?>((ref) {
  return ref.watch(engineProvider).textureInfo;
});

/// 能力探测：某方法是否可用（缺方法时必须降级而不是崩溃）。
bool engineSupports(WidgetRef ref, String method) =>
    ref.watch(engineCapabilitiesProvider).supports(method);
