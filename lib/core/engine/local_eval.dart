/// 内置求值器：参数 → 关键形插值 → 变形器级联 → 世界坐标网格。
///
/// 这是引擎 `am-eval`（tasks.md E2-6）在 Dart 侧的**降级等价物**，用于：
/// * 降级画布把模型画出来（参数滑杆实时生效）；
/// * `renderer.pick` / `renderer.measure` 的坐标与命中测试；
/// * 关键形、变形器手柄的可视化。
///
/// 语义约定见 `docs/engine-requests.md`：引擎接入后这些查询改走
/// `doc.query {path:"scene"}`。
library;

import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'am_types.dart';
import 'local_document.dart';

/// 二维仿射（只用到平移/旋转/缩放）。
class AmAffine {
  const AmAffine(this.a, this.b, this.c, this.d, this.tx, this.ty);

  const AmAffine.identity() : a = 1, b = 0, c = 0, d = 1, tx = 0, ty = 0;

  final double a, b, c, d, tx, ty;

  Offset apply(Offset p) =>
      Offset(a * p.dx + c * p.dy + tx, b * p.dx + d * p.dy + ty);

  AmAffine multiply(AmAffine o) => AmAffine(
    a * o.a + c * o.b,
    b * o.a + d * o.b,
    a * o.c + c * o.d,
    b * o.c + d * o.d,
    a * o.tx + c * o.ty + tx,
    b * o.tx + d * o.ty + ty,
  );

  static AmAffine rotationAround(
    Offset pivot,
    double angle,
    double sx,
    double sy,
  ) {
    final cos = math.cos(angle);
    final sin = math.sin(angle);
    // T(pivot) · R(angle) · S(sx, sy) · T(-pivot)
    final r = AmAffine(cos * sx, sin * sx, -sin * sy, cos * sy, 0, 0);
    final t = Offset(
      pivot.dx - (r.a * pivot.dx + r.c * pivot.dy),
      pivot.dy - (r.b * pivot.dx + r.d * pivot.dy),
    );
    return AmAffine(r.a, r.b, r.c, r.d, t.dx, t.dy);
  }
}

/// 世界坐标下的可绘制对象。
class AmSceneDrawable {
  AmSceneDrawable({
    required this.id,
    required this.name,
    required this.vertices,
    required this.uvs,
    required this.indices,
    required this.opacity,
    required this.blend,
    required this.texture,
    required this.drawOrder,
    required this.visible,
    required this.locked,
    required this.mask,
    required this.selectedVertexIds,
  });

  final String id;
  final String name;

  /// 世界坐标（画布像素，原点画布中心，Y 轴向上）。
  final List<Offset> vertices;
  final List<Offset> uvs;
  final List<int> indices;
  final double opacity;
  final AmBlendMode blend;
  final String? texture;
  final int drawOrder;
  final bool visible;
  final bool locked;
  final List<String> mask;
  final List<int> selectedVertexIds;
}

/// 世界坐标下的变形器手柄。
class AmSceneDeformer {
  AmSceneDeformer({
    required this.id,
    required this.name,
    required this.kind,
    required this.controlPoints,
    required this.pivot,
    required this.angle,
    required this.scaleX,
    required this.scaleY,
    required this.rows,
    required this.cols,
    required this.visible,
    required this.locked,
  });

  final String id;
  final String name;
  final AmNodeKind kind;
  final List<Offset> controlPoints;
  final Offset pivot;
  final double angle;
  final double scaleX;
  final double scaleY;
  final int rows;
  final int cols;
  final bool visible;
  final bool locked;
}

/// 求值结果。
class AmScene {
  AmScene({
    required this.drawables,
    required this.deformers,
    required this.parts,
    required this.bounds,
  });

  final List<AmSceneDrawable> drawables;
  final List<AmSceneDeformer> deformers;

  /// 部件节点的世界包围盒（部件选择用）。
  final Map<String, List<Offset>> parts;

  /// 整体包围盒 `[left, top, right, bottom]`（世界坐标）。
  final List<double> bounds;
}

/// 关键形求值结果（单个节点）。
class _KeyformState {
  double? opacity;
  Offset? position;
  double? angle;
  double? scaleX;
  double? scaleY;
  List<Offset>? controlPointOffsets;
  List<Offset>? vertexOffsets;
}

