/// 运行时层：参数值、动作播放、物理与自动效果的推进。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/am_types.dart';
import 'document_controller.dart';
import 'engine_providers.dart';
import 'ui_controllers.dart';

/// 运行时快照。
class RuntimeState {
  const RuntimeState({
    this.params = const <String, double>{},
    this.time = 0,
    this.duration = 3,
    this.playing = false,
    this.motion,
    this.expression,
    this.physicsEnabled = true,
    this.blinkEnabled = true,
    this.breathEnabled = true,
    this.lipsyncEnabled = false,
    this.lipsyncAmplitude = 0,
    this.loaded = false,
  });

  final Map<String, double> params;
  final double time;
  final double duration;
  final bool playing;
  final String? motion;
  final String? expression;
  final bool physicsEnabled;
  final bool blinkEnabled;
  final bool breathEnabled;
  final bool lipsyncEnabled;
  final double lipsyncAmplitude;
  final bool loaded;

  double valueOf(String paramId, [double fallback = 0]) =>
      params[paramId] ?? fallback;

  RuntimeState copyWith({
    Map<String, double>? params,
    double? time,
    double? duration,
    bool? playing,
    String? motion,
    bool clearMotion = false,
    String? expression,
    bool clearExpression = false,
    bool? physicsEnabled,
    bool? blinkEnabled,
    bool? breathEnabled,
    bool? lipsyncEnabled,
    double? lipsyncAmplitude,
    bool? loaded,
  }) => RuntimeState(
    params: params ?? this.params,
    time: time ?? this.time,
    duration: duration ?? this.duration,
    playing: playing ?? this.playing,
    motion: clearMotion ? null : (motion ?? this.motion),
    expression: clearExpression ? null : (expression ?? this.expression),
    physicsEnabled: physicsEnabled ?? this.physicsEnabled,
    blinkEnabled: blinkEnabled ?? this.blinkEnabled,
    breathEnabled: breathEnabled ?? this.breathEnabled,
    lipsyncEnabled: lipsyncEnabled ?? this.lipsyncEnabled,
    lipsyncAmplitude: lipsyncAmplitude ?? this.lipsyncAmplitude,
    loaded: loaded ?? this.loaded,
  );
}

/// 运行时控制器。
class RuntimeController extends Notifier<RuntimeState> {
  @override
  RuntimeState build() => const RuntimeState();

  /// 拉取参数默认值（打开工程后调用）。
  Future<void> load() async {
    final engine = ref.read(engineProvider);
    try {
      final result = await engine.call('runtime.params');
      final raw = asJsonMap(result['params']);
      state = RuntimeState(
        params: <String, double>{
          for (final entry in raw.entries) entry.key: asDouble(entry.value),
        },
        loaded: true,
        physicsEnabled: state.physicsEnabled,
        blinkEnabled: state.blinkEnabled,
        breathEnabled: state.breathEnabled,
        lipsyncEnabled: state.lipsyncEnabled,
      );
    } on AmException {
      // 引擎不支持 runtime.params（未在契约中）时，退化为用参数默认值。
      final document = ref.read(documentProvider);
      state = RuntimeState(
        params: <String, double>{
          for (final entry in document.parameters.entries)
            entry.key: asDouble(entry.value['default']),
        },
        loaded: true,
      );
    }
  }

  Future<void> setParam(String paramId, double value) async {
    final next = <String, double>{...state.params, paramId: value};
    state = state.copyWith(params: next);
    final engine = ref.read(engineProvider);
    try {
      await engine.call('runtime.set_param', <String, Object?>{
        'param': paramId,
        'value': value,
      });
    } on AmException catch (error) {
      ref
          .read(notificationsProvider.notifier)
          .warn(
            'notice.error.engineCall',
            args: <String, String>{
              'code': error.code,
              'method': 'runtime.set_param',
            },
            detail: error.message,
          );
    }
  }

  Future<void> setParams(Map<String, double> values) async {
    if (values.isEmpty) return;
    state = state.copyWith(
      params: <String, double>{...state.params, ...values},
    );
    final engine = ref.read(engineProvider);
    try {
      await engine.call('runtime.set_params', <String, Object?>{
        'params': values,
      });
    } on AmException {
      // 忽略：本地状态已更新，UI 仍然可用。
    }
  }

