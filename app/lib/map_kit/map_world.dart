import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'package:latlong2/latlong.dart';

import '../services/game_api.dart';
import 'smoke.dart';

/// Below this zoom the hexes are clouds.
const double kHexZoom = 14.5;

/// The server's cloud square sizes in degrees (company.CLOUD_SIZES), smallest first.
const kCloudSizes = [0.002, 0.01, 0.05, 0.25, 1.0, 5.0];

/// Which cloud squares fit [zoom]: the biggest that is not wider than one puff, so puffs still overlap
/// into one soft cloud and there are never more than a few thousand on the screen.
int cloudLevel(double zoom) {
  final puffDeg = SmokePainter.radiusFor(zoom) * 360 / (256 * math.pow(2, zoom));
  var level = 0;
  for (var i = 0; i < kCloudSizes.length; i++) {
    if (kCloudSizes[i] <= puffDeg) level = i;
  }
  return level;
}

/// What is drawn on the map, known in one place (owner 2026-10-31: Campuses and hexes kept vanishing
/// until a refresh). Hexes, Campuses and clouds come from one request for the view plus a margin, so
/// moving a little needs no request. An answer is merged into what is known and never wipes the
/// rest; a failed request changes nothing and [want] simply asks again, so the map heals by itself.
class MapWorld extends ChangeNotifier {
  MapWorld(this._fetch, this._picture);

  final Future<ApiResult> Function(String path, Map<String, Object?> args) _fetch;
  final String Function(Map<String, dynamic> hex) _picture;

  static const _freshFor = Duration(seconds: 30);
  static const _topFreshFor = Duration(minutes: 5);
  static const _maxDetailArea = 0.045;       // square degrees; the server refuses more than 0.05
  static const _maxKept = 8000;

  /// Every known hex and Campus cell, as the server sent them plus `type` and `isMine`.
  List<Map<String, dynamic>> hexes = [];
  List<Map<String, dynamic>> campuses = [];
  List<Map<String, dynamic>> moves = [];         // new places of Campuses being moved: construction sites
  List<Map<String, dynamic>> topCampuses = [];   // the biggest Campus of every country
  SmokeData? smoke;
  MapScene scene = const MapScene();

  LatLngBounds? _box;        // what the last answer covered
  LatLngBounds? _acrossBox;  // and its part beyond the date line
  bool _boxDetail = false;
  double _boxZoom = 0;
  bool _boxCut = false;      // the answer hit a server limit
  DateTime? _boxAt;
  // owner 2026-11-06: asking again for the same area sends what the server called it ("sig"); with
  // nothing changed there the answer is {"same": 1} and nothing is read or rebuilt. A full answer at
  // least every [_fullEvery] anyway (names, the lease days).
  String? _sig, _acrossSig;
  int _boxCloud = -1;        // the cloud squares of the last far answer
  DateTime? _fullAt;
  static const _fullEvery = Duration(minutes: 5);

  LatLngBounds? _view;
  LatLngBounds? _across;     // the view's part beyond the date line, on the other end of the longitudes
  double _zoom = 0;
  Duration _maxAge = _freshFor;
  bool _dirty = false;       // something changed: fetch even if the view is covered
  bool _busy = false;
  bool _gone = false;
  DateTime? _topAt;

  @override
  void dispose() {
    _gone = true;
    super.dispose();
  }

  static LatLngBounds _clamped(LatLngBounds b) => LatLngBounds(
        LatLng(b.south.clamp(-85.0, 85.0), b.west.clamp(-180.0, 180.0)),
        LatLng(b.north.clamp(-85.0, 85.0), b.east.clamp(-180.0, 180.0)),
      );

  static bool _inside(LatLngBounds inner, LatLngBounds outer) =>
      inner.south >= outer.south && inner.north <= outer.north &&
      inner.west >= outer.west && inner.east <= outer.east;

  /// The view plus one view on every side, less when the server would call it too big, and half that when
  /// the last answer was cut off ([crowded]: a built-up place, where a smaller area is filled sooner).
  static LatLngBounds _withMargin(LatLngBounds view, bool detail, {bool crowded = false}) {
    final h = view.north - view.south, w = view.east - view.west;
    var m = crowded ? 0.5 : 1.0;
    if (detail) {
      final area = h * w;
      while (m > 0 && area * (1 + 2 * m) * (1 + 2 * m) > _maxDetailArea) m -= 0.25;
      if (m < 0) m = 0;
    }
    return LatLngBounds(
      LatLng((view.south - h * m).clamp(-85.0, 85.0), (view.west - w * m).clamp(-180.0, 180.0)),
      LatLng((view.north + h * m).clamp(-85.0, 85.0), (view.east + w * m).clamp(-180.0, 180.0)),
    );
  }