/// 按混合类型合成基准值与关键形值。
double blendKeyValue(double base, double keyed, AmKeyformBlend blend) {
  switch (blend) {
    case AmKeyformBlend.normal:
      return keyed;
    case AmKeyformBlend.add:
      return base + keyed;
    case AmKeyformBlend.multiply:
      return base * keyed;
    case AmKeyformBlend.screen:
      return 1 - (1 - base) * (1 - keyed);
  }
}

/// 关键形相对基准值的**增量**。
///
/// 同一个节点可以被多个参数驱动，增量形式保证各参数的贡献可以叠加：
/// `result = base + Σ blendDelta(base, keyed_i, blend_i)`；
/// 只有一个参数时结果与 [blendKeyValue] 完全一致。
double blendDelta(double base, double keyed, AmKeyformBlend blend) =>
    blendKeyValue(base, keyed, blend) - base;

/// 场景构建器。
class AmSceneBuilder {
  AmSceneBuilder(this.document);

  final LocalDocument document;

  late Map<String, Object?> _params;

  /// 当前参数值（未提供的参数取 default）。
  Map<String, double> defaultParams() {
    final result = <String, double>{};
    for (final entry in document.parameters.entries) {
      final param = asJsonMap(entry.value);
      result[entry.key] = asDouble(param['default']);
    }
    return result;
  }

  AmScene build({
    required Map<String, double> params,
    bool includeHidden = false,
    List<int> selectedVertices = const <int>[],
    String? selectedNode,
  }) {
    _params = document.parameters;
    final drawables = <AmSceneDrawable>[];
    final deformers = <AmSceneDeformer>[];
    final parts = <String, List<Offset>>{};
    final verticesById = <String, List<Offset>>{};

    final rootId = document.rootId;
    if (rootId != null) {
      _walk(
        rootId,
        const AmAffine.identity(),
        <Map<String, Object?>>[],
        params,
        includeHidden,
        drawables,
        deformers,
        parts,
        verticesById,
        selectedVertices,
        selectedNode,
      );
    }

    final bounds = <double>[
      double.infinity,
      double.infinity,
      double.negativeInfinity,
      double.negativeInfinity,
    ];
    for (final drawable in drawables) {
      for (final vertex in drawable.vertices) {
        bounds[0] = math.min(bounds[0], vertex.dx);
        bounds[1] = math.min(bounds[1], vertex.dy);
        bounds[2] = math.max(bounds[2], vertex.dx);
        bounds[3] = math.max(bounds[3], vertex.dy);
      }
    }
    if (!bounds[0].isFinite) {
      bounds[0] = -100;
      bounds[1] = -100;
      bounds[2] = 100;
      bounds[3] = 100;
    }

    drawables.sort((a, b) => a.drawOrder.compareTo(b.drawOrder));
    return AmScene(
      drawables: drawables,
      deformers: deformers,
      parts: parts,
      bounds: bounds,
    );
  }

