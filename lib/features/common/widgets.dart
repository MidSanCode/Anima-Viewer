/// 面板通用小组件：统一密度与交互，避免各面板重复造轮子。
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../core/platform/app_info.dart';
import '../../core/theme/app_theme.dart';

/// 分组标题。
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.titleKey,
    this.actions = const <Widget>[],
    this.padding = const EdgeInsets.fromLTRB(8, 8, 8, 4),
  });

  final String titleKey;
  final List<Widget> actions;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTheme.of(context);
    return Padding(
      padding: padding,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              titleKey.tr(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
                color: tokens.divider,
              ),
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// 空状态。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.titleKey,
    this.subtitleKey,
    this.action,
  });

  final IconData icon;
  final String titleKey;
  final String? subtitleKey;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(icon, size: 30, color: tokens.divider),
            const SizedBox(height: 10),
            Text(
              titleKey.tr(),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (subtitleKey != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                subtitleKey!.tr(),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: tokens.divider),
              ),
            ],
            if (action != null) ...<Widget>[
              const SizedBox(height: 14),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 带数值显示的滑杆（参数面板 / 物理面板通用）。
class LabeledSlider extends StatelessWidget {
  const LabeledSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.onChangeEnd,
    this.defaultValue,
    this.digits = 2,
    this.suffix,
    this.enabled = true,
    this.trailing,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  final double? defaultValue;
  final int digits;
  final String? suffix;
  final bool enabled;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5),
                ),
              ),
              ?trailing,
              SizedBox(
                width: 56,
                child: Text(
                  value.toStringAsFixed(digits),
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 11, color: tokens.divider),
                ),
              ),
              if (defaultValue != null)
                SmallIconButton(
                  icon: Icons.restart_alt,
                  tooltipKey: 'common.resetToDefault',
                  onPressed: enabled ? () => onChanged(defaultValue!) : null,
                ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: enabled ? onChanged : null,
            onChangeEnd: enabled ? onChangeEnd : null,
          ),
          if (suffix != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                suffix!,
                style: TextStyle(fontSize: 10, color: tokens.divider),
              ),
            ),
        ],
      ),
    );
  }
}

/// 小图标按钮。
class SmallIconButton extends StatelessWidget {
  const SmallIconButton({
    super.key,
    required this.icon,
    required this.tooltipKey,
    this.onPressed,
    this.selected = false,
    this.size = 15,
  });

  final IconData icon;
  final String tooltipKey;
  final VoidCallback? onPressed;
  final bool selected;
  final double size;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTheme.of(context);
    return Tooltip(
      message: tooltipKey.tr(),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            icon,
            size: size,
            color: onPressed == null
                ? tokens.divider.withValues(alpha: 0.4)
                : (selected
                      ? Theme.of(context).colorScheme.primary
                      : tokens.divider),
          ),
        ),
      ),
    );
  }
}

/// 文本按钮（小号）。
class SmallTextButton extends StatelessWidget {
  const SmallTextButton({
    super.key,
    required this.labelKey,
    this.onPressed,
    this.icon,
  });

  final String labelKey;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontSize: 11.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 14),
            const SizedBox(width: 4),
          ],
          Text(labelKey.tr()),
        ],
      ),
    );
  }
}

/// 键值行。
///
/// [labelKey] 与 [label] 二选一：前者是 i18n 键（会翻译），
/// 后者是原样文本（引擎方法名、路径、外部标识符等**不得翻译**的内容）。
/// 把非 i18n 内容传给 [labelKey] 会触发
/// `Localization key [xxx] not found` 并把原始键直接显示到界面上。
class KeyValueRow extends StatelessWidget {
  const KeyValueRow({
    super.key,
    this.labelKey,
    this.label,
    required this.value,
    this.monospace = false,
  }) : assert(
         labelKey != null || label != null,
         'KeyValueRow 需要 labelKey（i18n 键）或 label（原样文本）之一',
       );

