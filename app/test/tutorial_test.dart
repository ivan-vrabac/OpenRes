import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openres/widgets/tutorial.dart';

void main() {
  Future<void> show(WidgetTester t, void Function() done, {GlobalKey? target}) => t.pumpWidget(MaterialApp(
        home: Scaffold(body: Stack(children: [
          Align(key: target, alignment: Alignment.bottomCenter, child: const SizedBox(width: 50, height: 50)),
          TutorialOverlay(onDone: done, steps: [
            TutorialStep('One', 'first', target: target),
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

  testWidgets('a step scrolls its target into view, and leaving it scrolls back', (t) async {
    final far = GlobalKey();
    final list = ScrollController();
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: Stack(children: [
        ListView(controller: list, cacheExtent: 5000, children: [
          const SizedBox(height: 1500),
          SizedBox(key: far, height: 100),
          const SizedBox(height: 800),
        ]),
        TutorialOverlay(onDone: () {}, steps: [TutorialStep('Far', 'text', target: far), const TutorialStep('After', 'next')]),
      ])),
    ));
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    expect(list.offset, greaterThan(1000));
    await t.tap(find.text('Next'));
    await t.pumpAndSettle();
    expect(list.offset, 0);
    await t.pump(const Duration(milliseconds: 400));
  });

  testWidgets('a target on a page of the tabs leaves the pages where they are', (t) async {
    final onPage = GlobalKey();
    final pages = PageController(initialPage: 1);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: Stack(children: [
        PageView(controller: pages, children: [
          const SizedBox(),
          Align(alignment: Alignment.bottomRight, child: SizedBox(key: onPage, width: 50, height: 50)),
          const SizedBox(),
        ]),
        TutorialOverlay(onDone: () {}, steps: [TutorialStep('On map', 'text', target: onPage), const TutorialStep('After', 'next')]),
      ])),
    ));
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    expect(pages.page, 1);
    await t.tap(find.text('Next'));
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    expect(pages.page, 1);
  });

  group('guided', () {
    late ValueNotifier<bool> placed;
    final target = GlobalKey();
    var mapTaps = 0, tabTaps = 0, topTaps = 0;

    Future<void> campus(WidgetTester t) async {
      placed = ValueNotifier(false);
      mapTaps = tabTaps = topTaps = 0;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: Stack(children: [
          Positioned.fill(child: GestureDetector(onTap: () => mapTaps++, behavior: HitTestBehavior.opaque)),
          Positioned(left: 0, right: 0, top: 0, height: 40,
              child: GestureDetector(onTap: () => topTaps++, behavior: HitTestBehavior.opaque)),
          Positioned(left: 0, right: 0, bottom: 0, height: 60,
              child: GestureDetector(onTap: () => tabTaps++, behavior: HitTestBehavior.opaque)),
          Positioned(left: 100, right: 100, bottom: 70, height: 50, child: SizedBox(key: target)),
          TutorialOverlay(onDone: () {}, guided: true, changes: placed, steps: [
            const TutorialStep('Welcome', 'hello'),
            TutorialStep('Place', 'slide', target: target, done: () => placed.value),
            const TutorialStep('After', 'next'),
          ]),
        ])),
      ));
    }

    testWidgets('no skipping or going back; the map is free, its top buttons and the tab bar are not; done goes on',
        (t) async {
      await campus(t);
      expect(find.text('Skip tutorial'), findsNothing);
      await t.tap(find.text('Next'));
      await t.pump();
      await t.pump();
      expect(find.text('Place'), findsOneWidget);
      expect(find.text('Next'), findsNothing);
      expect(find.text('Back'), findsNothing);
      await t.tapAt(const Offset(400, 400));
      expect(mapTaps, 1);
      await t.tapAt(const Offset(400, 10));
      expect(topTaps, 0);
      await t.tapAt(const Offset(400, 590));
      await t.pump();
      expect(tabTaps, 0);
      mapTaps = 0;
      await t.tapAt(const Offset(40, 505));                   // a button beside the slider
      await t.pump();
      expect(mapTaps, 0);
      placed.value = true;
      await t.pump();
      expect(find.text('Place'), findsOneWidget);             // done: it waits for Next
      await t.tap(find.text('Next'));
      await t.pump();
      expect(find.text('After'), findsOneWidget);
      expect(find.text('Back'), findsNothing);
      await t.pumpWidget(const SizedBox());                   // ends its timers
    });

    testWidgets('read from Settings a task is a plain card', (t) async {
      placed = ValueNotifier(false);
      await t.pumpWidget(MaterialApp(home: Scaffold(body: Stack(children: [
        SizedBox(key: target, width: 50, height: 50),
        TutorialOverlay(onDone: () {}, steps: [
          TutorialStep('Place', 'slide', target: target, done: () => placed.value),
          const TutorialStep('After', 'next'),
        ]),
      ]))));
      expect(find.text('Next'), findsOneWidget);
      expect(find.text('Skip tutorial'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });
  });
}