  void _walk(
    String id,
    AmAffine affine,
    List<Map<String, Object?>> warps,
    Map<String, double> params,
    bool includeHidden,
    List<AmSceneDrawable> drawables,
    List<AmSceneDeformer> deformers,
    Map<String, List<Offset>> parts,
    Map<String, List<Offset>> verticesById,
    List<int> selectedVertices,
    String? selectedNode,
  ) {
    final node = asJsonMap(document.nodes[id]);
    if (node.isEmpty) return;
    final kind = AmNodeKind.parse(node['type']);
    final visible = asBool(node['visible'], true);
    if (!visible && !includeHidden) return;

    final keyform = _evaluateKeyforms(node, params);
    var nextWarps = warps;
    var nextAffine = affine;

    if (kind == AmNodeKind.rotationDeformer) {
      final basePosition = asJsonList(node['position']);
      final pivot =
          keyform.position ??
          Offset(
            basePosition.isNotEmpty ? asDouble(basePosition[0]) : 0,
            basePosition.length > 1 ? asDouble(basePosition[1]) : 0,
          );
      final baseScale = asJsonList(node['scale']);
      final sx =
          keyform.scaleX ??
          (baseScale.isNotEmpty ? asDouble(baseScale[0]) : 1.0);
      final sy =
          keyform.scaleY ??
          (baseScale.length > 1 ? asDouble(baseScale[1]) : 1.0);
      final angle = keyform.angle ?? asDouble(node['angle']);
      nextAffine = affine.multiply(
        AmAffine.rotationAround(
          pivot,
          angle,
          sx == 0 ? 1 : sx,
          sy == 0 ? 1 : sy,
        ),
      );
      final worldPivot = nextAffine.applyInversePivot(pivot);
      deformers.add(
        AmSceneDeformer(
          id: id,
          name: '${node['name']}',
          kind: kind,
          controlPoints: <Offset>[worldPivot],
          pivot: worldPivot,
          angle: angle,
          scaleX: sx,
          scaleY: sy,
          rows: 0,
          cols: 0,
          visible: visible,
          locked: asBool(node['locked']),
        ),
      );
    } else if (kind == AmNodeKind.warpDeformer) {
      final points = _warpPoints(node, keyform, params);
      nextWarps = <Map<String, Object?>>[
        ...warps,
        <String, Object?>{
          'rest': points.$1,
          'current': points.$2,
          'rows': asInt(points.$3),
          'cols': asInt(points.$4),
        },
      ];
      deformers.add(
        AmSceneDeformer(
          id: id,
          name: '${node['name']}',
          kind: kind,
          controlPoints: <Offset>[
            for (var i = 0; i < points.$2.length; i++)
              nextAffine.apply(points.$2[i]),
          ],
          pivot: nextAffine.apply(
            points.$2.isEmpty ? Offset.zero : points.$2.first,
          ),
          angle: 0,
          scaleX: 1,
          scaleY: 1,
          rows: asInt(points.$3),
          cols: asInt(points.$4),
          visible: visible,
          locked: asBool(node['locked']),
        ),
      );
    } else if (kind == AmNodeKind.drawable) {
      final world = _drawableVertices(node, keyform, warps, nextAffine);
      verticesById[id] = world;
      final uvList = asJsonList(asJsonMap(node['mesh'])['uvs']);
      final uvs = <Offset>[
        for (final uv in uvList)
          Offset(
            asDouble(asJsonList(uv).isNotEmpty ? asJsonList(uv)[0] : 0),
            asDouble(asJsonList(uv).length > 1 ? asJsonList(uv)[1] : 0),
          ),
      ];
      final indices = asJsonList(
        asJsonMap(node['mesh'])['indices'],
      ).map(asInt).toList();
      final opacity = keyform.opacity ?? asDouble(node['opacity'], 1);
      drawables.add(
        AmSceneDrawable(
          id: id,
          name: '${node['name']}',
          vertices: world,
          uvs: uvs,
          indices: indices,
          opacity: opacity,
          blend: AmBlendMode.parse(node['blend_mode']),
          texture: node['texture'] == null ? null : '${node['texture']}',
          drawOrder: asInt(node['draw_order']),
          visible: visible,
          locked: asBool(node['locked']),
          mask: asJsonList(node['mask']).map((e) => '$e').toList(),
          selectedVertexIds: id == selectedNode
              ? selectedVertices
              : const <int>[],
        ),
      );
    }

    final childBounds = <Offset>[];
    for (final child in asJsonList(node['children'])) {
      final childId = '$child';
      _walk(
        childId,
        nextAffine,
        nextWarps,
        params,
        includeHidden,
        drawables,
        deformers,
        parts,
        verticesById,
        selectedVertices,
        selectedNode,
      );
      final childVertices = parts[childId] ?? verticesById[childId];
      if (childVertices != null) childBounds.addAll(childVertices);
    }
    if (kind == AmNodeKind.part) {
      parts[id] = childBounds;
    }
  }

