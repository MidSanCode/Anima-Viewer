/// 安全区回归测试。
///
/// 外壳是自绘的停靠布局，**没有 Scaffold**，所以 Scaffold 那套自动避让刘海 /
/// 状态栏 / 手势条的机制全都不生效。这个测试就是盯着这件事：给一个带安全区的
/// 窗口，确认顶栏和底栏真的让开了，且**背景铺满**（不是留一条白缝）。
///
/// 只测 [SafeAreaInsets] 这一层的行为契约，不依赖具体某个 App 的整棵树 ——
/// 两个 App 的顶栏/底栏 widget 不一样，但用的都是这套 extension。
library;

import 'package:anima_viewer/core/platform/safe_area.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造一个带指定安全区的环境，把 [child] 放进去。
///
/// 外面套一层定高的 `SizedBox`：真实的窗口高度是有界的，而 `MediaQuery` 自己
/// 不给约束 —— 不套的话，任何 `Container` 都会在纵向无限伸展。
Widget _host({
  required Widget child,
  double top = 0,
  double bottom = 0,
  double left = 0,
  double right = 0,
  Size size = const Size(800, 600),
}) {
  return MediaQuery(
    data: MediaQueryData(
      size: size,
      padding: EdgeInsets.only(top: top, bottom: bottom, left: left, right: right),
    ),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: child,
        ),
      ),
    ),
  );
}

/// 一个按本 App 的写法搭出来的顶栏：高度 = 设计高度 + 安全区，内容靠 padding 让开。
///
/// 必须放进一个**受约束**的父级（这里是 `Column`）：真实顶栏在壳里也是 `Column`
/// 的孩子。若把 `Container` 单独丢给无界的父级，它会去吃掉整个可用高度 ——
/// 那是测试替身的问题，不是被测代码的问题。
/// [alignment] 用 `topLeft`，好让 content 紧贴栏的内上边，便于断言位移。
class _ProbeTopBar extends StatelessWidget {
  const _ProbeTopBar({required this.base});
  final double base;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('topbar'),
      height: context.topBarHeight(base),
      padding: EdgeInsets.only(top: context.safeTop),
      color: const Color(0xFF102030),
      alignment: Alignment.topLeft,
      child: const Text('MENU', key: Key('topbar-content')),
    );
  }
}

class _ProbeBottomBar extends StatelessWidget {
  const _ProbeBottomBar({required this.base});
  final double base;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('bottombar'),
      height: context.bottomBarHeight(base),
      padding: EdgeInsets.only(bottom: context.safeBottom),
      color: const Color(0xFF102030),
      alignment: Alignment.bottomLeft,
      child: const Text('STATUS', key: Key('bottombar-content')),
    );
  }
}

void main() {
  testWidgets('桌面：没有安全区时，栏高就是设计高度（行为不变）', (tester) async {
    await tester.pumpWidget(
      _host(
        child: const Column(
          children: <Widget>[_ProbeTopBar(base: 32), Expanded(child: SizedBox())],
        ),
      ),
    );
    expect(tester.getSize(find.byKey(const Key('topbar'))).height, 32);

    await tester.pumpWidget(
      _host(
        child: const Column(
          children: <Widget>[
            Expanded(child: SizedBox()),
            _ProbeBottomBar(base: 24),
          ],
        ),
      ),
    );
    expect(tester.getSize(find.byKey(const Key('bottombar'))).height, 24);
  });

  testWidgets('顶部状态栏：顶栏长高并让开，背景铺到 y=0', (tester) async {
    const statusBar = 44.0;
    await tester.pumpWidget(
      _host(
        top: statusBar,
        child: const Column(
          children: <Widget>[_ProbeTopBar(base: 32), Expanded(child: SizedBox())],
        ),
      ),
    );

    // 栏长高了，总高度 = 设计高度 + 安全区。
    final bar = tester.getRect(find.byKey(const Key('topbar')));
    expect(bar.height, 32 + statusBar);
    // 背景从屏幕最顶边开始铺 —— 不能在上面留一条没有背景的缝。
    expect(bar.top, 0);
    expect(bar.bottom, 32 + statusBar);

    // 内容整块被推到状态栏下面。
    final content = tester.getRect(find.byKey(const Key('topbar-content')));
    expect(
      content.top,
      greaterThanOrEqualTo(statusBar - 1),
      reason: '菜单内容钻到状态栏底下了',
    );
  });

  testWidgets('底部手势条：底栏长高并让开，背景铺到屏幕最底边', (tester) async {
    const gestureBar = 34.0;
    await tester.pumpWidget(
      _host(
        bottom: gestureBar,
        child: const Column(
          children: <Widget>[
            Expanded(child: SizedBox()),
            _ProbeBottomBar(base: 24),
          ],
        ),
      ),
    );

    final bar = tester.getRect(find.byKey(const Key('bottombar')));
    expect(bar.height, 24 + gestureBar);
    expect(bar.bottom, 600, reason: '底栏背景没铺到屏幕最底边');
    expect(bar.top, 600 - 24 - gestureBar);

    final content = tester.getRect(find.byKey(const Key('bottombar-content')));
    expect(
      content.bottom,
      lessThanOrEqualTo(600 - gestureBar),
      reason: '状态栏文字压在手势条上了',
    );
  });

  testWidgets('左右刘海/圆角安全区不影响纵向栏高', (tester) async {
    await tester.pumpWidget(
      _host(
        left: 48,
        right: 48,
        child: const Column(
          children: <Widget>[_ProbeTopBar(base: 32), Expanded(child: SizedBox())],
        ),
      ),
    );
    // 横向安全区由上层布局处理，纵向栏高只吃上下安全区。
    expect(tester.getSize(find.byKey(const Key('topbar'))).height, 32);
  });

  testWidgets('安全区为零时，栏高与内容位置都不变（桌面回归）', (tester) async {
    await tester.pumpWidget(
      _host(
        child: const Column(
          children: <Widget>[
            _ProbeTopBar(base: 32),
            Expanded(child: SizedBox()),
            _ProbeBottomBar(base: 24),
          ],
        ),
      ),
    );
    final top = tester.getRect(find.byKey(const Key('topbar')));
    final bottom = tester.getRect(find.byKey(const Key('bottombar')));
    expect(top.height, 32);
    expect(top.top, 0);
    expect(bottom.height, 24);
    expect(bottom.bottom, 600);

    // 内容紧贴栏的内边缘：padding 为 0 时不该有任何多余位移。
    // 用「相对栏顶的偏移」而不是绝对 0 —— 字体 strut 本身会占几个像素，
    // 那是 Text 的事，跟安全区无关。
    final contentTop =
        tester.getRect(find.byKey(const Key('topbar-content'))).top - top.top;
    expect(
      contentTop,
      lessThan(2),
      reason: '安全区为 0 时菜单内容不该被推下来（偏移 $contentTop）',
    );
  });
}
