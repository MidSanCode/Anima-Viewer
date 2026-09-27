/// 报告与产出面板：性能检查（AV2-1）、渲染设置（AV2-2）、
/// 运行时包导出（AV2-3）、第三方接入代码片段（AV3-1）。
library;

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/file_service.dart';
import '../../core/state/document_controller.dart';
import '../../core/state/engine_providers.dart';
import '../../core/state/project_controller.dart';
import '../../core/state/settings_controller.dart';
import '../../core/state/ui_controllers.dart';
import '../../core/theme/app_theme.dart';
import '../common/widgets.dart';

/// 性能检查报告。
class PerformancePanel extends ConsumerWidget {
  const PerformancePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = AppTheme.of(context);
    final boot = ref.watch(engineStatusProvider);
    final capabilities = ref.watch(engineCapabilitiesProvider);
    final statsAsync = ref.watch(statsProvider);

    return PanelScroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SectionHeader(titleKey: 'panel.performance.section.engine'),
          KeyValueRow(
            labelKey: 'panel.performance.backend',
            value: '${boot.backend.id} · ${boot.backend.label.tr()}',
          ),
          KeyValueRow(
            labelKey: 'panel.performance.engineVersion',
            value: capabilities.engine,
          ),
          KeyValueRow(
            labelKey: 'panel.performance.sdk',
            value: capabilities.sdk,
          ),
          SectionHeader(titleKey: 'panel.performance.section.stats'),
          statsAsync.when(
            loading: () => Text('common.loading'.tr()),
            error: (error, _) => Text('$error'),
            data: (stats) => Column(
              children: <Widget>[
                for (final entry in stats.entries)
                  KeyValueRow(
                    labelKey: 'stat.${entry.key}',
                    value: '${entry.value}',
                  ),
              ],
            ),
          ),
          SectionHeader(titleKey: 'panel.performance.section.capabilities'),
          Text(
            capabilities.methods.isEmpty
                ? 'viewer.performance.noCapabilities'.tr()
                : (capabilities.methods.toList()..sort()).join(' · '),
            style: TextStyle(fontSize: 10.5, color: tokens.textMuted),
          ),
        ],
      ),
    );
  }
}

/// 渲染设置。
class RenderPanel extends ConsumerWidget {
  const RenderPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    final controller = ref.read(settingsProvider.notifier);

    return PanelScroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SectionHeader(titleKey: 'viewer.render.section.quality'),
          EnumDropdown<String>(
            value: settings.renderQuality,
            items: const <String>['low', 'medium', 'high'],
            labelOf: (value) => 'settings.quality.$value'.tr(),
            onChanged: (value) {
              if (value == null) return;
              controller.patch((s) => s.copyWith(renderQuality: value));
            },
          ),
          LabeledSlider(
            label: 'settings.devicePixelRatio'.tr(),
            value: settings.devicePixelRatioOverride,
            min: 0.5,
            max: 4,
            defaultValue: 1,
            onChanged: (value) => controller.patch(
              (s) => s.copyWith(devicePixelRatioOverride: value),
            ),
          ),
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

/// 导出面板。
class ExportPanel extends ConsumerWidget {
  const ExportPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final project = ref.watch(projectProvider);
    final tokens = AppTheme.of(context);

