import 'dart:async';

import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openres/map_kit/map_world.dart';
import 'package:openres/services/game_api.dart';

LatLngBounds at(double lat, double lng, [double size = 0.01]) =>
    LatLngBounds(LatLng(lat - size, lng - size), LatLng(lat + size, lng + size));

Map<String, dynamic> hex(int id, double lat, double lng) =>
    {'id': id, 'lat': lat, 'lng': lng, 'op': 'logging_camp', 'item': 'wood', 'own': true};
Map<String, dynamic> campus(double lat, double lng, {int level = 3}) =>
    {'lat': lat, 'lng': lng, 'level': level, 'name': 'Co', 'own': false};

/// A fake server: holds the world, answers what is inside the box, can fail or hold answers back.
class Server {
  final hexes = <Map<String, dynamic>>[];
  final campuses = <Map<String, dynamic>>[];
  final moving = <Map<String, dynamic>>[];
  final calls = <Map<String, Object?>>[];
  bool down = false;
  bool cut = false;
  Completer<void>? gate;

  bool _in(Map<String, dynamic> m, Map<String, Object?> a) =>
      (m['lat'] as num) >= (a['south'] as num) && (m['lat'] as num) <= (a['north'] as num) &&
      (m['lng'] as num) >= (a['west'] as num) && (m['lng'] as num) <= (a['east'] as num);

  Future<ApiResult> call(String path, Map<String, Object?> a) async {
    if (path != '/api/v3/map') return const ApiResult({'campuses': []});
    calls.add(a);
    final g = gate;
    if (g != null) await g.future;
    if (down) return const ApiResult({}, code: 'net', message: 'no network');
    final inside = hexes.where((h) => _in(h, a)).toList();
    return ApiResult({
      'campuses': campuses.where((c) => _in(c, a)).toList(),
      'moves': moving.where((m) => _in(m, a)).toList(),
      'more': cut,
      if (a['detail'] == 1) 'hexes': inside
      else 'dots': [for (final h in inside) ...[h['lat'], h['lng']]],
    });
  }
}

