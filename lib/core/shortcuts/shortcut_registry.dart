/// 统一快捷键注册表（A0-6 / AE2-9）。
///
/// 绑定可被用户在设置里改写；这里负责把 `ctrl+shift+s` 这样的字符串解析成
/// Flutter 的 [SingleActivator]，并提供统一的帮助列表数据。
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 动作 id → i18n key（用于快捷键设置与帮助）。
const Map<String, String> shortcutActionKeys = <String, String>{
  'file.new': 'shortcut.file.new',
  'file.open': 'shortcut.file.open',
  'file.save': 'shortcut.file.save',
  'file.saveAs': 'shortcut.file.saveAs',
  'file.export': 'shortcut.file.export',
  'file.import': 'shortcut.file.import',
  'edit.undo': 'shortcut.edit.undo',
  'edit.redo': 'shortcut.edit.redo',
  'edit.delete': 'shortcut.edit.delete',
  'edit.copy': 'shortcut.edit.copy',
  'edit.paste': 'shortcut.edit.paste',
  'view.fit': 'shortcut.view.fit',
  'view.zoomIn': 'shortcut.view.zoomIn',
  'view.zoomOut': 'shortcut.view.zoomOut',
  'view.flipX': 'shortcut.view.flipX',
  'view.flipY': 'shortcut.view.flipY',
  'view.toggleGrid': 'shortcut.view.toggleGrid',
  'motion.play': 'shortcut.motion.play',
  'motion.prevFrame': 'shortcut.motion.prevFrame',
  'motion.nextFrame': 'shortcut.motion.nextFrame',
  'panel.left': 'shortcut.panel.left',
  'panel.right': 'shortcut.panel.right',
  'panel.bottom': 'shortcut.panel.bottom',
  'panel.fullscreenCanvas': 'shortcut.panel.fullscreenCanvas',
};

/// 快捷键注册表。
class AmShortcuts {
  const AmShortcuts._();

  /// 解析 `ctrl+shift+s`。
  static SingleActivator? parse(String binding) {
    final parts = binding
        .toLowerCase()
        .split('+')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (parts.isEmpty) return null;

    var control = false;
    var shift = false;
    var alt = false;
    var meta = false;
    LogicalKeyboardKey? key;

    for (final part in parts) {
      switch (part) {
        case 'ctrl':
        case 'control':
          control = true;
        case 'shift':
          shift = true;
        case 'alt':
        case 'option':
          alt = true;
        case 'meta':
        case 'cmd':
        case 'win':
          meta = true;
        default:
          key = _logicalKey(part);
      }
    }
    if (key == null) return null;
    return SingleActivator(
      key,
      control: control,
      shift: shift,
      alt: alt,
      meta: meta,
    );
  }

  static LogicalKeyboardKey? _logicalKey(String name) {
    // 单字符键：字母/数字/常见符号的 LogicalKeyboardKey 值等于其 ASCII 码。
    if (name.length == 1) {
      final code = name.toLowerCase().codeUnitAt(0);
      final printable =
          (code >= 0x61 && code <= 0x7A) || // a-z
          (code >= 0x30 && code <= 0x39) || // 0-9
          code == 0x3D || // =
          code == 0x2D || // -
          code == 0x27 || // '
          code == 0x2F; // /
      if (printable) return LogicalKeyboardKey(code);
    }
    switch (name) {
      case 'space':
        return LogicalKeyboardKey.space;
      case 'enter':
        return LogicalKeyboardKey.enter;
      case 'escape':
      case 'esc':
        return LogicalKeyboardKey.escape;
      case 'tab':
        return LogicalKeyboardKey.tab;
      case 'delete':
      case 'del':
        return LogicalKeyboardKey.delete;
      case 'backspace':
        return LogicalKeyboardKey.backspace;
      case 'left':
        return LogicalKeyboardKey.arrowLeft;
      case 'right':
        return LogicalKeyboardKey.arrowRight;
      case 'up':
        return LogicalKeyboardKey.arrowUp;
      case 'down':
        return LogicalKeyboardKey.arrowDown;
      case 'plus':
        return LogicalKeyboardKey.equal;
      case 'minus':
        return LogicalKeyboardKey.minus;
      case 'f1':
        return LogicalKeyboardKey.f1;
      case 'f2':
        return LogicalKeyboardKey.f2;
      case 'f3':
        return LogicalKeyboardKey.f3;
      case 'f4':
        return LogicalKeyboardKey.f4;
      case 'f5':
        return LogicalKeyboardKey.f5;
      case 'f6':
        return LogicalKeyboardKey.f6;
      default:
        return null;
    }
  }

  /// 生成 [Shortcuts] 的映射表。
  static Map<ShortcutActivator, VoidCallback> build(
    Map<String, String> bindings,
    Map<String, VoidCallback> handlers,
  ) {
    final result = <ShortcutActivator, VoidCallback>{};
    for (final entry in bindings.entries) {
      final handler = handlers[entry.key];
      if (handler == null) continue;
      final activator = parse(entry.value);
      if (activator == null) continue;
      result[activator] = handler;
    }
    return result;
  }

  /// 人类可读的绑定文本（`Ctrl+Shift+S`）。
  static String label(String binding) => binding
      .split('+')
      .map((part) {
        switch (part.toLowerCase()) {
          case 'ctrl':
          case 'control':
            return 'Ctrl';
          case 'shift':
            return 'Shift';
          case 'alt':
            return 'Alt';
          case 'meta':
          case 'cmd':
            return 'Meta';
          case 'space':
            return 'Space';
          case 'left':
            return '←';
          case 'right':
            return '→';
          case 'delete':
            return 'Del';
          default:
            return part.toUpperCase();
        }
      })
      .join(' + ');
}
