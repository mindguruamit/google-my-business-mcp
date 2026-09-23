import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../utils/constants.dart';

/// Yellow tap-to-focus square: pops in, settles, fades out.
class FocusIndicator extends StatefulWidget {
  const FocusIndicator({super.key, required this.position});

  /// Center of the square in the parent's coordinates.
  final Offset position;

  @override
  State<FocusIndicator> createState() => _FocusIndicatorState();
}

class _FocusIndicatorState extends State<FocusIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..forward();

  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 1.6, end: 1.0).chain(CurveTween(curve: Curves.easeOutBack)),
      weight: 25,
    ),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 75),
  ]).animate(_controller);

  late final Animation<double> _opacity = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 10),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 60),
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 30),
  ]).animate(_controller);

  @override
  void didUpdateWidget(FocusIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.position != widget.position) _controller.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    const size = 72.0;
    return Positioned(
      left: widget.position.dx - size / 2,
      top: widget.position.dy - size / 2,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => Opacity(
            opacity: _opacity.value,
            child: Transform.scale(
              scale: _scale.value,
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.focus, width: 1.6),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Center(
                  child: Icon(Icons.wb_sunny_outlined, color: AppColors.focus, size: 16),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

/// Green live waveform + "Listening: `last word`".
class VoiceIndicator extends StatefulWidget {
  const VoiceIndicator({
    super.key,
    required this.level,
    required this.lastWord,
    this.preparing = false,
  });

  /// 0..1 input level.
  final double level;
  final String lastWord;
  final bool preparing;

  @override
  State<VoiceIndicator> createState() => _VoiceIndicatorState();
}

class _VoiceIndicatorState extends State<VoiceIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 44,
            height: 22,
            child: AnimatedBuilder(
              animation: _wave,
              builder: (context, _) => CustomPaint(
                painter: _WavePainter(
                  phase: _wave.value,
                  level: widget.preparing ? 0.15 : widget.level,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              widget.preparing
                  ? 'Preparing offline model…'
                  : 'Listening: ${widget.lastWord.isEmpty ? '…' : widget.lastWord}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.greenAccent,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({required this.phase, required this.level});

  final double phase;
  final double level;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.greenAccent
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3;
    const bars = 7;
    final gap = size.width / bars;
    for (var i = 0; i < bars; i++) {
      final wave = (math.sin((phase * 2 * math.pi) + i * 0.9) + 1) / 2;
      final amplitude = 0.15 + 0.85 * level.clamp(0.0, 1.0) * (0.4 + 0.6 * wave);
      final h = size.height * amplitude;
      final x = gap * i + gap / 2;
      canvas.drawLine(
        Offset(x, (size.height - h) / 2),
        Offset(x, (size.height + h) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => old.phase != phase || old.level != level;
}

/// Small lime dot just under the front camera, so the speaker's eyes stay
/// near the lens while reading.
class EyeContactGuide extends StatelessWidget {
  const EyeContactGuide({super.key});

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.viewPaddingOf(context).top;
    return Positioned(
      top: math.max(4, top - 6),
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: AppColors.accent,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: AppColors.accent.withValues(alpha: 0.7),
                  blurRadius: 10,
                  spreadRadius: 2,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact toggle chip for the studio top bar.
class StudioToggleChip extends StatelessWidget {
  const StudioToggleChip({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.enabled = true,
    this.tooltip,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final bool enabled;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final foreground = !enabled
        ? AppColors.disabled
        : selected
            ? Colors.black
            : Colors.white;
    final chip = FilterChip(
      avatar: Icon(icon, size: 16, color: foreground),
      label: Text(label),
      selected: selected,
      onSelected: enabled ? (_) => onTap() : null,
      labelStyle: TextStyle(color: foreground, fontWeight: FontWeight.w700, fontSize: 12),
      backgroundColor: Colors.black.withValues(alpha: 0.45),
      disabledColor: Colors.black.withValues(alpha: 0.3),
      selectedColor: AppColors.accent,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return tooltip == null ? chip : Tooltip(message: tooltip!, child: chip);
  }
}

/// Circular icon button used on the bottom studio bar.
class StudioRoundButton extends StatelessWidget {
  const StudioRoundButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.active = false,
    this.tooltip,
    this.size = 52,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final bool active;
  final String? tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '',
      child: Material(
        color: active ? AppColors.accent : Colors.white.withValues(alpha: 0.12),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(
              icon,
              color: onPressed == null
                  ? AppColors.disabled
                  : active
                      ? Colors.black
                      : Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

/// The 72dp record button: lime when idle, red rounded-square when recording.
class RecordButton extends StatelessWidget {
  const RecordButton({
    super.key,
    required this.recording,
    required this.onPressed,
  });

  final bool recording;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: recording ? 'Stop recording' : 'Start recording',
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 4),
          ),
          alignment: Alignment.center,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            width: recording ? 28 : 56,
            height: recording ? 28 : 56,
            decoration: BoxDecoration(
              color: recording ? AppColors.recording : AppColors.accent,
              borderRadius: BorderRadius.circular(recording ? 6 : 28),
            ),
          ),
        ),
      ),
    );
  }
}
