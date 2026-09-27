/// 调试面板：参数只读调试（AV1-3）与物理/自动效果开关（AV1-4）。
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/am_types.dart';
import '../../core/state/document_controller.dart';
import '../../core/state/runtime_controller.dart';
import '../../core/theme/app_theme.dart';
import '../common/widgets.dart';

/// 参数调试面板：滑杆可拖，但不写回工程（运行时状态只留在会话内）。
class ParamsPanel extends ConsumerWidget {
  const ParamsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = AppTheme.of(context);
    final document = ref.watch(documentProvider);
    final runtime = ref.watch(runtimeProvider);
    final controller = ref.read(runtimeProvider.notifier);

    if (document.parameters.isEmpty) {
      return EmptyState(
        icon: Icons.tune,
        titleKey: 'viewer.params.empty',
        subtitleKey: 'viewer.params.emptyHint',
      );
    }

    return PanelScroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final entry in document.parameterGroups.entries) ...<Widget>[
            SectionHeader(titleKey: entry.key),
            for (final paramId in entry.value)
              _ParamSlider(
                name: '${document.parameters[paramId]?['name'] ?? paramId}',
                min: asDouble(document.parameters[paramId]?['min'], -1),
                max: asDouble(document.parameters[paramId]?['max'], 1),
                value: runtime.valueOf(paramId),
                onChanged: (value) => controller.setParam(paramId, value),
              ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: SmallTextButton(
              labelKey: 'viewer.params.reset',
              onPressed: () => controller.reset(),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'viewer.params.hint'.tr(),
            style: TextStyle(fontSize: 10.5, color: tokens.textMuted),
          ),
        ],
      ),
    );
  }
}

class _ParamSlider extends StatelessWidget {
  const _ParamSlider({
    required this.name,
    required this.min,
    required this.max,
    required this.value,
    required this.onChanged,
  });

  final String name;
  final double min;
  final double max;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5),
              ),
            ),
            Text(
              value.toStringAsFixed(2),
              style: TextStyle(fontSize: 10.5, color: tokens.textMuted),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            trackHeight: 3,
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max <= min ? min + 1 : max,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

/// 物理与自动效果面板。
class EffectsPanel extends ConsumerWidget {
  const EffectsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runtime = ref.watch(runtimeProvider);
    final controller = ref.read(runtimeProvider.notifier);
    final document = ref.watch(documentProvider);

    return PanelScroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SectionHeader(titleKey: 'panel.physics.section.settings'),
          SwitchRow(
            labelKey: 'panel.physics.enabled',
            value: runtime.physicsEnabled,
            onChanged: controller.setPhysics,
          ),
          SectionHeader(titleKey: 'viewer.effects.auto'),
          SwitchRow(
            labelKey: 'viewer.effects.blink',
            value: runtime.blinkEnabled,
            onChanged: controller.setBlink,
          ),
          SwitchRow(
            labelKey: 'viewer.effects.breath',
            value: runtime.breathEnabled,
            onChanged: controller.setBreath,
          ),
          SwitchRow(
            labelKey: 'panel.lipsync.enabled',
            value: runtime.lipsyncEnabled,
            onChanged: (value) => controller.setLipsync(enabled: value),
          ),
          LabeledSlider(
            label: 'panel.lipsync.amplitude'.tr(),
            value: runtime.lipsyncAmplitude,
            min: 0,
            max: 1,
            defaultValue: 0,
            suffix: '${(runtime.lipsyncAmplitude * 100).round()}%',
            onChanged: (value) => controller.setLipsync(amplitude: value),
          ),
          Text(
            'panel.lipsync.hint'.tr(),
            style: const TextStyle(fontSize: 10.5),
          ),
          if (document.physics.isNotEmpty) ...<Widget>[
            SectionHeader(titleKey: 'viewer.effects.bindings'),
            for (final raw in document.physics)
              KeyValueRow(
                labelKey: 'viewer.effects.binding',
                value: '${asJsonMap(raw)['name'] ?? 'physics'}',
              ),
          ],
        ],
      ),
    );
  }
}
