/// Anima 契约 v1 的基础类型（纯 Dart，无 Flutter 依赖）。
///
/// 这里只描述 tasks.md §3 冻结契约的**形状**，不包含任何引擎实现。
/// 引擎实现见 [AmEngine] 的两个实现：FFI 动态库与内置降级实现。
library;

/// 引擎调用失败。`code` 与契约的 `error.code` 对齐（如 `UNSUPPORTED`、
/// `PROJECT_NOT_OPEN`、`NO_ENGINE`）。
class AmException implements Exception {
  const AmException(this.code, this.message, {this.detail});

  /// 机器可读错误码。
  final String code;

  /// 面向开发者的英文描述（UI 请用 i18n key 翻译 `code`）。
  final String message;

  /// 附加信息（可能是任意 JSON）。
  final Object? detail;

  @override
  String toString() => 'AmException($code): $message';
}

/// 引擎回推事件（帧呈现、脏标记、进度、错误）。
class AmEvent {
  const AmEvent(this.type, this.data);

  /// 事件名，例如 `frame_presented`。
  final String type;

  /// 事件负载。
  final Map<String, Object?> data;

  /// 从 `{"event":"x", ...}` 解析。
  static AmEvent? parse(Object? raw) {
    if (raw is! Map) return null;
    final map = raw.map((k, v) => MapEntry('$k', v));
    final type = map['event'] ?? map['type'];
    if (type is! String) return null;
    return AmEvent(type, map);
  }

  @override
  String toString() => 'AmEvent($type)';
}

/// `system.capabilities` 的结果。
class AmCapabilities {
  const AmCapabilities({
    this.engine = 'unknown',
    this.sdk = '0.0.0',
    this.format = 'amproj',
    this.minSdk = '0.0.0',
    this.methods = const <String>{},
    this.platform = const <String, Object?>{},
  });

  final String engine;
  final String sdk;
  final String format;
  final String minSdk;

  /// 引擎声明支持的方法名集合。
  final Set<String> methods;

  /// 平台能力，例如 `texture_bridge`、`wasm`。
  final Map<String, Object?> platform;

  static const AmCapabilities unavailable = AmCapabilities(
    engine: 'unavailable',
  );

  factory AmCapabilities.fromJson(Map<String, Object?> json) {
    Object? pick(String a, String b) => json[a] ?? json[b];
    final rawMethods = pick('methods', 'supported_methods');
    final rawPlatform = json['platform'];
    return AmCapabilities(
      engine: '${pick('engine', 'engine_version') ?? 'unknown'}',
      sdk: '${pick('sdk', 'sdk_version') ?? '0.0.0'}',
      format: '${json['format'] ?? 'amproj'}',
      minSdk: '${pick('min_sdk', 'minSdk') ?? '0.0.0'}',
      methods: rawMethods is List
          ? rawMethods.map((e) => '$e').toSet()
          : const <String>{},
      platform: rawPlatform is Map
          ? rawPlatform.map((k, v) => MapEntry('$k', v))
          : const <String, Object?>{},
    );
  }

  bool supports(String method) => methods.contains(method);

  bool hasPlatformFlag(String key) {
    final value = platform[key];
    return value == true || value == 'true' || value == 1;
  }

  AmCapabilities mergeFallback(AmCapabilities other) => AmCapabilities(
    engine: engine == 'unknown' ? other.engine : engine,
    sdk: sdk == '0.0.0' ? other.sdk : sdk,
    format: format,
    minSdk: minSdk == '0.0.0' ? other.minSdk : minSdk,
    methods: methods.isEmpty ? other.methods : methods,
    platform: platform.isEmpty ? other.platform : platform,
  );
}

/// `am_renderer_texture_info` 的结果。
class AmTextureInfo {
  const AmTextureInfo({
    required this.width,
    required this.height,
    this.format = 2,
    this.nativeHandle = 0,
    this.textureId = 0,
  });

  final int width;
  final int height;

  /// 1 = RGBA8，2 = BGRA8（默认）。
  final int format;

  /// 平台原生句柄（Windows 为 DXGI 共享 NT handle）。
  final int nativeHandle;

  /// Flutter 外部纹理注册后的 id；0 表示尚未注册。
  final int textureId;

  /// 是否可以直接交给 `Texture` widget 使用。
  bool get isBridged => textureId > 0;

  AmTextureInfo copyWith({int? textureId}) => AmTextureInfo(
    width: width,
    height: height,
    format: format,
    nativeHandle: nativeHandle,
    textureId: textureId ?? this.textureId,
  );

