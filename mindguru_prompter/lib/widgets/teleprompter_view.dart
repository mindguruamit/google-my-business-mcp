import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/script_document.dart';
import '../services/teleprompter_engine.dart';
import '../utils/app_theme.dart';
import '../utils/constants.dart';

/// Renders the script and scrolls it with [Transform.translate] from the
/// engine's word position.
///
/// The text is laid out once with a [TextPainter]; every spoken word gets a
/// y-coordinate (line top + horizontal progress through the line), so the
/// scroll is continuous and lands exactly where voice tracking says.
class TeleprompterView extends StatefulWidget {
  const TeleprompterView({
    super.key,
    required this.document,
    required this.engine,
    this.fontSize = TeleprompterConstants.defaultFontSize,
    this.mirror = false,
    this.readingLine = TeleprompterConstants.readingLine,
    this.padding = const EdgeInsets.symmetric(horizontal: 20),
    this.textColor = Colors.white,
    this.showReadingLine = true,
    this.lineHeight = 1.35,
  });

  final ScriptDocument document;
  final TeleprompterEngine engine;
  final double fontSize;
  final bool mirror;

  /// Where the current line sits, as a fraction of the view height.
  final double readingLine;
  final EdgeInsets padding;
  final Color textColor;
  final bool showReadingLine;
  final double lineHeight;

  @override
  State<TeleprompterView> createState() => _TeleprompterViewState();
}

class _TeleprompterViewState extends State<TeleprompterView> {
  final ValueNotifier<double> _wordPosition = ValueNotifier<double>(0);
  StreamSubscription<double>? _subscription;

  TextPainter? _painter;
  double _layoutWidth = -1;
  List<double> _wordY = const [];
  double _contentHeight = 0;

