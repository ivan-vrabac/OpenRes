import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openres/branding.dart';
import 'package:openres/constants.dart';

void main() {
  test('branding defaults are generic', () {
    // Run without --dart-define, so these are the public defaults.
    expect(Branding.appName, 'OpenRes');
    expect(Branding.appTitle, 'OpenRes');
    expect(Branding.appId, 'com.example.openres');
    expect(kBaseUrl, Branding.apiBaseUrl);
    expect(Branding.apiBaseUrl, 'http://10.0.2.2:8000');
  });

  test('a Campus picture exists for every level 1-50', () {
    for (var lvl = 1; lvl <= 50; lvl++) {
      final p = 'assets/game/campus/campus_${lvl.toString().padLeft(2, '0')}.png';
      expect(File(p).existsSync(), isTrue, reason: p);
    }
  });
}
