import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../constants.dart';
import '../models/player.dart';

class SignInResult {
  final String? hid;
  final String? sid;
  final bool created;
  final bool deletionCancelled;   // signing in cancelled a scheduled account deletion
  final String? error;
  const SignInResult({this.hid, this.sid, this.created = false, this.deletionCancelled = false, this.error});
}

class ApiService {
  /// Signs in, or creates the account if the company name is free.
  /// Returns the server-signed session; on failure [SignInResult.error] is set.
  /// [register]: true = create a new account (fails if the name is taken),
  /// false = log in to an existing one.
  static Future<SignInResult> signIn(String companyName, String password,
      {bool register = false}) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/api/v1/auth/session'), body: {
        'name': companyName, 'password': password, 'mode': register ? 'register' : 'login',
      }).timeout(const Duration(seconds: 15));
      final m = jsonDecode(r.body) as Map<String, dynamic>;
      final sid = m['sid'] as String?;
      final hid = m['hID'] as String?;
      if (sid != null && hid != null) {
        return SignInResult(hid: hid, sid: sid, created: m['created'] == true,
          deletionCancelled: m['deletionCancelled'] == true);
      }
      return SignInResult(error: m['message'] as String? ?? 'Sign-in failed');
    } catch (_) {
      return const SignInResult(error: 'Could not reach the server. Check your connection.');
    }
  }

  /// Returns null on success, otherwise a message for the user.
  /// Who is signed in (/api/v3/me; it also counts the day as played).
  static Future<Player?> getPlayerData(String sid) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/api/v3/me'),
          body: {'sid': sid}).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      final m = _zlibJson(r.bodyBytes);
      if (m == null || m['err'] != 0) return null;
      return Player.fromJson(m);
    } catch (_) { return null; }
  }

  // ── Mines ────────────────────────────────────────────────────────────────

  /// All of the player's mines (Mines tab).
  static Future<List<Hex>?> getMineList(String sid) async {
    try {
      // the company's hexes with their leases (0.2.3)
      final r = await http.post(Uri.parse('$kBaseUrl/api/v3/hex/list'),
          body: {'sid': sid, 'sort': 'value', 'limit': '10000'}).timeout(const Duration(seconds: 30));
      final m = _zlibJson(r.bodyBytes);
      if (m == null || m['err'] != 0) return null;
      return [for (final j in m['hexes'] as List) Hex.fromJson(j as Map<String, dynamic>)];
    } catch (_) { return null; }
  }

  /// The player's own mines within [radiusM] metres of a point (map taps, HQ placement).
  // ── Log ────────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>?> getLog(String sid, {int offset = 0, String type = ''}) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/api/game/log'),
          body: {'sid': sid, 'offset': offset.toString(), 'type': type})
          .timeout(const Duration(seconds: 10));
      final decoded = ZLibDecoder().convert(r.bodyBytes);
      return jsonDecode(utf8.decode(decoded)) as Map<String, dynamic>;
    } catch (_) { return null; }
  }

  // ── Geolocation ──────────────────────────────────────────────────────────

  /// Last known country (memory, then this device), so the flag shows at once; the IP lookup
  /// runs at most once a day (owner 2026-10-23: the More flag loaded slowly every time).
  static String? countryNow;

  static Future<String?> getCountryCode() async {
    final prefs = await SharedPreferences.getInstance();
    countryNow ??= prefs.getString('country_code');
    final last = prefs.getInt('country_checked') ?? 0;
    if (countryNow != null && DateTime.now().millisecondsSinceEpoch - last < 86400000) return countryNow;
    final fresh = await _lookupCountryCode();
    if (fresh != null) {
      countryNow = fresh;
      await prefs.setString('country_code', fresh);
      await prefs.setInt('country_checked', DateTime.now().millisecondsSinceEpoch);
    }
    return countryNow;
  }

  static Future<String?> _lookupCountryCode() async {
    try {
      final r = await http.get(Uri.parse('http://ip-api.com/json?fields=status,countryCode'))
          .timeout(const Duration(seconds: 5));
      final data = jsonDecode(r.body) as Map<String, dynamic>;
      if (data['status'] == 'success') {
        return (data['countryCode'] as String).toLowerCase();
      }
    } catch (_) {}
    return null;
  }

  static Future<void> setCountryCode(String sid, String code) async {
    try {
      await http.post(Uri.parse('$kBaseUrl/api/game/player/country'),
          body: {'sid': sid, 'code': code}).timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  static Future<void> registerFcmToken(String sid, String token) async {
    try {
      await http.post(Uri.parse('$kBaseUrl/api/game/push/register'),
          body: {'sid': sid, 'token': token, 'platform': 'android'})
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  static Map<String, dynamic>? _zlibJson(List<int> bytes) {
    try {
      final decoded = ZLibDecoder().convert(bytes);
      return jsonDecode(utf8.decode(decoded)) as Map<String, dynamic>;
    } catch (_) { return null; }
  }
}
