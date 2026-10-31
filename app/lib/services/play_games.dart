import 'dart:async';

import 'package:flutter/services.dart';

import '../branding.dart';
import 'game_api.dart';

/// Play Games sign-in: without a tap for a player who is signed in to Play Games. It ends in the same
/// Google ID token as the Sign in with Google button, so the company is the same either way.
class PlayGames {
  static const _ch = MethodChannel('openres/playgames');

  static bool get enabled => Branding.playGamesClientId.isNotEmpty;

  static Timer? _timer;
  static var _sent = const <String>{};

  /// While the game is open: the server records stars only when asked, so a balance reached and spent
  /// again still counts, and what is earned goes on to Play Games.
  static void start(String sid) {
    stop();
    _sync(sid);
    _timer = Timer.periodic(const Duration(minutes: 10), (_) => _sync(sid));
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
    _sent = const {};
  }

  static Future<void> _sync(String sid) async {
    try {
      final r = await GameApi.call('/api/v1/achievements', sid, {});
      final earned = ((r.ok ? r.data['earned'] : null) as List?)?.cast<String>().toSet() ?? const <String>{};
      if (!enabled || earned.isEmpty || earned.difference(_sent).isEmpty) return;
      await _ch.invokeMethod<int>('unlock', {'names': earned.toList()});
      _sent = earned;
    } catch (_) {}                     // Play Games is a bonus: the game's own stars are already saved
  }

  /// A Google ID token, or null: not signed in to Play Games, or anything failed (the player still
  /// has the Google button). [ask]: the player tapped the button, so Play Games may show its sign-in.
  static Future<String?> idToken({bool ask = false}) async {
    if (!enabled) return null;
    try {
      final code = await _ch.invokeMethod<String>('code', {'client': Branding.playGamesClientId, 'ask': ask});
      if (code == null || code.isEmpty) return null;
      final r = await GameApi.call('/api/v1/auth/play_games', '', {'code': code, 'client_id': Branding.playGamesClientId});
      return r.ok ? r.data['id_token'] as String? : null;
    } catch (_) {
      return null;
    }
  }
}