  /// The camera's bounds stop at the date line: what the screen shows beyond it.
  static LatLngBounds? _beyond(LatLngBounds view, double centerLng) {
    final w = view.longitudeWidth;
    if (w >= 360) return null;
    final s = view.south.clamp(-85.0, 85.0), n = view.north.clamp(-85.0, 85.0);
    if (centerLng + w / 2 > 180) return LatLngBounds(LatLng(s, -180), LatLng(n, centerLng + w / 2 - 360));
    if (centerLng - w / 2 < -180) return LatLngBounds(LatLng(s, centerLng - w / 2 + 360), LatLng(n, 180));
    return null;
  }

  bool get _stale {
    final box = _box, view = _view, at = _boxAt;
    if (view == null) return false;
    if (_dirty || box == null || at == null) return true;
    if (!_inside(view, box)) {
      // owner 2026-11-06: a cut-off answer covers only the box the server filled (`cover`), so the view
      // leaving it asks again. In a place so built up that even the view holds more than one answer can
      // carry, it asks again only when the view's middle leaves the middle of what was filled (never in a loop).
      final tooFull = _boxCut && _boxDetail &&
          (box.north - box.south < view.north - view.south || box.east - box.west < view.east - view.west);
      if (!tooFull) return true;
      final lat = (view.north + view.south) / 2, lng = (view.east + view.west) / 2;
      final qh = (box.north - box.south) / 4, qw = (box.east - box.west) / 4;
      final mid = (box.north + box.south) / 2, mlng = (box.east + box.west) / 2;
      if ((lat - mid).abs() > qh || (lng - mlng).abs() > qw) return true;
    }
    final across = _across, abox = _acrossBox;
    if (across != null && (abox == null || !_inside(across, abox))) return true;
    if (DateTime.now().difference(at) >= _maxAge) return true;
    if (_zoom >= kHexZoom && !_boxDetail) return true;
    if (_zoom < kHexZoom && (_boxDetail || cloudLevel(_zoom) != _boxCloud)) return true;   // other cloud squares
    // far out a cut-off answer (more clouds than one answer carries) is asked again closer in
    return _boxCut && !_boxDetail && _zoom >= _boxZoom + 1;
  }

  /// Keep [view] covered. Cheap: call it as often as you like (camera moves, a timer). With [centerLng]
  /// (the camera's) what shows beyond the date line is covered too.
  void want(LatLngBounds view, double zoom, {Duration? maxAge, double? centerLng}) {
    _view = _clamped(view);
    _across = centerLng == null ? null : _beyond(view, centerLng);
    _zoom = zoom;
    _maxAge = maxAge ?? _freshFor;
    _load();
    if (zoom < 9) _loadTop();
  }

  /// Something changed on the map (a hex built, a lease cancelled): fetch again now.
  void refresh() {
    _dirty = true;
    _load();
  }

  /// Show a hex right away, before the server's answer has it.
  void addLocal(Map<String, dynamic> hex) {
    hexes = [...hexes, hex];
    _rebuild();
  }

