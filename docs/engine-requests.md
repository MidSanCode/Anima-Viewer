# 引擎对接需求（查看器 → engine）

> 状态：**原生引擎已交付并接通**。查看器通过 `anima.dll` 的 C ABI 直接驱动真实引擎；
> `lib/core/engine/local_am_engine.dart` 保留为降级路径。
>
> 通用 ABI 说明、信封格式、动态库探测顺序见 `editor/docs/engine-requests.md` 第 1 节
> （两个仓库同源，此处只记查看器特有与优先级更高的条目）。

---

## 1. 查看器最关心的缺口：外部纹理桥

查看器的核心是**显示**，因此这一条优先级最高。

现状：ABI 没有导出离屏帧的共享纹理句柄，画布只能用降级画家
（`CustomPaint` + `AmSceneProvider`）重绘几何。`renderer.render` 与
`am_frame_copy` 都可用，`FfiAmEngine.copyFrame()` 也已封装好「先探测容量再拷贝」，
但逐帧 `am_frame_copy` + `decodeImageFromPixels` 在交互场景下开销明显，
不适合作为默认路径。

期望（二选一）：

1. **首选**：暴露共享纹理句柄（wgpu → D3D11 共享 NT 句柄 →
   `FlutterDesktopTextureRegistrar`），画布改用 `Texture` widget，零拷贝；
2. **次选**：明确把 `renderer.render` + `am_frame_copy` +
   `decodeImageFromPixels` 定为受支持路径，并说明目标帧率与建议的
   帧尺寸上限，查看器据此实现按需重绘。

在此之前，`renderer.*` 只用于维护视图状态（缩放/平移/翻转/像素比/画布尺寸）。

## 2. 查看器特有的方法翻译

| UI 调用 | 引擎侧 | 说明 |
| --- | --- | --- |
| `runtime.play_motion {motion, loop, speed, fadeIn, fadeOut}` | `motion.play` | 淡入淡出由宿主侧插值 |
| `runtime.stop_motion` | `motion.stop` | — |
| `runtime.seek {time}` | `runtime.set_time` | 不得改变 `playing` 状态 |
| `runtime.set_param` / `set_params` | `runtime.set_param` | 逐参数串行写入 |
| `runtime.step {dt}` | `runtime.advance` + `runtime.scene` | 一步一取场景 |
| `runtime.blink` / `breath` / `lipsync` | **无** | 宿主侧按 `EyeOpen` / `Breath` / `MouthOpen` 参数名写入 |
| `physics.query` / `physics.set` | `physics.info` / `physics.step` / `physics.reset` | 开关与幅度为宿主侧状态 |
| `project.export` / `project.import` | **无** | 宿主侧 `AmprojWriter` 处理 ZIP |
| `project.create {dir, name, ...}` | `project.new` + `project.save` | 引擎无 `project.create`：宿主先写 `info.json`/`registry.json`，再让引擎建模型并写出 spec；之后补一个 `node_create` 根部件以对齐内置实现 |
| `renderer.create` / `destroy` / `frame` / `pick` / `measure` | **无** | 适配层在宿主侧模拟 |
| `diagnostics.stats` | 直通 | 字段名拼成 `stat.<field>` 文案 |

## 3. 仍需引擎侧确认

| # | 条目 | 现状 | 期望 |
| --- | --- | --- | --- |
| 1 | 外部纹理桥 | 见第 1 节 | 暴露共享纹理句柄，或确认回读路径 |
| 2 | `diagnostics.stats` 字段稳定性 | `nodes` / `parameters` / `textures` / `motions` / `expressions` / `physics` / `drawables` / `revision` / `dirty` / `frame` | 性能面板按 `stat.<field>` 取文案，请保持字段名稳定 |
| 3 | 口型同步的音频喂入 | 引擎无音频接口 | 若引擎愿意接管，暴露 `runtime.lipsync {amplitude}`；否则维持宿主侧驱动 |
| 4 | `project.load` / `project.save` 回传 `name` + `display_name` | 只有 `path/nodes/parameters/motions/expressions` | 回传 `model.name` 与 `info.display_name`，省掉宿主自己记名字 |
| 5 | `doc.undo`/`doc.redo` 后的缓存失效 | 引擎行为正确 | 适配层已自行重拉 `project.spec`；若引擎能回传结构版本号可省一次拉取 |
| 6 | 暴露 `project.create` | `am-format` 有 `Project::create` 但 `am_call` 没暴露 | 直接暴露建目录 + 空 spec 的方法，宿主就不必自己写 `info.json` |
| 7 | `project.save {path}` 对已存在目录的语义 | 目录存在 → `Project::open`（要求 `info.json`，否则报错）；不存在 → `Project::create` | 建议目录存在但为空时也走 `Project::create` |

已确认的语义：

* `min_sdk` 是**格式版本整数**（`integer, minimum 1`），不是 semver 字符串。
* `spec/model.json` 的 `nodes` 是**数组**（字段 `kind`）。
* 动作 spec 字段为 `id/name/duration/looping/curves[].parameter/keys[].time,value`；
  适配层映射到 UI 的 `loop` / `param`。

## 4. 打包

`pubspec.yaml` 中的 `anima_engine` 路径依赖**保持注释**：真实接入走 C ABI，
不依赖 Flutter 插件；引擎未就绪时 `flutter pub get` 也不会失败。
