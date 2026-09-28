/// Web 端 wasm 引擎入口的条件导出。
///
/// * 原生平台 → [webWasmStub]（恒返回 `null`，因为没有 wasm 运行时）；
/// * Web  平台 → 真正的 wasm 适配器（经 `dart:js_interop` 驱动引擎的
///   wasm-bindgen 产物）。
///
/// 上层只允许 `import 'web_wasm_am_engine.dart'`；直接 import 具体实现会让
/// 原生构建碰上 `dart:js_interop` / `package:web` 而失败。
library;

export 'web_wasm_am_engine_stub.dart'
    if (dart.library.js_interop) 'web_wasm_am_engine_web.dart';
