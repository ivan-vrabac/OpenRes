import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/rendering.dart';
import 'package:latlong2/latlong.dart';

/// Map clouds (moved from the 0.2 map).

// ── Mine smoke painter ─────────────────────────────────────────────────────────
// One soft smoke puff per mine at far zoom, drawn as a single GPU sprite batch
// (drawRawAtlas), so tens of thousands of mines stay smooth. Puffs pile up inside
// one layer that is composited at a capped opacity: overlapping smoke merges and
// thickens but never turns into a solid block. The puff's screen radius is one
// continuous function of zoom, so nothing jumps or teleports while zooming.

const double kPuffTex = 64;      // puff sprite size (px)
const double kSmokeMaxAlpha = 0.45; // opacity cap for fully merged smoke

/// The puff in [color] (the app's Icon & Symbol colour, owner 2026-10-31; it was always orange).
Future<ui.Image> makePuffImage(Color color) {
  final rec = ui.PictureRecorder();
  const r = kPuffTex / 2;
  Canvas(rec).drawCircle(const Offset(r, r), r, Paint()
    ..shader = RadialGradient(
      colors: [color.withValues(alpha: 0.5), color.withValues(alpha: 0.15), color.withValues(alpha: 0)],
      stops: [0.0, 0.45, 1.0],
    ).createShader(Rect.fromCircle(center: const Offset(r, r), radius: r)));
  return rec.endRecording().toImage(kPuffTex.toInt(), kPuffTex.toInt());
}

double mercX(double lng) => (lng + 180) / 360 * 256;
double mercY(double lat) {
  final lr = lat.clamp(-85.05, 85.05) * math.pi / 180;
  return (1 - math.log(math.tan(lr) + 1 / math.cos(lr)) / math.pi) / 2 * 256;
}

/// Mine positions in Web-Mercator pixels at zoom 0, plus reusable sprite buffers.
class SmokeData {
  final Float32List world; // x, y pairs
  final Float32List rects; // sprite source rects (all the same)
  final Float32List xf;    // per-frame RSTransforms, rewritten in paint()
  SmokeData._(this.world, this.rects, this.xf);

  factory SmokeData.fromLatLng(Float64List latLng) {
    final n = latLng.length ~/ 2;
    final world = Float32List(n * 2);
    final rects = Float32List(n * 4);
    for (int i = 0; i < n; i++) {
      world[2 * i]     = mercX(latLng[2 * i + 1]);
      world[2 * i + 1] = mercY(latLng[2 * i]);
      rects[4 * i + 2] = kPuffTex;
      rects[4 * i + 3] = kPuffTex;
    }
    return SmokeData._(world, rects, Float32List(n * 4));
  }

  int get length => world.length ~/ 2;
}

class SmokePainter extends CustomPainter {
  final SmokeData? data;
  final ui.Image? puff;
  final LatLng center;
  final double zoom;
  const SmokePainter({required this.data, required this.puff,
      required this.center, required this.zoom});

  /// Puff radius in screen px: ~12 px fully zoomed out, growing smoothly to ~48 px
  /// at the switch to individual mine icons (zoom 14.5).
  static double radiusFor(double zoom) =>
      12.0 * math.pow(4.0, ((zoom - 3.0) / 11.5).clamp(0.0, 1.0)).toDouble();

  @override
  void paint(Canvas canvas, Size size) {
    final d = data, img = puff;
    if (d == null || img == null || d.length == 0) return;
    final scale = math.pow(2, zoom).toDouble();
    final cx = mercX(center.longitude), cy = mercY(center.latitude);
    final r = radiusFor(zoom);
    final s = 2 * r / kPuffTex;
    final halfW = size.width / 2, halfH = size.height / 2;
    final w = d.world, xf = d.xf;
    int k = 0;
    for (int i = 0; i < d.length; i++) {
      final sx = halfW + (w[2 * i] - cx) * scale;
      final sy = halfH + (w[2 * i + 1] - cy) * scale;
      if (sx < -r || sx > size.width + r || sy < -r || sy > size.height + r) continue;
      xf[4 * k]     = s;
      xf[4 * k + 1] = 0;
      xf[4 * k + 2] = sx - r;
      xf[4 * k + 3] = sy - r;
      k++;
    }
    if (k == 0) return;
    canvas.saveLayer(Offset.zero & size,
        Paint()..color = Color.fromRGBO(255, 255, 255, kSmokeMaxAlpha));
    canvas.drawRawAtlas(img, Float32List.sublistView(xf, 0, 4 * k),
        Float32List.sublistView(d.rects, 0, 4 * k), null, null, null, Paint());
    canvas.restore();
  }

  @override
  bool shouldRepaint(SmokePainter old) =>
      old.data != data || old.puff != puff || old.center != center || old.zoom != zoom;
}
