/// 画布绘制：降级场景 + 辅助线 + 选择/手柄覆盖层。
///
/// 引擎纹理桥可用时这里不会被使用（画布直接用 `Texture` widget）；
/// 引擎未就绪时，本文件让模型、网格、变形器手柄、洋葱皮全部可见可交互。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/engine/am_types.dart';
import '../../core/engine/local_eval.dart';
import '../../core/state/ui_controllers.dart';
import '../../core/theme/app_theme.dart';

/// 洋葱皮幽灵帧。
class OnionGhost {
  const OnionGhost({
    required this.scene,
    required this.opacity,
    required this.color,
  });

  final AmScene scene;
  final double opacity;
  final Color color;
}

/// 画布绘制选项。
class CanvasPaintOptions {
  const CanvasPaintOptions({
    this.showGrid = false,
    this.showGuides = true,
    this.showWireframe = true,
    this.showVertices = true,
    this.showHandles = true,
    this.showBounds = false,
    this.gridSpacing = 50,
    this.gridDivisions = 4,
    this.background = const Color(0x00000000),
    this.selectedVertices = const <int>[],
    this.selectedNode,
    this.ghosts = const <OnionGhost>[],
    this.hoverNode,
    this.showDeformers = true,
  });

  final bool showGrid;
  final bool showGuides;
  final bool showWireframe;
  final bool showVertices;
  final bool showHandles;
  final bool showBounds;
  final double gridSpacing;
  final int gridDivisions;
  final Color background;
  final List<int> selectedVertices;
  final String? selectedNode;
  final List<OnionGhost> ghosts;
  final String? hoverNode;
  final bool showDeformers;
}

/// 场景绘制器。
class CanvasScenePainter extends CustomPainter {
  CanvasScenePainter({
    required this.scene,
    required this.viewport,
    required this.tokens,
    required this.options,
  });

