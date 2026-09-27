/// 桌面窗口标题：产品名 + 版本号 + 构建号（+ 当前工程路径）。
///
/// Windows 上窗口标题是在 `windows/runner/main.cpp` 里创建窗口时直接写入的，
/// Flutter 引擎**不会**把 `MaterialApp.title` / `onGenerateTitle` 同步到
/// Win32 标题栏（`flutter_windows.dll` 中不存在
/// `setApplicationSwitcherDescription`），因此这里显式走一条 MethodChannel，
/// 由 `windows/runner/flutter_window.cpp` 收到后调用原生 `SetWindowText`。
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app_info.dart';

/// 与 `windows/runner/flutter_window.cpp` 约定的通道名 / 方法名。
const String kWindowChannelName = 'anima/window';
const String kWindowChannelSetTitle = 'setTitle';

/// 原生窗口标题通道。
const MethodChannel kWindowChannel = MethodChannel(kWindowChannelName);

/// 组装窗口标题：`<产品名> <版本>+<构建> - <工程路径>`。
///
/// [projectPath] 为空（尚未新建/打开工程）时省略尾部的路径段。
String composeWindowTitle(BuildContext context, {String? projectPath}) {
  final name = 'app.title'.tr(context: context);
  final base = '$name $kAppVersionWithBuild';
  final path = projectPath?.trim() ?? '';
  return path.isEmpty ? base : '$base - $path';
}

/// 把标题推送到原生窗口，并在标题变化时自动重推。
///
/// 其它平台（Linux/macOS/Web）尚未实现原生端，此时抛出
/// `MissingPluginException`，已被静默忽略——标题只影响观感，绝不能让界面报错。
class WindowTitleSync extends StatefulWidget {
  const WindowTitleSync({super.key, required this.title, required this.child});

  /// 目标标题；为空字符串时不同步。
  final String title;

  final Widget child;

  @override
  State<WindowTitleSync> createState() => _WindowTitleSyncState();
}

class _WindowTitleSyncState extends State<WindowTitleSync> {
  String? _applied;

  @override
  void initState() {
    super.initState();
    _push();
  }

  @override
  void didUpdateWidget(WindowTitleSync oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.title != widget.title) _push();
  }

  Future<void> _push() async {
    final title = widget.title;
    if (title.isEmpty || title == _applied) return;
    _applied = title;
    try {
      await kWindowChannel.invokeMethod<void>(kWindowChannelSetTitle, title);
    } on MissingPluginException {
      // 非 Windows 平台或原生端未接入：忽略。
    } on PlatformException {
      // 原生端拒绝设置标题：忽略，不影响界面。
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
