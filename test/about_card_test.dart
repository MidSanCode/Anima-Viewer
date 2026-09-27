/// 关于卡片回归测试：版本号 / 构建号 / 开发者文案必须真实渲染。
///
/// 背景：
///  - 版本号以前是写死在界面上的字符串（`'0.1.0'`），且构建号根本不显示；
///    现在统一走 `core/platform/app_info.dart`，由 `app_info_test.dart`
///    守住与 `pubspec.yaml` 的一致性，这里守住「界面上真的显示出来了」。
///  - `about.*` 这些键如果漏加，`.tr()` 会把**原始键名**显示到界面上并在
///    控制台报 `Localization key [about.build] not found`，属于 A0-2 违规。
///
/// 注意：easy_localization 是全局单例，一个测试文件里只建一次
/// EasyLocalization，再用 ValueNotifier 换子节点。
library;

import 'package:anima_viewer/core/i18n/l10n.dart';
import 'package:anima_viewer/core/platform/app_info.dart';
import 'package:anima_viewer/features/common/widgets.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/shared_preferences'),
          (MethodCall call) async =>
              call.method == 'getAll' ? <String, Object>{} : null,
        );
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('AboutCard：显示版本号、构建号与开发者', (tester) async {
    final child = ValueNotifier<Widget>(const SizedBox.shrink());
    addTearDown(child.dispose);

    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: L10n.supportedLocales,
        path: 'assets/translations',
        fallbackLocale: L10n.fallbackLocale,
        useOnlyLangCode: false,
        child: Builder(
          builder: (context) => MaterialApp(
            locale: context.locale,
            supportedLocales: context.supportedLocales,
            localizationsDelegates: context.localizationDelegates,
            home: Scaffold(
              body: SingleChildScrollView(
                child: ValueListenableBuilder<Widget>(
                  valueListenable: child,
                  builder: (_, value, _) => value,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    child.value = const AboutCard();
    await tester.pumpAndSettle();

    expect(
      find.byType(AboutCard),
      findsOneWidget,
      reason: 'AboutCard 没有渲染出来，断言会空过',
    );

    // 具体译文取决于测试进程的语言环境，因此按当前生效语言取期望值，
    // 避免断言写成「只认中文」而在英文环境下误报。
    final active = tester.element(find.byType(AboutCard)).locale;
    final zh = active.languageCode == 'zh';
    final expectTitle = zh ? '赋灵 查看器' : '赋灵 Viewer';
    final expectDeveloperName = zh
        ? '由 MSC 钟码开发（MidSanCode）'
        : 'Developed by MSC MidSanCode';
    final expectVersionLabel = zh ? '版本号' : 'Version';
    final expectBuildLabel = zh ? '构建号' : 'Build';
    final expectDeveloperLabel = zh ? '开发者' : 'Developer';

    // 版本号与构建号都必须出现（不是写死的旧值）。
    expect(find.text(kAppVersion), findsOneWidget);
    expect(find.text(kAppBuildNumber), findsOneWidget);

    // 产品名、开发者和三个标签都必须走翻译。
    expect(find.text(expectTitle), findsOneWidget);
    expect(find.text(expectDeveloperName), findsOneWidget);
    expect(find.text(expectVersionLabel), findsOneWidget);
    expect(find.text(expectBuildLabel), findsOneWidget);
    expect(find.text(expectDeveloperLabel), findsOneWidget);

    // 不能把 i18n 键名直接露在界面上。
    for (final key in <String>[
      'about.version',
      'about.build',
      'about.developer',
      'about.developerName',
      'about.notice',
      'app.title',
    ]) {
      expect(find.text(key), findsNothing, reason: '$key 没有被翻译，原始键名露到界面上了');
    }

    // 版本号与构建号是两个独立的行，不能合成一个「0.1.0+1」。
    expect(find.text(kAppVersionWithBuild), findsNothing);
  });
}
