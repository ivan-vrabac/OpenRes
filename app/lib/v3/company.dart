import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../services/game_api.dart';

/// OpenRes 0.3: the company as the server sees it (/api/v3/state) plus the catalog of names.
/// Screens read it through Provider and call [refresh] after anything that changes it.
class Company extends ChangeNotifier {
  Company(this.sid);

  /// The signed-in company, provided at the app root (main.dart) so pages pushed from any tab can
  /// read it too (owner 2026-10-31: the Luxury screen stayed empty, it could not reach the company).
  static final ValueNotifier<Company?> active = ValueNotifier(null);

  final String sid;
  Map<String, dynamic> state = const {};
  Map<String, dynamic> catalog = const {};
  bool loading = false;
  String? error;

  Future<ApiResult> call(String path, [Map<String, Object?> params = const {}]) => GameApi.call(path, sid, params);

  Future<void> start() async {
    final c = await call('/api/v3/catalog');
    if (c.ok) catalog = c.data;
    await refresh();
  }

  Future<void> refresh() async {
    loading = true;
    final r = await call('/api/v3/state');
    loading = false;
    if (r.ok) {
      state = r.data;
      error = null;
    } else {
      error = r.message;
    }
    notifyListeners();
  }

  // ── shortcuts ──
  num get credits => (state['credits'] as num?) ?? 0;
  Map<String, dynamic>? get campus => state['campus'] as Map<String, dynamic>?;
  int get campusLevel => (campus?['level'] as num?)?.toInt() ?? 0;
  bool get hasCampus => campusLevel > 0;
  double get efficiency => (campus?['efficiency'] as num?)?.toDouble() ?? 1.0;
  Map<String, dynamic> get stock => (state['stock'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic>? get survey => state['survey'] as Map<String, dynamic>?;
  int get surveyMaxRadius => (state['surveyMaxRadius'] as num?)?.toInt() ?? 100;

  String itemName(String key) => (catalog['items']?[key]?['name'] as String?) ?? key;
  String opName(String key) => (catalog['operations']?[key]?['name'] as String?) ?? key;
  String plantName(String key) => (catalog['plants']?[key]?['name'] as String?) ?? key;

  /// What a survey of this radius costs (same formula as the server).
  int surveyTax(double radius) {
    final b = catalog['surveyBase'] as Map? ?? const {'radius': 100, 'tax': 5000, 'exponent': 0.9};
    final area = (radius / (b['radius'] as num)) * (radius / (b['radius'] as num));
    return ((b['tax'] as num) * math.pow(area, (b['exponent'] as num).toDouble()) / 100).round() * 100;
  }
}

/// A place someone asked to see on the map: GameScreen switches to the map tab, MapTab centres on it.
final ValueNotifier<LatLng?> mapFocus = ValueNotifier<LatLng?>(null);
void showOnMap(LatLng p) => mapFocus.value = p;

/// The Campus screen asks the map to pick the Campus's new place.
final ValueNotifier<bool> campusMoveAsked = ValueNotifier<bool>(false);

/// "45 days 3 h", "5 h 12 min", "3 min 20 s" (seconds only near the end).
String fmtDuration(double days) {
  if (days <= 0) return 'expired';
  final totalMin = (days * 24 * 60).floor();
  final d = totalMin ~/ (24 * 60), h = (totalMin % (24 * 60)) ~/ 60, m = totalMin % 60;
  if (d > 0) return h > 0 ? '$d days $h h' : '$d days';
  if (h > 0) return '$h h $m min';
  final s = ((days * 86400) % 60).floor();
  return m > 0 ? '$m min $s s' : '$s s';
}

/// Picture of an item or operation in app/assets/game.
String itemPicture(String item) => 'assets/game/items/$item.png';
String operationPicture(String op) => 'assets/game/operations/$op.png';
String plantPicture(String key) => 'assets/game/plants/$key.png';
/// The picture for a hex: its item, or for solar/wind farms the operation.
String itemPictureOrEnergy(String op, String item) => item == 'electricity' ? operationPicture(op) : itemPicture(item);
/// The Campus seen from above: exactly its 7-hex compound (75 m x 77.9 m), for the map.
String campusPicture(int level) => 'assets/game/campus/campus_${level.clamp(1, 50).toString().padLeft(2, '0')}.png';
