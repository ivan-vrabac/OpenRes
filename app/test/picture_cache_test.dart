import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openres/widgets/picture_cache.dart';

/// A small PNG made on the spot (a different colour per [seed]), standing in for a picture or a map tile.
Future<Uint8List> png(int seed) async {
  final rec = ui.PictureRecorder();
  Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 64, 64), Paint()..color = Color(0xFF000000 + seed * 9973));
  final img = await rec.endRecording().toImage(64, 64);
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

/// A screen shows [p] and is then left: the picture is decoded, used, and let go.
Future<void> showAndLeave(ImageProvider p) {
  final done = Completer<void>();
  final stream = p.resolve(ImageConfiguration.empty);
  late final ImageStreamListener l;
  l = ImageStreamListener((info, _) {
    info.dispose();
    stream.removeListener(l);
    done.complete();
  });
  stream.addListener(l);
  return done.future;
}

void main() {
  testWidgets('a pinned picture stays when the map tiles fill the cache, an ordinary one goes (owner 2026-11-06)',
      (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    }));
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    cache.maximumSizeBytes = 64 * 64 * 4 * 10;            // room for ten 64 x 64 pictures

    final pinned = MemoryImage(await tester.runAsync(() => png(1)) as Uint8List);
    final ordinary = MemoryImage(await tester.runAsync(() => png(2)) as Uint8List);
    await tester.runAsync(() async {
      await pinPicture(pinned, ctx);
      await showAndLeave(ordinary);
    });
    final pinnedKey = await pinned.obtainKey(ImageConfiguration.empty);
    final ordinaryKey = await ordinary.obtainKey(ImageConfiguration.empty);
    expect(cache.statusForKey(pinnedKey).live, isTrue);
    expect(cache.statusForKey(ordinaryKey).keepAlive, isTrue);   // still cached for now

    // scrolling the map: 40 tiles come through the same cache and are left again
    for (var i = 0; i < 40; i++) {
      final tile = MemoryImage(await tester.runAsync(() => png(100 + i)) as Uint8List);
      await tester.runAsync(() => showAndLeave(tile));
    }
    expect(cache.statusForKey(pinnedKey).live, isTrue, reason: 'the pinned picture is still there');
    expect(cache.statusForKey(ordinaryKey).untracked, isTrue, reason: 'an ordinary picture was pushed out');
    cache.maximumSizeBytes = 100 << 20;
  });
}
