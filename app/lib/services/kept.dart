import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A screen's last answer from the server, kept in memory and on the phone (owner 2026-11-06): opening the
/// screen again, also after the app was closed, shows it at once while the fresh one comes, instead of a
/// spinner. Keys include the company, so another account on the phone never sees someone else's.
class Kept {
  Kept._();
  static final _mem = <String, Map<String, dynamic>>{};

  static String key(String hid, String what) => 'kept|$hid|$what';

  /// What this run of the app already has (no waiting).
  static Map<String, dynamic>? now(String key) => _mem[key];

  /// What the phone kept from an earlier run, or null.
  static Future<Map<String, dynamic>?> fromDisk(String key) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(key);
      if (raw == null) return null;
      return _mem[key] = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static void save(String key, Map<String, dynamic> data) {
    _mem[key] = data;
    SharedPreferences.getInstance().then((p) => p.setString(key, jsonEncode(data))).catchError((_) => false);
  }
}
