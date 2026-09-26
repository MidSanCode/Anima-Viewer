/// 编辑器设置：语言、主题、自动保存、渲染质量、快捷键、画布辅助。
///
/// 全部持久化到 `shared_preferences`（A0-2 的“可手动切换并持久化”）。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 语言：`system` 表示跟随系统。
const String kLocaleSystem = 'system';

/// 键盘绑定：动作 id → 组合键（如 `ctrl+z`）。
typedef ShortcutBindings = Map<String, String>;

/// 设置模型。
class AppSettings {
  const AppSettings({
    this.localeCode = kLocaleSystem,
    this.themeMode = ThemeMode.dark,
    this.autosaveSeconds = 300,
    this.renderQuality = 'high',
    this.shortcuts = defaultShortcuts,
    this.showGrid = false,
    this.showGuides = true,
    this.snapEnabled = true,
    this.onionSkin = false,
    this.onionSkinFrames = 3,
    this.engineMode = 'auto',
    this.devicePixelRatioOverride = 0,
    this.layoutJson,
    this.recentProjects = const <String>[],
    this.panelDensity = 'compact',
  });

  final String localeCode;
  final ThemeMode themeMode;

  /// 自动保存间隔（秒）；0 表示关闭。
  final int autosaveSeconds;

  /// `low` / `medium` / `high`。
  final String renderQuality;

  final ShortcutBindings shortcuts;
  final bool showGrid;
  final bool showGuides;
  final bool snapEnabled;
  final bool onionSkin;
  final int onionSkinFrames;

  /// `auto`（先 FFI 后内置） / `local`（强制内置）。
  final String engineMode;

  /// 0 表示自动取设备像素比。
  final double devicePixelRatioOverride;

  /// 上次保存的面板布局。
  final String? layoutJson;

  /// 最近打开的工程（最新在前，最多 12 条）。
  final List<String> recentProjects;

  /// `compact` / `comfortable`。
  final String panelDensity;

  static const ShortcutBindings defaultShortcuts = <String, String>{
    'file.new': 'ctrl+n',
    'file.open': 'ctrl+o',
    'file.save': 'ctrl+s',
    'file.saveAs': 'ctrl+shift+s',
    'file.export': 'ctrl+e',
    'file.import': 'ctrl+i',
    'edit.undo': 'ctrl+z',
    'edit.redo': 'ctrl+y',
    'edit.delete': 'delete',
    'view.fit': 'ctrl+0',
    'view.zoomIn': 'ctrl+=',
    'view.zoomOut': 'ctrl+-',
    'view.flipX': 'ctrl+shift+x',
    'view.flipY': 'ctrl+shift+y',
    'view.toggleGrid': "ctrl+'",
    'motion.play': 'space',
    'motion.prevFrame': 'left',
    'motion.nextFrame': 'right',
    'panel.left': 'ctrl+1',
    'panel.right': 'ctrl+2',
    'panel.bottom': 'ctrl+3',
    'panel.fullscreenCanvas': 'ctrl+shift+f',
  };

  AppSettings copyWith({
    String? localeCode,
    ThemeMode? themeMode,
    int? autosaveSeconds,
    String? renderQuality,
    ShortcutBindings? shortcuts,
    bool? showGrid,
    bool? showGuides,
    bool? snapEnabled,
    bool? onionSkin,
    int? onionSkinFrames,
    String? engineMode,
    double? devicePixelRatioOverride,
    String? layoutJson,
    List<String>? recentProjects,
    String? panelDensity,
  }) => AppSettings(
    localeCode: localeCode ?? this.localeCode,
    themeMode: themeMode ?? this.themeMode,
    autosaveSeconds: autosaveSeconds ?? this.autosaveSeconds,
    renderQuality: renderQuality ?? this.renderQuality,
    shortcuts: shortcuts ?? this.shortcuts,
    showGrid: showGrid ?? this.showGrid,
    showGuides: showGuides ?? this.showGuides,
    snapEnabled: snapEnabled ?? this.snapEnabled,
    onionSkin: onionSkin ?? this.onionSkin,
    onionSkinFrames: onionSkinFrames ?? this.onionSkinFrames,
    engineMode: engineMode ?? this.engineMode,
    devicePixelRatioOverride:
        devicePixelRatioOverride ?? this.devicePixelRatioOverride,
    layoutJson: layoutJson ?? this.layoutJson,
    recentProjects: recentProjects ?? this.recentProjects,
    panelDensity: panelDensity ?? this.panelDensity,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'locale': localeCode,
    'theme': themeMode.name,
    'autosave_seconds': autosaveSeconds,
    'render_quality': renderQuality,
    'shortcuts': shortcuts,
    'show_grid': showGrid,
    'show_guides': showGuides,
    'snap': snapEnabled,
    'onion_skin': onionSkin,
    'onion_skin_frames': onionSkinFrames,
    'engine_mode': engineMode,
    'device_pixel_ratio': devicePixelRatioOverride,
    'layout': layoutJson,
    'recent_projects': recentProjects,
    'panel_density': panelDensity,
  };

