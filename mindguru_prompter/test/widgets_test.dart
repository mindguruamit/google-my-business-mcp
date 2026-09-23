import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mindguru_prompter/models/script_document.dart';
import 'package:mindguru_prompter/services/teleprompter_engine.dart';
import 'package:mindguru_prompter/utils/app_theme.dart';
import 'package:mindguru_prompter/utils/constants.dart';
import 'package:mindguru_prompter/widgets/resolution_selector.dart';
import 'package:mindguru_prompter/widgets/speed_control.dart';
import 'package:mindguru_prompter/widgets/teleprompter_view.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('ResolutionSelector greys out 8K with a device tooltip', (tester) async {
    VideoResolution? picked;
    await tester.pumpWidget(_wrap(
      ResolutionSelector(
        selected: VideoResolution.uhd4k,
        isSupported: (r) => r != VideoResolution.uhd8k,
        onSelected: (r) => picked = r,
        maxLabel: '4K60',
      ),
    ));
    await tester.pumpAndSettle();

    final chip8k = tester.widget<ChoiceChip>(
      find.ancestor(of: find.text('8K'), matching: find.byType(ChoiceChip)),
    );
    expect(chip8k.onSelected, isNull);
    expect(
      find.byWidgetPredicate(
        (w) => w is Tooltip && w.message == 'Not supported on this device - max 4K60',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('1080p'));
    expect(picked, VideoResolution.fhd1080);
  });

  testWidgets('SpeedControl reports WPM changes in range', (tester) async {
    var wpm = 140;
    await tester.pumpWidget(_wrap(
      StatefulBuilder(
        builder: (context, setState) => SpeedControl(
          wpm: wpm,
          onChanged: (v) => setState(() => wpm = v),
        ),
      ),
    ));
    expect(find.text('140 WPM'), findsOneWidget);
    await tester.drag(find.byType(Slider), const Offset(600, 0));
    await tester.pump();
    expect(wpm, TeleprompterConstants.maxWpm);
  });

  testWidgets('TeleprompterView scrolls as the engine advances', (tester) async {
    final document = ScriptDocument.parse(List.generate(300, (i) => 'word$i').join(' '));
    final engine = TeleprompterEngine()..load(wordCount: document.wordCount);
    addTearDown(engine.dispose);

    await tester.pumpWidget(_wrap(
      SizedBox(
        height: 300,
        child: TeleprompterView(document: document, engine: engine),
      ),
    ));

    double translateY() => tester
        .widget<Transform>(
          find.descendant(of: find.byType(TeleprompterView), matching: find.byType(Transform)).first,
        )
        .transform
        .getTranslation()
        .y;

    final start = translateY();
    engine.seek(0.5);
    await tester.pump();
    expect(translateY(), lessThan(start));
  });
}
