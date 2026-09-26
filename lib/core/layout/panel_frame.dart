/// 面板外壳：标题栏 + 内容（查看器右侧面板列使用）。
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 面板标题栏 + 内容的标准外壳。
class PanelFrame extends StatelessWidget {
  const PanelFrame({
    super.key,
    required this.titleKey,
    required this.child,
    this.actions = const <Widget>[],
    this.icon,
    this.dense = true,
  });

  final String titleKey;
  final Widget child;
  final List<Widget> actions;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTheme.of(context);
    return Container(
      color: tokens.panelBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            height: dense ? 30 : 36,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: tokens.panelHeader,
              border: Border(bottom: BorderSide(color: tokens.divider)),
            ),
            child: Row(
              children: <Widget>[
                if (icon != null) ...<Widget>[
                  Icon(icon, size: 14, color: tokens.divider),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    titleKey.tr(),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                for (final action in actions) action,
              ],
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}
