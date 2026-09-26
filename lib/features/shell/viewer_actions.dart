/// 查看器动作：打开 / 导入 / 截图 / 关闭（AV0-2、AV2-2）。
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/file_service.dart';
import '../../core/state/project_controller.dart';
import '../../core/state/settings_controller.dart';
import '../../core/state/ui_controllers.dart';
import '../canvas/viewer_canvas.dart';

/// 查看器顶层动作集合。
class ViewerActions {
  const ViewerActions._();

  /// 打开工程目录或 `.amproj` 包。
  static Future<void> open(BuildContext context, WidgetRef ref) async {
    final files = await FileService.pickFiles(
      extensions: const <String>['amproj'],
      dialogTitle: 'dialog.openProject'.tr(),
    );
    if (files.isNotEmpty) {
      final path = files.first.path;
      if (path != null) {
        await ref.read(projectProvider.notifier).open(path);
        return;
      }
    }
    final directory = await FileService.pickDirectory(
      dialogTitle: 'dialog.openProjectDir'.tr(),
    );
    if (directory == null) return;
    await ref.read(projectProvider.notifier).open(directory);
  }

  /// 导入 `.amproj` 到目录后打开。
  static Future<void> import(BuildContext context, WidgetRef ref) async {
    final files = await FileService.pickFiles(
      extensions: const <String>['amproj'],
      dialogTitle: 'dialog.importProject'.tr(),
    );
    if (files.isEmpty) return;
    final source = files.first.path;
    if (source == null) {
      ref
          .read(notificationsProvider.notifier)
          .warn('notice.project.importNeedsPath');
      return;
    }
    if (!context.mounted) return;
    final directory = await FileService.pickDirectory(
      dialogTitle: 'dialog.importTarget'.tr(),
    );
    if (directory == null) return;
    await ref.read(projectProvider.notifier).importPackage(source, directory);
  }

  /// 拖放打开：`.amproj` 文件或工程目录。
  static Future<void> openDropped(WidgetRef ref, String path) async {
    await ref.read(projectProvider.notifier).open(path);
  }

  /// 截图并保存。
  static Future<void> screenshot(WidgetRef ref, GlobalKey boundaryKey) async {
    final bytes = await captureCanvas(boundaryKey);
    if (bytes == null) {
      ref
          .read(notificationsProvider.notifier)
          .warn('viewer.render.screenshotFailed');
      return;
    }
    final target = await FileService.saveBytes(
      suggestedName:
          'anima_${DateTime.now().millisecondsSinceEpoch ~/ 1000}.png',
      bytes: bytes,
      mimeType: 'image/png',
    );
    if (target != null) {
      ref
          .read(notificationsProvider.notifier)
          .success('viewer.render.screenshotSaved');
    }
  }

  /// 从最近列表移除（设置层补丁的小包装，供 UI 复用）。
  static void forgetRecent(WidgetRef ref, String path) {
    ref
        .read(settingsProvider.notifier)
        .patch(
          (s) =>
              s.copyWith(recentProjects: s.withoutRecent(path).recentProjects),
        );
  }
}
