import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

/// Pre-rendered mine hexes (owner 2026-10-25, performance): the coloured frame, the dark inner
/// hex and the resource picture clipped to it are drawn ONCE per (picture, ring colour) into an
/// image; the map then draws one image per mine instead of a path, a clip and a picture every
/// frame while zooming. Same geometry as the old widgets (frame 100 %, inner 78 %, picture in
/// the middle 76 % zoomed 1.1x).
class HexTiles {
  HexTiles._();

  /// Rendered size: width × width·√3/2 (a flat-top hex).
  static const double w = 256, h = w * 0.866;

  static final _tiles = <String, ui.Image>{};
  static final _pictures = <String, Future<ui.Image?>>{};
  static final _busy = <String>{};

  /// Bumps when a new tile is ready (the mine layer listens and rebuilds once).
  static final ready = ValueNotifier<int>(0);

  static String _key(String asset, Color ring) => '$asset|${ring.toARGB32()}';

  /// The tile, or null while it is being made (then [ready] fires).
  static ui.Image? get(String asset, Color ring) {
    final k = _key(asset, ring);
    final t = _tiles[k];
    if (t != null || _busy.contains(k)) return t;
    _busy.add(k);
    _make(asset, ring).then((img) {
      _busy.remove(k);
      if (img != null) {
        _tiles[k] = img;
        ready.value++;
      }
    });
    return null;
  }

  // ── Campus pictures: decoded at a few sizes, so zooming reuses them ──

  static const _campusSizes = [64, 128, 256, 0];        // px wide; 0 = the full picture
  static const _keepLarge = 16;                         // the biggest sizes kept in memory
  static final _campus = <String, ui.Image>{};          // oldest first
  static final _campusBusy = <String>{};

  /// The picture for about [px] wide, or the closest size already decoded while that one is being
  /// made ([ready] fires), so a Campus never blinks away while zooming.
  static ui.Image? campus(String asset, double px) {
    final size = _campusSizes.firstWhere((s) => s >= px, orElse: () => 0);
    final k = '$asset|$size';
    final img = _campus.remove(k);
    if (img != null) {
      _campus[k] = img;                                 // now the newest
      return img;
    }
    if (_campusBusy.add(k)) {
      _decode(asset, size).then((i) {
        _campusBusy.remove(k);
        if (i == null) return;
        _campus[k] = i;
        if (size == 0 || size == 256) {
          final large = _campus.keys.where((c) => c.endsWith('|0') || c.endsWith('|256')).toList();
          for (final old in large.take(math.max(0, large.length - _keepLarge))) {
            _campus.remove(old);
          }
        }
        ready.value++;
      });
    }
    for (final s in _campusSizes.reversed) {
      final other = _campus['$asset|$s'];
      if (other != null) return other;
    }
    return null;
  }

  static Future<ui.Image?> _decode(String asset, int width) async {
    try {
      final data = await rootBundle.load(asset);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List(), targetWidth: width == 0 ? null : width);
      return (await codec.getNextFrame()).image;
    } catch (_) {
      return null;
    }
  }

  /// A resource picture, decoded once.
  static Future<ui.Image?> _picture(String asset) => _pictures.putIfAbsent(asset, () async {
        try {
          final data = await rootBundle.load(asset);
          final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
          return (await codec.getNextFrame()).image;
        } catch (_) {
          return null;
        }
      });

  static Path hexPath(double cx, double cy, double r) {
    final p = Path();
    for (var i = 0; i < 6; i++) {
      final a = i * math.pi / 3;
      final x = cx + r * math.cos(a), y = cy - r * math.sin(a);
      i == 0 ? p.moveTo(x, y) : p.lineTo(x, y);
    }
    return p..close();
  }

  static Future<ui.Image?> _make(String asset, Color ring) async {
    final pic = await _picture(asset);
    if (pic == null) return null;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    const cx = w / 2, cy = h / 2, outer = w / 2;
    // frame: ring colour, dark inner hex, thin grey edge
    c.drawPath(hexPath(cx, cy, outer), Paint()..color = ring.withValues(alpha: 0.85));
    c.drawPath(hexPath(cx, cy, outer * 0.78), Paint()..color = const Color(0xFF0A0A0A));
    const sw = outer * 0.03;
    c.drawPath(hexPath(cx, cy, outer - sw / 2), Paint()
      ..color = const Color(0xFF888888)
      ..style = PaintingStyle.stroke
      ..strokeWidth = sw);
    // the picture: box 76 % of the hex, clipped to a hex of that width, zoomed 1.1 (cover)
    const bw = w * 0.76, bh = h * 0.76;
    final box = Rect.fromCenter(center: const Offset(cx, cy), width: bw, height: bh);
    c.save();
    c.clipPath(hexPath(cx, cy, bw / 2));
    final iw = pic.width.toDouble(), ih = pic.height.toDouble();
    final s = math.max(bw / iw, bh / ih) * 1.1;
    final dst = Rect.fromCenter(center: box.center, width: iw * s, height: ih * s);
    c.drawImageRect(pic, Rect.fromLTWH(0, 0, iw, ih), dst, Paint()..filterQuality = FilterQuality.high);
    c.restore();
    final picture = rec.endRecording();
    final img = await picture.toImage(w.toInt(), h.round());
    picture.dispose();
    return img;
  }
}
