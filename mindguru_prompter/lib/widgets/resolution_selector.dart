import 'package:flutter/material.dart';

import '../utils/constants.dart';

/// Horizontal ChoiceChip row: 720p · 1080p · 1440p · 4K · 8K.
///
/// Unsupported resolutions stay visible but grey, with a tooltip explaining
/// the device limit (e.g. 8K on vivo X200 FE: "max 4K60").
class ResolutionSelector extends StatelessWidget {
  const ResolutionSelector({
    super.key,
    required this.selected,
    required this.isSupported,
    required this.onSelected,
    required this.maxLabel,
    this.enabled = true,
  });

  final VideoResolution selected;
  final bool Function(VideoResolution) isSupported;
  final ValueChanged<VideoResolution> onSelected;

  /// e.g. "4K60" – shown in the tooltip of disabled chips.
  final String maxLabel;

  /// False while recording.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: VideoResolution.values.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final resolution = VideoResolution.values[index];
          final supported = isSupported(resolution);
          final isSelected = resolution == selected;

          final chip = ChoiceChip(
            label: Text(resolution.label),
            selected: isSelected,
            onSelected: supported && enabled ? (_) => onSelected(resolution) : null,
            labelStyle: TextStyle(
              color: !supported
                  ? AppColors.disabled
                  : isSelected
                      ? Colors.black
                      : AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              decoration: supported ? null : TextDecoration.lineThrough,
              decorationColor: AppColors.disabled,
            ),
            backgroundColor: Colors.black.withValues(alpha: 0.45),
            disabledColor: Colors.black.withValues(alpha: 0.3),
            selectedColor: AppColors.accent,
            visualDensity: VisualDensity.compact,
          );

          if (supported) {
            if (resolution == VideoResolution.qhd1440) {
              return Tooltip(
                message: 'Records through the 4K preset '
                    '(the Flutter camera plugin has no 1440p preset)',
                child: chip,
              );
            }
            return chip;
          }
          return Tooltip(
            message: 'Not supported on this device - max $maxLabel',
            triggerMode: TooltipTriggerMode.tap,
            child: chip,
          );
        },
      ),
    );
  }
}

/// FPS chips: 24 · 30 · 60 · 120, auto-limited per resolution.
class FpsSelector extends StatelessWidget {
  const FpsSelector({
    super.key,
    required this.selected,
    required this.allowed,
    required this.onSelected,
    this.enabled = true,
  });

  final FrameRate selected;
  final List<FrameRate> allowed;
  final ValueChanged<FrameRate> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      children: [
        for (final fps in FrameRate.values)
          Tooltip(
            message: allowed.contains(fps)
                ? '${fps.value} frames per second'
                : 'Not available at this resolution',
            child: ChoiceChip(
              label: Text('${fps.value}'),
              selected: fps == selected,
              onSelected:
                  allowed.contains(fps) && enabled ? (_) => onSelected(fps) : null,
              labelStyle: TextStyle(
                color: !allowed.contains(fps)
                    ? AppColors.disabled
                    : fps == selected
                        ? Colors.black
                        : AppColors.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
              backgroundColor: Colors.black.withValues(alpha: 0.45),
              disabledColor: Colors.black.withValues(alpha: 0.3),
              selectedColor: AppColors.accent,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
      ],
    );
  }
}
