import 'script_model.dart';

/// A spoken word inside the script, with its character range in the raw text.
class ScriptWord {
  const ScriptWord({
    required this.text,
    required this.normalized,
    required this.start,
    required this.end,
  });

  /// The word as written.
  final String text;

  /// Lower-case, punctuation-free form used for voice matching.
  final String normalized;

  /// Character offsets into [ScriptDocument.raw].
  final int start;
  final int end;
}

/// A cue marker as it appears in the raw text, e.g. `[pause]`.
class MarkerSpan {
  const MarkerSpan({
    required this.marker,
    required this.start,
    required this.end,
  });

  final CueMarker marker;
  final int start;
  final int end;
}

/// Parsed script: spoken words (for scrolling + voice tracking) and cue
/// markers (for holds and highlighting). The raw text is displayed as-is, so
/// every offset here maps 1:1 onto what the prompter renders.
class ScriptDocument {
  ScriptDocument._(this.raw, this.words, this.markerSpans);

  factory ScriptDocument.parse(String raw) {
    final words = <ScriptWord>[];
    final markers = <MarkerSpan>[];

    var index = 0;
    while (index < raw.length) {
      final markerMatch = _markerPattern.matchAsPrefix(raw, index);
      if (markerMatch != null) {
        final body = markerMatch.group(1)!.trim();
        markers.add(
          MarkerSpan(
            marker: CueMarker.fromTag(body, position: words.length),
            start: markerMatch.start,
            end: markerMatch.end,
          ),
        );
        index = markerMatch.end;
        continue;
      }

      final wordMatch = _wordPattern.matchAsPrefix(raw, index);
      if (wordMatch != null) {
        final text = wordMatch.group(0)!;
        final normalized = normalize(text);
        if (normalized.isNotEmpty) {
          words.add(
            ScriptWord(
              text: text,
              normalized: normalized,
              start: wordMatch.start,
              end: wordMatch.end,
            ),
          );
        }
        index = wordMatch.end;
        continue;
      }

      index++;
    }

    return ScriptDocument._(raw, words, markers);
  }

  static final RegExp _markerPattern = RegExp(r'\[([^\[\]\n]{1,40})\]');
  static final RegExp _wordPattern = RegExp(r'[^\s\[\]]+');
  static final RegExp _nonWord = RegExp(r"[^\p{L}\p{N}\p{M}']", unicode: true);

  final String raw;
  final List<ScriptWord> words;
  final List<MarkerSpan> markerSpans;

  List<CueMarker> get markers => markerSpans.map((m) => m.marker).toList();

  int get wordCount => words.length;

  List<String> get normalizedWords => words.map((w) => w.normalized).toList();

  /// Lower-cases and strips punctuation. Keeps letters from every script
  /// (Devanagari, Latin, CJK…) and combining marks so Hindi matras survive.
  static String normalize(String input) {
    return input
        .toLowerCase()
        .replaceAll('’', "'")
        .replaceAll(_nonWord, '')
        .replaceAll(RegExp(r"^'+|'+$"), '');
  }

  /// Splits free recognized speech into normalized words.
  static List<String> tokenize(String text) {
    return text
        .split(RegExp(r'\s+'))
        .map(normalize)
        .where((w) => w.isNotEmpty)
        .toList();
  }

  /// Estimated read time at [wpm], including cue holds.
  Duration estimateDuration(int wpm) {
    if (wpm <= 0) return Duration.zero;
    final speakingMs = (wordCount / wpm * 60000).round();
    final holdMs = markers.fold<int>(0, (sum, m) => sum + m.hold.inMilliseconds);
    return Duration(milliseconds: speakingMs + holdMs);
  }
}