  double? _dragStartY;
  double _dragStartPosition = 0;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(TeleprompterView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.engine != widget.engine) {
      _subscription?.cancel();
      _subscribe();
    }
    if (oldWidget.document != widget.document ||
        oldWidget.fontSize != widget.fontSize ||
        oldWidget.textColor != widget.textColor ||
        oldWidget.lineHeight != widget.lineHeight) {
      _layoutWidth = -1;
    }
  }

  void _subscribe() {
    _wordPosition.value = widget.engine.wordPosition;
    _subscription = widget.engine.scrollStream.listen((_) {
      _wordPosition.value = widget.engine.wordPosition;
    });
  }

  void _layout(double width) {
    if (width == _layoutWidth && _painter != null) return;
    _layoutWidth = width;

    final base = TextStyle(
      fontFamily: AppTheme.fontFamily,
      fontSize: widget.fontSize,
      height: widget.lineHeight,
      fontWeight: FontWeight.w600,
      color: widget.textColor,
    );
    final markerStyle = base.copyWith(
      color: AppColors.marker,
      fontStyle: FontStyle.italic,
      fontWeight: FontWeight.w500,
      fontSize: widget.fontSize * 0.8,
    );

    // Style marker ranges without changing character offsets.
    final raw = widget.document.raw;
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final marker in widget.document.markerSpans) {
      if (marker.start > cursor) {
        spans.add(TextSpan(text: raw.substring(cursor, marker.start)));
      }
      spans.add(TextSpan(text: raw.substring(marker.start, marker.end), style: markerStyle));
      cursor = marker.end;
    }
    if (cursor < raw.length) spans.add(TextSpan(text: raw.substring(cursor)));

    final painter = TextPainter(
      text: TextSpan(style: base, children: spans),
      textDirection: Directionality.of(context),
      textAlign: TextAlign.left,
    )..layout(maxWidth: math.max(1, width));

    final lineHeightPx = widget.fontSize * widget.lineHeight;
    final words = widget.document.words;
    final y = List<double>.filled(words.length + 1, 0);
    for (var i = 0; i < words.length; i++) {
      final caret = painter.getOffsetForCaret(TextPosition(offset: words[i].start), Rect.zero);
      // Line top plus how far across the line the word sits, so scrolling
      // glides through each line instead of stepping line by line.
      y[i] = caret.dy + (caret.dx / math.max(1, width)) * lineHeightPx;
    }
    y[words.length] = painter.height;

    // Keep y monotonic (RTL or odd wraps can produce tiny regressions).
    for (var i = 1; i < y.length; i++) {
      if (y[i] < y[i - 1]) y[i] = y[i - 1];
    }

    _painter?.dispose();
    _painter = painter;
    _wordY = y;
    _contentHeight = painter.height;
  }

  double _yFor(double position) {
    if (_wordY.isEmpty) return 0;
    final clamped = position.clamp(0.0, (_wordY.length - 1).toDouble());
    final index = clamped.floor();
    if (index >= _wordY.length - 1) return _wordY.last;
    final t = clamped - index;
    return _wordY[index] + (_wordY[index + 1] - _wordY[index]) * t;
  }

  double _positionFor(double y) {
    if (_wordY.length < 2) return 0;
    if (y <= _wordY.first) return 0;
    if (y >= _wordY.last) return (_wordY.length - 1).toDouble();
    var lo = 0;
    var hi = _wordY.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (_wordY[mid] <= y) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final span = _wordY[hi] - _wordY[lo];
    return lo + (span <= 0 ? 0 : (y - _wordY[lo]) / span);
  }

  void _onDragStart(DragStartDetails details) {
    _dragStartY = details.localPosition.dy;
    _dragStartPosition = widget.engine.wordPosition;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final start = _dragStartY;
    final count = widget.engine.wordCount;
    if (start == null || count == 0) return;
    final delta = details.localPosition.dy - start;
    final targetY = _yFor(_dragStartPosition) - delta;
    widget.engine.seek(_positionFor(targetY) / count);
  }

  @override
  Widget build(BuildContext context) {
    Widget content = LayoutBuilder(
      builder: (context, constraints) {
        final textWidth = constraints.maxWidth - widget.padding.horizontal;
        _layout(textWidth);
        final painter = _painter!;
        final readingY = constraints.maxHeight * widget.readingLine;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: _onDragStart,
          onVerticalDragUpdate: _onDragUpdate,
          onVerticalDragEnd: (_) => _dragStartY = null,
          child: ClipRect(
            child: Stack(
              children: [
                ValueListenableBuilder<double>(
                  valueListenable: _wordPosition,
                  builder: (context, position, _) {
                    final y = _yFor(position);
                    final words = widget.document.words;
                    final current =
                        words.isEmpty ? 0 : position.floor().clamp(0, words.length - 1);
                    return Transform.translate(
                      offset: Offset(widget.padding.left, readingY - y),
                      child: CustomPaint(
                        size: Size(textWidth, _contentHeight),
                        painter: _ScriptPainter(
                          painter: painter,
                          highlight: words.isEmpty ? null : words[current],
                        ),
                      ),
                    );
                  },
                ),
                if (widget.showReadingLine)
                  Positioned(
                    left: 0,
                    top: readingY - 2,
                    child: Container(
                      width: 6,
                      height: widget.fontSize * widget.lineHeight,
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );

    if (widget.mirror) {
      // Horizontal flip for beam-splitter glass rigs.
      content = Transform(
        alignment: Alignment.center,
        transform: Matrix4.rotationY(math.pi),
        child: content,
      );
    }
    return content;
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _wordPosition.dispose();
    _painter?.dispose();
    super.dispose();
  }
}

class _ScriptPainter extends CustomPainter {
  _ScriptPainter({required this.painter, this.highlight});

  final TextPainter painter;
  final ScriptWord? highlight;

  static final Paint _highlightPaint = Paint()
    ..color = AppColors.accent.withValues(alpha: 0.22);

  @override
  void paint(Canvas canvas, Size size) {
    final word = highlight;
    if (word != null) {
      final boxes = painter.getBoxesForSelection(
        TextSelection(baseOffset: word.start, extentOffset: word.end),
      );
      for (final box in boxes) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(box.toRect().inflate(3), const Radius.circular(6)),
          _highlightPaint,
        );
      }
    }
    painter.paint(canvas, Offset.zero);
  }

  @override
  bool shouldRepaint(_ScriptPainter old) =>
      old.painter != painter || old.highlight != highlight;
}
