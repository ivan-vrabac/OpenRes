import 'package:flutter/services.dart';

import '../branding.dart';
import 'game_api.dart';

/// Play Integrity (server: systems/integrity.py): on start, when the server asks for it, the app gets
/// a token from Google Play and hands it in. Nothing here ever stops the game: whatever fails, the
/// player carries on and the next start tries again. Only the Play build has a token to get.
class IntegrityCheck {
  static const _ch = MethodChannel('openres/integrity');

  static Future<void> run(String sid) async {
    if (!Branding.isPlay || Branding.cloudProjectNumber.isEmpty) return;
    try {
      final c = await GameApi.call('/api/v3/integrity/challenge', sid);
      if (!c.ok || c.data['due'] != true) return;
      final nonce = c.data['nonce'] as String;
      final token = await _ch.invokeMethod<String>('token', {'project': Branding.cloudProjectNumber, 'hash': nonce});
      if (token == null) return;
      await GameApi.call('/api/v3/integrity/report', sid, {'token': token, 'nonce': nonce});
    } catch (_) {}
  }
}
