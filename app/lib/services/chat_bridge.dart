import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../constants.dart';
import 'game_api.dart';

/// The Android side of notifications (ChatBridge.kt): the 15-minute check of the game's inbox.
/// Everything is a no-op off Android.
class ChatBridge {
  static const _ch = MethodChannel('openres/chat');
  static bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<T?> _call<T>(String m, [Map<String, Object?>? args]) async {
    if (!_android) return null;
    try {
      return await _ch.invokeMethod<T>(m, args);
    } catch (_) {
      return null;
    }
  }

  /// Signed in: the worker fetches this player's notifications from now on.
  static Future<void> configure(String sid) async {
    if (sid.isEmpty) return;
    await _call('configure', {'base': kBaseUrl, 'sid': sid});
  }

  static Future<void> logout() => _call('logout');

  /// The notification the player tapped to open the app ('chat', 'dm:<pid>', ...), once.
  static Future<String?> takeOpen() => _call<String>('takeOpen');

  /// The device, hashed (multi-account detection; the raw ID never leaves the phone).
  static Future<void> reportDevice(String sid) async {
    final id = await _call<String>('deviceId');
    if (id == null || id.isEmpty || sid.isEmpty) return;
    final hashed = sha256.convert(utf8.encode('openres-device:$id')).toString();
    await GameApi.call('/api/v1/device', sid, {'device': hashed});
  }
}
