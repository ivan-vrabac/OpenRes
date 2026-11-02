import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openres/widgets/report.dart';

void main() {
  testWidgets('each reason is its own button and sends its key', (t) async {
    final picked = <String>[];
    await t.pumpWidget(MaterialApp(home: Scaffold(body: ReportSheet(onPick: picked.add))));
    await t.tap(find.text('Offensive company name'));
    await t.tap(find.text('Cheating'));
    await t.tap(find.text('Something else'));
    expect(picked, ['insult', 'cheating', 'other']);
  });

  testWidgets('it fits a small phone', (t) async {
    t.view.physicalSize = const Size(640, 900);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: Scaffold(body: Align(alignment: Alignment.bottomCenter,
        child: ReportSheet(onPick: (_) {})))));
    expect(t.takeException(), isNull);
  });
}
