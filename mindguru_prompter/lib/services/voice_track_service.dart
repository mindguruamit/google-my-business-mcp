import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:vosk_flutter_service/vosk_flutter_service.dart';

import '../models/script_document.dart';
import '../utils/constants.dart';
import 'script_matcher.dart';
import 'teleprompter_engine.dart';

typedef WordMatchedCallback = void Function(
  int index,
  double progress,
  bool isBackward,
);

enum VoiceEngineMode {
  /// Platform recognizer (Google on Android, Apple Speech on iOS).
  /// 40+ locales, needs network unless the on-device pack is installed.
  system,

  /// Vosk, fully offline after a one-time model download.
  offline,
}

/// Follows the speaker through the whole script and drives the prompter.
class VoiceTrackService extends ChangeNotifier {
  VoiceTrackService({SpeechToText? speech}) : _speech = speech ?? SpeechToText();

  final SpeechToText _speech;

  TeleprompterEngine? _engine;
  ScriptMatcher? _matcher;
  List<String> _scriptWords = const [];

  /// Optional extra listener, called on every confident match.
  WordMatchedCallback? onWordMatched;

  bool _initialized = false;
  bool _available = false;
  bool _tracking = false;
  bool _restarting = false;
  VoiceEngineMode _mode = VoiceEngineMode.system;
  String? _localeId;
  List<LocaleName> _locales = const [];

  String _lastWord = '';
  String? _error;
  double _soundLevel = 0;
  int _currentIndex = 0;
  bool _preparingOffline = false;

  // Rolling tail of committed (final) words, plus the live partial.
  final List<String> _committed = [];
  String _lastQueryKey = '';

  // Pace measurement for adaptive speed.
  final List<(DateTime, int)> _samples = [];
  DateTime _lastMatchAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _watchdog;
  Timer? _sessionTimer;
  bool _pausedBySilence = false;

  // Vosk.
  Model? _voskModel;
  Recognizer? _voskRecognizer;
  SpeechService? _voskService;
  StreamSubscription<String>? _voskPartialSub;
  StreamSubscription<String>? _voskResultSub;

  bool get isAvailable => _available;
  bool get isTracking => _tracking;
  bool get isPreparingOffline => _preparingOffline;
  String get lastWord => _lastWord;
  String? get error => _error;
  double get soundLevel => _soundLevel;
  int get currentIndex => _currentIndex;
  VoiceEngineMode get mode => _mode;
  String? get localeId => _localeId;
  List<LocaleName> get locales => _locales;

