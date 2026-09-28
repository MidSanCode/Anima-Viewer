/// 引擎启动：先尝试 FFI 动态库，失败则降级到内置实现。
///
/// A0-4/A0-5：引擎不可用**绝不崩溃、绝不白屏**。降级原因通过
/// [EngineBootResult.warningKey] 交给 UI 显示为可读提示。
library;

import 'am_engine.dart';
import 'am_types.dart';
import 'contract_am_engine.dart';
import 'ffi_am_engine.dart';
import 'local_am_engine.dart';
import 'web_wasm_am_engine.dart';

/// 启动结果。
class EngineBootResult {
  const EngineBootResult({
    required this.engine,
    required this.warningKey,
    required this.notes,
  });

  final AmEngine engine;

  /// 需要展示给用户的提示（i18n key），无提示为 `null`。
  final String? warningKey;

  /// 附加诊断信息（显示在“关于/诊断”里）。
  final Map<String, Object?> notes;

  bool get usedFallback => engine.backend.isLocal;

  AmEngineBackend get backend => engine.backend;

  AmCapabilities get capabilities => engine.capabilities;
}

/// 候选动态库名与探测结果（诊断面板展示）。
String? lastProbedLibrary;

/// 启动引擎。
///
/// * `forceLocal`：设置页/测试用，强制内置实现；
/// * `document`：内置实现的初始文档（打开工程时注入）。
Future<EngineBootResult> bootEngine({
  int width = 1280,
  int height = 720,
  double devicePixelRatio = 1.0,
  bool forceLocal = false,
  Map<String, Object?>? document,
  bool demo = false,
  String? projectDir,
}) async {
  final notes = <String, Object?>{};

  if (!forceLocal) {
    // Web 端只能走 wasm；原生端这个工厂恒返回 null（见 web_wasm_am_engine_stub）。
    // 两条路径都把结果包成 ContractAmEngine，所以上面的 UI 完全无感。
    try {
      final wasm = await tryCreateWebWasmEngine(
        width: width,
        height: height,
        devicePixelRatio: devicePixelRatio,
      );
      if (wasm != null && wasm.isAvailable) {
        final contract = ContractAmEngine(wasm);
        await contract.initialize(
          width: width,
          height: height,
          devicePixelRatio: devicePixelRatio,
        );
        notes['backend'] = 'wasm';
        notes['capabilities'] = wasm.capabilities.methods.length;
        return EngineBootResult(
          engine: contract,
          warningKey: null,
          notes: notes,
        );
      }
      notes['wasm'] = 'module not loaded (no ENGINE_WEB_URL, or load failed)';
    } on AmException catch (error) {
      notes['wasm'] = '${error.code}: ${error.message}';
    } on Object catch (error) {
      notes['wasm'] = '$error';
    }

    try {
      final ffi = await tryCreateFfiEngine(
        width: width,
        height: height,
        devicePixelRatio: devicePixelRatio,
      );
      if (ffi != null && ffi.isAvailable) {
        // UI 方法面 → 引擎契约面 的适配器。
        final contract = ContractAmEngine(ffi);
        await contract.initialize(
          width: width,
          height: height,
          devicePixelRatio: devicePixelRatio,
        );
        notes['backend'] = 'ffi';
        notes['capabilities'] = ffi.capabilities.methods.length;
        return EngineBootResult(
          engine: contract,
          warningKey: null,
          notes: notes,
        );
      }
      notes['ffi'] = 'library not found or symbols missing';
    } on AmException catch (error) {
      notes['ffi'] = '${error.code}: ${error.message}';
    } on Object catch (error) {
      notes['ffi'] = '$error';
    }
  } else {
    notes['ffi'] = 'skipped (forced local)';
  }

  final local = LocalAmEngine(
    initialDocument: document,
    demo: demo,
    projectDir: projectDir,
  );
  await local.initialize(
    width: width,
    height: height,
    devicePixelRatio: devicePixelRatio,
  );
  notes['backend'] = 'local';
  notes['local_methods'] = kLocalEngineMethods.length;

  return EngineBootResult(
    engine: local,
    warningKey: forceLocal ? null : 'engine.warning.fallback',
    notes: notes,
  );
}