    return PanelScroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SectionHeader(titleKey: 'viewer.export.section.package'),
          Text(
            'viewer.export.packageHint'.tr(),
            style: TextStyle(fontSize: 10.5, color: tokens.textMuted),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: SmallTextButton(
              labelKey: 'viewer.export.runtimePackage',
              onPressed: project.hasProject ? () => _exportRuntime(ref) : null,
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: SmallTextButton(
              labelKey: 'menu.file.export',
              onPressed: project.hasProject
                  ? () async {
                      final directory = await FileService.pickDirectory(
                        dialogTitle: 'dialog.exportTo'.tr(),
                      );
                      if (directory == null || !context.mounted) return;
                      await ref
                          .read(projectProvider.notifier)
                          .export(
                            outPath:
                                '$directory${Platform.pathSeparator}model.amproj',
                          );
                    }
                  : null,
            ),
          ),
          if (project.exportPath != null) ...<Widget>[
            const SizedBox(height: 8),
            KeyValueRow(
              labelKey: 'panel.validation.lastExport',
              value: project.exportPath!,
            ),
            KeyValueRow(
              labelKey: 'panel.validation.sha256',
              value: project.exportSha256 ?? '—',
            ),
          ],
        ],
      ),
    );
  }

  /// 运行时包：只打包 `info.json` + `assets/` + `spec/`（不含注册表与元数据）。
  Future<void> _exportRuntime(WidgetRef ref) async {
    final project = ref.read(projectProvider);
    final dir = project.projectDir;
    if (dir == null) return;
    try {
      final bytes = await _runtimePackageBytes(dir);
      final target = await FileService.saveBytes(
        suggestedName: '${project.name ?? 'model'}.runtime.zip',
        bytes: Uint8List.fromList(bytes),
        mimeType: 'application/zip',
      );
      if (target != null) {
        ref
            .read(notificationsProvider.notifier)
            .success(
              'notice.project.exported',
              args: <String, String>{'path': target},
            );
      }
    } on Object catch (error) {
      ref
          .read(notificationsProvider.notifier)
          .error(
            'notice.error.commandFailed',
            args: <String, String>{'op': 'runtime.package'},
            detail: '$error',
          );
    }
  }

  Future<List<int>> _runtimePackageBytes(String dir) async {
    final archive = Archive();
    void addFile(String relative, List<int> bytes) {
      archive.addFile(ArchiveFile(relative, bytes.length, bytes));
    }

    final info = File('$dir${Platform.pathSeparator}info.json');
    if (info.existsSync()) addFile('info.json', info.readAsBytesSync());

    final specDir = Directory('$dir${Platform.pathSeparator}spec');
    if (specDir.existsSync()) {
      for (final entity in specDir.listSync(recursive: true)) {
        if (entity is! File) continue;
        final relative = entity.path.replaceAll(r'\', '/').split('spec/').last;
        addFile('spec/$relative', entity.readAsBytesSync());
      }
    }

    final assetsDir = Directory('$dir${Platform.pathSeparator}assets');
    if (assetsDir.existsSync()) {
      for (final entity in assetsDir.listSync(recursive: true)) {
        if (entity is! File) continue;
        final relative = entity.path
            .replaceAll(r'\', '/')
            .split('assets/')
            .last;
        addFile('assets/$relative', entity.readAsBytesSync());
      }
    }

    return ZipEncoder().encode(archive);
  }
}

/// 第三方接入代码片段。
/// 第三方接入代码片段。
class IntegrationPanel extends ConsumerWidget {
  const IntegrationPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = AppTheme.of(context);
    final project = ref.watch(projectProvider);
    final name = project.name ?? 'model';

    final snippets = <(String, String)>[
      ('viewer.integration.c', _cSnippet(name)),
      ('viewer.integration.dart', _dartSnippet(name)),
      ('viewer.integration.js', _jsSnippet(name)),
    ];

    return PanelScroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'viewer.integration.hint'.tr(),
            style: TextStyle(fontSize: 10.5, color: tokens.textMuted),
          ),
          const SizedBox(height: 8),
          for (final (labelKey, code) in snippets) ...<Widget>[
            SectionHeader(
              titleKey: labelKey,
              actions: <Widget>[
                SmallTextButton(
                  labelKey: 'viewer.integration.copy',
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: code));
                    if (!context.mounted) return;
                    ref
                        .read(notificationsProvider.notifier)
                        .success('viewer.integration.copied');
                  },
                ),
              ],
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: tokens.panelHeader,
                borderRadius: BorderRadius.circular(tokens.panelRadius),
                border: Border.all(color: tokens.divider),
              ),
              child: SelectableText(
                code,
                style: const TextStyle(
                  fontSize: 10,
                  fontFamily: 'monospace',
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }

  String _cSnippet(String name) =>
      '''
#include "anima_engine.h"

int main(void) {
  AmEngine *engine = am_engine_create();
  am_call(engine, "project.open", "{\\"path\\":\\"$name.amproj\\"}", NULL);
  am_call(engine, "runtime.play_motion", "{\\"motion\\":\\"Idle\\"}", NULL);
  /* 每帧： */
  am_call(engine, "runtime.step", "{\\"dt\\":0.016}", NULL);
  am_engine_destroy(engine);
  return 0;
}
''';

  String _dartSnippet(String name) =>
      '''
import 'package:anima_engine/anima_engine.dart';

Future<void> main() async {
  final engine = AnimaEngine();
  await engine.initialize(width: 1280, height: 720);
  await engine.call('project.open', {'path': '$name.amproj'});
  await engine.call('runtime.play_motion', {'motion': 'Idle', 'loop': true});
  // 每帧：
  await engine.call('runtime.step', {'dt': 1 / 60});
  await engine.dispose();
}
''';

  String _jsSnippet(String name) =>
      '''
import initAnima from './anima_engine.js';

const engine = await initAnima({ width: 1280, height: 720 });
await engine.call('project.open', { path: '$name.amproj' });
await engine.call('runtime.play_motion', { motion: 'Idle', loop: true });

function frame() {
  engine.call('runtime.step', { dt: 1 / 60 });
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
''';
}
