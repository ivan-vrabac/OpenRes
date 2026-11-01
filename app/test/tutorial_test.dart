import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openres/widgets/tutorial.dart';

void main() {
  Future<void> show(WidgetTester t, void Function() done, {GlobalKey? target}) => t.pumpWidget(MaterialApp(
        home: Scaffold(body: Stack(children: [
          Align(key: target, alignment: Alignment.bottomCenter, child: const SizedBox(width: 50, height: 50)),
          TutorialOverlay(onDone: done, steps: [
            TutorialStep('One', 'first', target),
            const TutorialStep('Two', 'second'),
          ]),
        ])),
      ));

  testWidgets('steps go forward and back, and the last one finishes', (t) async {
    var done = 0;
    await show(t, () => done++);
    expect(find.text('1 of 2'), findsOneWidget);
    await t.tap(find.text('Next'));
    await t.pump();
    expect(find.text('Two'), findsOneWidget);
    await t.tap(find.text('Back'));
    await t.pump();
    expect(find.text('One'), findsOneWidget);
    await t.tap(find.text('Next'));
    await t.pump();
    await t.tap(find.text('Start playing'));
    expect(done, 1);
  });

  testWidgets('it can be skipped at once', (t) async {
    var done = 0;
    await show(t, () => done++);
    await t.tap(find.text('Skip tutorial'));
    expect(done, 1);
  });
}
