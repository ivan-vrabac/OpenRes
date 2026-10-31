import 'package:flutter/foundation.dart';
import 'player.dart';
import '../services/api_service.dart';
import '../services/chat_bridge.dart';
import '../services/google_auth.dart';
import '../services/storage_service.dart';

class PlayerProvider extends ChangeNotifier {
  Player? _player;
  String? _sid;
  Player? get player => _player;
  String get sid => _sid ?? '';

  int? _creditsNow;   // balance right after a known spend, until the next full refresh arrives

  /// Credits to show (updated instantly after spending, then replaced by the server's value).
  int get credits => _creditsNow ?? _player?.credits ?? 0;

  /// Show a spend (or a gain, negative) immediately; the next refresh brings the exact balance.
  void adjustCredits(int spent) {
    if (_player == null) return;
    _creditsNow = credits - spent;
    notifyListeners();
  }

  /// The balance the server just reported.
  void setCredits(int value) {
    if (_player == null || credits == value) return;
    _creditsNow = value;
    notifyListeners();
  }

  void setPlayer(Player p, {String? sid}) {
    _player = p;
    _creditsNow = null;
    if (sid != null) _sid = sid;
    notifyListeners();
  }

  Future<void> refresh() async {
    final sid = _sid ?? await StorageService.getSid();
    if (sid == null) return;
    final p = await ApiService.getPlayerData(sid);
    if (p != null) {
      setPlayer(p, sid: sid);
      // keep the Hexes list current
      if (_mines != null) await loadMines();
    }
  }

  // ── Full mine list (Mines tab) — loaded on demand, not with every player refresh ──

  List<Hex>? _mines;
  bool _minesLoading = false;

  /// The company's hexes, or null until [loadMines] has completed once.
  List<Hex>? get mines => _mines;
  bool get minesLoading => _minesLoading;

  Future<void> loadMines() async {
    if (_minesLoading || sid.isEmpty) return;
    _minesLoading = true;
    notifyListeners();
    final list = await ApiService.getMineList(sid);
    _minesLoading = false;
    if (list != null) _mines = list;
    notifyListeners();
  }

  void clear() {
    ChatBridge.logout();          // no more notifications for this account on this phone
    GoogleAuth.signOut();         // the next sign-in shows Google's account picker again
    StorageService.saveSignedOut(true);    // and Play Games doesn't sign straight back in
    _player = null;
    _sid = null;
    _mines = null;
    notifyListeners();
  }
}
