import 'package:flutter_test/flutter_test.dart';
import 'package:openres/constants.dart';
import 'package:openres/widgets/async_view.dart' show fmtCredits, fmtQty;

/// Scores and countries far past anything played (owner 2026-11-03): always a short number, never the
/// full digits, an exponent or a crash.
void main() {
  test('short numbers have two decimals and a suffix up to decillions', () {
    expect(fmtNum(999), '999');
    expect(fmtNum(1234), '1.23K');
    expect(fmtNum(5.678e9), '5.68B');
    expect(fmtNum(1.2e15), '1.2Q');
    expect(fmtNum(9.3e18), '9.3Qi');           // past the 64-bit integer range
    expect(fmtNum(4.5e22), '45Sx');
    expect(fmtNum(7e33), '7Dc');
    expect(fmtNum(2e50), contains('e'));         // absurd: still short
  });

  test('negative numbers keep their suffix', () {
    expect(fmtNum(-5e9), '-5B');
    expect(fmtNum(-42), '-42');
    expect(fmtCredits(-2.5e6), 'ꞓ-2.5M');
  });

  test('credits and quantities', () {
    expect(fmtCredits(9999), 'ꞓ9999');
    expect(fmtCredits(12345), 'ꞓ12.3k');
    expect(fmtCredits(3.2e12), 'ꞓ3.2T');
    expect(fmtCredits(1.5e19), 'ꞓ15Qi');
    expect(fmtQty(2.5), '2.5');
    expect(fmtQty(8e18), '8Qi');
  });

  test('the activity log shows exact amounts', () {
    expect(fmtFull(1234567), '1,234,567');
    expect(fmtFull(-9876543.5), '-9,876,543.50');
    expect(fmtFull(999), '999');
    expect(fmtFull(5e18), '5,000,000,000,000,000,000');
    expect(fmtFull(3e22), '30Sx');            // beyond exact digits: the short form
  });

  test('not a number or infinite: no crash', () {
    expect(fmtNum(double.infinity), '∞');
    expect(fmtNum(double.nan), '-');
    expect(fmtCredits(double.negativeInfinity), 'ꞓ-∞');
  });

  test('Tantalum-180m in mg, g, kg and t', () {
    expect(fmtMass(5), '5 mg');
    expect(fmtMass(2.5), '2.5 mg');
    expect(fmtMass(1500), '1.5 g');
    expect(fmtMass(10013084), '10.01 kg');
    expect(fmtMass(2e9), '2 t');
  });
}
