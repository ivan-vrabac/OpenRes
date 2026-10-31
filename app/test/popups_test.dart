import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openres/widgets/popups.dart';

/// The black screen (owner 2026-10-31): a late close after a lease cancel, with the sheet already gone.
void main() {
  late BuildContext page, sheet;

  Future<void> app(WidgetTester t) async {
    await t.pumpWidget(MaterialApp(
      navigatorObservers: [RootGuard((_) => const Text('restarted'))],
      home: Builder(builder: (c) {
        page = c;
        return const Text('game');
      }),
    ));
  }

  Future<void> openSheet(WidgetTester t) async {
    showModalBottomSheet<void>(context: page, builder: (c) {
      sheet = c;
      return const Text('hex');
    });
    await t.pumpAndSettle();
  }

  testWidgets('a late close while the sheet is closing keeps the game', (t) async {
    await app(t);
    await openSheet(t);
    Navigator.of(sheet).pop();                  // swiped away, its closing animation has started
    await t.pump(const Duration(milliseconds: 20));
    expect(sheet.mounted, isTrue);
    popIfCurrent(sheet);                        // the refresh after the cancel comes back
    await t.pumpAndSettle();
    expect(find.text('game'), findsOneWidget);
    expect(find.text('restarted'), findsNothing);
  });

  testWidgets('the first page is never closed by popIfCurrent', (t) async {
    await app(t);
    popIfCurrent(page);
    await t.pumpAndSettle();
    expect(find.text('game'), findsOneWidget);
  });

  testWidgets('a popup over the first page still closes with the page context', (t) async {
    await app(t);
    await openSheet(t);
    popIfCurrent(page);
    await t.pumpAndSettle();
    expect(find.text('hex'), findsNothing);
    expect(find.text('game'), findsOneWidget);
  });

  testWidgets('if the last page does get closed the app starts over', (t) async {
    await app(t);
    Navigator.of(page).pop();
    await t.pumpAndSettle();
    expect(find.text('restarted'), findsOneWidget);
  });
}
