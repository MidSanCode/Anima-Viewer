/// 查看器画布：显示模型，支持平移/缩放/适应/翻转与截图。
///
/// 引擎纹理桥可用时直接承载 `Texture`；否则使用降级画家。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/am_types.dart';
import '../../core/engine/local_eval.dart';
import '../../core/state/document_controller.dart';
import '../../core/state/engine_providers.dart';
import '../../core/state/settings_controller.dart';
import '../../core/state/ui_controllers.dart';
import '../../core/theme/app_theme.dart';

/// 画布。
class ViewerCanvas extends ConsumerStatefulWidget {
  const ViewerCanvas({super.key, this.boundaryKey});

  /// 截图用 RepaintBoundary 的 key（外壳持有）。
  final GlobalKey? boundaryKey;

  @override
  ConsumerState<ViewerCanvas> createState() => _ViewerCanvasState();
}

class _ViewerCanvasState extends ConsumerState<ViewerCanvas> {
  bool _fitted = false;
  int _lastFitRequest = 0;

  @override
  Widget build(BuildContext context) {
    final boot = ref.watch(engineBootProvider);
    if (boot.isLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text('common.loading'.tr()),
          ],
        ),
      );
    }
    if (!boot.hasValue) {
      return Center(child: Text('viewer.engineUnavailable'.tr()));
    }

    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    final sceneProvider = ref.watch(sceneProviderProvider);
    final engine = ref.watch(engineProvider);
    final document = ref.watch(documentProvider);
    final viewport = ref.watch(viewportProvider);

    final scene = sceneProvider?.buildScene();

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ref.read(viewportProvider.notifier).setCanvasSize(size);
          if (!_fitted && scene != null) {
            _fitted = true;
            _fitTo(scene);
          } else if (viewport.fitRequested != _lastFitRequest) {
            _lastFitRequest = viewport.fitRequested;
            if (scene != null) _fitTo(scene);
          }
        });

        final background = asJsonList(document.settings['background']);

        Widget content;
        if (engine.textureInfo != null && engine.textureInfo!.isBridged) {
          content = Texture(textureId: engine.textureInfo!.textureId);
        } else if (scene != null) {
          content = CustomPaint(
            painter: _ViewerScenePainter(
              scene: scene,
              viewport: viewport,
              tokens: AppTheme.of(context),
              showGrid: settings.showGrid,
              showGuides: settings.showGuides,
              background: _backgroundOf(background),
            ),
            child: const SizedBox.expand(),
          );
        } else {
          content = Center(child: Text('viewer.noModel'.tr()));
        }

        return RepaintBoundary(
          key: widget.boundaryKey,
          child: ClipRect(
            child: Listener(
              onPointerSignal: _onPointerSignal,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (details) =>
                    ref.read(viewportProvider.notifier).panBy(details.delta),
                onDoubleTap: () =>
                    ref.read(viewportProvider.notifier).requestFit(),
                child: content,
              ),
            ),
          ),
        );
      },
    );
  }

  void _fitTo(AmScene scene) {
    final bounds = scene.bounds;
    if (bounds.any((v) => v.isInfinite || v.isNaN)) return;
    ref.read(viewportProvider.notifier).fitTo(bounds);
  }

  Color _backgroundOf(List<Object?> rgba) {
    if (rgba.length >= 4) {
      return Color.fromARGB(
        (asDouble(rgba[3]).clamp(0.0, 1.0) * 255).round(),
        (asDouble(rgba[0]).clamp(0.0, 1.0) * 255).round(),
        (asDouble(rgba[1]).clamp(0.0, 1.0) * 255).round(),
        (asDouble(rgba[2]).clamp(0.0, 1.0) * 255).round(),
      );
    }
    return AppTheme.of(context).canvasBackground;
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      ref.read(viewportProvider.notifier).zoomAt(
        event.localPosition,
        event.scrollDelta.dy < 0 ? 1.1 : 0.9,
      );
    }
  }
}

class _ViewerScenePainter extends CustomPainter {
  _ViewerScenePainter({
    required this.scene,
    required this.viewport,
    required this.tokens,
    required this.showGrid,
    required this.showGuides,
    required this.background,
  });

  final AmScene scene;
  final ViewportState viewport;
  final AppTokens tokens;
  final bool showGrid;
  final bool showGuides;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, Paint()..color = background);

    if (showGrid) {
      final paint = Paint()
        ..color = tokens.gridLine
        ..strokeWidth = 1;
      final spacing = 50 * viewport.zoom;
      if (spacing >= 4) {
        final originX =
            size.width / 2 + viewport.pan.dx * viewport.zoom;
        final originY =
            size.height / 2 - viewport.pan.dy * viewport.zoom;
        var x = originX % spacing;
        while (x < size.width) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
          x += spacing;
        }
        var y = originY % spacing;
        while (y < size.height) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
          y += spacing;
        }
      }
    }
    if (showGuides) {
      final paint = Paint()
        ..color = tokens.guideLine
        ..strokeWidth = 1;
      final originX = size.width / 2 + viewport.pan.dx * viewport.zoom;
      final originY = size.height / 2 - viewport.pan.dy * viewport.zoom;
      canvas.drawLine(Offset(originX, 0), Offset(originX, size.height), paint);
      canvas.drawLine(Offset(0, originY), Offset(size.width, originY), paint);
    }

    for (final drawable in scene.drawables) {
      if (!drawable.visible) continue;
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
          final pa = viewport.worldToScreen(vertices[a]);
          final pb = viewport.worldToScreen(vertices[b]);
          final pc = viewport.worldToScreen(vertices[c]);
          path
            ..moveTo(pa.dx, pa.dy)
            ..lineTo(pb.dx, pb.dy)
            ..lineTo(pc.dx, pc.dy)
            ..close();
        }
      } else if (vertices.isNotEmpty) {
        final first = viewport.worldToScreen(vertices.first);
        path.moveTo(first.dx, first.dy);
        for (final vertex in vertices.skip(1)) {
          final screen = viewport.worldToScreen(vertex);
          path.lineTo(screen.dx, screen.dy);
        }
        path.close();
      }

      final baseColor = _colorOf(drawable.id);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.fill
          ..color = baseColor.withValues(
            alpha: (0.25 + 0.55 * drawable.opacity).clamp(0.0, 0.9),
          ),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6
          ..color = baseColor.withValues(alpha: 0.55),
      );
    }
  }

  static Color _colorOf(String id) {
    var hash = 0;
    for (final code in id.codeUnits) {
      hash = (hash * 31 + code) & 0x7fffffff;
    }
    final hue = (hash % 360).toDouble();
    return HSLColor.fromAHSL(1, hue, 0.42, 0.6).toColor();
  }

  @override
  bool shouldRepaint(covariant _ViewerScenePainter oldDelegate) =>
      oldDelegate.scene != scene ||
      oldDelegate.viewport != viewport ||
      oldDelegate.background != background ||
      oldDelegate.showGrid != showGrid ||
      oldDelegate.showGuides != showGuides;
}

/// 截图当前画布为 PNG 字节。
Future<Uint8List?> captureCanvas(GlobalKey boundaryKey) async {
  final boundary =
      boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
  if (boundary == null) return null;
  final ratio = ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
  final image = await boundary.toImage(pixelRatio: ratio.clamp(1.0, 4.0));
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data?.buffer.asUint8List();
}