void main() {
  late Server srv;
  late MapWorld w;
  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() {
    srv = Server();
    w = MapWorld(srv.call, (h) => 'pic/${h['item']}');
  });

  test('a Campus just outside the loaded area is fetched, however close it is', () async {
    srv.campuses.add(campus(45.05, 16));
    w.want(at(45, 16), 15);
    await settle();
    expect(w.campuses, isEmpty);
    w.want(at(45.05, 16), 15);               // 5 km away: the old tolerance skipped this request
    await settle();
    expect(w.campuses, hasLength(1));
  });

  test('an answer for an old view is kept when the map has moved on', () async {
    srv.hexes.add(hex(1, 45, 16));
    srv.hexes.add(hex(2, 46, 16));
    srv.gate = Completer();
    w.want(at(45, 16), 15);
    await settle();
    w.want(at(46, 16), 15);                  // moved while the first answer is on its way
    final g = srv.gate!;
    srv.gate = null;
    g.complete();
    await settle();
    expect(w.hexes.map((h) => h['id']), containsAll([1, 2]));
  });

  test('a failed request keeps what is known and the next want heals it', () async {
    srv.hexes.add(hex(1, 45, 16));
    w.want(at(45, 16), 15);
    await settle();
    expect(w.hexes, hasLength(1));
    srv.down = true;
    w.refresh();
    await settle();
    expect(w.hexes, hasLength(1));
    srv.down = false;
    srv.hexes.add(hex(2, 45.001, 16));
    w.want(at(45, 16), 15);                  // only the timer calls this: same view, nothing moved
    await settle();
    expect(w.hexes, hasLength(2));
  });

  test('moving inside the margin needs no request', () async {
    w.want(at(45, 16), 15);
    await settle();
    final n = srv.calls.length;
    w.want(at(45.01, 16.01), 15);
    await settle();
    expect(srv.calls.length, n);
  });

  test('hexes gone from the server go from the map, those elsewhere stay', () async {
    srv.hexes.addAll([hex(1, 45, 16), hex(2, 45.001, 16), hex(3, 46, 16)]);
    w.want(at(46, 16), 15);
    await settle();
    w.want(at(45, 16), 15);
    await settle();
    srv.hexes.removeWhere((h) => h['id'] == 2);
    w.refresh();
    await settle();
    expect(w.hexes.map((h) => h['id']), unorderedEquals([1, 3]));
  });

  test('a refresh during a request fetches again afterwards', () async {
    srv.gate = Completer();
    w.want(at(45, 16), 15);
    await settle();
    w.refresh();
    srv.hexes.add(hex(1, 45, 16));           // built after the first request was answered
    final g = srv.gate!;
    srv.gate = null;
    g.complete();
    await settle();
    expect(srv.calls.length, 2);
    expect(w.hexes, hasLength(1));
  });

  test('zooming from clouds to hexes loads the hexes although the area is covered', () async {
    srv.hexes.add(hex(1, 45, 16));
    w.want(at(45, 16, 0.2), 10);
    await settle();
    expect(w.hexes, isEmpty);
    expect(w.smoke!.length, 1);
    w.want(at(45, 16), 15);
    await settle();
    expect(w.hexes, hasLength(1));
    expect(w.smoke!.length, 1);
  });

  test('a Campus is part of the clouds like any hex', () async {
    srv.hexes.addAll([hex(1, 45, 16), {...hex(2, 45.001, 16), 'op': 'campus'}]);
    w.want(at(45, 16), 15);
    await settle();
    expect(w.smoke!.length, 2);
  });

  test('a cut-off answer is fetched again closer in, a complete one is not', () async {
    srv.cut = true;
    w.want(at(45, 16, 1), 7);
    await settle();
    final n = srv.calls.length;
    w.want(at(45, 16, 0.5), 7.5);
    await settle();
    expect(srv.calls.length, n);
    w.want(at(45, 16, 0.25), 8.5);
    await settle();
    expect(srv.calls.length, greaterThan(n));
  });

  test('the world view does not loop: bounds beyond the map still count as covered', () async {
    final view = LatLngBounds(const LatLng(-89, -179.9), const LatLng(89, 179.9));
    w.want(view, 3);
    await settle();
    w.want(view, 3);
    await settle();
    expect(srv.calls.length, 1);
  });

  test('the detail request stays within what the server accepts', () async {
    w.want(at(45, 16, 0.05), 14.6);
    await settle();
    final a = srv.calls.single;
    final area = ((a['north'] as num) - (a['south'] as num)) * ((a['east'] as num) - (a['west'] as num));
    expect(area, lessThanOrEqualTo(0.05));
  });

  test('the scene: one list per picture, marks only where needed', () async {
    srv.hexes.addAll([
      hex(1, 45, 16), hex(2, 45, 16),
      {...hex(3, 45.001, 16), 'leaseDays': 4.2},
      hex(4, 45.002, 16),
      {'id': 5, 'lat': 45.003, 'lng': 16.0, 'op': 'campus', 'item': '', 'own': true},
    ]);
    w.want(at(45, 16), 15);
    await settle();
    expect(w.scene.tiles.keys, ['pic/wood']);
    expect(w.scene.tiles['pic/wood']!.length, 4 * 3);    // the Campus cell is not a hex tile
    expect(w.scene.marks.map((m) => m.stack), unorderedEquals([2, 1]));
    expect(w.scene.marks.firstWhere((m) => m.stack == 1).leaseDays, 4.2);
  });

  test('a Campus being moved is a construction site in the scene', () async {
    srv.moving.add({'lat': 45.001, 'lng': 16.0, 'name': 'Co', 'own': false});
    w.want(at(45, 16), 15);
    await settle();
    expect(w.scene.sites, hasLength(1));
    srv.moving.clear();
    w.refresh();
    await settle();
    expect(w.scene.sites, isEmpty);
  });

  test('metres on the map: 1 m is the same length as the tile maths gives', () {
    expect(worldPerMetre(0), closeTo(256 / 40075017, 1e-9));
    expect(worldPerMetre(60), closeTo(2 * 256 / 40075017, 2e-8));
  });
}