  /// 关键形插值。返回该节点在当前参数下的有效局部状态。
  _KeyformState _evaluateKeyforms(
    Map<String, Object?> node,
    Map<String, double> params,
  ) {
    final state = _KeyformState();
    final keyforms = asJsonMap(node['keyforms']);
    if (keyforms.isEmpty) return state;

    final controlOffsets = <int, Offset>{};
    final vertexOffsets = <int, Offset>{};

    // 多个参数可以同时驱动同一个节点，各自的贡献必须**叠加**而不是互相覆盖。
    // 因此这里累加每个参数的增量，最后一次性作用到基准状态上。
    final basePosition = asJsonList(node['position']);
    final baseX = basePosition.isNotEmpty ? asDouble(basePosition[0]) : 0.0;
    final baseY = basePosition.length > 1 ? asDouble(basePosition[1]) : 0.0;
    final baseAngle = asDouble(node['angle']);
    final baseScale = asJsonList(node['scale']);
    final baseSx = baseScale.isNotEmpty ? asDouble(baseScale[0]) : 1.0;
    final baseSy = baseScale.length > 1 ? asDouble(baseScale[1]) : 1.0;
    final baseOpacity = asDouble(node['opacity'], 1);

    var positionDelta = Offset.zero;
    var angleDelta = 0.0;
    var scaleDelta = Offset.zero;
    var opacityDelta = 0.0;
    var hasPosition = false;
    var hasAngle = false;
    var hasScale = false;
    var hasOpacity = false;

    for (final entry in keyforms.entries) {
      final paramId = entry.key;
      final perParam = asJsonMap(entry.value);
      final keys = asJsonList(perParam['keys']);
      if (keys.isEmpty) continue;
      final value =
          params[paramId] ?? asDouble(asJsonMap(_params[paramId])['default']);
      final blend = AmKeyformBlend.parse(perParam['blend_type']);

      // 找到包夹该值的两帧；范围外按端点取值（默认不外推）。
      final sorted = keys.map(asJsonMap).toList()
        ..sort((a, b) => asDouble(a['value']).compareTo(asDouble(b['value'])));
      var lower = sorted.first;
      var upper = sorted.last;
      if (value <= asDouble(lower['value'])) {
        upper = lower;
      } else if (value >= asDouble(upper['value'])) {
        lower = upper;
      } else {
        for (var i = 0; i + 1 < sorted.length; i++) {
          if (value >= asDouble(sorted[i]['value']) &&
              value <= asDouble(sorted[i + 1]['value'])) {
            lower = sorted[i];
            upper = sorted[i + 1];
            break;
          }
        }
      }
      final lowValue = asDouble(lower['value']);
      final highValue = asDouble(upper['value']);
      final span = highValue - lowValue;
      final t = span.abs() < 1e-9
          ? 0.0
          : ((value - lowValue) / span).clamp(0.0, 1.0);

      if (lower['transform'] != null || upper['transform'] != null) {
        final loT = asJsonMap(lower['transform']);
        final hiT = asJsonMap(upper['transform']);
        final loPos = asJsonList(loT['position']);
        final hiPos = asJsonList(hiT['position']);
        if (loPos.isNotEmpty || hiPos.isNotEmpty) {
          final x = lerp(
            loPos.isNotEmpty ? asDouble(loPos[0]) : baseX,
            hiPos.isNotEmpty ? asDouble(hiPos[0]) : baseX,
            t,
          );
          final y = lerp(
            loPos.isNotEmpty && loPos.length > 1 ? asDouble(loPos[1]) : baseY,
            hiPos.isNotEmpty && hiPos.length > 1 ? asDouble(hiPos[1]) : baseY,
            t,
          );
          positionDelta += Offset(
            blendDelta(baseX, x, blend),
            blendDelta(baseY, y, blend),
          );
          hasPosition = true;
        }
        final loAngle = loT['angle'];
        final hiAngle = hiT['angle'];
        if (loAngle != null || hiAngle != null) {
          final angle = lerp(
            loAngle == null ? baseAngle : asDouble(loAngle),
            hiAngle == null ? baseAngle : asDouble(hiAngle),
            t,
          );
          angleDelta += blendDelta(baseAngle, angle, blend);
          hasAngle = true;
        }
        final loS = asJsonList(loT['scale']);
        final hiS = asJsonList(hiT['scale']);
        if (loS.isNotEmpty || hiS.isNotEmpty) {
          scaleDelta += Offset(
            blendDelta(
              baseSx,
              lerp(
                loS.isNotEmpty ? asDouble(loS[0]) : baseSx,
                hiS.isNotEmpty ? asDouble(hiS[0]) : baseSx,
                t,
              ),
              blend,
            ),
            blendDelta(
              baseSy,
              lerp(
                loS.length > 1 ? asDouble(loS[1]) : baseSy,
                hiS.length > 1 ? asDouble(hiS[1]) : baseSy,
                t,
              ),
              blend,
            ),
          );
          hasScale = true;
        }
      }

      if (lower['opacity'] != null || upper['opacity'] != null) {
        final opacity = lerp(
          asDouble(lower['opacity'], baseOpacity),
          asDouble(upper['opacity'], baseOpacity),
          t,
        );
        opacityDelta += blendDelta(baseOpacity, opacity, blend);
        hasOpacity = true;
      }

      final loVertices = asJsonList(lower['vertices']);
      final hiVertices = asJsonList(upper['vertices']);
      final count = math.max(loVertices.length, hiVertices.length);
      for (var i = 0; i < count; i++) {
        final a = i < loVertices.length
            ? asJsonList(loVertices[i])
            : asJsonList(hiVertices[i]);
        final b = i < hiVertices.length
            ? asJsonList(hiVertices[i])
            : asJsonList(loVertices[i]);
        final dx = lerp(
          a.isNotEmpty ? asDouble(a[0]) : 0.0,
          b.isNotEmpty ? asDouble(b[0]) : 0.0,
          t,
        );
        final dy = lerp(
          a.length > 1 ? asDouble(a[1]) : 0.0,
          b.length > 1 ? asDouble(b[1]) : 0.0,
          t,
        );
        final previous = vertexOffsets[i] ?? Offset.zero;
        vertexOffsets[i] = Offset(
          previous.dx + blendKeyValue(0, dx, blend),
          previous.dy + blendKeyValue(0, dy, blend),
        );
      }

      final loPoints = asJsonList(lower['control_points']);
      final hiPoints = asJsonList(upper['control_points']);
      final pointCount = math.max(loPoints.length, hiPoints.length);
      for (var i = 0; i < pointCount; i++) {
        final a = i < loPoints.length
            ? asJsonList(loPoints[i])
            : asJsonList(hiPoints[i]);
        final b = i < hiPoints.length
            ? asJsonList(hiPoints[i])
            : asJsonList(loPoints[i]);
        final px = lerp(
          a.isNotEmpty ? asDouble(a[0]) : 0.0,
          b.isNotEmpty ? asDouble(b[0]) : 0.0,
          t,
        );
        final py = lerp(
          a.length > 1 ? asDouble(a[1]) : 0.0,
          b.length > 1 ? asDouble(b[1]) : 0.0,
          t,
        );
        final previous = controlOffsets[i] ?? Offset.zero;
        controlOffsets[i] = Offset(previous.dx + px, previous.dy + py);
      }

      // 位置/角度/缩放/不透明度累加到增量里（见上方分支）。
    }

    // 所有参数贡献叠加后一次性作用到基准状态。
    if (hasPosition) {
      state.position = Offset(
        baseX + positionDelta.dx,
        baseY + positionDelta.dy,
      );
    }
    if (hasAngle) state.angle = baseAngle + angleDelta;
    if (hasScale) {
      state.scaleX = baseSx + scaleDelta.dx;
      state.scaleY = baseSy + scaleDelta.dy;
    }
    if (hasOpacity) {
      state.opacity = (baseOpacity + opacityDelta).clamp(0.0, 1.0);
    }

    if (vertexOffsets.isNotEmpty) {
      state.vertexOffsets = <Offset>[
        for (var i = 0; i <= vertexOffsets.keys.reduce(math.max); i++)
          vertexOffsets[i] ?? Offset.zero,
      ];
    }
    if (controlOffsets.isNotEmpty) {
      state.controlPointOffsets = <Offset>[
        for (var i = 0; i <= controlOffsets.keys.reduce(math.max); i++)
          controlOffsets[i] ?? Offset.zero,
      ];
    }
    return state;
  }