  final AmScene scene;
  final ViewportState viewport;
  final AppTokens tokens;
  final CanvasPaintOptions options;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, Paint()..color = options.background);

    if (options.showGrid) {
      _paintGrid(canvas, size);
    }
    if (options.showGuides) {
      _paintGuides(canvas, size);
    }

    for (final ghost in options.ghosts) {
      _paintGhost(canvas, ghost);
    }

    for (final drawable in scene.drawables) {
      _paintDrawable(canvas, drawable);
    }

    if (options.showDeformers) {
      _paintDeformers(canvas);
    }

    if (options.showVertices) {
      _paintVerticesAll(canvas);
    }

    if (options.showBounds) {
      _paintBounds(canvas);
    }
  }

  void _paintGrid(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = tokens.gridLine
      ..strokeWidth = 1;
    final spacing = options.gridSpacing * viewport.zoom;
    if (spacing < 4) return;
    final center = Offset(size.width / 2, size.height / 2);
    final originX = center.dx + viewport.pan.dx * viewport.zoom;
    final originY = center.dy - viewport.pan.dy * viewport.zoom;
    final divisions = math.max(1, options.gridDivisions);
    final step = spacing / divisions;
    var x = originX % step;
    while (x < size.width) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      x += step;
    }
    var y = originY % step;
    while (y < size.height) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      y += step;
    }
  }

  void _paintGuides(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = tokens.guideLine
      ..strokeWidth = 1;
    final center = Offset(size.width / 2, size.height / 2);
    final originX = center.dx + viewport.pan.dx * viewport.zoom;
    final originY = center.dy - viewport.pan.dy * viewport.zoom;
    canvas.drawLine(Offset(originX, 0), Offset(originX, size.height), paint);
    canvas.drawLine(Offset(0, originY), Offset(size.width, originY), paint);
  }

  void _paintGhost(Canvas canvas, OnionGhost ghost) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = ghost.color.withValues(alpha: ghost.opacity);
    for (final drawable in ghost.scene.drawables) {
      final path = _pathOf(drawable, worldToScreen: viewport.worldToScreen);
      canvas.drawPath(path, paint);
    }
  }

  void _paintDrawable(Canvas canvas, AmSceneDrawable drawable) {
    if (!drawable.visible) return;
    final path = _pathOf(drawable, worldToScreen: viewport.worldToScreen);
    final selected = options.selectedNode == drawable.id;
    final hovered = options.hoverNode == drawable.id;

    // 纹理尚未接入时用稳定的占位色区分不同绘制对象。
    final baseColor = _colorOf(drawable.id);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.fill
        ..color = baseColor.withValues(
          alpha: (0.22 + 0.5 * drawable.opacity).clamp(0.0, 0.85),
        ),
    );

    if (options.showWireframe) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.7
          ..color = baseColor.withValues(alpha: 0.75),
      );
    }

    if (selected || hovered) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = selected ? 1.8 : 1.2
          ..color = selected
              ? tokens.selectionStroke
              : tokens.accentSecondary.withValues(alpha: 0.8),
      );
    }
  }

  void _paintVertices(Canvas canvas, AmSceneDrawable drawable) {
    if (!drawable.visible) return;
    final paint = Paint()..color = tokens.handleFill;
    final selectedPaint = Paint()..color = tokens.selectionStroke;
    final selected = options.selectedVertices.toSet();
    for (var i = 0; i < drawable.vertices.length; i++) {
      final screen = viewport.worldToScreen(drawable.vertices[i]);
      final isSelected = selected.contains(i);
      canvas.drawCircle(
        screen,
        isSelected ? 3.6 : 2.2,
        isSelected ? selectedPaint : paint,
      );
    }
  }

  void _paintVerticesAll(Canvas canvas) {
    // 顶点只在“当前节点”上显示，避免画面噪声。
    final target = options.selectedNode;
    for (final drawable in scene.drawables) {
      if (target != null && drawable.id != target) continue;
      _paintVertices(canvas, drawable);
    }
  }

  void _paintDeformers(Canvas canvas) {
    for (final deformer in scene.deformers) {
      if (!deformer.visible) continue;
      final selected = options.selectedNode == deformer.id;
      if (deformer.kind == AmNodeKind.warpDeformer) {
        _paintWarp(canvas, deformer, selected);
      } else if (deformer.kind == AmNodeKind.rotationDeformer) {
        _paintRotation(canvas, deformer, selected);
      }
    }
  }

  void _paintWarp(Canvas canvas, AmSceneDeformer deformer, bool selected) {
    final rows = deformer.rows;
    final cols = deformer.cols;
    if (rows <= 0 || cols <= 0) return;
    final points = deformer.controlPoints;
    if (points.length != (rows + 1) * (cols + 1)) return;

    final gridPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = selected ? 1.0 : 0.6
      ..color = (selected ? tokens.selectionStroke : tokens.accentSecondary)
          .withValues(alpha: selected ? 0.9 : 0.45);
    for (var r = 0; r <= rows; r++) {
      final path = Path();
      for (var c = 0; c <= cols; c++) {
        final screen = viewport.worldToScreen(points[r * (cols + 1) + c]);
        if (c == 0) {
          path.moveTo(screen.dx, screen.dy);
        } else {
          path.lineTo(screen.dx, screen.dy);
        }
      }
      canvas.drawPath(path, gridPaint);
    }
    for (var c = 0; c <= cols; c++) {
      final path = Path();
      for (var r = 0; r <= rows; r++) {
        final screen = viewport.worldToScreen(points[r * (cols + 1) + c]);
        if (r == 0) {
          path.moveTo(screen.dx, screen.dy);
        } else {
          path.lineTo(screen.dx, screen.dy);
        }
      }
      canvas.drawPath(path, gridPaint);
    }

    if (!options.showHandles) return;
    for (final point in points) {
      final screen = viewport.worldToScreen(point);
      canvas.drawCircle(
        screen,
        selected ? 3.4 : 2.6,
        Paint()..color = selected ? tokens.selectionStroke : tokens.handleFill,
      );
      canvas.drawCircle(
        screen,
        selected ? 3.4 : 2.6,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = tokens.handleStroke,
      );
    }
  }

  void _paintRotation(Canvas canvas, AmSceneDeformer deformer, bool selected) {
    final pivot = viewport.worldToScreen(deformer.pivot);
    final radius = 42.0 * viewport.zoom.clamp(0.4, 2.0);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = selected ? 1.6 : 1.0
      ..color = (selected ? tokens.selectionStroke : tokens.accentSecondary)
          .withValues(alpha: selected ? 0.9 : 0.4);
    canvas.drawCircle(pivot, radius, paint);
    // 旋转轴：水平 / 垂直短线 + 拖拽手柄。
    final handle =
        pivot +
        Offset(
          math.cos(deformer.angle) * radius,
          -math.sin(deformer.angle) * radius,
        );
    canvas.drawLine(pivot, handle, paint);
    canvas.drawLine(
      pivot - const Offset(10, 0),
      pivot + const Offset(10, 0),
      paint,
    );
    canvas.drawLine(
      pivot - const Offset(0, 10),
      pivot + const Offset(0, 10),
      paint,
    );
    if (options.showHandles) {
      canvas.drawCircle(
        handle,
        4,
        Paint()..color = selected ? tokens.selectionStroke : tokens.handleFill,
      );
    }
  }

  void _paintBounds(Canvas canvas) {
    final bounds = scene.bounds;
    final topLeft = viewport.worldToScreen(Offset(bounds[0], bounds[3]));
    final bottomRight = viewport.worldToScreen(Offset(bounds[2], bounds[1]));
    canvas.drawRect(
      Rect.fromPoints(topLeft, bottomRight),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = tokens.accentSecondary.withValues(alpha: 0.6),
    );
  }

  Path _pathOf(
    AmSceneDrawable drawable, {
    required Offset Function(Offset) worldToScreen,
  }) {
    final path = Path();
    final vertices = drawable.vertices;
    final indices = drawable.indices;
    if (indices.length >= 3) {
      for (var i = 0; i + 2 < indices.length; i += 3) {
        final a = indices[i];
        final b = indices[i + 1];
        final c = indices[i + 2];
        if (a >= vertices.length ||
            b >= vertices.length ||
            c >= vertices.length) {
          continue;
        }
        final pa = worldToScreen(vertices[a]);
        final pb = worldToScreen(vertices[b]);
        final pc = worldToScreen(vertices[c]);
        path
          ..moveTo(pa.dx, pa.dy)
          ..lineTo(pb.dx, pb.dy)
          ..lineTo(pc.dx, pc.dy)
          ..close();
      }
      return path;
    }
    if (vertices.isEmpty) return path;
    final first = worldToScreen(vertices.first);
    path.moveTo(first.dx, first.dy);
    for (final vertex in vertices.skip(1)) {
      final screen = worldToScreen(vertex);
      path.lineTo(screen.dx, screen.dy);
    }
    path.close();
    return path;
  }

  static Color _colorOf(String id) {
    var hash = 0;
    for (final code in id.codeUnits) {
      hash = (hash * 31 + code) & 0x7fffffff;
    }
    final hue = (hash % 360).toDouble();
    return HSLColor.fromAHSL(1, hue, 0.45, 0.62).toColor();
  }

  @override
  bool shouldRepaint(covariant CanvasScenePainter oldDelegate) {
    return oldDelegate.scene != scene ||
        oldDelegate.viewport != viewport ||
        oldDelegate.options != options;
  }
}