  @override
  String toString() =>
      'AmTextureInfo(${width}x$height fmt=$format texture=$textureId)';
}

/// 校验问题（`project.validate` 的条目）。
class AmValidationIssue {
  const AmValidationIssue({
    required this.code,
    required this.path,
    this.message = '',
    this.severity = 'error',
  });

  final String code;
  final String path;
  final String message;

  /// `error` / `warning` / `info`。
  final String severity;

  bool get isError => severity == 'error';

  factory AmValidationIssue.fromJson(Map<String, Object?> json) {
    return AmValidationIssue(
      code: '${json['code'] ?? 'UNKNOWN'}',
      path: '${json['path'] ?? ''}',
      message: '${json['message'] ?? ''}',
      severity: '${json['severity'] ?? 'error'}',
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'code': code,
    'path': path,
    'message': message,
    'severity': severity,
  };

  @override
  String toString() => '[$severity] $code $path';
}

/// 校验结果汇总。
class AmValidationReport {
  const AmValidationReport(this.issues);

  final List<AmValidationIssue> issues;

  bool get ok => issues.every((i) => !i.isError);

  int get errorCount => issues.where((i) => i.severity == 'error').length;

  int get warningCount => issues.where((i) => i.severity == 'warning').length;

  factory AmValidationReport.fromJson(Object? raw) {
    if (raw is Map) {
      final list = raw['issues'];
      if (list is List) {
        return AmValidationReport(
          list
              .whereType<Map>()
              .map((e) => AmValidationIssue.fromJson(e.cast<String, Object?>()))
              .toList(growable: false),
        );
      }
    }
    if (raw is List) {
      return AmValidationReport(
        raw
            .whereType<Map>()
            .map((e) => AmValidationIssue.fromJson(e.cast<String, Object?>()))
            .toList(growable: false),
      );
    }
    return const AmValidationReport(<AmValidationIssue>[]);
  }

  @override
  String toString() =>
      'AmValidationReport(errors=$errorCount, warnings=$warningCount)';
}

/// 节点类别（tasks.md §1.4 的核心词汇）。
enum AmNodeKind {
  part('part'),
  drawable('drawable'),
  warpDeformer('warp_deformer'),
  rotationDeformer('rotation_deformer'),
  unknown('unknown');

  const AmNodeKind(this.wire);

  final String wire;

  static AmNodeKind parse(Object? value) {
    final text = '$value';
    for (final kind in AmNodeKind.values) {
      if (kind.wire == text) return kind;
    }
    return AmNodeKind.unknown;
  }

  bool get isDeformer =>
      this == AmNodeKind.warpDeformer || this == AmNodeKind.rotationDeformer;
}

/// 混合模式（tasks.md §1.4）。
enum AmBlendMode {
  normal('normal'),
  multiply('multiply'),
  screen('screen'),
  additive('additive');

  const AmBlendMode(this.wire);

  final String wire;

  static AmBlendMode parse(Object? value) {
    final text = '$value';
    for (final mode in AmBlendMode.values) {
      if (mode.wire == text) return mode;
    }
    return AmBlendMode.normal;
  }
}

/// 关键形混合类型（tasks.md §1.1 / §1.4）。
enum AmKeyformBlend {
  normal('normal'),
  multiply('multiply'),
  screen('screen'),
  add('add');

  const AmKeyformBlend(this.wire);

  final String wire;

  static AmKeyformBlend parse(Object? value) {
    final text = '$value';
    for (final mode in AmKeyformBlend.values) {
      if (mode.wire == text) return mode;
    }
    return AmKeyformBlend.normal;
  }
}

/// 插值类型（动画曲线）。
enum AmInterpolation {
  linear('linear'),
  step('step'),
  bezier('bezier');

  const AmInterpolation(this.wire);

  final String wire;

  static AmInterpolation parse(Object? value) {
    final text = '$value';
    for (final mode in AmInterpolation.values) {
      if (mode.wire == text) return mode;
    }
    return AmInterpolation.linear;
  }
}

/// 简单的 JSON 取值助手，避免到处写 `as Map<String, Object?>`。
Map<String, Object?> asJsonMap(Object? value) {
  if (value is Map) return value.map((k, v) => MapEntry('$k', v));
  return const <String, Object?>{};
}

List<Object?> asJsonList(Object? value) =>
    value is List ? value.toList(growable: false) : const <Object?>[];

double asDouble(Object? value, [double fallback = 0]) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? fallback;
  return fallback;
}

int asInt(Object? value, [int fallback = 0]) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

bool asBool(Object? value, [bool fallback = false]) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) return value == 'true' || value == '1';
  return fallback;
}