  (List<Offset>, List<Offset>, int, int) _warpPoints(
    Map<String, Object?> node,
    _KeyformState keyform,
    Map<String, double> params,
  ) {
    final rest = <Offset>[
      for (final point in asJsonList(node['control_points']))
        Offset(
          asDouble(asJsonList(point).isNotEmpty ? asJsonList(point)[0] : 0),
          asDouble(asJsonList(point).length > 1 ? asJsonList(point)[1] : 0),
        ),
    ];
    final offsets = keyform.controlPointOffsets ?? const <Offset>[];
    final current = <Offset>[
      for (var i = 0; i < rest.length; i++)
        Offset(
          rest[i].dx + (i < offsets.length ? offsets[i].dx : 0),
          rest[i].dy + (i < offsets.length ? offsets[i].dy : 0),
        ),
    ];
    return (rest, current, asInt(node['rows'], 1), asInt(node['cols'], 1));
  }

  List<Offset> _drawableVertices(
    Map<String, Object?> node,
    _KeyformState keyform,
    List<Map<String, Object?>> warps,
    AmAffine affine,
  ) {
    final mesh = asJsonMap(node['mesh']);
    final raw = asJsonList(mesh['vertices']);
    final offsets = keyform.vertexOffsets ?? const <Offset>[];
    final points = <Offset>[
      for (var i = 0; i < raw.length; i++)
        Offset(
          asDouble(asJsonList(raw[i]).isNotEmpty ? asJsonList(raw[i])[0] : 0) +
              (i < offsets.length ? offsets[i].dx : 0),
          asDouble(asJsonList(raw[i]).length > 1 ? asJsonList(raw[i])[1] : 0) +
              (i < offsets.length ? offsets[i].dy : 0),
        ),
    ];
    // 先叠加变形器位移（由内到外），再做父级仿射。
    for (final warp in warps) {
      _applyWarp(points, warp);
    }
    if (affine == const AmAffine.identity()) return points;
    return points.map(affine.apply).toList();
  }

