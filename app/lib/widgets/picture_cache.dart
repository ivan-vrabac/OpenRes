import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;

import 'async_view.dart' show kSmallPicturePx;

/// The game's own pictures (items, plants, operations, land: 122 of them, decoded at the small icon size,
/// kSmallPicturePx: about 8 MB; the plants also in full for Production's big cards: about 9 MB) and
/// the leaderboard flags are decoded once, a moment after the game opens, and PINNED (owner 2026-11-06):
/// Market, Storage, Production, Hexes and the leaderboards show them at once, also right after the app was
/// closed. Only warming them was not enough: the map's tiles share the image cache, and scrolling the map
/// pushed the pictures out again. A pinned picture keeps a listener, so the cache never lets it go.
/// They are kept under the same key `Image.asset(path)` (and `cacheWidth`) uses.
const _folders = ['assets/game/items/', 'assets/game/plants/', 'assets/game/operations/', 'assets/game/land/'];
final _pinned = <(ImageStream, ImageStreamListener)>[];
var _warm = false;

/// Decode [provider] and keep it in the cache for as long as the app runs.
Future<void> pinPicture(ImageProvider provider, BuildContext context) {
  final done = Completer<void>();
  final stream = provider.resolve(createLocalImageConfiguration(context));
  final listener = ImageStreamListener((_, __) {
    if (!done.isCompleted) done.complete();
  }, onError: (_, __) {
    if (!done.isCompleted) done.complete();
  });
  stream.addListener(listener);
  _pinned.add((stream, listener));
  return done.future;
}

/// Every asset whose path starts with one of [folders].
Future<List<String>> assetsIn(List<String> folders) async {
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  return manifest.listAssets().where((a) => folders.any(a.startsWith) && a.endsWith('.png')).toList();
}

Future<void> warmGamePictures(BuildContext context) async {
  if (_warm) return;
  _warm = true;
  try {
    for (final path in await assetsIn(_folders)) {
      if (!context.mounted) return;
      await pinPicture(ResizeImage.resizeIfNeeded(kSmallPicturePx, null, AssetImage(path)), context);
      if (path.startsWith('assets/game/plants/') && context.mounted) await pinPicture(AssetImage(path), context);
    }
  } catch (_) {
    _warm = false;                            // try again next time
  }
}
