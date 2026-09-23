import 'package:flutter_test/flutter_test.dart';
import 'package:mindguru_prompter/models/script_document.dart';
import 'package:mindguru_prompter/services/script_matcher.dart';

void main() {
  const script = '''
The mind follows the body and the body follows the nervous system.
Today we will learn a simple breathing practice that calms you down.
Sit tall, relax your shoulders, and breathe in slowly through your nose.
Hold for a moment, then breathe out through your mouth for twice as long.
''';

  final words = ScriptDocument.parse(script).normalizedWords;
  final matcher = ScriptMatcher(words);

  List<String> say(String text) => ScriptDocument.tokenize(text);

  int indexOfPhraseEnd(String phrase) {
    final target = say(phrase);
    for (var i = 0; i + target.length <= words.length; i++) {
      var ok = true;
      for (var j = 0; j < target.length; j++) {
        if (words[i + j] != target[j]) ok = false;
      }
      if (ok) return i + target.length - 1;
    }
    throw StateError('phrase not found');
  }

  test('tracks normal forward reading', () {
    final result = matcher.match(say('the mind follows the body'), currentIndex: 0);
    expect(result, isNotNull);
    expect(result!.index, indexOfPhraseEnd('the mind follows the body'));
    expect(result.isBackward, isFalse);
  });

  test('tolerates a dropped word and a recognizer typo', () {
    final current = indexOfPhraseEnd('Sit tall');
    // "your" dropped, "shoulder" instead of "shoulders".
    final result = matcher.match(say('sit tall relax shoulder and breathe'), currentIndex: current);
    expect(result, isNotNull);
    expect(result!.index, indexOfPhraseEnd('relax your shoulders, and breathe'));
  });

  test('detects going back to repeat an earlier line', () {
    final current = indexOfPhraseEnd('then breathe out through your mouth');
    final result = matcher.match(
      say('today we will learn a simple breathing practice'),
      currentIndex: current,
    );
    expect(result, isNotNull);
    expect(result!.isBackward, isTrue);
    expect(result.index, indexOfPhraseEnd('learn a simple breathing practice'));
  });

  test('ignores speech that is not in the script', () {
    final result = matcher.match(say('pizza delivery tomorrow evening please'), currentIndex: 10);
    expect(result, isNull);
  });

  test('prefers the nearest occurrence of a repeated phrase', () {
    // "the body" appears twice in the first sentence.
    final result = matcher.match(say('and the body'), currentIndex: 5);
    expect(result, isNotNull);
    expect(result!.index, indexOfPhraseEnd('and the body'));
  });
}