  /// 双线性位移：按原始控制网格定位所在格子，再取该格子的位移量。
  void _applyWarp(List<Offset> points, Map<String, Object?> warp) {
    final rest = warp['rest'] as List<Offset>;
    final current = warp['current'] as List<Offset>;
    final rows = asInt(warp['rows'], 1);
    final cols = asInt(warp['cols'], 1);
    if (rest.length != (rows + 1) * (cols + 1) || rest.isEmpty) return;

    final minX = rest.map((p) => p.dx).reduce(math.min);
    final maxX = rest.map((p) => p.dx).reduce(math.max);
    final minY = rest.map((p) => p.dy).reduce(math.min);
    final maxY = rest.map((p) => p.dy).reduce(math.max);
    final spanX = maxX - minX;
    final spanY = maxY - minY;
    if (spanX.abs() < 1e-9 || spanY.abs() < 1e-9) return;

    for (var i = 0; i < points.length; i++) {
      final point = points[i];
      final u = ((point.dx - minX) / spanX).clamp(0.0, 1.0) * cols;
      final v = ((point.dy - minY) / spanY).clamp(0.0, 1.0) * rows;
      final c0 = u.floor().clamp(0, cols - 1);
      final r0 = v.floor().clamp(0, rows - 1);
      final tu = u - c0;
      final tv = v - r0;
      Offset displacement(int r, int c) {
        final index = r * (cols + 1) + c;
        return current[index] - rest[index];
      }

      final d00 = displacement(r0, c0);
      final d10 = displacement(r0, c0 + 1);
      final d01 = displacement(r0 + 1, c0);
      final d11 = displacement(r0 + 1, c0 + 1);
      final top = Offset(
        d00.dx + (d10.dx - d00.dx) * tu,
        d00.dy + (d10.dy - d00.dy) * tu,
      );
      final bottom = Offset(
        d01.dx + (d11.dx - d01.dx) * tu,
        d01.dy + (d11.dy - d01.dy) * tu,
      );
      points[i] =
          point +
          Offset(
            top.dx + (bottom.dx - top.dx) * tv,
            top.dy + (bottom.dy - top.dy) * tv,
          );
    }
  }
}

double lerp(double a, double b, double t) => a + (b - a) * t;