  Future<void> _load() async {
    if (_busy) return;
    _busy = true;
    try {
      // a newer view or a refresh that came in while waiting is fetched straight after
      for (var i = 0; i < 3 && !_gone && _stale; i++) {
        _dirty = false;
        final view = _view!;
        final zoom = _zoom;
        final detail = zoom >= kHexZoom;
        // the same area as last time, only older: ask with its sig (the view stays inside it, so keep it)
        final old = _box;
        final cloud = detail ? -1 : cloudLevel(zoom);
        final sameArea = old != null && _boxDetail == detail && cloud == _boxCloud && _inside(view, old) &&
            (_across == null || (_acrossBox != null && _inside(_across!, _acrossBox!))) &&
            _fullAt != null && DateTime.now().difference(_fullAt!) < _fullEvery;
        final crowded = _boxCut && _boxDetail && detail;
        final box = sameArea ? old : _withMargin(view, detail, crowded: crowded);
        final across = _across == null ? null : (sameArea ? _acrossBox : _withMargin(_across!, detail, crowded: crowded));
        final r = await _fetch('/api/v3/map', {'south': box.south, 'west': box.west,
            'north': box.north, 'east': box.east, 'detail': detail ? 1 : 0, if (!detail) 'cloud': cloud,
            if (sameArea) 'sig': _sig});
        if (_gone) return;
        if (!r.ok) { _dirty = true; break; }        // what is known stays; the next want tries again
        final ra = across == null ? null : await _fetch('/api/v3/map', {'south': across.south, 'west': across.west,
            'north': across.north, 'east': across.east, 'detail': detail ? 1 : 0, if (!detail) 'cloud': cloud,
            if (sameArea) 'sig': _acrossSig});
        if (_gone) return;
        if (ra != null && !ra.ok) { _dirty = true; break; }
        _sig = r.data['sig'] as String?;
        _acrossSig = ra?.data['sig'] as String?;
        if (r.data['same'] == 1 && (ra == null || ra.data['same'] == 1)) {
          _boxAt = DateTime.now();                  // still right: nothing to read or draw again
          continue;
        }
        if (r.data['same'] == 1 || ra?.data['same'] == 1) {
          _fullAt = null;                           // one half same, one changed: ask for both in full
          _dirty = true;
          continue;
        }
        if (!sameArea) _fullAt = DateTime.now();
        // what is really loaded: the box the server filled when it had to cut the answer off
        final filled = _cover(r) ?? box;
        _merge(r, filled, detail, also: ra == null ? null : (ra, _cover(ra) ?? across!));
        _box = filled;
        _acrossBox = ra == null ? across : (_cover(ra) ?? across);
        _boxDetail = detail;
        _boxZoom = zoom;
        _boxCloud = cloud;
        _boxCut = r.data['more'] == true;
        _boxAt = DateTime.now();
      }
    } finally {
      _busy = false;
    }
  }

  /// Up close, but [view] holds more hexes than one answer carries (a built-up city at the first hex zooms):
  /// show clouds there instead of the strip of hexes that came (owner 2026-11-06). Zooming in until the view
  /// fits shows hexes again.
  bool crowdedFor(LatLngBounds view) {
    final box = _box;
    if (box == null || !_boxCut || !_boxDetail) return false;
    return box.north - box.south < (view.north - view.south) * 0.98 ||
        box.east - box.west < (view.east - view.west) * 0.98;
  }

  static LatLngBounds? _cover(ApiResult r) {
    final c = r.data['cover'];
    if (c is! List || c.length != 4) return null;
    final v = [for (final x in c) (x as num).toDouble()];
    return LatLngBounds(LatLng(v[0], v[1]), LatLng(v[2], v[3]));
  }

  void _merge(ApiResult r, LatLngBounds box, bool detail, {(ApiResult, LatLngBounds)? also}) {
    _mergeOne(r, box, detail);
    if (also != null) _mergeOne(also.$1, also.$2, detail);
    if (detail && r.data['clouds'] != null) {           // cut off up close: the area's clouds came too
      smoke = SmokeData.fromClouds(Float64List.fromList([
        for (final a in [r, if (also != null) also.$1])
          for (final v in a.data['clouds'] as List? ?? const []) (v as num).toDouble(),
      ]));
    } else if (detail) {
      smoke = SmokeData.fromLatLng(Float64List.fromList([
        for (final h in hexes)
          ...[(h['lat'] as num).toDouble(), (h['lng'] as num).toDouble()],     // Campus cells too
      ]));
    } else if (r.data['clouds'] != null) {
      smoke = SmokeData.fromClouds(Float64List.fromList([
        for (final a in [r, if (also != null) also.$1])
          for (final v in a.data['clouds'] as List? ?? const []) (v as num).toDouble(),
      ]));
    } else {                                     // an older server: one dot per hex
      smoke = SmokeData.fromLatLng(Float64List.fromList([
        for (final a in [r, if (also != null) also.$1])
          for (final v in a.data['dots'] as List? ?? const []) (v as num).toDouble(),
      ]));
    }
    _rebuild();
  }

  void _mergeOne(ApiResult r, LatLngBounds box, bool detail) {
    bool inBox(Map<String, dynamic> m) =>
        (m['lat'] as num) >= box.south && (m['lat'] as num) <= box.north &&
        (m['lng'] as num) >= box.west && (m['lng'] as num) <= box.east;

    campuses = [
      ...campuses.where((c) => !inBox(c)),
      for (final c in r.list('campuses')) {...c, 'type': 'campus', 'isMine': c['own'] == true},
    ]..sort((a, b) => (b['level'] as num).compareTo(a['level'] as num));
    moves = [...moves.where((m) => !inBox(m)), ...r.list('moves')];

    if (detail) {
      final now = DateTime.now();
      final kept = hexes.where((h) => !inBox(h)).toList();
      if (kept.length > _maxKept) kept.clear();
      hexes = [
        ...kept,
        for (final h in r.list('hexes'))
          {
            ...h,
            'type': h['op'] == 'campus' ? 'campuscell' : 'mine',
            'isMine': h['own'] == true,
            if (h['shareFor'] != null)
              'overlapUntil': now.add(Duration(milliseconds: ((h['shareFor'] as num) * 1000).round())),
          },
      ];
    }
  }

