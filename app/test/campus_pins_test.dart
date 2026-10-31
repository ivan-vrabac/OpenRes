import 'dart:math' show Point;

import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openres/map_kit/campus_pins.dart';

void main() {
  final cam = MapCamera(
    crs: const Epsg3857(),
    center: const LatLng(45, 16),
    zoom: 5,
    rotation: 0,
    nonRotatedSize: const Point(400.0, 800.0),
  );
  Map<String, dynamic> campus(String name, double lat, double lng) =>
      {'name': name, 'lat': lat, 'lng': lng, 'level': 3, 'own': false};

  test('a tap on a pin finds its Campus, the nearest of several', () {
    final a = campus('A', 45, 16), b = campus('B', 45, 18);
    final at = cam.latLngToScreenPoint(const LatLng(45, 18));
    expect(campusPinAt([a, b], cam, Offset(at.x, at.y - 8)), b);
  });

  test('a tap away from every pin finds nothing', () {
    expect(campusPinAt([campus('A', 45, 16)], cam, const Offset(10, 10)), isNull);
  });
}
