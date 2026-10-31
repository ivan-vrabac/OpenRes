import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../screens/settings_screen.dart' show paletteColorAt;

/// Scan / survey heatmaps (moved from the 0.2 map): palette lookup tables (Settings › Scan
/// Heatmap: classic, cold, contrast), colouring a grayscale picture, and an ImageProvider for a
/// decoded ui.Image.

// ── Palette colorization: build LUTs from palette stops ──────────────────────

Uint8List buildPaletteLut(String palette) {
  final lut = Uint8List(256 * 4); // [R, G, B, A] per v
  for (int v = 1; v < 256; v++) {
    final c = paletteColorAt(v, palette);
    lut[v * 4]     = (c.r * 255).round();
    lut[v * 4 + 1] = (c.g * 255).round();
    lut[v * 4 + 2] = (c.b * 255).round();
    lut[v * 4 + 3] = (c.a * 255).round();
  }
  return lut;
}

final classicLut  = buildPaletteLut('classic');
final coldLut     = buildPaletteLut('cold');
final contrastLut = buildPaletteLut('contrast');

Uint8List heatmapLut(String palette) {
  switch (palette) {
    case 'cold':     return coldLut;
    case 'contrast': return contrastLut;
    default:         return classicLut;
  }
}

// Apply LUT to a grayscale PNG, returning a decoded ui.Image.
// Eliminates the expensive PNG re-encode that was the primary scan latency bottleneck.
Future<ui.Image> colorizeGrayscale(Uint8List grayscalePng, Uint8List lut) async {
  final codec = await ui.instantiateImageCodec(grayscalePng);
  final frame = await codec.getNextFrame();
  final srcImg = frame.image;
  final w = srcImg.width, h = srcImg.height;
  final bd = await srcImg.toByteData(format: ui.ImageByteFormat.rawRgba);
  srcImg.dispose();
  if (bd == null) {
    final c2 = await ui.instantiateImageCodec(grayscalePng);
    return (await c2.getNextFrame()).image;
  }
  final src = bd.buffer.asUint8List();
  final dst = Uint8List(src.length);
  for (int i = 0; i < src.length; i += 4) {
    final v = src[i];
    dst[i]     = lut[v * 4];
    dst[i + 1] = lut[v * 4 + 1];
    dst[i + 2] = lut[v * 4 + 2];
    dst[i + 3] = lut[v * 4 + 3];
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(dst, w, h, ui.PixelFormat.rgba8888, completer.complete);
  return completer.future;
}

// ImageProvider that wraps a decoded ui.Image directly — no encode/decode roundtrip.
class UiImageProvider extends ImageProvider<UiImageProvider> {
  final ui.Image image;
  const UiImageProvider(this.image);

  @override
  Future<UiImageProvider> obtainKey(ImageConfiguration _) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(UiImageProvider key, ImageDecoderCallback _) =>
      OneFrameImageStreamCompleter(
        SynchronousFuture(ImageInfo(image: key.image.clone())),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is UiImageProvider && other.image == image);

  @override
  int get hashCode => image.hashCode;
}


/// A survey grid (n x n quality values 0-100, rows north to south) coloured with the palette:
/// 0 = transparent, 1-100 spread over the palette like the 0.2 scans.
Future<ui.Image> colorizeValues(Uint8List values, int n, Uint8List lut) {
  final dst = Uint8List(n * n * 4);
  for (var i = 0; i < n * n; i++) {
    final q = values[i];
    if (q == 0) continue;
    final v = (q * 255 / 100).round().clamp(1, 255);
    dst[i * 4] = lut[v * 4];
    dst[i * 4 + 1] = lut[v * 4 + 1];
    dst[i * 4 + 2] = lut[v * 4 + 2];
    dst[i * 4 + 3] = lut[v * 4 + 3];
  }
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(dst, n, n, ui.PixelFormat.rgba8888, done.complete);
  return done.future;
}
