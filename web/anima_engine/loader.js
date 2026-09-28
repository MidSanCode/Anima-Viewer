// 引擎 wasm 加载器（Web）。
//
// 引擎产物（anima_wasm.js / anima_wasm_bg.wasm）由 CI 从引擎仓库的
// anima-engine-web.zip 解到本目录；未配置 ENGINE_WEB_URL 时它们不存在，
// 这里会静默失败，应用照常降级到内置实现。
//
// 用**动态 import** 而不是顶层 import：顶层 import 解析不到目标文件时是
// 链接期错误，`try/catch` 抓不住，整个模块会直接挂掉；动态 import 的失败
// 是可捕获的，于是「没有 wasm 也要能跑」这条约定在 Web 端同样成立。
try {
  const { default: init, Engine } = await import('./anima_wasm.js');
  await init();
  window.AnimaEngine = {
    create: () => new Engine(),
    version: () => Engine.version(),
  };
} catch (e) {
  window.AnimaEngine = null;
  window.AnimaEngineError = String(e);
  console.warn('[anima] wasm 引擎不可用，已降级到内置实现：', e);
}
// Dart 侧据此判断「wasm 就绪 / 未就绪」，避免靠轮询。
window.dispatchEvent(new Event('anima-engine-ready'));
