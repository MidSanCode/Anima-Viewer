/// 查看器外壳：顶栏 + 画布 + 右侧面板列 + 通知 + 拖放打开（AV0-2/3）。
library;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/engine_bootstrap.dart';
import '../../core/i18n/l10n.dart';
import '../../core/layout/panel_frame.dart';
import '../../core/platform/safe_area.dart';
import '../../core/platform/window_title.dart';
import '../../core/state/engine_providers.dart';
import '../../core/state/project_controller.dart';
import '../../core/state/runtime_controller.dart';
import '../../core/state/settings_controller.dart';
import '../../core/state/ui_controllers.dart';
import '../../core/theme/app_theme.dart';
import '../canvas/viewer_canvas.dart';
import '../common/widgets.dart';
import '../panels/debug_panels.dart';
import '../panels/playback_panels.dart';
import '../panels/report_panels.dart';
import 'viewer_actions.dart';
import 'viewer_start_page.dart';
import 'viewer_widgets.dart';

/// 查看器外壳。
class ViewerShell extends ConsumerStatefulWidget {
  const ViewerShell({super.key});

  @override
  ConsumerState<ViewerShell> createState() => _ViewerShellState();
}

class _ViewerShellState extends ConsumerState<ViewerShell>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  final GlobalKey _boundaryKey = GlobalKey();
  bool _dragging = false;
  bool _localeSynced = false;
  bool _sampleLoaded = false;
  int _panelIndex = 0;

  static const List<_PanelSpec> _panels = <_PanelSpec>[
    _PanelSpec(id: 'motions', titleKey: 'panel.timeline', icon: Icons.movie),
    _PanelSpec(
      id: 'expressions',
      titleKey: 'panel.expression',
      icon: Icons.emoji_emotions_outlined,
    ),
    _PanelSpec(id: 'params', titleKey: 'panel.parameter', icon: Icons.tune),
    _PanelSpec(id: 'effects', titleKey: 'panel.physics', icon: Icons.waves),
    _PanelSpec(
      id: 'performance',
      titleKey: 'panel.performance',
      icon: Icons.speed,
    ),
    _PanelSpec(
      id: 'render',
      titleKey: 'viewer.render.title',
      icon: Icons.tonality,
    ),
    _PanelSpec(
      id: 'export',
      titleKey: 'viewer.export.title',
      icon: Icons.ios_share,
    ),
    _PanelSpec(
      id: 'integration',
      titleKey: 'viewer.integration.title',
      icon: Icons.code,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1000000;
    _lastTick = elapsed;
    if (dt <= 0 || dt > 0.5) return;
    final playback = ref.read(viewerPlaybackProvider);
    final runtime = ref.read(runtimeProvider);
    if (playback.playing && playback.motion != null) {
      final time = ref.read(viewerPlaybackProvider.notifier).advance(dt);
      ref.read(runtimeProvider.notifier).seek(time);
    } else if (runtime.loaded) {
      // 无动作时也推进自动效果（眨眼/呼吸/物理）。
      ref.read(runtimeProvider.notifier).tick(dt);
    }
  }

  @override
  Widget build(BuildContext context) {
    final boot = ref.watch(engineBootProvider);
    return boot.when(
      loading: () => _Splash(),
      error: (error, stack) => _BootFailure(
        message: '$error',
        onRetry: () => ref.invalidate(engineBootProvider),
      ),
      data: (result) => _buildShell(context, result),
    );
  }

  Widget _buildShell(BuildContext context, EngineBootResult boot) {
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    _syncLocale(settings);

    final project = ref.watch(projectProvider);
    final tokens = AppTheme.of(context);
    final hasModel = project.hasProject || _sampleLoaded;

    return WindowTitleSync(
      title: composeWindowTitle(
        context,
        projectPath: project.path ?? project.projectDir,
      ),
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyO, control: true): () =>
              ViewerActions.open(context, ref),
          const SingleActivator(LogicalKeyboardKey.space): () {
            final playback = ref.read(viewerPlaybackProvider);
            if (playback.motion != null) {
              ref.read(viewerPlaybackProvider.notifier).toggle();
              final runtime = ref.read(runtimeProvider);
              if (playback.playing) {
                ref.read(runtimeProvider.notifier).pause();
              } else if (runtime.motion != null) {
                ref.read(runtimeProvider.notifier).play(runtime.motion!);
              }
            }
          },
          const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
              ref.read(viewportProvider.notifier).requestFit(),
        },
        child: Focus(
          autofocus: true,
          child: DropTarget(
            onDragEntered: (_) => setState(() => _dragging = true),
            onDragExited: (_) => setState(() => _dragging = false),
            onDragDone: (details) async {
              setState(() => _dragging = false);
              if (details.files.isEmpty) return;
              await ViewerActions.openDropped(ref, details.files.first.path);
            },
            child: Stack(
              children: <Widget>[
                Scaffold(
                  backgroundColor: AppTheme.of(context).panelBackground,
                  body: Column(
                    children: <Widget>[
                      _TopBar(
                        onOpen: () => ViewerActions.open(context, ref),
                        onScreenshot: () =>
                            ViewerActions.screenshot(ref, _boundaryKey),
                        onPreferences: () => _showPreferences(context),
                        onAbout: () => _showAbout(context),
                      ),
                      NoticeBanner(boot: boot),
                      Expanded(
                        child: hasModel
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: <Widget>[
                                  Expanded(
                                    child: ViewerCanvas(
                                      boundaryKey: _boundaryKey,
                                    ),
                                  ),
                                  _PanelColumn(
                                    panels: _panels,
                                    index: _panelIndex,
                                    onIndexChanged: (index) =>
                                        setState(() => _panelIndex = index),
                                  ),
                                ],
                              )
                            : ViewerStartPage(
                                onUseSample: () {
                                  setState(() => _sampleLoaded = true);
                                },
                              ),
                      ),
                      const ViewerStatusBar(),
                    ],
                  ),
                ),
                if (_dragging)
                  IgnorePointer(
                    child: Container(
                      color: tokens.accentSecondary.withValues(alpha: 0.12),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.file_open_outlined,
                        size: 48,
                        color: tokens.accentSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 让界面语言跟随设置。
  void _syncLocale(AppSettings settings) {
    if (_localeSynced) return;
    _localeSynced = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = L10n.resolve(
        settings.localeCode,
        WidgetsBinding.instance.platformDispatcher.locale,
      );
      if (context.locale != target) context.setLocale(target);
    });
  }

  void _showPreferences(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('dialog.preferences'.tr()),
        content: const SizedBox(width: 380, child: PreferencesBody()),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text('common.close'.tr()),
          ),
        ],
      ),
    );
  }

  void _showAbout(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('app.title'.tr()),
        content: const AboutCard(),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text('common.close'.tr()),
          ),
        ],
      ),
    );
  }
}

