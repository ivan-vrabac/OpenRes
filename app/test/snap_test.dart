import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openres/map_kit/snap.dart';

const here = LatLng(45.8, 16.0);

LatLng offset(LatLng p, double north, double east) => LatLng(p.latitude + north / 111320.0,
    p.longitude + east / (111320.0 * math.cos(p.latitude * math.pi / 180)));

double metres(LatLng a, LatLng b) {
  final n = (b.latitude - a.latitude) * 111320.0;
  final e = (b.longitude - a.longitude) * 111320.0 * math.cos(a.latitude * math.pi / 180);
  return math.sqrt(n * n + e * e);
}

void expectClear(LatLng campus, List<LatLng> hexes) {
  for (final cell in campusCells(campus)) {
    for (final h in hexes) {
      expect(metres(cell, h), greaterThanOrEqualTo(hexMinDist(h, cell) - 0.2),
          reason: 'a Campus cell overlaps the hex at $h');
    }
  }
}

void main() {
  test('the 7 cells sit edge to edge around the centre', () {
    final cells = campusCells(here);
    expect(cells, hasLength(7));
    for (final c in cells.skip(1)) {
      expect(metres(here, c), closeTo(25.98, 0.05));
    }
  });

  test('free ground: the Campus goes exactly on the target', () {
    expect(snapCampusPos(here, const []), here);
    expect(snapCampusPos(here, [offset(here, 500, 0)]), here);
  });

  test('a target over a hex moves just far enough for all 7 cells to clear it', () {
    final hexes = [here];
    final at = snapCampusPos(here, hexes);
    expect(at, isNot(here));
    expectClear(at, hexes);
    expect(metres(at, here), lessThan(60));
  });

  test('against a row of hexes the Campus sits beside them and touches', () {
    final hexes = [for (var k = -4; k <= 4; k++) offset(here, 0, k * 22.5)];
    final at = snapCampusPos(offset(here, 10, 0), hexes);
    expectClear(at, hexes);
    expect(metres(at, here), lessThan(90));
  });

  test('a packed honeycomb: it still finds the nearest room outside it', () {
    final hexes = <LatLng>[];
    for (var q = -4; q <= 4; q++) {
      for (var r = -4; r <= 4; r++) {
        hexes.add(offset(here, 25.98 * (r + q / 2), 22.5 * q));
      }
    }
    final at = snapCampusPos(here, hexes);
    expectClear(at, hexes);
  });

  test('hexes as a building: a gap too small for 7 cells is not used', () {
    final ring = [for (var k = 0; k < 6; k++) offset(here, 52 * math.cos(k * math.pi / 3), 52 * math.sin(k * math.pi / 3))];
    final at = snapCampusPos(here, ring);
    expectClear(at, ring);
  });

  test('stays fast enough for every frame, even at its worst', () {
    final hexes = <LatLng>[];
    for (var q = -6; q <= 6; q++) {
      for (var r = -6; r <= 6; r++) {
        hexes.add(offset(here, 25.98 * (r + q / 2), 22.5 * q));
      }
    }
    final sw = Stopwatch()..start();
    snapCampusPos(here, hexes);
    // ignore: avoid_print
    print('worst snap: ${sw.elapsedMilliseconds} ms');
    expect(sw.elapsedMilliseconds, lessThan(100));
  });

  test('a hex keeps snapping as before', () {
    final hexes = [SnapHex(here)];
    final at = snapBuildPos(offset(here, 5, 0), hexes);
    expect(metres(at, here), closeTo(25.98, 0.05));
  });
}
