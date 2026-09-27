/// 播放面板：动作列表与播放控制（AV1-1）、表情与姿势切换（AV1-2）。
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/am_types.dart';
import '../../core/i18n/l10n.dart';
import '../../core/state/document_controller.dart';
import '../../core/state/runtime_controller.dart';
import '../../core/state/ui_controllers.dart';
import '../../core/theme/app_theme.dart';
import '../common/widgets.dart';

/// 动作面板。
class MotionsPanel extends ConsumerWidget {
  const MotionsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = AppTheme.of(context);
    final document = ref.watch(documentProvider);
    final runtime = ref.watch(runtimeProvider);
    final playback = ref.watch(viewerPlaybackProvider);
    final runtimeController = ref.read(runtimeProvider.notifier);
    final playbackController = ref.read(viewerPlaybackProvider.notifier);

    if (document.motions.isEmpty) {
      return EmptyState(
        icon: Icons.movie_creation_outlined,
        titleKey: 'viewer.motions.empty',
        subtitleKey: 'viewer.motions.emptyHint',
      );
    }

    return PanelScroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final raw in document.motions)
            _MotionTile(
              name: '${asJsonMap(raw)['name'] ?? 'motion'}',
              duration: asDouble(asJsonMap(raw)['duration'], 3),
              loop: asBool(asJsonMap(raw)['loop'], true),
              selected: runtime.motion == '${asJsonMap(raw)['name'] ?? ''}',
              playing:
                  playback.playing &&
                  playback.motion == '${asJsonMap(raw)['name'] ?? ''}',
              onPlay: (loop) {
                final name = '${asJsonMap(raw)['name'] ?? ''}';
                final duration = asDouble(asJsonMap(raw)['duration'], 3);
                playbackController.play(name, duration: duration);
                runtimeController.play(name, loop: loop);
              },
              onPause: () {
                playbackController.pause();
                runtimeController.pause();
              },
            ),
          SectionHeader(titleKey: 'viewer.motions.section.control'),
          SwitchRow(
            labelKey: 'motion.loop',
            value: playback.loop,
            onChanged: (value) => playbackController.setLoop(value),
          ),
          LabeledSlider(
            label: 'motion.speed'.tr(),
            value: playback.speed,
            min: 0.25,
            max: 4,
            defaultValue: 1,
            suffix: 'viewer.motion.speedSuffix'.tr(
              namedArgs: <String, String>{
                'value': playback.speed.toStringAsFixed(2),
              },
            ),
            onChanged: (value) => playbackController.setSpeed(value),
          ),
          LabeledSlider(
            label: 'motion.duration'.tr(),
            value: playback.duration,
            min: 0,
            max: 30,
            defaultValue: 3,
            digits: 1,
            suffix: Fmt.duration(playback.duration),
            onChanged: (value) => playbackController.setDuration(value),
          ),
          LabeledSlider(
            label: 'viewer.motions.fadeIn'.tr(),
            value: playback.fadeIn,
            min: 0,
            max: 3,
            defaultValue: 0,
            digits: 1,
            suffix: Fmt.duration(playback.fadeIn),
            onChanged: (value) => playbackController.setFade(inSeconds: value),
          ),
          LabeledSlider(
            label: 'viewer.motions.fadeOut'.tr(),
            value: playback.fadeOut,
            min: 0,
            max: 3,
            defaultValue: 0,
            digits: 1,
            suffix: Fmt.duration(playback.fadeOut),
            onChanged: (value) => playbackController.setFade(outSeconds: value),
          ),
          const SizedBox(height: 6),
          Text(
            'viewer.motions.time'.tr(
              namedArgs: <String, String>{
                'time': playback.time.toStringAsFixed(2),
                'duration': playback.duration.toStringAsFixed(2),
              },
            ),
            style: TextStyle(fontSize: 11, color: tokens.textMuted),
          ),
        ],
      ),
    );
  }
}

class _MotionTile extends StatelessWidget {
  const _MotionTile({
    required this.name,
    required this.duration,
    required this.loop,
    required this.selected,
    required this.playing,
    required this.onPlay,
    required this.onPause,
  });

  final String name;
  final double duration;
  final bool loop;
  final bool selected;
  final bool playing;
  final void Function(bool loop) onPlay;
  final VoidCallback onPause;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTheme.of(context);
    return ListRow(
      selected: selected,
      trailing: IconButton(
        icon: Icon(playing ? Icons.pause_circle : Icons.play_circle, size: 18),
        tooltip: playing ? 'motion.pause'.tr() : 'motion.play'.tr(),
        onPressed: playing ? onPause : () => onPlay(loop),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Text(
            name,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          Text(
            '${Fmt.duration(duration)} · ${loop ? 'motion.loop'.tr() : 'viewer.motions.once'.tr()}',
            style: TextStyle(fontSize: 10, color: tokens.textMuted),
          ),
        ],
      ),
    );
  }
}

/// 表情 + 姿势面板。
class ExpressionsPanel extends ConsumerWidget {
  const ExpressionsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = AppTheme.of(context);
    final document = ref.watch(documentProvider);
    final runtime = ref.watch(runtimeProvider);
    final controller = ref.read(runtimeProvider.notifier);

    if (document.expressions.isEmpty && document.pose.isEmpty) {
      return EmptyState(
        icon: Icons.emoji_emotions_outlined,
        titleKey: 'viewer.expressions.empty',
        subtitleKey: 'viewer.expressions.emptyHint',
      );
    }

    return PanelScroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (document.expressions.isNotEmpty) ...<Widget>[
            SectionHeader(
              titleKey: 'panel.expression.section.list',
              actions: <Widget>[
                SmallTextButton(
                  labelKey: 'panel.expression.clear',
                  onPressed: () => controller.setExpression(null),
                ),
              ],
            ),
            for (final raw in document.expressions)
              ListRow(
                selected:
                    runtime.expression == '${asJsonMap(raw)['name'] ?? ''}',
                onTap: () =>
                    controller.setExpression('${asJsonMap(raw)['name'] ?? ''}'),
                trailing: Icon(
                  Icons.chevron_right,
                  size: 16,
                  color: tokens.textMuted,
                ),
                child: Text(
                  '${asJsonMap(raw)['name'] ?? 'expression'}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          if (document.pose.isNotEmpty) ...<Widget>[
            SectionHeader(titleKey: 'panel.pose.section.list'),
            for (final raw in document.pose)
              ListRow(
                onTap: () => _applyPose(ref, asJsonMap(raw)),
                trailing: Icon(
                  Icons.chevron_right,
                  size: 16,
                  color: tokens.textMuted,
                ),
                child: Text(
                  '${asJsonMap(raw)['name'] ?? 'pose'}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ],
      ),
    );
  }

  void _applyPose(WidgetRef ref, Map<String, Object?> pose) {
    final values = <String, double>{};
    for (final entry in asJsonMap(pose['values']).entries) {
      values[entry.key] = asDouble(entry.value);
    }
    if (values.isNotEmpty) {
      ref.read(runtimeProvider.notifier).setParams(values);
    }
  }
}