class _PanelSpec {
  const _PanelSpec({
    required this.id,
    required this.titleKey,
    required this.icon,
  });

  final String id;
  final String titleKey;
  final IconData icon;
}

/// 顶栏。
class _TopBar extends ConsumerWidget {
  const _TopBar({
    required this.onOpen,
    required this.onScreenshot,
    required this.onPreferences,
    required this.onAbout,
  });

  final VoidCallback onOpen;
  final VoidCallback onScreenshot;
  final VoidCallback onPreferences;
  final VoidCallback onAbout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = AppTheme.of(context);
    final project = ref.watch(projectProvider);
    final playback = ref.watch(viewerPlaybackProvider);

    return Container(
      // 高度要**加上**顶部安全区：条本身长高、背景照样铺到屏幕最上边，内容
      // 再靠 padding 让开状态栏。直接把整根 Column 包 SafeArea 的话，上面会
      // 留一条没有背景的空白，看着像渲染坏了。
      height: context.topBarHeight(40),
      decoration: BoxDecoration(
        color: tokens.panelHeader,
        border: Border(bottom: BorderSide(color: tokens.divider)),
      ),
      padding: EdgeInsets.only(
        left: 8,
        right: 8,
        top: context.safeTop,
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.smart_display_outlined, size: 16, color: tokens.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              project.displayName ?? project.name ?? 'app.title'.tr(),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.folder_open, size: 18),
            tooltip: 'menu.file.open'.tr(),
            onPressed: onOpen,
          ),
          IconButton(
            icon: Icon(
              playback.playing ? Icons.pause : Icons.play_arrow,
              size: 18,
            ),
            tooltip: playback.playing
                ? 'motion.pause'.tr()
                : 'motion.play'.tr(),
            onPressed: playback.motion == null
                ? null
                : () {
                    if (playback.playing) {
                      ref.read(viewerPlaybackProvider.notifier).pause();
                      ref.read(runtimeProvider.notifier).pause();
                    } else {
                      ref.read(viewerPlaybackProvider.notifier).toggle();
                      ref
                          .read(runtimeProvider.notifier)
                          .play(playback.motion ?? '');
                    }
                  },
          ),
          IconButton(
            icon: const Icon(Icons.photo_camera, size: 18),
            tooltip: 'viewer.render.screenshot'.tr(),
            onPressed: onScreenshot,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 18),
            onSelected: (value) {
              if (value == 'preferences') onPreferences();
              if (value == 'about') onAbout();
            },
            itemBuilder: (context) => <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'preferences',
                child: Text('menu.help.preferences'.tr()),
              ),
              PopupMenuItem<String>(
                value: 'about',
                child: Text('menu.help.about'.tr()),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 右侧面板列。
class _PanelColumn extends StatelessWidget {
  const _PanelColumn({
    required this.panels,
    required this.index,
    required this.onIndexChanged,
  });

  final List<_PanelSpec> panels;
  final int index;
  final ValueChanged<int> onIndexChanged;

  static const Map<String, WidgetBuilder> _builders = <String, WidgetBuilder>{
    'motions': _buildMotion,
    'expressions': _buildExpressions,
    'params': _buildParams,
    'effects': _buildEffects,
    'performance': _buildPerformance,
    'render': _buildRender,
    'export': _buildExport,
    'integration': _buildIntegration,
  };

  static Widget _buildMotion(BuildContext context) => const MotionsPanel();
  static Widget _buildExpressions(BuildContext context) =>
      const ExpressionsPanel();
  static Widget _buildParams(BuildContext context) => const ParamsPanel();
  static Widget _buildEffects(BuildContext context) => const EffectsPanel();
  static Widget _buildPerformance(BuildContext context) =>
      const PerformancePanel();
  static Widget _buildRender(BuildContext context) => const RenderPanel();
  static Widget _buildExport(BuildContext context) => const ExportPanel();
  static Widget _buildIntegration(BuildContext context) =>
      const IntegrationPanel();

  @override
  Widget build(BuildContext context) {
    final tokens = AppTheme.of(context);
    final spec = panels[index.clamp(0, panels.length - 1)];
    final builder = _builders[spec.id];
    return Container(
      width: 320,
      decoration: BoxDecoration(
        color: tokens.panelBackground,
        border: Border(left: BorderSide(color: tokens.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: tokens.panelHeader,
              border: Border(bottom: BorderSide(color: tokens.divider)),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: <Widget>[
                        for (var i = 0; i < panels.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(right: 2),
                            child: ChoiceChip(
                              label: Icon(panels[i].icon, size: 14),
                              tooltip: panels[i].titleKey.tr(),
                              selected: i == index,
                              visualDensity: VisualDensity.compact,
                              onSelected: (_) => onIndexChanged(i),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: builder == null
                ? Center(child: Text('panel.missing'.tr()))
                : PanelFrame(titleKey: spec.titleKey, child: builder(context)),
          ),
        ],
      ),
    );
  }
}

/// 状态栏。
class ViewerStatusBar extends ConsumerWidget {
  const ViewerStatusBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = AppTheme.of(context);
    final runtime = ref.watch(runtimeProvider);
    final viewport = ref.watch(viewportProvider);

    return Container(
      // 同上：条长高、背景铺到底，内容靠 padding 让开底部手势条。
      height: context.bottomBarHeight(24),
      padding: EdgeInsets.only(
        left: 10,
        right: 10,
        bottom: context.safeBottom,
      ),
      decoration: BoxDecoration(
        color: tokens.panelHeader,
        border: Border(top: BorderSide(color: tokens.divider)),
      ),
      child: Row(
        children: <Widget>[
          Text(
            runtime.motion == null
                ? 'status.noMotion'.tr()
                : 'status.motion'.tr(
                    namedArgs: <String, String>{
                      'name': runtime.motion!,
                      'time': runtime.time.toStringAsFixed(2),
                    },
                  ),
            style: TextStyle(fontSize: 10.5, color: tokens.textMuted),
          ),
          const Spacer(),
          Text(
            'status.zoom'.tr(
              namedArgs: <String, String>{
                'value': viewport.zoom.toStringAsFixed(2),
              },
            ),
            style: TextStyle(fontSize: 10.5, color: tokens.textMuted),
          ),
        ],
      ),
    );
  }
}

class _Splash extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppTheme.of(context).panelBackground,
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text('app.starting'.tr(), style: const TextStyle(fontSize: 12)),
        ],
      ),
    ),
  );
}

class _BootFailure extends StatelessWidget {
  const _BootFailure({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTheme.of(context);
    return Scaffold(
      backgroundColor: tokens.panelBackground,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.error_outline, size: 32, color: tokens.danger),
              const SizedBox(height: 12),
              Text(
                'engine.error.title'.tr(),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              SelectableText(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: tokens.textMuted),
              ),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: onRetry,
                child: Text('engine.error.retry'.tr()),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
