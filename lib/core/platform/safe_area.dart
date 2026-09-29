import 'package:flutter/widgets.dart';

/// 移动端的安全区适配。
///
/// 外壳是自绘的停靠布局（一根 `Column`：菜单栏 / 工具栏 / 内容 / 状态栏），
/// **不是** `Scaffold`，所以 `Scaffold` 那些自动处理刘海和状态栏的机制一个都
/// 不会生效 —— 不处理的话，顶部菜单栏会直接钻到系统状态栏底下，底部状态栏
/// 会跟手势条重叠，两边都点不着。
///
/// 这里不把整根 `Column` 包进 `SafeArea`：那样上下会各留一条**没有任何背景**
/// 的空白，看起来像渲染坏了。正确的做法是把内边距加进**条本身**——让它长高、
/// 把背景一直铺到屏幕边，内容再让开安全区。所以这些方法返回的都是「要额外
/// 加多少 padding」，而不是直接改布局。
///
/// 桌面端这些值全是 0，行为与之前完全一致。
extension SafeAreaInsets on BuildContext {
  /// 屏幕顶部的系统占用（状态栏 / 刘海 / 灵动岛）。
  double get safeTop => MediaQuery.paddingOf(this).top;

  /// 屏幕底部的系统占用（手势条 / home indicator）。
  double get safeBottom => MediaQuery.paddingOf(this).bottom;

  /// 给固定高度的顶栏加顶部内边距（只加纵向，别动横向）。
  EdgeInsets get barInsets =>
      EdgeInsets.only(top: safeTop, bottom: safeBottom);

  /// 顶栏自己要占的总高度：设计高度 + 顶部安全区。
  double topBarHeight(double base) => base + safeTop;

  /// 底栏自己要占的总高度：设计高度 + 底部安全区。
  double bottomBarHeight(double base) => base + safeBottom;
}
