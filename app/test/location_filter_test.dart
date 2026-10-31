import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openres/services/location_service.dart';

const _d = Distance();
LatLng _at(LatLng o, double east, double north) => LatLng(
    o.latitude + north / LocationService.mPerDegLat,
    o.longitude + east / (LocationService.mPerDegLat * cos(o.latitude * pi / 180)));

void main() {
  const o = LatLng(45.8, 15.97);
  final t0 = DateTime(2026, 10, 24, 20);
  final s = LocationService.instance;

  double run(double speed, double acc, {bool? moving, int outlierAt = -1}) {
    final rnd = Random(7);
    var worst = 0.0;
    for (var i = 0; i < 120; i++) {
      final truth = _at(o, speed * i, 0);                            // heading east
      final g = rnd.nextDouble() * 2 - 1, h = rnd.nextDouble() * 2 - 1;
      var meas = _at(truth, g * acc, h * acc);
      if (i == outlierAt) meas = _at(truth, 800, 800);               // a bad Wi-Fi/cell jump
      s.addForTest(meas.latitude, meas.longitude, acc, speed > 0 ? speed : 0.0, speed > 0 ? 90.0 : null,
          t0.add(Duration(seconds: 1000 * (speed + acc).round() + i)), movingNow: moving);
      if (i > 20) worst = max(worst, _d.as(LengthUnit.Meter, s.fix.value!.pos, truth));
    }
    return worst;
  }

  test('standing still with weak GPS: the position barely moves', () {
    expect(run(0, 40, moving: false), lessThan(12));
  });
  test('walking with ordinary GPS: follows closely', () {
    expect(run(1.4, 8, moving: true), lessThan(8));
  });
  test('driving: no lag', () {
    expect(run(15, 10, moving: true), lessThan(12));
  });
  test('bus with weak GPS (30-150 m, speed sometimes missing): never stuck behind', () {
    final rnd = Random(3);
    var worst = 0.0;
    for (var i = 0; i < 300; i++) {
      final truth = _at(o, 12.0 * i, 3.0 * i);
      final acc = 30 + rnd.nextDouble() * 120;
      final meas = _at(truth, (rnd.nextDouble() * 2 - 1) * acc * .7, (rnd.nextDouble() * 2 - 1) * acc * .7);
      final hasSpeed = rnd.nextDouble() < .6;
      s.addForTest(meas.latitude, meas.longitude, acc, hasSpeed ? 12.4 : null, hasSpeed ? 76.0 : null,
          t0.add(Duration(hours: 1, seconds: i)), movingNow: true);
      if (i > 20) worst = max(worst, _d.as(LengthUnit.Meter, s.fix.value!.pos, truth));
    }
    expect(worst, lessThan(120));
  });
  test('phone lying still in a smooth train: follows the train', () {
    expect(run(20, 10, moving: false), lessThan(15));
  });
  test('a single 1 km jump is ignored', () {
    expect(run(1.4, 8, moving: true, outlierAt: 60), lessThan(8));
  });
}
