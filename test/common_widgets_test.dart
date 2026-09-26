/// 通用控件回归测试。
///
/// `KeyValueRow` 的 `label`（原样文本）入口：把非 i18n 内容传给 `labelKey`
/// 会触发 `Localization key [xxx] not found` 并把原始键显示到界面上（A0-2 违规）。
/// 编辑器的性能面板曾因此把引擎方法名当成翻译键，查看器这里守住同一个约定。
///
/// 注意：easy_localization 是全局单例，同一进程里反复新建 EasyLocalization
/// 会让第二个用例的异步资源加载不完成（断言跑在空树上）。
/// 因此这里只在**一个** testWidgets 里建一次 EasyLocalization，
/// 之后用 ValueNotifier 替换内部子节点。
library;

import 'package:anima_viewer/core/i18n/l10n.dart';
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

  testWidgets('KeyValueRow：label 原样显示，labelKey 走翻译', (tester) async {
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
              body: ValueListenableBuilder<Widget>(
                valueListenable: child,
                builder: (_, value, _) => value,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    /// 替换子节点并等待重建，同时确认控件确实渲染出来了（防止断言空过）。
    Future<void> show(Widget widget) async {
      child.value = widget;
      await tester.pumpAndSettle();
      expect(
        find.byType(KeyValueRow),
        findsOneWidget,
        reason: 'KeyValueRow 没有渲染出来，断言会空过',
      );
    }

    // 1) 引擎方法名这类非 i18n 内容：必须原样显示。
    await show(const KeyValueRow(label: 'runtime.set_param', value: '✓'));
    expect(find.text('runtime.set_param'), findsOneWidget);
    expect(find.text('✓'), findsOneWidget);

    // 2) label 优先于 labelKey：若没有短路 labelKey.tr()，
    //    这里会显示 common.confirm 的译文。
    await show(
      const KeyValueRow(
        label: 'raw.identifier',
        labelKey: 'common.confirm',
        value: 'v',
      ),
    );
    expect(find.text('raw.identifier'), findsOneWidget);
    expect(find.text('common.confirm'), findsNothing);

    // 3) 只给 labelKey 时仍然走翻译，不得露出原始键。
    await show(const KeyValueRow(labelKey: 'common.confirm', value: 'v'));
    expect(find.text('common.confirm'), findsNothing);

    // 4) 两者都不给：构造即断言失败，避免运行期空指针。
    expect(
      () => KeyValueRow(labelKey: null, label: null, value: 'v'),
      throwsA(isA<AssertionError>()),
    );
  });
}
