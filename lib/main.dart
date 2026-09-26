/// 入口：初始化本地化，安装全局错误界面，启动应用。
library;

import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/i18n/l10n.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await EasyLocalization.ensureInitialized();

  // A0-5：任何未捕获的构建异常都给出可读提示，而不是白屏。
  ErrorWidget.builder = (FlutterErrorDetails details) =>
      _FallbackError(message: details.exceptionAsString());

  runApp(
    ProviderScope(
      child: EasyLocalization(
        supportedLocales: L10n.supportedLocales,
        path: 'assets/translations',
        fallbackLocale: L10n.fallbackLocale,
        useOnlyLangCode: false,
        saveLocale: true,
        child: const AnimaViewerApp(),
      ),
    ),
  );
}

class _FallbackError extends StatelessWidget {
  const _FallbackError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: ui.TextDirection.ltr,
      child: Container(
        color: const Color(0xFF1B1D21),
        padding: const EdgeInsets.all(16),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.warning_amber_rounded,
              color: Color(0xFFE0A458),
              size: 28,
            ),
            const SizedBox(height: 10),
            Text(
              'ui.renderError'.tr(),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFE6E6E6), fontSize: 12),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: SingleChildScrollView(
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF9AA0A6),
                    fontSize: 10,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