  final String? labelKey;
  final String? label;
  final String value;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 108,
            child: Text(
              label ?? labelKey!.tr(),
              style: TextStyle(fontSize: 11, color: tokens.divider),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                fontSize: 11,
                fontFamily: monospace ? 'monospace' : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 下拉选择。
class EnumDropdown<T> extends StatelessWidget {
  const EnumDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.labelOf,
    required this.onChanged,
  });

  final T value;
  final List<T> items;
  final String Function(T item) labelOf;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButton<T>(
      value: value,
      isExpanded: true,
      isDense: true,
      underline: const SizedBox.shrink(),
      style: const TextStyle(fontSize: 11.5),
      items: <DropdownMenuItem<T>>[
        for (final item in items)
          DropdownMenuItem<T>(value: item, child: Text(labelOf(item))),
      ],
      onChanged: onChanged,
    );
  }
}

/// 带标签的开关行。
class SwitchRow extends StatelessWidget {
  const SwitchRow({
    super.key,
    required this.labelKey,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String labelKey;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? () => onChanged(!value) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                labelKey.tr(),
                style: const TextStyle(fontSize: 11.5),
              ),
            ),
            Switch(
              value: value,
              onChanged: enabled ? onChanged : null,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ],
        ),
      ),
    );
  }
}

/// 可滚动面板容器。
class PanelScroll extends StatelessWidget {
  const PanelScroll({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: padding ?? const EdgeInsets.only(bottom: 16),
    child: child,
  );
}

/// 列表项外框（选中态）。
class ListRow extends StatelessWidget {
  const ListRow({
    super.key,
    required this.child,
    this.selected = false,
    this.onTap,
    this.onSecondaryTap,
    this.depth = 0,
    this.trailing,
    this.leading,
  });

  final Widget child;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onSecondaryTap;
  final int depth;
  final Widget? trailing;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      onSecondaryTap: onSecondaryTap,
      child: Container(
        height: 24,
        padding: EdgeInsets.only(left: 6 + depth * 12.0, right: 4),
        color: selected ? scheme.primary.withValues(alpha: 0.22) : null,
        child: Row(
          children: <Widget>[
            if (leading != null) ...<Widget>[
              leading!,
              const SizedBox(width: 4),
            ],
            Expanded(child: child),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// 确认对话框。
Future<bool> confirmDialog(
  BuildContext context, {
  required String titleKey,
  required String messageKey,
  String confirmKey = 'common.confirm',
  String cancelKey = 'common.cancel',
  Map<String, String> args = const <String, String>{},
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(titleKey.tr()),
      content: Text(messageKey.tr(namedArgs: args)),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(cancelKey.tr()),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmKey.tr()),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// 文本输入对话框。
Future<String?> promptDialog(
  BuildContext context, {
  required String titleKey,
  required String labelKey,
  String? initial,
  String confirmKey = 'common.confirm',
}) async {
  final controller = TextEditingController(text: initial ?? '');
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(titleKey.tr()),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(labelText: labelKey.tr()),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('common.cancel'.tr()),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: Text(confirmKey.tr()),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}

/// 关于卡片：产品名 / 版本号 / 构建号 / 开发者 / 独立实现声明。
///
/// 版本号与构建号来自 `core/platform/app_info.dart`（由 `pubspec.yaml` 的
/// `version` 派生，见 `test/app_info_test.dart` 的漂移守卫），而不是写死的字符串。
class AboutCard extends StatelessWidget {
  const AboutCard({super.key, this.descriptionKey = 'app.description'});

  /// 产品简介的 i18n 键。
  final String descriptionKey;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          'app.title'.tr(),
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          descriptionKey.tr(),
          style: TextStyle(fontSize: 11, color: tokens.divider),
        ),
        const SizedBox(height: 10),
        KeyValueRow(labelKey: 'about.version', value: kAppVersion),
        KeyValueRow(labelKey: 'about.build', value: kAppBuildNumber),
        KeyValueRow(
          labelKey: 'about.developer',
          value: 'about.developerName'.tr(),
        ),
        const SizedBox(height: 10),
        Text(
          'about.notice'.tr(),
          style: TextStyle(fontSize: 10.5, color: tokens.divider),
        ),
      ],
    );
  }
}
