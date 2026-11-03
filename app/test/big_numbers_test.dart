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
    expect(fmtNum(1.2e15), '1.20Q');
    expect(fmtNum(9.3e18), '9.30Qi');           // past the 64-bit integer range
    expect(fmtNum(4.5e22), '45.00Sx');
    expect(fmtNum(7e33), '7.00Dc');
    expect(fmtNum(2e50), contains('e'));         // absurd: still short
  });

  test('negative numbers keep their suffix', () {
    expect(fmtNum(-5e9), '-5.00B');
    expect(fmtNum(-42), '-42');
    expect(fmtCredits(-2.5e6), 'ꞓ-2.50M');
  });

  test('credits and quantities', () {
    expect(fmtCredits(9999), 'ꞓ9999');
    expect(fmtCredits(12345), 'ꞓ12.3k');
    expect(fmtCredits(3.2e12), 'ꞓ3.20T');
    expect(fmtCredits(1.5e19), 'ꞓ15.00Qi');
    expect(fmtQty(2.5), '2.50');
    expect(fmtQty(8e18), '8.00Qi');
  });

  test('the activity log shows exact amounts', () {
    expect(fmtFull(1234567), '1,234,567');
    expect(fmtFull(-9876543.5), '-9,876,543.50');
    expect(fmtFull(999), '999');
    expect(fmtFull(5e18), '5,000,000,000,000,000,000');
    expect(fmtFull(3e22), '30.00Sx');            // beyond exact digits: the short form
  });

  test('not a number or infinite: no crash', () {
    expect(fmtNum(double.infinity), '∞');
    expect(fmtNum(double.nan), '-');
    expect(fmtCredits(double.negativeInfinity), 'ꞓ-∞');
  });
}