  Future<void> reset() async {
    final engine = ref.read(engineProvider);
    try {
      final result = await engine.call('runtime.reset');
      final raw = asJsonMap(result['params']);
      state = state.copyWith(
        params: <String, double>{
          for (final entry in raw.entries) entry.key: asDouble(entry.value),
        },
        time: 0,
        playing: false,
        clearMotion: true,
        clearExpression: true,
      );
    } on AmException {
      await load();
    }
  }

  /// 推进一帧（`runtime.step`）。
  Future<void> tick(double dt) async {
    if (dt <= 0) return;
    final engine = ref.read(engineProvider);
    try {
      final result = await engine.call('runtime.step', <String, Object?>{
        'dt': dt,
      });
      final raw = asJsonMap(result['params']);
      state = state.copyWith(
        params: <String, double>{
          for (final entry in raw.entries) entry.key: asDouble(entry.value),
        },
        time: asDouble(result['time'], state.time),
        playing: asBool(result['playing'], state.playing),
      );
    } on AmException {
      // 引擎不支持 runtime.step 时保持静止，但 UI 不崩。
    }
  }

  Future<void> play(String motion, {bool loop = true}) async {
    final engine = ref.read(engineProvider);
    try {
      await engine.call('runtime.play_motion', <String, Object?>{
        'motion': motion,
        'loop': loop,
      });
      state = state.copyWith(playing: true, motion: motion, time: 0);
    } on AmException catch (error) {
      ref
          .read(notificationsProvider.notifier)
          .warn(
            'notice.error.engineCall',
            args: <String, String>{
              'code': error.code,
              'method': 'runtime.play_motion',
            },
            detail: error.message,
          );
    }
  }

  Future<void> pause() async {
    final engine = ref.read(engineProvider);
    state = state.copyWith(playing: false);
    try {
      await engine.call('runtime.stop_motion');
    } on AmException {
      // 忽略。
    }
  }

  Future<void> seek(double time) async {
    final engine = ref.read(engineProvider);
    try {
      final result = await engine.call('runtime.seek', <String, Object?>{
        'time': time,
      });
      final raw = asJsonMap(result['params']);
      state = state.copyWith(
        params: <String, double>{
          for (final entry in raw.entries) entry.key: asDouble(entry.value),
        },
        time: asDouble(result['time'], time),
      );
    } on AmException {
      state = state.copyWith(time: time);
    }
  }

  Future<void> setExpression(String? name) async {
    final engine = ref.read(engineProvider);
    try {
      final result = await engine.call(
        'runtime.set_expression',
        <String, Object?>{'name': name},
      );
      final raw = asJsonMap(result['params']);
      state = state.copyWith(
        expression: name,
        clearExpression: name == null,
        params: <String, double>{
          for (final entry in raw.entries) entry.key: asDouble(entry.value),
        },
      );
    } on AmException {
      state = state.copyWith(expression: name, clearExpression: name == null);
    }
  }

  Future<void> setPhysics(bool enabled) async {
    state = state.copyWith(physicsEnabled: enabled);
    final engine = ref.read(engineProvider);
    try {
      await engine.call('physics.set', <String, Object?>{'enabled': enabled});
    } on AmException {
      // 忽略。
    }
  }

  Future<void> setBlink(bool enabled) async {
    state = state.copyWith(blinkEnabled: enabled);
    final engine = ref.read(engineProvider);
    try {
      await engine.call('runtime.blink', <String, Object?>{'enabled': enabled});
    } on AmException {
      // 忽略。
    }
  }

  Future<void> setBreath(bool enabled) async {
    state = state.copyWith(breathEnabled: enabled);
    final engine = ref.read(engineProvider);
    try {
      await engine.call('runtime.breath', <String, Object?>{
        'enabled': enabled,
      });
    } on AmException {
      // 忽略。
    }
  }

  Future<void> setLipsync({bool? enabled, double? amplitude}) async {
    state = state.copyWith(
      lipsyncEnabled: enabled,
      lipsyncAmplitude: amplitude,
    );
    final engine = ref.read(engineProvider);
    try {
      await engine.call('runtime.lipsync', <String, Object?>{
        'enabled': ?enabled,
        'amplitude': ?amplitude,
      });
    } on AmException {
      // 忽略。
    }
  }
}

final runtimeProvider = NotifierProvider<RuntimeController, RuntimeState>(
  RuntimeController.new,
);
