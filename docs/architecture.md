# 查看器架构

```
lib/
├── app.dart / main.dart          应用根：EasyLocalization、主题、ProviderScope、全局错误界面
├── core/
│   ├── engine/                   引擎抽象 + 真实引擎适配 + 内置降级实现（不含任何 UI）
│   │   ├── am_engine.dart        抽象接口 AmEngine / AmEngineBackend / 响应解包
│   │   ├── am_types.dart         契约数据类型（能力、校验、节点/混合/插值枚举）
│   │   ├── ffi_am_engine*.dart   FFI 动态库探测（io / stub 条件导出）
│   │   ├── contract_am_engine.dart  UI 方法面 → 真实引擎 C ABI 的翻译层
│   │   ├── local_am_engine.dart  内置引擎：完整实现 kLocalEngineMethods
│   │   ├── local_document.dart   文档模型 + 全部 doc.command 操作 + 撤销栈
│   │   ├── local_eval.dart       求值：关键形插值、变形器级联、命中测试
│   │   ├── am_scene_provider.dart 降级画家需要的场景接口
│   │   └── engine_bootstrap.dart 启动策略：FFI → 内置，绝不抛给 UI
│   ├── project/                  `.amproj` 读写（目录模式 ⇄ ZIP+Deflate）
│   ├── state/                    Riverpod 控制器（设置/文档/工程/运行时/UI/引擎）
│   ├── layout/                   面板框（标题栏 + 内容 + 动作）
│   ├── theme/                    AppTokens / AppTheme（深色优先）
│   ├── i18n/                     语言列表、`context.t()`、格式化工具
│   ├── shortcuts/                快捷键注册表（字符串 ↔ SingleActivator）
│   └── platform/                 文件选择与保存（file_picker 封装）
└── features/
    ├── shell/                    外壳：顶栏、启动页、状态栏、面板标签、设置/关于对话框
    ├── canvas/                   画布：视图交互、降级画家、截图
    ├── panels/                   8 个功能面板（动作/表情/参数/效果/性能/渲染/导出/集成）
    └── common/                   通用控件
```

## 引擎接入

查看器**不依赖 Flutter 插件**，直接调用引擎的 C ABI（`anima.dll` /
`libanima.dylib` / `libanima.so`，可用 `ANIMA_ENGINE_LIB` 覆盖）。

```
UI 面板 ──► ContractAmEngine ──► am_call(engine, method, params_json)
                    │
                    └─► LocalAmEngine（引擎缺失时接管，功能等价，仅无纹理桥）
```

`ContractAmEngine` 把查看器的 UI 方法面翻译成引擎的真实方法：

| UI 调用 | 翻译 |
| --- | --- |
| `project.open {path}` | `project.load` → `project.spec`（取 `model.name`） |
| `doc.query {path}` | 由 `project.spec` 缓存的模型表提供 |
| `doc.undo` / `doc.redo` | 调引擎后**重新拉 spec**，否则层级表是旧的 |
| `runtime.step {dt}` | `runtime.advance` → `runtime.scene` → `AmScene` |
| `runtime.seek` | `runtime.set_time` |
| `runtime.play_motion` | `motion.play` |
| `runtime.blink/breath/lipsync` | 引擎无此方法，**宿主侧**按参数名写 `runtime.set_param` |
| `project.export/import` | 引擎无压缩包 API → 宿主侧 `AmprojWriter` |
| `physics.query/set` | 宿主侧状态 + `physics.info/step/reset` |
| `diagnostics.stats` | 直通；字段名拼成 `stat.<field>` 文案 |

引擎不可用时：`engine_bootstrap.dart` 返回内置实现并给出
`warningKey = 'engine.warning.fallback'`，界面显示横幅；**任何路径都不抛给 UI**。

## 画布

当前画布是**降级画家**（`CustomPaint` + `AmSceneProvider.buildScene()`）：
几何由适配层从 `runtime.scene` 解析成 `AmScene` 后重绘。
`renderer.*` 只维护视图状态（缩放/平移/翻转/像素比）。

走引擎真实帧的路径已就绪但未接线：`FfiAmEngine.copyFrame()` 封装了
`am_frame_copy`（先探测容量再拷贝），配合 `renderer.render` +
`ui.decodeImageFromPixels` 即可显示引擎画面。之所以默认不启用，是因为
ABI 尚未导出共享纹理句柄，逐帧回读 + 解码在交互场景下开销明显；
详见 `docs/engine-requests.md`。

## 面板

| 标签 | 内容 |
| --- | --- |
| 动作 | 动作列表、播放/暂停、循环、速度、淡入淡出、时间显示 |
| 表情 | 表情列表与切换、姿势切换、清除表情 |
| 参数 | 只读滑杆（拖动实时写入引擎，不写回工程）、重置 |
| 效果 | 物理开关、眨眼/呼吸/口型开关与幅度 |
| 性能 | 后端、引擎/SDK 版本、`diagnostics.stats`、能力清单 |
| 渲染 | 渲染质量、像素比、网格/参考线、截图 |
| 导出 | 运行时资源包（ZIP）、`.amproj` 再导出、上次导出路径与校验和 |
| 集成 | C / Dart / JS 三种接入代码片段 + 一键复制 |

## i18n

`easy_localization`，`assets/translations/{zh-CN,en-US}.json`，默认跟随系统语言，
可手动切换并持久化。覆盖率由 `tool/check_translations.ps1` 强制校验：

```
used=167 zh=167 en=167   missing=0 onlyZh=0 onlyEn=0 empty=0 extra=0   → RESULT: OK
```

脚本从 `lib/**` 按 UI 命名空间白名单提取被引用的键，任何「源码用了但翻译缺」
或「翻译有但源码不用」都会让校验失败。

> 该脚本含中文注释，必须保存为 **UTF-8 with BOM**，否则 Windows PowerShell 5.1
> 会按 ANSI 解码而解析失败。
