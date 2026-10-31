import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openres/widgets/slide_confirm.dart';

void main() {
  late bool busy;
  late int confirmed;
  late StateSetter update;

  Widget app() => MaterialApp(home: Scaffold(body: Center(child: SizedBox(width: 300, child: StatefulBuilder(
        builder: (_, set) {
          update = set;
          return SlideToConfirm(label: 'Survey here', icon: Icons.satellite_alt, busy: busy,
              onConfirm: () => set(() { confirmed++; busy = true; }));
        },
      )))));

  double turns(WidgetTester t) => t.widget<RotationTransition>(find.ancestor(
      of: find.byIcon(Icons.satellite_alt), matching: find.byType(RotationTransition)).first).turns.value;
  double iconX(WidgetTester t) => t.getCenter(find.byIcon(Icons.satellite_alt)).dx;

  setUp(() { busy = false; confirmed = 0; });

  testWidgets('the knob waits at the end while busy, the icon turns, then it goes back', (t) async {
    await t.pumpWidget(app());
    final start = iconX(t);
    await t.drag(find.byIcon(Icons.satellite_alt), const Offset(300, 0));
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(confirmed, 1);
    expect(iconX(t), greaterThan(start + 150));              // still at the end
    expect(turns(t), greaterThan(0));
    await t.pump(const Duration(seconds: 5));
    expect(iconX(t), greaterThan(start + 150));              // however long it takes
    update(() => busy = false);
    await t.pumpAndSettle();
    expect(iconX(t), closeTo(start, 1));
    expect(turns(t), 0);
  });

  testWidgets('a slide that does not reach the end goes back and does nothing', (t) async {
    await t.pumpWidget(app());
    final start = iconX(t);
    await t.drag(find.byIcon(Icons.satellite_alt), const Offset(80, 0));
    await t.pumpAndSettle();
    expect(confirmed, 0);
    expect(iconX(t), closeTo(start, 1));
  });

  testWidgets('an action that is not busy goes back straight away', (t) async {
    await t.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: SizedBox(width: 300, child: SlideToConfirm(
        label: 'Go', icon: Icons.upgrade, onConfirm: () => confirmed++))))));
    final start = t.getCenter(find.byIcon(Icons.upgrade)).dx;
    await t.drag(find.byIcon(Icons.upgrade), const Offset(300, 0));
    await t.pumpAndSettle();
    expect(confirmed, 1);
    expect(t.getCenter(find.byIcon(Icons.upgrade)).dx, closeTo(start, 1));
  });
}