  Future<void> _loadTop() async {
    final now = DateTime.now();
    if (_topAt != null && now.difference(_topAt!) < _topFreshFor) return;
    _topAt = now;
    final r = await _fetch('/api/v3/campuses/top', const {});
    if (_gone) return;
    if (!r.ok) { _topAt = null; return; }
    topCampuses = r.list('campuses');
    notifyListeners();
  }

  void _rebuild() {
    scene = MapScene.of(hexes, campuses, moves, _picture);
    notifyListeners();
  }
}

/// Metres to Web-Mercator pixels at zoom 0, at a latitude.
double worldPerMetre(double lat) => mercY(lat - 0.0005) - mercY(lat + 0.0005) == 0
    ? 0 : (mercY(lat - 0.0005) - mercY(lat + 0.0005)) / (0.001 * 111319.49);

/// Something on a hex that needs more than its picture: a stack, a lease countdown, a shared hex.
class HexMark {
  final double x, y, perM;
  final int stack;
  final double? leaseDays;
  final DateTime? overlapUntil;
  const HexMark(this.x, this.y, this.perM, this.stack, this.leaseDays, this.overlapUntil);
}

class CampusMark {
  final double x, y, perM;
  final int level;
  final bool own;
  const CampusMark(this.x, this.y, this.perM, this.level, this.own);
}

/// [MapWorld]'s data ready for drawing (positions in Web-Mercator pixels at zoom 0, as doubles: a
/// float is metres off at street zoom). Made once per answer, not per frame.
class MapScene {
  /// Per hex picture: x, y, world units per metre.
  final Map<String, Float64List> tiles;
  final List<HexMark> marks;
  final List<CampusMark> campuses;
  final List<CampusMark> sites;       // Campuses being moved, at their new place
  const MapScene({this.tiles = const {}, this.marks = const [], this.campuses = const [], this.sites = const []});

  /// A shared-hex ring is still running down (an expired one needs no more frames).
  bool get hasCountdowns {
    final now = DateTime.now();
    return marks.any((m) => m.overlapUntil != null && m.overlapUntil!.isAfter(now));
  }

  factory MapScene.of(List<Map<String, dynamic>> hexes, List<Map<String, dynamic>> campuses,
      List<Map<String, dynamic>> moves, String Function(Map<String, dynamic>) picture) {
    final byPicture = <String, List<double>>{};
    final spots = <String, List<Map<String, dynamic>>>{};
    for (final h in hexes) {
      if (h['type'] != 'mine') continue;
      final lat = (h['lat'] as num).toDouble(), lng = (h['lng'] as num).toDouble();
      byPicture.putIfAbsent(picture(h), () => []).addAll([mercX(lng), mercY(lat), worldPerMetre(lat)]);
      (spots['${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}'] ??= []).add(h);
    }
    final marks = <HexMark>[];
    for (final s in spots.values) {
      final lease = [for (final h in s) if (h['leaseDays'] != null) (h['leaseDays'] as num).toDouble()];
      if (lease.isNotEmpty) lease.sort();
      DateTime? until;
      for (final h in s) {
        final u = h['overlapUntil'];
        if (u is DateTime && h['isMine'] != true) until = u;
      }
      if (s.length < 2 && lease.isEmpty && until == null) continue;
      final lat = (s.first['lat'] as num).toDouble(), lng = (s.first['lng'] as num).toDouble();
      marks.add(HexMark(mercX(lng), mercY(lat), worldPerMetre(lat), s.length,
          lease.isEmpty ? null : lease.first, until));       // the most urgent lease of the spot
    }
    return MapScene(
      tiles: {for (final e in byPicture.entries) e.key: Float64List.fromList(e.value)},
      marks: marks,
      campuses: [
        for (final c in campuses)
          CampusMark(mercX((c['lng'] as num).toDouble()), mercY((c['lat'] as num).toDouble()),
              worldPerMetre((c['lat'] as num).toDouble()), (c['level'] as num).toInt(), c['isMine'] == true),
      ],
      sites: [
        for (final m in moves)
          CampusMark(mercX((m['lng'] as num).toDouble()), mercY((m['lat'] as num).toDouble()),
              worldPerMetre((m['lat'] as num).toDouble()), 0, m['own'] == true),
      ],
    );
  }
}
