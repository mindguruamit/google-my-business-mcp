import 'package:flutter_test/flutter_test.dart';
import 'package:mindguru_prompter/models/script_document.dart';
import 'package:mindguru_prompter/models/script_model.dart';

void main() {
  group('ScriptDocument', () {
    test('splits spoken words and keeps raw offsets', () {
      final doc = ScriptDocument.parse('Hello, world! This is MindGuru.');
      expect(doc.normalizedWords, ['hello', 'world', 'this', 'is', 'mindguru']);
      final second = doc.words[1];
      expect(doc.raw.substring(second.start, second.end), 'world!');
    });

    test('extracts [pause] and [breath] as markers at the next word', () {
      final doc = ScriptDocument.parse('One two [pause] three [breath]four [note: smile]');
      expect(doc.wordCount, 4);
      expect(doc.markers.map((m) => m.type), [CueType.pause, CueType.breath, CueType.note]);
      expect(doc.markers.map((m) => m.position), [2, 3, 4]);
      // Marker text is not a spoken word.
      expect(doc.normalizedWords, isNot(contains('pause')));
    });

    test('normalizes Hindi (Devanagari) without dropping matras', () {
      final doc = ScriptDocument.parse('नमस्ते, दोस्तों!');
      expect(doc.normalizedWords, ['नमस्ते', 'दोस्तों']);
    });

    test('estimates duration from WPM plus cue holds', () {
      final words = List.filled(140, 'word').join(' ');
      final doc = ScriptDocument.parse('$words [pause]');
      // 140 words at 140 WPM = 60s, plus a 1.5s pause.
      expect(doc.estimateDuration(140), const Duration(milliseconds: 61500));
    });

    test('tokenize strips punctuation and case', () {
      expect(ScriptDocument.tokenize("It's  GREAT, isn't it?"), ["it's", 'great', "isn't", 'it']);
    });
  });

  group('ScriptModel JSON', () {
    test('round-trips', () {
      final model = ScriptModel(
        id: 'abc',
        title: 'Take one',
        content: 'Hello [pause] there',
        createdAt: DateTime(2026, 1, 2),
        scrollSpeed: 160,
        fontSize: 40,
        driveFileId: 'drive123',
      );
      final copy = ScriptModel.fromJson(model.toJson());
      expect(copy.title, 'Take one');
      expect(copy.scrollSpeed, 160);
      expect(copy.markers.single.type, CueType.pause);
      expect(copy.driveFileId, 'drive123');
    });
  });
}
