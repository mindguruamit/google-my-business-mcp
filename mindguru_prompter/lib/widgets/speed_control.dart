import 'package:flutter/material.dart';

import '../utils/constants.dart';

/// Words-per-minute slider, 80–250.
class SpeedControl extends StatelessWidget {
  const SpeedControl({
    super.key,
    required this.wpm,
    required this.onChanged,
    this.onChangeEnd,
    this.adaptiveFactor = 1.0,
  });

  final int wpm;
  final ValueChanged<int> onChanged;
  final ValueChanged<int>? onChangeEnd;

  /// Shown when VoiceTrack is adapting speed (1.0 = off).
  final double adaptiveFactor;

  @override
  Widget build(BuildContext context) {
    final adaptive = (adaptiveFactor - 1).abs() > 0.05;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              const Icon(Icons.speed, size: 16, color: AppColors.textSecondary),
              const SizedBox(width: 6),
              Text(
                '$wpm WPM',
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              if (adaptive) ...[
                const SizedBox(width: 8),
                Text(
                  'voice ×${adaptiveFactor.toStringAsFixed(2)}',
                  style: const TextStyle(color: AppColors.accent, fontSize: 12),
                ),
              ],
              const Spacer(),
              Text(
                _label(wpm),
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ),
        Slider(
          value: wpm.toDouble().clamp(
                TeleprompterConstants.minWpm.toDouble(),
                TeleprompterConstants.maxWpm.toDouble(),
              ),
          min: TeleprompterConstants.minWpm.toDouble(),
          max: TeleprompterConstants.maxWpm.toDouble(),
          divisions: (TeleprompterConstants.maxWpm - TeleprompterConstants.minWpm) ~/ 5,
          label: '$wpm',
          onChanged: (v) => onChanged(v.round()),
          onChangeEnd: onChangeEnd == null ? null : (v) => onChangeEnd!(v.round()),
        ),
      ],
    );
  }

  static String _label(int wpm) {
    if (wpm < 110) return 'Slow & calm';
    if (wpm < 150) return 'Conversational';
    if (wpm < 190) return 'Energetic';
    return 'Fast';
  }
}
