import 'dart:math' as math;

import '../utils/constants.dart';

/// Result of aligning recognized speech against the script.
class MatchResult {
  const MatchResult({
    required this.index,
    required this.score,
    required this.isBackward,
  });

  /// Index of the last script word the speaker just said.
  final int index;

  /// Number of query words that aligned (higher is more confident).
  final double score;

  /// True when the speaker went back to an earlier line.
  final bool isBackward;
}

/// Finds where in the whole script the speaker currently is.
///
/// Uses the last few recognized words as a query and aligns them backwards
/// against the script. It searches a window around the current position
/// first (cheap, and handles normal reading plus re-reading a nearby line),
/// then the whole script with a stricter threshold (handles jumping to a
/// distant paragraph or starting over).
class ScriptMatcher {
  ScriptMatcher(this.scriptWords);

  final List<String> scriptWords;

  int get length => scriptWords.length;

  MatchResult? match(List<String> spokenWords, {required int currentIndex}) {
    if (scriptWords.isEmpty || spokenWords.isEmpty) return null;

    final query = spokenWords.length > VoiceConstants.queryWords
        ? spokenWords.sublist(spokenWords.length - VoiceConstants.queryWords)
        : spokenWords;

    final current = currentIndex.clamp(0, scriptWords.length - 1);

    final local = _bestInRange(
      query,
      from: math.max(0, current - VoiceConstants.backWindow),
      to: math.min(scriptWords.length - 1, current + VoiceConstants.forwardWindow),
      current: current,
    );

    // A short query is only trusted close to where we already are.
    final localThreshold = query.length >= 3 ? 2.0 : 1.0;
    if (local != null && local.score >= localThreshold) {
      final distance = local.index - current;
      final isNear = distance >= -3 && distance <= 12;
      // Far moves (either direction) need stronger evidence.
      if (isNear || local.score >= math.min(3, query.length)) {
        return MatchResult(
          index: local.index,
          score: local.score,
          isBackward: distance < -3,
        );
      }
    }

    // Whole-script fallback for big jumps.
    if (query.length >= 4) {
      final global = _bestInRange(
        query,
        from: 0,
        to: scriptWords.length - 1,
        current: current,
      );
      if (global != null && global.score >= 4) {
        return MatchResult(
          index: global.index,
          score: global.score,
          isBackward: global.index < current - 3,
        );
      }
    }
    return null;
  }

  _Candidate? _bestInRange(
    List<String> query, {
    required int from,
    required int to,
    required int current,
  }) {
    _Candidate? best;
    for (var end = from; end <= to; end++) {
      final score = _alignScore(query, end);
      if (score <= 0) continue;
      // Prefer higher scores; on ties, prefer the candidate closest to (and
      // preferably just ahead of) the current position.
      final distance = (end - current).abs() + (end < current ? 2 : 0);
      if (best == null ||
          score > best.score ||
          (score == best.score && distance < best.distance)) {
        best = _Candidate(end, score, distance);
      }
    }
    return best;
  }

  /// Aligns [query] so its last word lands on script[end], walking backwards.
  /// Allows one skipped/extra word (recognizers drop and insert fillers).
  double _alignScore(List<String> query, int end) {
    // The last spoken word must match the anchor, or the alignment is noise.
    if (!_similar(query.last, scriptWords[end])) return 0;

    var score = 1.0;
    var q = query.length - 2;
    var s = end - 1;
    var skips = 0;
    while (q >= 0 && s >= 0) {
      if (_similar(query[q], scriptWords[s])) {
        score += 1;
        q--;
        s--;
      } else if (skips < 2 && s - 1 >= 0 && _similar(query[q], scriptWords[s - 1])) {
        // Recognizer dropped a script word.
        skips++;
        s--;
      } else if (skips < 2 && q - 1 >= 0 && _similar(query[q - 1], scriptWords[s])) {
        // Recognizer inserted a word.
        skips++;
        q--;
      } else {
        break;
      }
    }
    return score - skips * 0.25;
  }

  static bool _similar(String a, String b) {
    if (a == b) return true;
    if (a.length < 4 || b.length < 4) return false;
    if ((a.length - b.length).abs() > 1) return false;
    return _editDistanceAtMostOne(a, b);
  }

  static bool _editDistanceAtMostOne(String a, String b) {
    var i = 0;
    var j = 0;
    var edits = 0;
    while (i < a.length && j < b.length) {
      if (a[i] == b[j]) {
        i++;
        j++;
        continue;
      }
      if (++edits > 1) return false;
      if (a.length > b.length) {
        i++;
      } else if (a.length < b.length) {
        j++;
      } else {
        i++;
        j++;
      }
    }
    return edits + (a.length - i) + (b.length - j) <= 1;
  }
}

class _Candidate {
  _Candidate(this.index, this.score, this.distance);

  final int index;
  final double score;
  final int distance;
}
