/// 查看器 UI 控制器：通知、画布视图、播放。
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';

// ---------------------------------------------------------------------------
// 通知
// ---------------------------------------------------------------------------

/// 通知级别。
enum NoticeLevel { info, success, warning, error }

/// 一条通知。`messageKey` 是 i18n key，附带 `args` 做插值。
class Notice {
  Notice({
    required this.level,
    required this.messageKey,
    this.args = const <String, String>{},
    this.detail,
    this.id,
  });

  final NoticeLevel level;
  final String messageKey;
  final Map<String, String> args;
  final String? detail;
  final String? id;
}

/// 通知控制器（顶部横幅）。
class NotificationsController extends Notifier<List<Notice>> {
  @override
  List<Notice> build() => <Notice>[];

  void push(NoticeLevel level, String messageKey, {Map<String, String>? args, String? detail}) {
    final notice = Notice(
      level: level,
      messageKey: messageKey,
      args: args ?? const <String, String>{},
      detail: detail,
      id: DateTime.now().microsecondsSinceEpoch.toString(),
    );
    state = <Notice>[...state, notice];
  }

  void info(String messageKey, {Map<String, String>? args, String? detail}) =>
      push(NoticeLevel.info, messageKey, args: args, detail: detail);

  void success(String messageKey, {Map<String, String>? args, String? detail}) =>
      push(NoticeLevel.success, messageKey, args: args, detail: detail);

  void warn(String messageKey, {Map<String, String>? args, String? detail}) =>
      push(NoticeLevel.warning, messageKey, args: args, detail: detail);

  void error(String messageKey, {Map<String, String>? args, String? detail}) =>
      push(NoticeLevel.error, messageKey, args: args, detail: detail);

  void dismiss(String id) {
    state = <Notice>[for (final item in state) if (item.id != id) item];
  }
}

final notificationsProvider =
    NotifierProvider<NotificationsController, List<Notice>>(
      NotificationsController.new,
    );

// ---------------------------------------------------------------------------
// 画布视图
// ---------------------------------------------------------------------------

/// 视图状态：世界（画布像素，原点中心，Y 向上）↔ 屏幕。
class ViewportState {
  const ViewportState({
    this.pan = Offset.zero,
    this.zoom = 1.0,
    this.flipX = false,
    this.flipY = false,
    this.canvasSize = const Size(1280, 720),
    this.fitRequested = 0,
  });

  final Offset pan;
  final double zoom;
  final bool flipX;
  final bool flipY;
  final Size canvasSize;

  /// 每次“适应窗口”自增，画布据此重新计算。
  final int fitRequested;

  ViewportState copyWith({
    Offset? pan,
    double? zoom,
    bool? flipX,
    bool? flipY,
    Size? canvasSize,
    int? fitRequested,
  }) => ViewportState(
    pan: pan ?? this.pan,
    zoom: zoom ?? this.zoom,
    flipX: flipX ?? this.flipX,
    flipY: flipY ?? this.flipY,
    canvasSize: canvasSize ?? this.canvasSize,
    fitRequested: fitRequested ?? this.fitRequested,
  );

  Offset worldToScreen(Offset world) => Offset(
    canvasSize.width / 2 + (world.dx * (flipX ? -1 : 1) + pan.dx) * zoom,
    canvasSize.height / 2 - (world.dy * (flipY ? -1 : 1) + pan.dy) * zoom,
  );

  Offset screenToWorld(Offset screen) {
    final x = (screen.dx - canvasSize.width / 2) / zoom - pan.dx;
    final y = -(screen.dy - canvasSize.height / 2) / zoom - pan.dy;
    return Offset(flipX ? -x : x, flipY ? -y : y);
  }
}

/// 视图控制器。
class ViewportController extends Notifier<ViewportState> {
  @override
  ViewportState build() => const ViewportState();

  void setCanvasSize(Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    if (state.canvasSize == size) return;
    state = state.copyWith(canvasSize: size);
  }

  void panBy(Offset delta) => state = state.copyWith(pan: state.pan + delta);

  void setPan(Offset pan) => state = state.copyWith(pan: pan);

  void zoomAt(Offset focal, double factor) {
    final next = (state.zoom * factor).clamp(0.05, 32.0);
    if (next == state.zoom) return;
    final before = state.screenToWorld(focal);
    final updated = state.copyWith(zoom: next);
    final after = updated.screenToWorld(focal);
    state = updated.copyWith(pan: updated.pan + (after - before));
  }