  /// Initializes the platform recognizer and loads the locale list.
  Future<bool> initialize() async {
    if (_initialized) return _available;
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      _error = 'Microphone permission denied';
      notifyListeners();
      return false;
    }
    _available = await _speech.initialize(
      onError: _onSpeechError,
      onStatus: _onSpeechStatus,
      finalTimeout: const Duration(milliseconds: 800),
    );
    // Only cache success, so a later retry works after the user fixes
    // permissions in Settings.
    _initialized = _available;
    if (_available) {
      _locales = await _speech.locales();
      _localeId ??= (await _speech.systemLocale())?.localeId;
    } else {
      _error = 'Speech recognition not available on this device';
    }
    notifyListeners();
    return _available;
  }

  void attachEngine(TeleprompterEngine engine) => _engine = engine;

  /// Splits the full script into words for whole-script matching.
  void loadScript(String fullText) {
    final document = ScriptDocument.parse(fullText);
    _scriptWords = document.normalizedWords;
    _matcher = ScriptMatcher(_scriptWords);
    _currentIndex = 0;
    _committed.clear();
    _samples.clear();
    _lastQueryKey = '';
  }

  Future<void> setLocale(String? localeId) async {
    if (localeId == _localeId) return;
    _localeId = localeId;
    notifyListeners();
    final wasTracking = _tracking;
    if (wasTracking) await stopTracking();
    // An offline model is language-specific; load the new one next start.
    await _releaseVosk();
    if (wasTracking) await startTracking();
  }

  Future<void> _releaseVosk() async {
    await _voskPartialSub?.cancel();
    await _voskResultSub?.cancel();
    _voskPartialSub = null;
    _voskResultSub = null;
    await _voskService?.dispose();
    await _voskRecognizer?.dispose();
    _voskModel?.dispose();
    _voskService = null;
    _voskRecognizer = null;
    _voskModel = null;
  }

  Future<void> setMode(VoiceEngineMode mode) async {
    if (mode == _mode) return;
    final wasTracking = _tracking;
    if (wasTracking) await stopTracking();
    _mode = mode;
    notifyListeners();
    if (wasTracking) await startTracking();
  }

  Future<void> startTracking() async {
    if (_tracking) return;
    _error = null;
    if (_matcher == null || _scriptWords.isEmpty) {
      _error = 'Load a script first';
      notifyListeners();
      return;
    }

    final engine = _engine;
    if (engine != null) {
      _currentIndex = engine.wordPosition.floor().clamp(0, _scriptWords.length - 1);
    }

    _tracking = true;
    _committed.clear();
    _samples.clear();
    _lastMatchAt = DateTime.now();
    notifyListeners();

    try {
      if (_mode == VoiceEngineMode.offline) {
        await _startVosk();
      } else {
        if (!await initialize()) {
          _tracking = false;
          notifyListeners();
          return;
        }
        await _listen();
      }
    } catch (e) {
      _error = 'Voice tracking failed: $e';
      _tracking = false;
      notifyListeners();
      return;
    }

    _sessionTimer?.cancel();
    _sessionTimer = Timer(VoiceConstants.sessionLength, stopTracking);
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(milliseconds: 250), (_) => _checkPace());
  }

  Future<void> stopTracking() async {
    if (!_tracking) return;
    _tracking = false;
    _sessionTimer?.cancel();
    _watchdog?.cancel();
    _soundLevel = 0;
    _engine?.setAdaptiveSpeed(1.0);
    if (_mode == VoiceEngineMode.offline) {
      await _voskService?.stop();
    } else {
      await _speech.stop();
    }
    notifyListeners();
  }

  Future<void> toggle() => _tracking ? stopTracking() : startTracking();

  // ---------------------------------------------------------------------------
  // System recognizer

  Future<void> _listen() async {
    if (!_tracking) return;
    await _speech.listen(
      onResult: _onSpeechResult,
      onSoundLevelChange: _onSoundLevel,
      listenOptions: SpeechListenOptions(
        partialResults: true,
        listenMode: ListenMode.dictation,
        cancelOnError: false,
        listenFor: VoiceConstants.sessionLength,
        pauseFor: const Duration(seconds: 30),
        localeId: _localeId,
        // Biases the recognizer toward the script vocabulary where supported.
        contextualPhrases: _contextualPhrases(),
      ),
    );
  }

  List<String> _contextualPhrases() {
    final unique = <String>{};
    for (final word in _scriptWords) {
      if (word.length > 3) unique.add(word);
      if (unique.length >= 400) break;
    }
    return unique.toList();
  }

  void _restartListening() {
    if (!_tracking || _restarting) return;
    _restarting = true;
    // The platform recognizer ends a session after silence; stitch sessions
    // together so tracking feels continuous for the full 30 minutes.
    Future<void>.delayed(const Duration(milliseconds: 200), () async {
      _restarting = false;
      if (!_tracking) return;
      if (_mode == VoiceEngineMode.system && !_speech.isListening) {
        try {
          await _listen();
        } catch (e) {
          _error = 'Could not restart listening: $e';
          notifyListeners();
        }
      }
    });
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    _handleTranscript(result.recognizedWords, isFinal: result.finalResult);
  }

  void _onSpeechStatus(String status) {
    if (status == SpeechToText.doneStatus ||
        status == SpeechToText.notListeningStatus) {
      _restartListening();
    }
  }

  void _onSpeechError(SpeechRecognitionError error) {
    const fatal = {'error_permission', 'error_insufficient_permissions'};
    if (fatal.contains(error.errorMsg)) {
      _error = 'Microphone permission denied';
      stopTracking();
      return;
    }
    // no_match / speech_timeout / busy are routine between phrases.
    _restartListening();
  }

  void _onSoundLevel(double level) {
    // Android reports roughly -2..10 dB, iOS 0..1. Normalize to 0..1.
    final normalized = level > 1 ? (level + 2) / 12 : level;
    _soundLevel = normalized.clamp(0.0, 1.0);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Offline (Vosk)

  Future<void> _startVosk() async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) throw StateError('Microphone permission denied');

    final plugin = VoskFlutterPlugin.instance();
    if (_voskModel == null) {
      _preparingOffline = true;
      notifyListeners();
      try {
        final loader = ModelLoader();
        final url = await _resolveVoskModelUrl(loader);
        final path = await loader.loadFromNetwork(url);
        _voskModel = await plugin.createModel(path);
      } finally {
        _preparingOffline = false;
        notifyListeners();
      }
    }

    if (_voskService == null) {
      _voskRecognizer = await plugin.createRecognizer(
        model: _voskModel!,
        sampleRate: 16000,
      );
      _voskService = await plugin.initSpeechService(_voskRecognizer!);
      _voskPartialSub = _voskService!.onPartial().listen((json) {
        final text = _readVoskField(json, 'partial');
        if (text.isNotEmpty) _handleTranscript(text, isFinal: false);
        _soundLevel = text.isEmpty ? 0.1 : 0.7;
        notifyListeners();
      });
      _voskResultSub = _voskService!.onResult().listen((json) {
        final text = _readVoskField(json, 'text');
        if (text.isNotEmpty) _handleTranscript(text, isFinal: true);
      });
    }
    await _voskService!.start();
  }

  Future<String> _resolveVoskModelUrl(ModelLoader loader) async {
    final locale = (_localeId ?? 'en_US').replaceAll('_', '-').toLowerCase();
    final language = locale.split('-').first;
    try {
      final models = await loader.loadModelsList();
      final candidates = models
          .where((m) => !m.obsolete && m.type == 'small')
          .toList();
      for (final key in [locale, language]) {
        for (final model in candidates) {
          if (model.lang.toLowerCase() == key) return model.url;
        }
      }
    } catch (_) {
      // Catalogue unreachable – fall through to bundled URLs.
    }
    return VoiceConstants.voskFallbackModels[locale] ??
        VoiceConstants.voskFallbackModels[language] ??
        VoiceConstants.voskFallbackModels['en-us']!;
  }

  static String _readVoskField(String json, String field) {
    try {
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      return (decoded[field] as String? ?? '').trim();
    } catch (_) {
      return '';
    }
  }

  // ---------------------------------------------------------------------------
  // Matching

  void _handleTranscript(String transcript, {required bool isFinal}) {
    final matcher = _matcher;
    if (!_tracking || matcher == null) return;

    final words = ScriptDocument.tokenize(transcript);
    if (words.isEmpty) return;
    _lastWord = words.last;

    final query = [..._committed, ...words];
    if (isFinal) {
      _committed
        ..addAll(words)
        ..removeRange(0, (_committed.length - 12).clamp(0, _committed.length));
    }

    final key = query.length > VoiceConstants.queryWords
        ? query.sublist(query.length - VoiceConstants.queryWords).join(' ')
        : query.join(' ');
    if (key == _lastQueryKey) {
      notifyListeners();
      return;
    }
    _lastQueryKey = key;

    final result = matcher.match(query, currentIndex: _currentIndex);
    if (result != null) {
      _applyMatch(result);
    }
    notifyListeners();
  }

  void _applyMatch(MatchResult result) {
    // The speaker has finished word [index], so put the next word on the
    // reading line.
    final target = (result.index + 1).clamp(0, _scriptWords.length);
    final forward = target >= _currentIndex;
    _currentIndex = target;
    _lastMatchAt = DateTime.now();

    if (result.isBackward) {
      _samples.clear();
    } else if (forward) {
      _samples.add((_lastMatchAt, target));
      _samples.removeWhere(
        (s) => _lastMatchAt.difference(s.$1) > const Duration(seconds: 8),
      );
    }

    final progress = _scriptWords.isEmpty ? 0.0 : target / _scriptWords.length;
    final engine = _engine;
    if (engine != null) {
      engine.seek(progress, smooth: true);
      if (_pausedBySilence) {
        _pausedBySilence = false;
        engine.play();
      }
    }
    onWordMatched?.call(target, progress, result.isBackward);
  }

  /// Adapts speed to the speaker's measured pace, and stops the prompter
  /// from running away when the speaker goes quiet.
  void _checkPace() {
    final engine = _engine;
    if (!_tracking || engine == null) return;

    if (_samples.length >= 2) {
      final first = _samples.first;
      final last = _samples.last;
      final minutes = last.$1.difference(first.$1).inMilliseconds / 60000;
      final words = last.$2 - first.$2;
      if (minutes > 0.05 && words > 0) {
        final measuredWpm = words / minutes;
        final target = measuredWpm / engine.wpm;
        final smoothed = engine.adaptiveFactor * 0.7 + target * 0.3;
        engine.setAdaptiveSpeed(smoothed);
      }
    }

    final ahead = engine.wordPosition - _currentIndex;
    if (ahead > 6) {
      engine.setAdaptiveSpeed(TeleprompterConstants.minAdaptiveFactor);
    }

    final silence = DateTime.now().difference(_lastMatchAt);
    if (engine.isPlaying && silence > const Duration(milliseconds: 2500)) {
      engine.pause();
      _pausedBySilence = true;
    }
  }

  @override
  void dispose() {
    _tracking = false;
    _sessionTimer?.cancel();
    _watchdog?.cancel();
    _speech.cancel();
    _voskPartialSub?.cancel();
    _voskResultSub?.cancel();
    _voskService?.dispose();
    _voskRecognizer?.dispose();
    _voskModel?.dispose();
    super.dispose();
  }
}
