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
    nonRotatedSize: const Size(400.0, 800.0),
  );
  Map<String, dynamic> campus(String name, double lat, double lng) =>
      {'name': name, 'lat': lat, 'lng': lng, 'level': 3, 'own': false};

  test('a tap on a pin finds its Campus, the nearest of several', () {
    final a = campus('A', 45, 16), b = campus('B', 45, 18);
    final at = cam.latLngToScreenOffset(const LatLng(45, 18));
    expect(campusPinAt([a, b], cam, Offset(at.dx, at.dy - 8)), b);
  });

  test('a pin just across the date line is found on the nearest copy of the world', () {
    final seam = MapCamera(crs: const Epsg3857(), center: const LatLng(0, 179), zoom: 5, rotation: 0,
        nonRotatedSize: const Size(400.0, 800.0));
    final fiji = campus('F', 0, -179);
    final px = 256 * 32 * 2 / 360;                    // 2 degrees at zoom 5
    expect(campusPinAt([fiji], seam, Offset(200 + px, 400 - 8)), fiji);
  });

  test('a tap away from every pin finds nothing', () {
    expect(campusPinAt([campus('A', 45, 16)], cam, const Offset(10, 10)), isNull);
  });
}
