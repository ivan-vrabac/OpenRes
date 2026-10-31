import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:openres/services/location_service.dart';

void main() {
  const precise = LocationAccuracyStatus.precise, reduced = LocationAccuracyStatus.reduced;

  test('only precise location opens the map', () {
    expect(locationGate(true, LocationPermission.whileInUse, precise), LocationGate.ok);
    expect(locationGate(true, LocationPermission.always, precise), LocationGate.ok);
  });

  test('approximate location does not', () {
    expect(locationGate(true, LocationPermission.whileInUse, reduced), LocationGate.approximate);
  });

  test('location off comes first, whatever else is set', () {
    expect(locationGate(false, LocationPermission.whileInUse, precise), LocationGate.serviceOff);
  });

  test('no permission', () {
    expect(locationGate(true, LocationPermission.denied, LocationAccuracyStatus.unknown), LocationGate.denied);
    expect(locationGate(true, LocationPermission.deniedForever, LocationAccuracyStatus.unknown), LocationGate.deniedForever);
    expect(locationGate(true, LocationPermission.unableToDetermine, LocationAccuracyStatus.unknown), LocationGate.denied);
  });
}
