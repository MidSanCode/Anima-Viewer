/// 降级画布接口：当渲染纹理桥不可用时，UI 仍需要拿到“画什么”。
///
/// 只有内置引擎（`LocalAmEngine`）实现本接口。引擎的正式路径永远是
/// `Texture` widget + `am_renderer_texture_info`，本接口仅用于降级绘制，
/// 让编辑器/查看器在引擎交付前完全可用。
library;

import 'dart:ui' show Offset;

import 'local_eval.dart';

/// 视图状态（世界坐标 ↔ 屏幕坐标）。
class AmViewState {
  const AmViewState({
    this.pan = const Offset(0, 0),
    this.zoom = 1.0,
    this.flipX = false,
    this.flipY = false,
    this.canvasWidth = 1280,
    this.canvasHeight = 720,
  });

  final Offset pan;
  final double zoom;
  final bool flipX;
  final bool flipY;
  final double canvasWidth;
  final double canvasHeight;

  AmViewState copyWith({
    Offset? pan,
    double? zoom,
    bool? flipX,
    bool? flipY,
    double? canvasWidth,
    double? canvasHeight,
  }) => AmViewState(
    pan: pan ?? this.pan,
    zoom: zoom ?? this.zoom,
    flipX: flipX ?? this.flipX,
    flipY: flipY ?? this.flipY,
    canvasWidth: canvasWidth ?? this.canvasWidth,
    canvasHeight: canvasHeight ?? this.canvasHeight,
  );

  /// 世界坐标 → 屏幕坐标（原点画布中心、Y 轴向上 → 屏幕 Y 向下）。
  Offset worldToScreen(Offset world) => Offset(
    canvasWidth / 2 + (world.dx * (flipX ? -1 : 1) + pan.dx) * zoom,
    canvasHeight / 2 - (world.dy * (flipY ? -1 : 1) + pan.dy) * zoom,
  );

  /// 屏幕坐标 → 世界坐标。
  Offset screenToWorld(Offset screen) {
    final x = (screen.dx - canvasWidth / 2) / zoom - pan.dx;
    final y = -(screen.dy - canvasHeight / 2) / zoom - pan.dy;
    return Offset(flipX ? -x : x, flipY ? -y : y);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'pan': <Object?>[pan.dx, pan.dy],
    'zoom': zoom,
    'flip_x': flipX,
    'flip_y': flipY,
    'canvas': <Object?>[canvasWidth, canvasHeight],
  };
}

/// 提供可绘制场景的能力（降级路径）。
abstract class AmSceneProvider {
  /// 当前参数值（参数 id → 值）。
  Map<String, double> get paramValues;

  /// 当前视图状态。
  AmViewState get view;

  /// 背景色 `[r, g, b, a]`，各分量 0..1。
  List<double> get background;

  /// 正在播放的动作名。
  String? get playingMotion;

  /// 是否正在播放。
  bool get isPlaying;

  /// 当前表情名。
  String? get expression;

  /// 构建当前场景（世界坐标网格）。
  AmScene buildScene({
    bool includeHidden = false,
    List<int> selectedVertices = const <int>[],
    String? selectedNode,
  });

  /// 用指定参数值构建场景（洋葱皮、预览用）。
  AmScene buildSceneWith({
    required Map<String, double> params,
    bool includeHidden = false,
    String? selectedNode,
  });
}