  void setZoom(double zoom) =>
      state = state.copyWith(zoom: zoom.clamp(0.05, 32.0));

  void toggleFlipX() => state = state.copyWith(flipX: !state.flipX);

  void toggleFlipY() => state = state.copyWith(flipY: !state.flipY);

  void reset() => state = state.copyWith(
    pan: Offset.zero,
    zoom: 1,
    flipX: false,
    flipY: false,
  );

  /// 适应内容包围盒 `[left, top, right, bottom]`（世界坐标）。
  void fitTo(List<double> bounds, {double padding = 0.08}) {
    final width = bounds[2] - bounds[0];
    final height = bounds[3] - bounds[1];
    if (width <= 0 || height <= 0) {
      reset();
      return;
    }
    final available = Size(
      state.canvasSize.width * (1 - padding * 2),
      state.canvasSize.height * (1 - padding * 2),
    );
    final zoom = math.min(available.width / width, available.height / height);
    final center = Offset(
      (bounds[0] + bounds[2]) / 2,
      (bounds[1] + bounds[3]) / 2,
    );
    final clamped = zoom.clamp(0.05, 32.0);
    state = state.copyWith(
      zoom: clamped,
      pan: Offset(-center.dx, -center.dy),
      fitRequested: state.fitRequested + 1,
    );
  }

  /// 请求适应窗口（画布拿到下一帧的场景包围盒后执行）。
  void requestFit() =>
      state = state.copyWith(fitRequested: state.fitRequested + 1);
}

final viewportProvider = NotifierProvider<ViewportController, ViewportState>(
  ViewportController.new,
);

// ---------------------------------------------------------------------------
// 播放（查看器）
// ---------------------------------------------------------------------------

/// 播放状态。
class ViewerPlaybackState {
  const ViewerPlaybackState({
    this.playing = false,
    this.time = 0,
    this.duration = 0,
    this.loop = true,
    this.speed = 1,
    this.motion,
    this.fadeIn = 0,
    this.fadeOut = 0,
  });

  final bool playing;
  final double time;
  final double duration;
  final bool loop;
  final double speed;

  /// 当前动作名（null = 未选择，仅显示姿势/默认状态）。
  final String? motion;
  final double fadeIn;
  final double fadeOut;

  ViewerPlaybackState copyWith({
    bool? playing,
    double? time,
    double? duration,
    bool? loop,
    double? speed,
    String? motion,
    bool clearMotion = false,
    double? fadeIn,
    double? fadeOut,
  }) => ViewerPlaybackState(
    playing: playing ?? this.playing,
    time: time ?? this.time,
    duration: duration ?? this.duration,
    loop: loop ?? this.loop,
    speed: speed ?? this.speed,
    motion: clearMotion ? null : (motion ?? this.motion),
    fadeIn: fadeIn ?? this.fadeIn,
    fadeOut: fadeOut ?? this.fadeOut,
  );
}

/// 播放控制器：只管 UI 意图，引擎真值由 runtime 决定。
class ViewerPlaybackController extends Notifier<ViewerPlaybackState> {
  @override
  ViewerPlaybackState build() => const ViewerPlaybackState();

  void play(String motion, {double duration = 0}) {
    state = state.copyWith(
      playing: true,
      motion: motion,
      time: 0,
      duration: duration > 0 ? duration : state.duration,
    );
  }

  void pause() => state = state.copyWith(playing: false);

  void toggle() => state = state.copyWith(playing: !state.playing);

  void stop() => state = state.copyWith(playing: false, time: 0);

  void setTime(double time) => state = state.copyWith(time: time);

  void setDuration(double duration) =>
      state = state.copyWith(duration: duration);

  void setLoop(bool loop) => state = state.copyWith(loop: loop);

  void setSpeed(double speed) =>
      state = state.copyWith(speed: speed.clamp(0.1, 8.0));

  void setFade({double? inSeconds, double? outSeconds}) => state = state.copyWith(
    fadeIn: inSeconds,
    fadeOut: outSeconds,
  );

  /// 推进播放头；返回新时间。
  double advance(double dt) {
    var next = state.time + dt * state.speed;
    if (next > state.duration) {
      if (state.loop) {
        next = state.duration <= 0 ? 0 : next % state.duration;
      } else {
        next = state.duration;
        state = state.copyWith(playing: false);
      }
    }
    state = state.copyWith(time: next);
    return next;
  }
}

final viewerPlaybackProvider =
    NotifierProvider<ViewerPlaybackController, ViewerPlaybackState>(
      ViewerPlaybackController.new,
    );
