import 'package:flutter/services.dart';

import '../branding.dart';
import 'game_api.dart';

/// Play Games sign-in: without a tap for a player who is signed in to Play Games. It ends in the same
/// Google ID token as the Sign in with Google button, so the company is the same either way.
class PlayGames {
  static const _ch = MethodChannel('openres/playgames');

  static bool get enabled => Branding.playGamesClientId.isNotEmpty;

  /// A Google ID token, or null: not signed in to Play Games, or anything failed (the player still
  /// has the Google button).
  static Future<String?> idToken() async {
    if (!enabled) return null;
    try {
      final code = await _ch.invokeMethod<String>('code', {'client': Branding.playGamesClientId});
      if (code == null || code.isEmpty) return null;
      final r = await GameApi.call('/api/v1/auth/play_games', '', {'code': code, 'client_id': Branding.playGamesClientId});
      return r.ok ? r.data['id_token'] as String? : null;
    } catch (_) {
      return null;
    }
  }
}
