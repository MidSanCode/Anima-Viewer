/// 查看器通用部件：通知横幅、状态条辅助、偏好设置主体。
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/engine_bootstrap.dart';
import '../../core/i18n/l10n.dart';
import '../../core/state/project_controller.dart';
import '../../core/state/settings_controller.dart';
import '../../core/state/ui_controllers.dart';
import '../../core/theme/app_theme.dart';
import '../common/widgets.dart';

/// 顶部通知横幅 + 引擎降级提示 + 工程进度。
class NoticeBanner extends ConsumerWidget {
  const NoticeBanner({required this.boot, super.key});

  final EngineBootResult boot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = AppTheme.of(context);
    final notices = ref.watch(notificationsProvider);
    final project = ref.watch(projectProvider);

    final children = <Widget>[
      if (boot.warningKey != null)
        _Banner(
          color: tokens.warning,
          titleKey: boot.warningKey!,
          message: boot.notes.isEmpty
              ? null
              : boot.notes.entries
                    .map((entry) => '${entry.key}=${entry.value}')
                    .join(' · '),
          onDismiss: null,
        ),
      for (final notice in notices)
        _Banner(
          color: switch (notice.level) {
            NoticeLevel.error => tokens.danger,
            NoticeLevel.warning => tokens.warning,
            NoticeLevel.success => tokens.accentSecondary,
            NoticeLevel.info => tokens.divider,
          },
          titleKey: notice.messageKey,
          args: notice.args,
          message: notice.detail,
          onDismiss: () =>
              ref.read(notificationsProvider.notifier).dismiss(notice.id ?? ''),
        ),
      if (project.busy)
        LinearProgressIndicator(
          minHeight: 2,
          value: project.progress,
          backgroundColor: tokens.divider,
        ),
    ];

    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.color,
    required this.titleKey,
    required this.message,
    required this.onDismiss,
    this.args = const <String, String>{},
  });

  final Color color;
  final String titleKey;
  final Map<String, String> args;
  final String? message;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTheme.of(context);
    return Container(
      color: color.withValues(alpha: 0.14),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: <Widget>[
          Container(width: 3, height: 14, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              titleKey.tr(namedArgs: args),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5),
            ),
          ),
          if (message != null) ...<Widget>[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                message!,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.5, color: tokens.divider),
              ),
            ),
          ],
          if (onDismiss != null)
            InkWell(
              onTap: onDismiss,
              child: Icon(Icons.close, size: 14, color: tokens.divider),
            ),
        ],
      ),
    );
  }
}

/// 偏好设置主体（语言 / 主题 / 渲染）。
class PreferencesBody extends ConsumerWidget {
  const PreferencesBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    final controller = ref.read(settingsProvider.notifier);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SectionHeader(titleKey: 'settings.section.language'),
          EnumDropdown<String>(
            value: settings.localeCode,
            items: <String>[kLocaleSystem, 'zh-CN', 'en-US'],
            labelOf: (code) => code == kLocaleSystem
                ? 'settings.language.system'.tr()
                : L10n.displayName(L10n.resolve(code, context.locale)),
            onChanged: (value) {
              if (value == null) return;
              controller.patch((s) => s.copyWith(localeCode: value));
              final target = L10n.resolve(
                value,
                WidgetsBinding.instance.platformDispatcher.locale,
              );
              context.setLocale(target);
            },
          ),
          SectionHeader(titleKey: 'settings.section.theme'),
          EnumDropdown<ThemeMode>(
            value: settings.themeMode,
            items: ThemeMode.values,
            labelOf: (mode) => 'settings.theme.${mode.name}'.tr(),
            onChanged: (mode) {
              if (mode == null) return;
              controller.patch((s) => s.copyWith(themeMode: mode));
            },
          ),
          SectionHeader(titleKey: 'settings.section.render'),
          SwitchRow(
            labelKey: 'settings.showGrid',
            value: settings.showGrid,
            onChanged: (value) =>
                controller.patch((s) => s.copyWith(showGrid: value)),
          ),
          SwitchRow(
            labelKey: 'settings.showGuides',
            value: settings.showGuides,
            onChanged: (value) =>
                controller.patch((s) => s.copyWith(showGuides: value)),
          ),
        ],
      ),
    );
  }
}
