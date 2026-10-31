import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../v3/company.dart' show campusPicture;
import '../widgets/hex_tiles.dart';
import 'map_world.dart';
import 'smoke.dart';

const double kHexRadiusM = 15;
const double kCampusWidthM = 75, kCampusHeightM = 77.94;      // the Campus picture covers its 7 hexes

/// Hexes and Campuses on the map: both are things at a place with a size in metres, drawn by one
/// painter from [MapWorld.scene] at the camera of every frame. The camera moves only this layer.
class MapObjectsLayer extends StatefulWidget {
  final MapWorld world;
  final Color frame, accent;
  const MapObjectsLayer({super.key, required this.world, required this.frame, required this.accent});
  @override
  State<MapObjectsLayer> createState() => _MapObjectsLayerState();
}

class _MapObjectsLayerState extends State<MapObjectsLayer> {
  final _tick = ValueNotifier<int>(0);       // the shared-hex rings run down
  Timer? _timer;

  void _syncTimer() {
    final run = widget.world.scene.hasCountdowns;
    if (run && _timer == null) {
      _timer = Timer.periodic(const Duration(milliseconds: 250), (_) => _tick.value++);
    } else if (!run) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void initState() {
    super.initState();
    widget.world.addListener(_syncTimer);
    _syncTimer();
  }

  @override
  void dispose() {
    widget.world.removeListener(_syncTimer);
    _timer?.cancel();
    _tick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cam = MapCamera.of(context);
    final w = widget.world;
    return CustomPaint(
      size: Size.infinite,
      painter: _MapObjectsPainter(
        world: w, center: cam.center, zoom: cam.zoom, frame: widget.frame, accent: widget.accent,
        dpr: MediaQuery.of(context).devicePixelRatio,
        repaint: Listenable.merge([w, HexTiles.ready, _tick]),
      ),
    );
  }
}

class _MapObjectsPainter extends CustomPainter {
  final MapWorld world;
  final LatLng center;
  final double zoom, dpr;
  final Color frame, accent;
  _MapObjectsPainter({required this.world, required this.center, required this.zoom, required this.dpr,
      required this.frame, required this.accent, required Listenable repaint}) : super(repaint: repaint);

  static final _atlasPaint = Paint()..filterQuality = FilterQuality.medium;
  static final _textCache = <String, TextPainter>{};

  static TextPainter _text(String s, double size, Color color) {
    final k = '$s|${size.round()}|${color.toARGB32()}';
    if (_textCache.length > 300) _textCache.clear();
    return _textCache[k] ??= (TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: color, fontSize: size.roundToDouble(), fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr,
    )..layout());
  }

