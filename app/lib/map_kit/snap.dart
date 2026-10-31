import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Snapping a build spot to the hex grid around existing hexes (from the 0.2 map).
///
/// Neighbouring hexes sit edge to edge, √3·15 ≈ 25.98 m apart. A target that would overlap a hex
/// moves to the nearest free neighbour slot. A hex still open for sharing (built by someone else
/// in the last 30 s) doesn't block: a target inside it snaps onto it.
class SnapHex {
  const SnapHex(this.pos, {this.own = false, this.sharedOpen = false});
  final LatLng pos;
  final bool own;
  final bool sharedOpen;
}

const double kHexRadiusM = 15.0;
const double _edge = 25.98;              // √3·15 m
const _dirs = <double>[0, math.pi / 3, 2 * math.pi / 3, math.pi, 4 * math.pi / 3, 5 * math.pi / 3];

/// Metres between two close points; called many times a frame, so the short form.
double _distM(LatLng a, LatLng b) {
  final dLat = (b.latitude - a.latitude) * 111320.0;
  final dLng = (b.longitude - a.longitude) * 111320.0 * math.cos(a.latitude * math.pi / 180);
  return math.sqrt(dLat * dLat + dLng * dLng);
}

double _bearingRad(LatLng from, LatLng to) {
  final dLat = (to.latitude - from.latitude) * 111320.0;
  final dLng = (to.longitude - from.longitude) * 111320.0 * math.cos(from.latitude * math.pi / 180);
  return math.atan2(dLng, dLat);
}

LatLng _offset(LatLng p, double metres, double bearing) => LatLng(
      p.latitude + metres * math.cos(bearing) / 111320.0,
      p.longitude + metres * math.sin(bearing) / (111320.0 * math.cos(p.latitude * math.pi / 180)),
    );

/// Closest two flat-top hexes may be in this direction: 25.98 m edge to edge ... 30 m corner to corner.
double hexMinDist(LatLng from, LatLng to) {
  final b = ((_bearingRad(from, to) % (2 * math.pi)) + 2 * math.pi) % (2 * math.pi);
  final nearest = (b / (math.pi / 3)).round() * (math.pi / 3);
  final phi = (b - nearest).abs().clamp(0.0, math.pi / 6 - 0.001);
  return kHexRadiusM * math.sqrt(3) / math.cos(phi);
}

/// Where a hex aimed at [target] should go among [hexes].
LatLng snapBuildPos(LatLng target, List<SnapHex> hexes) {
  final ownSpots = {for (final h in hexes) if (h.own) '${h.pos.latitude},${h.pos.longitude}'};
  final blocking = <LatLng>[];
  for (final h in hexes) {
    final shared = h.sharedOpen && !ownSpots.contains('${h.pos.latitude},${h.pos.longitude}');
    if (shared && _distM(h.pos, target) < kHexRadiusM) return h.pos;
    if (!shared) blocking.add(h.pos);
  }
  if (blocking.isEmpty) return target;
  bool free(LatLng p) => blocking.every((m) => _distM(p, m) >= hexMinDist(m, p) - 0.1);
  if (free(target)) return target;
  LatLng? best;
  var bestD = double.infinity;
  for (final m in blocking) {
    for (final d in _dirs) {
      final c = _offset(m, _edge, d);
      if (!free(c)) continue;
      final dd = _distM(c, target);
      if (dd < bestD) {
        bestD = dd;
        best = c;
      }
    }
  }
  return best ?? target;
}

/// The 7 hexes of a Campus at [c]: the centre and its 6 neighbours, edge to edge.
List<LatLng> campusCells(LatLng c) => [c, for (final d in _dirs) _offset(c, _edge, d)];

/// Where a Campus aimed at [target] should go among [hexes], like [snapBuildPos] with 7 cells: a
/// target that would overlap anything moves to the nearest spot where all 7 fit against the hexes
/// around it. A Campus never shares a hex.
LatLng snapCampusPos(LatLng target, List<LatLng> hexes) {
  final near = [for (final h in hexes) if (_distM(h, target) < 220) h];
  bool free(LatLng c) {
    // a hex further than this from the centre can't touch any of the 7 cells
    final close = [for (final h in near) if (_distM(h, c) < 2 * _edge + 16) h];
    return campusCells(c).every((cell) => close.every((h) => _distM(cell, h) >= hexMinDist(h, cell) - 0.1));
  }
  if (near.isEmpty || free(target)) return target;
  // every spot where a cell touches a hex (a free cell beside it is one of the 7 of a Campus centred
  // on it or a neighbour), the nearest first: the first that fits is the answer
  final spots = <String, LatLng>{};
  for (final h in near) {
    for (final d in _dirs) {
      for (final c in campusCells(_offset(h, _edge, d))) {
        spots['${c.latitude.toStringAsFixed(5)},${c.longitude.toStringAsFixed(5)}'] = c;
      }
    }
  }
  final byDist = spots.values.toList()..sort((a, b) => _distM(a, target).compareTo(_distM(b, target)));
  for (final c in byDist) {
    if (free(c)) return c;
  }
  return target;
}
