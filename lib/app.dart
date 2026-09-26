/// 应用根：主题、语言（AV0-1 / A0-6）。
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/state/settings_controller.dart';
import 'core/theme/app_theme.dart';
import 'features/shell/viewer_shell.dart';

/// 查看器应用。
class AnimaViewerApp extends ConsumerWidget {
  const AnimaViewerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).value;

    return MaterialApp(
      onGenerateTitle: (context) => 'app.title'.tr(),
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: settings?.themeMode ?? ThemeMode.dark,
      locale: context.locale,
      supportedLocales: context.supportedLocales,
      localizationsDelegates: context.localizationDelegates,
      home: const ViewerShell(),
    );
  }
}