/// 动作曲线求值（linear / step / bezier）。
///
/// `bezier` 用三次 Hermite 近似：切线取关键帧的 `in_tangent` / `out_tangent`
/// （单位：值/秒；0 表示平滑过渡）。范围外按端点保持。
double evaluateCurve(List<Map<String, Object?>> keys, double time) {
  if (keys.isEmpty) return 0;
  final sorted = [...keys]
    ..sort((a, b) => asDouble(a['time']).compareTo(asDouble(b['time'])));
  if (sorted.length == 1) return asDouble(sorted.first['value']);
  if (time <= asDouble(sorted.first['time'])) {
    return asDouble(sorted.first['value']);
  }
  if (time >= asDouble(sorted.last['time'])) {
    return asDouble(sorted.last['value']);
  }
  var lower = sorted.first;
  var upper = sorted.last;
  for (var i = 0; i + 1 < sorted.length; i++) {
    if (time >= asDouble(sorted[i]['time']) &&
        time <= asDouble(sorted[i + 1]['time'])) {
      lower = sorted[i];
      upper = sorted[i + 1];
      break;
    }
  }
  final t0 = asDouble(lower['time']);
  final t1 = asDouble(upper['time']);
  final span = t1 - t0;
  if (span.abs() < 1e-9) return asDouble(upper['value']);
  final u = ((time - t0) / span).clamp(0.0, 1.0);
  final v0 = asDouble(lower['value']);
  final v1 = asDouble(upper['value']);
  switch (AmInterpolation.parse(lower['interp'])) {
    case AmInterpolation.step:
      return v0;
    case AmInterpolation.linear:
      return lerp(v0, v1, u);
    case AmInterpolation.bezier:
      final m0 = asDouble(lower['out_tangent']) * span;
      final m1 = asDouble(upper['in_tangent']) * span;
      final u2 = u * u;
      final u3 = u2 * u;
      return (2 * u3 - 3 * u2 + 1) * v0 +
          (u3 - 2 * u2 + u) * m0 +
          (-2 * u3 + 3 * u2) * v1 +
          (u3 - u2) * m1;
  }
}

/// 命中测试：返回世界坐标 [point] 命中的最上层节点 id。
String? hitTestScene(AmScene scene, Offset point) {
  String? hit;
  var bestOrder = -1 << 30;
  for (final drawable in scene.drawables) {
    if (!drawable.visible || drawable.locked) continue;
    if (drawable.drawOrder < bestOrder) continue;
    if (_pointInMesh(point, drawable)) {
      hit = drawable.id;
      bestOrder = drawable.drawOrder;
    }
  }
  if (hit != null) return hit;
  // 回退：部件的包围盒（便于选中空白区域的大部件）。
  for (final entry in scene.parts.entries) {
    if (_pointInPolygon(point, entry.value)) return entry.key;
  }
  return null;
}

bool _pointInMesh(Offset point, AmSceneDrawable drawable) {
  final v = drawable.vertices;
  final idx = drawable.indices;
  if (idx.length >= 3) {
    for (var i = 0; i + 2 < idx.length; i += 3) {
      final a = idx[i], b = idx[i + 1], c = idx[i + 2];
      if (a >= v.length || b >= v.length || c >= v.length) continue;
      if (_pointInTriangle(point, v[a], v[b], v[c])) return true;
    }
    return false;
  }
  return _pointInPolygon(point, v);
}

bool _pointInTriangle(Offset p, Offset a, Offset b, Offset c) {
  double cross(Offset o, Offset x, Offset y) =>
      (x.dx - o.dx) * (y.dy - o.dy) - (x.dy - o.dy) * (y.dx - o.dx);
  final d1 = cross(a, b, p);
  final d2 = cross(b, c, p);
  final d3 = cross(c, a, p);
  final hasNegative = d1 < 0 || d2 < 0 || d3 < 0;
  final hasPositive = d1 > 0 || d2 > 0 || d3 > 0;
  return !(hasNegative && hasPositive);
}

bool _pointInPolygon(Offset point, List<Offset> polygon) {
  if (polygon.length < 3) return false;
  var inside = false;
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final a = polygon[i];
    final b = polygon[j];
    if ((a.dy > point.dy) != (b.dy > point.dy) &&
        point.dx < (b.dx - a.dx) * (point.dy - a.dy) / (b.dy - a.dy) + a.dx) {
      inside = !inside;
    }
  }
  return inside;
}

/// 用于旋转变形器手柄：把世界坐标平移量取反。
extension on AmAffine {
  /// 在已含旋转的仿射下求“枢轴”的世界位置。
  Offset applyInversePivot(Offset pivot) => apply(pivot);
}
