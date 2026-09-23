import 'package:flutter_test/flutter_test.dart';
import 'package:mindguru_prompter/models/script_model.dart';
import 'package:mindguru_prompter/services/teleprompter_engine.dart';

void main() {
  late TeleprompterEngine engine;

  setUp(() {
    engine = TeleprompterEngine(wpm: 120)..load(wordCount: 240);
  });

  tearDown(() => engine.dispose());

  test('advances at the set WPM', () {
    engine.play();
    engine.advance(const Duration(seconds: 30));
    // 120 WPM = 2 words/second.
    expect(engine.wordPosition, closeTo(60, 0.001));
    expect(engine.progress, closeTo(0.25, 0.001));
  });

  test('adaptive factor scales speed and is clamped', () {
    engine
      ..setAdaptiveSpeed(1.5)
      ..play()
      ..advance(const Duration(seconds: 10));
    expect(engine.wordPosition, closeTo(30, 0.001));

    engine.setAdaptiveSpeed(10);
    expect(engine.adaptiveFactor, 2.0);
  });

  test('clamps WPM to 80..250', () {
    engine.setSpeed(10);
    expect(engine.wpm, 80);
    engine.setSpeed(999);
    expect(engine.wpm, 250);
  });

  test('holds on a [pause] marker, then continues', () {
    engine.load(
      wordCount: 100,
      markers: const [CueMarker(position: 4, type: CueType.pause, label: 'pause')],
    );
    engine.play();
    engine.advance(const Duration(seconds: 3)); // would reach word 6
    expect(engine.wordPosition, 4);
    expect(engine.activeCue.value?.type, CueType.pause);

    engine.advance(const Duration(milliseconds: 1600)); // hold is 1.5s
    expect(engine.activeCue.value, isNull);
    engine.advance(const Duration(seconds: 1));
    expect(engine.wordPosition, closeTo(6, 0.001));
  });

  test('stops at the end', () {
    engine.play();
    engine.advance(const Duration(minutes: 5));
    expect(engine.progress, 1.0);
    expect(engine.isPlaying, isFalse);
  });

  test('smooth seek glides toward the target', () {
    engine.seek(0.5, smooth: true);
    engine.advance(const Duration(milliseconds: 16));
    final first = engine.wordPosition;
    expect(first, greaterThan(0));
    expect(first, lessThan(120));
    for (var i = 0; i < 60; i++) {
      engine.advance(const Duration(milliseconds: 16));
    }
    expect(engine.wordPosition, closeTo(120, 0.05));
  });

  test('scrollStream emits progress', () async {
    final values = <double>[];
    final sub = engine.scrollStream.listen(values.add);
    engine.seek(0.1);
    await Future<void>.delayed(Duration.zero);
    expect(values.last, closeTo(0.1, 0.0001));
    await sub.cancel();
  });
}
