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

  group('waiting for the Campus', () {
    late ValueNotifier<bool> placed;
    final target = GlobalKey();
    var mapTaps = 0, tabTaps = 0;

    Future<void> campus(WidgetTester t) async {
      placed = ValueNotifier(false);
      mapTaps = tabTaps = 0;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: Stack(children: [
          Positioned.fill(child: GestureDetector(onTap: () => mapTaps++, behavior: HitTestBehavior.opaque)),
          Positioned(left: 0, right: 0, bottom: 0, height: 60,
              child: GestureDetector(onTap: () => tabTaps++, behavior: HitTestBehavior.opaque)),
          Positioned(left: 100, right: 100, bottom: 70, height: 50, child: SizedBox(key: target)),
          TutorialOverlay(onDone: () {}, changes: placed, passed: () => placed.value, steps: [
            const TutorialStep('Welcome', 'hello'),
            TutorialStep('Place', 'slide', target, null, false, true),
            const TutorialStep('After', 'next'),
          ]),
        ])),
      ));
    }

    testWidgets('no skipping, the map is free, the tab bar is not, placing goes on by itself', (t) async {
      await campus(t);
      expect(find.text('Skip tutorial'), findsNothing);
      await t.tap(find.text('Next'));
      await t.pump();
      await t.pump();
      expect(find.text('Place'), findsOneWidget);
      expect(find.text('Next'), findsNothing);
      expect(find.text('Skip tutorial'), findsNothing);
      await t.tapAt(const Offset(400, 400));
      expect(mapTaps, 1);
      await t.tapAt(const Offset(400, 590));
      await t.pump();
      expect(tabTaps, 0);
      mapTaps = 0;
      await t.tapAt(const Offset(40, 505));                   // a button beside the slider
      await t.pump();
      expect(mapTaps, 0);
      placed.value = true;
      await t.pump();
      expect(find.text('After'), findsOneWidget);
      expect(find.text('Skip tutorial'), findsNothing);       // the last card has none
      await t.tap(find.text('Back'));
      await t.pump();
      expect(find.text('Next'), findsOneWidget);              // done: a normal card now
      expect(find.text('Skip tutorial'), findsOneWidget);
      await t.pumpWidget(const SizedBox());                   // ends its timer
    });
  });
}
