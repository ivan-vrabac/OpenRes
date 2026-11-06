import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;

/// The game's own pictures (items, plants, operations, land: 122 of 256 x 256 px, about 32 MB decoded) are
/// decoded once in the background a moment after the game opens (owner 2026-11-06): Market, Storage,
/// Production and Hexes then show them at once, also right after the app was closed, instead of each
/// popping in when it first scrolls into view. They are kept under the same key `Image.asset(path)` uses.
const _folders = ['assets/game/items/', 'assets/game/plants/', 'assets/game/operations/', 'assets/game/land/'];
var _warm = false;

Future<void> warmGamePictures(BuildContext context) async {
  if (_warm) return;
  _warm = true;
  try {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final pictures = manifest.listAssets().where((a) => _folders.any(a.startsWith) && a.endsWith('.png'));
    for (final path in pictures) {
      if (!context.mounted) return;
      await precacheImage(AssetImage(path), context);
    }
  } catch (_) {
    _warm = false;                            // try again next time
  }
}