/// 顶点命中：返回离屏幕点最近的顶点索引（阈值内）。
int? nearestVertex(
  AmSceneDrawable drawable,
  Offset screenPoint,
  ViewportState viewport, {
  double threshold = 7,
}) {
  int? best;
  var bestDistance = threshold * threshold;
  for (var i = 0; i < drawable.vertices.length; i++) {
    final screen = viewport.worldToScreen(drawable.vertices[i]);
    final dx = screen.dx - screenPoint.dx;
    final dy = screen.dy - screenPoint.dy;
    final distance = dx * dx + dy * dy;
    if (distance <= bestDistance) {
      bestDistance = distance;
      best = i;
    }
  }
  return best;
}

/// 变形器控制点命中。
({String id, int index, bool isRotation})? nearestDeformerHandle(
  AmScene scene,
  Offset screenPoint,
  ViewportState viewport, {
  double threshold = 8,
}) {
  ({String id, int index, bool isRotation})? best;
  var bestDistance = threshold * threshold;
  for (final deformer in scene.deformers) {
    for (var i = 0; i < deformer.controlPoints.length; i++) {
      final screen = viewport.worldToScreen(deformer.controlPoints[i]);
      final dx = screen.dx - screenPoint.dx;
      final dy = screen.dy - screenPoint.dy;
      final distance = dx * dx + dy * dy;
      if (distance <= bestDistance) {
        bestDistance = distance;
        best = (
          id: deformer.id,
          index: i,
          isRotation: deformer.kind == AmNodeKind.rotationDeformer,
        );
      }
    }
  }
  return best;
}
