/// 引擎与派生能力 Provider。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/am_engine.dart';
import '../engine/am_scene_provider.dart';
import '../engine/am_types.dart';
import '../engine/engine_bootstrap.dart';
import 'settings_controller.dart';

/// 引擎启动结果（异步）。
///
/// **只依赖「引擎模式」这一个设置项。**
///
/// 不要写成 `await ref.watch(settingsProvider.future)`：那是一份整体快照，
/// 任何一次设置写入（自动保存、网格开关、主题、语言、面板布局、最近打开的
/// 工程……）都会改变它的值，于是本 Provider 被重建、`bootEngine` 再跑一遍，
/// **引擎实例被整体换成一张白纸**。后果不是报个错那么简单：
///
/// * 新实例上没有已打开的工程（适配器/内置实现的 `projectDir` 是空的），
///   下一次「保存」会失败成 `PROJECT_NOT_OPEN`；
/// * 适配器的影子文档被重置，未落盘的编辑与撤销历史一起消失。
///
/// 保存/打开/新建工程都会顺手写一次「最近打开」列表，所以「新建工程后
/// 第一次保存必失败」正是这条链路的典型症状。这里用 [selectAsync] 只挑选
/// `engineMode`：其余设置怎么变都不再牵动引擎。
final engineBootProvider = FutureProvider<EngineBootResult>((ref) async {
  final mode = await ref.watch(
    settingsProvider.selectAsync((settings) => settings.engineMode),
  );
  return bootEngine(forceLocal: mode == kEngineModeLocal);
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
