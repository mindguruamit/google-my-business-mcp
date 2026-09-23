import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/script_model.dart';
import '../utils/constants.dart';

/// Word-accurate scroll clock for the prompter.
///
/// Position is tracked in spoken words (fractional), and [scrollStream] emits
/// normalized progress 0..1 on a 16ms (60fps) ticker. The view converts a
/// word position to pixels with a text layout, so voice tracking and
/// auto-scroll land on exactly the same line.
class TeleprompterEngine {
  TeleprompterEngine({int wpm = TeleprompterConstants.defaultWpm})
      : _wpm = wpm.clamp(
          TeleprompterConstants.minWpm,
          TeleprompterConstants.maxWpm,
        );

  final StreamController<double> _scrollController =
      StreamController<double>.broadcast();

  /// Emits true/false when playback starts/stops.
  final ValueNotifier<bool> playing = ValueNotifier<bool>(false);

  /// The cue the engine is currently holding on, if any.
  final ValueNotifier<CueMarker?> activeCue = ValueNotifier<CueMarker?>(null);

  Timer? _ticker;
  final Stopwatch _clock = Stopwatch();

  int _wordCount = 0;
  List<CueMarker> _markers = const [];
  int _nextMarker = 0;

  double _position = 0;
  double? _glideTarget;
  Duration _holdRemaining = Duration.zero;

  int _wpm;
  double _adaptiveFactor = 1.0;
  bool _disposed = false;

  Stream<double> get scrollStream => _scrollController.stream;

  bool get isPlaying => playing.value;
  int get wpm => _wpm;
  double get adaptiveFactor => _adaptiveFactor;
  double get effectiveWpm => _wpm * _adaptiveFactor;
  int get wordCount => _wordCount;

  /// Current position in words.
  double get wordPosition => _position;

  /// Current normalized progress 0..1.
  double get progress => _wordCount == 0 ? 0 : _position / _wordCount;

  bool get isAtEnd => _wordCount > 0 && _position >= _wordCount;

  /// Loads a script. Resets position to the top.
  void load({required int wordCount, List<CueMarker> markers = const []}) {
    _wordCount = wordCount;
    _markers = [...markers]..sort((a, b) => a.position.compareTo(b.position));
    _position = 0;
    _glideTarget = null;
    _holdRemaining = Duration.zero;
    _nextMarker = 0;
    activeCue.value = null;
    _emit();
  }

  void play() {
    if (_disposed || _wordCount == 0) return;
    if (isAtEnd) seek(0);
    _clock
      ..reset()
      ..start();
    _ticker ??= Timer.periodic(TeleprompterConstants.tick, (_) => _onTick());
    playing.value = true;
  }

  void pause() {
    _ticker?.cancel();
    _ticker = null;
    _clock.stop();
    playing.value = false;
    activeCue.value = null;
    _holdRemaining = Duration.zero;
  }

  void toggle() => isPlaying ? pause() : play();

  /// Jumps to normalized [progress] (0..1). With [smooth], the engine glides
  /// there over ~250ms instead of snapping – used by voice tracking.
  void seek(double progress, {bool smooth = false}) {
    if (_wordCount == 0) return;
    final target = progress.clamp(0.0, 1.0) * _wordCount;
    if (smooth) {
      _glideTarget = target;
      if (_ticker == null) {
        _clock
          ..reset()
          ..start();
        _ticker = Timer.periodic(TeleprompterConstants.tick, (_) => _onTick());
      }
    } else {
      _glideTarget = null;
      _position = target;
      _syncMarkerCursor();
      _emit();
    }
  }

  /// Seeks to a word index.
  void seekToWord(int index, {bool smooth = false}) {
    if (_wordCount == 0) return;
    seek(index / _wordCount, smooth: smooth);
  }

  /// Nudges by [words] (negative scrolls back).
  void nudge(double words) {
    if (_wordCount == 0) return;
    seek((_position + words) / _wordCount);
  }

  void setSpeed(int wpm) {
    _wpm = wpm.clamp(TeleprompterConstants.minWpm, TeleprompterConstants.maxWpm);
  }

  /// Multiplies the base WPM. VoiceTrack raises this when the speaker is
  /// faster than the set speed and lowers it when slower.
  void setAdaptiveSpeed(double factor) {
    _adaptiveFactor = factor.clamp(
      TeleprompterConstants.minAdaptiveFactor,
      TeleprompterConstants.maxAdaptiveFactor,
    );
  }

  void _onTick() {
    final elapsed = _clock.elapsed;
    _clock
      ..reset()
      ..start();
    advance(elapsed);
  }

  /// Advances the clock by [elapsed]. Public for deterministic tests.
  @visibleForTesting
  void advance(Duration elapsed) {
    if (_disposed || _wordCount == 0) return;

    final glide = _glideTarget;
    if (glide != null) {
      // Exponential ease, frame-rate independent: ~95% of the way in 250ms.
      final fraction = 1 - math.exp(-elapsed.inMicroseconds / 83000);
      final delta = glide - _position;
      if (delta.abs() < 0.02) {
        _position = glide;
        _glideTarget = null;
      } else {
        _position += delta * fraction;
      }
      _syncMarkerCursor();
      _emit();
      if (!isPlaying && _glideTarget == null) {
        _ticker?.cancel();
        _ticker = null;
        _clock.stop();
      }
      return;
    }

    if (!isPlaying) return;

    if (_holdRemaining > Duration.zero) {
      _holdRemaining -= elapsed;
      if (_holdRemaining <= Duration.zero) {
        _holdRemaining = Duration.zero;
        activeCue.value = null;
      }
      return;
    }

    final wordsPerMicro = effectiveWpm / 60 / 1000000;
    var next = _position + elapsed.inMicroseconds * wordsPerMicro;

    // Stop at the next cue marker and hold there.
    if (_nextMarker < _markers.length) {
      final marker = _markers[_nextMarker];
      if (next >= marker.position && _position <= marker.position) {
        next = marker.position.toDouble();
        _nextMarker++;
        if (marker.hold > Duration.zero) {
          _holdRemaining = marker.hold;
          activeCue.value = marker;
        }
      }
    }

    _position = next;
    if (_position >= _wordCount) {
      _position = _wordCount.toDouble();
      _emit();
      pause();
      return;
    }
    _emit();
  }

  void _syncMarkerCursor() {
    _nextMarker = _markers.indexWhere((m) => m.position >= _position.ceil());
    if (_nextMarker == -1) _nextMarker = _markers.length;
  }

  void _emit() {
    if (!_scrollController.isClosed) _scrollController.add(progress);
  }

  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _scrollController.close();
    playing.dispose();
    activeCue.dispose();
  }
}