  factory AppSettings.fromJson(Map<String, Object?> json) {
    ThemeMode parseTheme(Object? value) {
      switch ('$value') {
        case 'light':
          return ThemeMode.light;
        case 'system':
          return ThemeMode.system;
        default:
          return ThemeMode.dark;
      }
    }

    final shortcuts = <String, String>{...defaultShortcuts};
    final raw = json['shortcuts'];
    if (raw is Map) {
      raw.forEach((key, value) => shortcuts['$key'] = '$value');
    }
    return AppSettings(
      localeCode: '${json['locale'] ?? kLocaleSystem}',
      themeMode: parseTheme(json['theme']),
      autosaveSeconds: (json['autosave_seconds'] as num?)?.toInt() ?? 300,
      renderQuality: '${json['render_quality'] ?? 'high'}',
      shortcuts: shortcuts,
      showGrid: json['show_grid'] == true,
      showGuides: json['show_guides'] != false,
      snapEnabled: json['snap'] != false,
      onionSkin: json['onion_skin'] == true,
      onionSkinFrames: (json['onion_skin_frames'] as num?)?.toInt() ?? 3,
      engineMode: '${json['engine_mode'] ?? 'auto'}',
      devicePixelRatioOverride:
          (json['device_pixel_ratio'] as num?)?.toDouble() ?? 0,
      layoutJson: json['layout'] as String?,
      recentProjects:
          (json['recent_projects'] as List?)?.map((e) => '$e').toList() ??
          const <String>[],
      panelDensity: '${json['panel_density'] ?? 'compact'}',
    );
  }

  /// 最近工程去重插入。
  AppSettings withRecent(String path) {
    final list = <String>[path, ...recentProjects.where((e) => e != path)];
    return copyWith(recentProjects: list.take(12).toList());
  }

  /// 从“最近打开”里移除一条。
  AppSettings withoutRecent(String path) =>
      copyWith(recentProjects: recentProjects.where((e) => e != path).toList());
}

/// 设置控制器。
class SettingsController extends AsyncNotifier<AppSettings> {
  static const String _key = 'anima.editor.settings';

  SharedPreferences? _prefs;

  @override
  Future<AppSettings> build() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      final raw = _prefs?.getString(_key);
      if (raw == null || raw.isEmpty) return const AppSettings();
      return AppSettings.fromJson(jsonDecode(raw) as Map<String, Object?>);
    } on Object {
      // Web/受限平台上持久化失败不应阻塞启动。
      return const AppSettings();
    }
  }

  /// 修改设置并持久化。
  ///
  /// 方法名不用 `update`，避免与 Riverpod 的 `AsyncNotifier.update` 冲突。
  Future<void> patch(AppSettings Function(AppSettings current) change) async {
    final current = state.value ?? const AppSettings();
    final next = change(current);
    state = AsyncData(next);
    await _persist(next);
  }

  Future<void> _persist(AppSettings settings) async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setString(_key, jsonEncode(settings.toJson()));
    } on Object {
      // 忽略持久化失败。
    }
  }

  /// 当前语言（`system` 或具体 locale code）。
  String get localeCode => state.value?.localeCode ?? kLocaleSystem;
}

final settingsProvider = AsyncNotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);
