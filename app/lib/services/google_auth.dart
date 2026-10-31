import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../branding.dart';
import 'game_api.dart';

/// Sign in with Google (owner 2026-10-25: the only way to sign in). Google gives the app an ID
/// token for our server (Branding.googleClientId = the OAuth Web client ID); the server checks it.
class GoogleAuth {
  static bool get enabled => Branding.googleClientId.isNotEmpty;

  static final _google = GoogleSignIn(scopes: const ['email'], serverClientId: Branding.googleClientId);

  /// Google's account picker; null when the player cancels.
  static Future<String?> idToken({bool pick = false}) async {
    if (pick) await _google.signOut();
    final acc = await _google.signIn();
    if (acc == null) return null;
    return (await acc.authentication).idToken;
  }

  /// The server's answer: {sid, hID, created, name}, or the code need_name for a new Google account.
  static Future<ApiResult> signIn(String token, {String? name, String? linkName, String? linkPassword}) =>
      GameApi.call('/api/v1/auth/google', '', {
        'id_token': token,
        if (name != null) 'name': name,
        if (linkName != null) 'link_name': linkName,
        if (linkPassword != null) 'link_password': linkPassword,
      });

  /// A failed sign-in for the player, with Google's error code (owner 2026-10-25: "oauth not
  /// working" gave no clue). 10 = this app's package + signing key aren't registered with Google.
  static String errorText(Object e) {
    final code = e is PlatformException
        ? RegExp(r'ApiException: (\d+)').firstMatch('${e.message} ${e.details}')?.group(1) ?? e.code
        : e.runtimeType.toString();
    if (code == '10') return 'Google sign-in is not set up for this version of the app yet (error 10).';
    if (code == '7' || code == 'network_error') return 'No connection to Google. Check your internet and try again.';
    return 'Google sign-in failed ($code). Please try again.';
  }

  static Future<void> signOut() async {
    if (!enabled) return;
    try {
      await _google.signOut();
    } catch (_) {}
  }
}
