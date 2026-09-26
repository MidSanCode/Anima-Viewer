/// 起始页：打开工程 / 最近列表 / 示例（AV0-2）。
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/project_controller.dart';
import '../../core/state/settings_controller.dart';
import '../../core/theme/app_theme.dart';
import '../common/widgets.dart';
import 'viewer_actions.dart';

/// 起始页。
class ViewerStartPage extends ConsumerWidget {
  const ViewerStartPage({super.key, required this.onUseSample});

  /// 载入内置示例模型。
  final VoidCallback onUseSample;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = AppTheme.of(context);
    final recent = ref.watch(recentProjectsProvider);
    final project = ref.watch(projectProvider);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    Icons.smart_display_outlined,
                    size: 34,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'app.title'.tr(),
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        'app.description'.tr(),
                        style: TextStyle(fontSize: 11.5, color: tokens.divider),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 26),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: <Widget>[
                  _ActionCard(
                    icon: Icons.folder_open,
                    titleKey: 'viewer.start.open',
                    subtitleKey: 'viewer.start.openHint',
                    onTap: () => ViewerActions.open(context, ref),
                  ),
                  _ActionCard(
                    icon: Icons.unarchive_outlined,
                    titleKey: 'viewer.start.import',
                    subtitleKey: 'viewer.start.importHint',
                    onTap: () => ViewerActions.import(context, ref),
                  ),
                  _ActionCard(
                    icon: Icons.auto_awesome,
                    titleKey: 'start.sample',
                    subtitleKey: 'start.sampleHint',
                    onTap: onUseSample,
                  ),
                ],
              ),
              const SizedBox(height: 22),
              SectionHeader(
                titleKey: 'start.section.recent',
                actions: <Widget>[
                  if (recent.isNotEmpty)
                    SmallTextButton(
                      labelKey: 'start.clearRecent',
                      onPressed: () => ref
                          .read(settingsProvider.notifier)
                          .patch((s) => s.copyWith(recentProjects: <String>[])),
                    ),
                ],
              ),
              if (recent.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 12,
                  ),
                  child: Text(
                    'start.noRecent'.tr(),
                    style: TextStyle(fontSize: 11.5, color: tokens.divider),
                  ),
                )
              else
                for (final path in recent)
                  ListRow(
                    onTap: () => ref.read(projectProvider.notifier).open(path),
                    trailing: SmallIconButton(
                      icon: Icons.close,
                      tooltipKey: 'start.forget',
                      onPressed: () => ref
                          .read(settingsProvider.notifier)
                          .patch(
                            (s) => s.copyWith(
                              recentProjects: s.withoutRecent(path)
                                  .recentProjects,
                            ),
                          ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Text(
                          _basename(path),
                          style: const TextStyle(fontSize: 11.5),
                        ),
                        Text(
                          path,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10, color: tokens.divider),
                        ),
                      ],
                    ),
                  ),
              if (project.busy) ...<Widget>[
                const SizedBox(height: 16),
                const LinearProgressIndicator(minHeight: 2),
              ],
              const SizedBox(height: 22),
              Text(
                'start.hint'.tr(),
                style: TextStyle(fontSize: 10.5, color: tokens.divider),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized.split('/').where((e) => e.isNotEmpty).toList();
    return parts.isEmpty ? path : parts.last;
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.titleKey,
    required this.subtitleKey,
    required this.onTap,
  });

  final IconData icon;
  final String titleKey;
  final String subtitleKey;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTheme.of(context);
    return SizedBox(
      width: 180,
      height: 96,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(tokens.panelRadius),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: tokens.panelHeader,
            borderRadius: BorderRadius.circular(tokens.panelRadius),
            border: Border.all(color: tokens.divider),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(icon, size: 20),
              const Spacer(),
              Text(
                titleKey.tr(),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitleKey.tr(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, color: tokens.divider),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