  void _chip(Canvas c, String s, double size, Color color, Offset at) {
    final t = _text(s, size, color);
    final r = Rect.fromCenter(center: at, width: t.width + 6, height: t.height);
    c.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(4)), Paint()..color = Colors.black87);
    t.paint(c, r.topLeft + const Offset(3, 0));
  }

  @override
  bool? hitTest(Offset position) => false;

  @override
  void paint(Canvas canvas, Size size) {
    final scene = world.scene;
    final scale = math.pow(2, zoom).toDouble();
    final cx = mercX(center.longitude), cy = mercY(center.latitude);
    final halfW = size.width / 2, halfH = size.height / 2;
    if (zoom < kHexZoom) return;              // further out both are clouds
    _hexes(canvas, size, scene, scale, cx, cy, halfW, halfH);
    _campuses(canvas, size, scene, scale, cx, cy, halfW, halfH);
    _sites(canvas, size, scene, scale, cx, cy, halfW, halfH);
  }

  void _hexes(Canvas canvas, Size size, MapScene scene, double scale, double cx, double cy, double halfW, double halfH) {
    for (final e in scene.tiles.entries) {
      final d = e.value;
      final tile = HexTiles.get(e.key, frame);
      final n = d.length ~/ 3;
      final xf = Float32List(n * 4), rects = Float32List(n * 4);
      var k = 0;
      for (var i = 0; i < n; i++) {
        final px = 2 * kHexRadiusM * d[3 * i + 2] * scale;
        final sx = halfW + (d[3 * i] - cx) * scale, sy = halfH + (d[3 * i + 1] - cy) * scale;
        if (sx < -px || sx > size.width + px || sy < -px || sy > size.height + px) continue;
        if (tile == null) {                   // the picture is still being made: its place, not a hole
          canvas.drawPath(HexTiles.hexPath(sx, sy, px / 2), Paint()..color = frame.withValues(alpha: 0.5));
          continue;
        }
        final s = px / HexTiles.w;
        xf[4 * k] = s;
        xf[4 * k + 2] = sx - px / 2;
        xf[4 * k + 3] = sy - px * 0.433;
        rects[4 * k + 2] = HexTiles.w;
        rects[4 * k + 3] = tile.height.toDouble();
        k++;
      }
      if (tile != null && k > 0) {
        canvas.drawRawAtlas(tile, Float32List.sublistView(xf, 0, 4 * k),
            Float32List.sublistView(rects, 0, 4 * k), null, null, null, _atlasPaint);
      }
    }
    final now = DateTime.now();
    for (final m in scene.marks) {
      final px = 2 * kHexRadiusM * m.perM * scale, ph = px * 0.866;
      final sx = halfW + (m.x - cx) * scale, sy = halfH + (m.y - cy) * scale;
      if (sx < -px || sx > size.width + px || sy < -px || sy > size.height + px) continue;
      if (m.stack > 1 && px >= 18) {          // inside the hex, top centre (neighbours cover the edges)
        _chip(canvas, '×${m.stack}', (px * 0.16).clamp(8.0, 12.0), Colors.white, Offset(sx, sy - ph * 0.3));
      }
      final until = m.overlapUntil;
      if (until != null && until.isAfter(now)) {
        final left = (until.difference(now).inMilliseconds / 30000.0).clamp(0.0, 1.0);
        final r = ph * 0.35, sw = (ph * 0.07).clamp(1.5, 5.0);
        final o = Offset(sx, sy);
        canvas.drawCircle(o, r, Paint()..style = PaintingStyle.stroke..strokeWidth = sw..color = Colors.black38);
        canvas.drawArc(Rect.fromCircle(center: o, radius: r), -math.pi / 2, 2 * math.pi * left, false,
            Paint()..style = PaintingStyle.stroke..strokeWidth = sw..color = Colors.yellowAccent);
      }
      if (m.leaseDays != null && px >= 14) {  // the lease's last days, in red
        _chip(canvas, '${m.leaseDays!.ceil()}d', (px * 0.16).clamp(8.0, 13.0), Colors.redAccent, Offset(sx, sy + ph * 0.3));
      }
    }
  }

  void _campuses(Canvas canvas, Size size, MapScene scene, double scale, double cx, double cy, double halfW, double halfH) {
    // the smallest first, so a big Campus stays on top of its neighbours
    for (final c in scene.campuses.reversed) {
      final ppm = c.perM * scale;
      final w = kCampusWidthM * ppm, h = kCampusHeightM * ppm;
      final sx = halfW + (c.x - cx) * scale, sy = halfH + (c.y - cy) * scale;
      if (sx < -w || sx > size.width + w || sy < -h || sy > size.height + h) continue;
      final img = w >= 2 ? HexTiles.campus(campusPicture(c.level), w * dpr) : null;
      if (img != null) {
        canvas.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
            Rect.fromCenter(center: Offset(sx, sy), width: w, height: h), _atlasPaint);
      }
      canvas.save();
      canvas.translate(sx, sy);
      canvas.scale(ppm);
      canvas.drawPath(_compound, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = (ppm * 0.5).clamp(0.5, 3.0) / ppm    // thinner as the Campus gets smaller
        ..color = c.own ? accent : Colors.grey);
      canvas.restore();
    }
  }

  /// A Campus's new place while it moves: the 7 hexes in construction stripes.
  void _sites(Canvas canvas, Size size, MapScene scene, double scale, double cx, double cy, double halfW, double halfH) {
    for (final c in scene.sites) {
      final ppm = c.perM * scale;
      final w = kCampusWidthM * ppm;
      final sx = halfW + (c.x - cx) * scale, sy = halfH + (c.y - cy) * scale;
      if (sx < -w || sx > size.width + w || sy < -w || sy > size.height + w) continue;
      canvas.save();
      canvas.translate(sx, sy);
      canvas.scale(ppm);
      canvas.save();
      canvas.clipPath(_compoundFill);
      canvas.drawRect(const Rect.fromLTRB(-40, -40, 40, 40), Paint()..color = Colors.black.withValues(alpha: 0.55));
      final stripe = Paint()
        ..color = Colors.amber.withValues(alpha: 0.75)
        ..strokeWidth = 4;
      for (var x = -80.0; x <= 80; x += 11) {
        canvas.drawLine(Offset(x - 40, 40), Offset(x + 40, -40), stripe);
      }
      canvas.restore();
      canvas.drawPath(_compound, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 / ppm
        ..color = c.own ? accent : Colors.amber);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_MapObjectsPainter old) =>
      old.center != center || old.zoom != zoom || old.frame != frame || old.accent != accent || old.world != world;
}

/// The 7-hex outline of a Campus about to be placed, as the marker's child at [ppm] pixels per metre.
class CampusGhostPainter extends CustomPainter {
  final double ppm;
  final Color color;
  const CampusGhostPainter({required this.ppm, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(ppm);
    canvas.drawPath(_compound, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 / ppm
      ..color = color);
  }

  @override
  bool shouldRepaint(CampusGhostPainter old) => old.ppm != ppm || old.color != color;
}

/// The centres of the 7 hexes in metres around the Campus: the middle and the neighbours across its
/// edges (N, 60°, ...).
final List<Offset> _centres = [
  Offset.zero,
  for (var k = 0; k < 6; k++)
    Offset(kHexRadiusM * math.sqrt(3) * math.sin(k * math.pi / 3), -kHexRadiusM * math.sqrt(3) * math.cos(k * math.pi / 3)),
];

List<Offset> _corners(Offset c) => [
      for (var k = 0; k < 6; k++)
        c + Offset(kHexRadiusM * math.cos(k * math.pi / 3), kHexRadiusM * math.sin(k * math.pi / 3)),
    ];

/// The 7 hexes as one filled shape.
final Path _compoundFill = () {
  final p = Path();
  for (final c in _centres) {
    p.addPolygon(_corners(c), true);
  }
  return p;
}();

/// The outline of the 7 hexes in metres around the Campus (x east, y south): the edges no two of the
/// hexes share.
final Path _compound = () {
  final edges = <(Offset, Offset)>[];
  for (final c in _centres) {
    final v = _corners(c);
    for (var k = 0; k < 6; k++) {
      edges.add((v[k], v[(k + 1) % 6]));
    }
  }
  Offset mid((Offset, Offset) e) => (e.$1 + e.$2) / 2;
  final p = Path();
  for (final e in edges) {
    if (edges.where((o) => (mid(o) - mid(e)).distance < 0.5).length > 1) continue;
    p.moveTo(e.$1.dx, e.$1.dy);
    p.lineTo(e.$2.dx, e.$2.dy);
  }
  return p;
}();
