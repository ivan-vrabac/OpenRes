import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../branding.dart';
import '../widgets/popups.dart';

/// "New update available" at start for the Google Play app (owner 2026-11-07): Play itself says whether a
/// newer version is out; Update runs Play's own update (full screen, the app restarts on the new version).
/// Only Google Play is supported (owner 2026-11-07: no sideloaded builds); a build not installed from Play
/// (a dev build) gets an error from Play and stays quiet.
class PlayUpdate {
  static const _kDismissed = 'play_update_dismissed_code';
  static bool _asked = false;           // once per launch

  static Future<void> checkOnStart(BuildContext context) async {
    if (_asked || kIsWeb || !Platform.isAndroid) return;
    _asked = true;
    final AppUpdateInfo info;
    try {
      info = await InAppUpdate.checkForUpdate();
    } catch (_) {
      return;                           // not from Play, or Play unreachable
    }
    // an update started earlier and left half way: carry on with it
    if (info.updateAvailability == UpdateAvailability.developerTriggeredUpdateInProgress) {
      await _run(info);
      return;
    }
    if (info.updateAvailability != UpdateAvailability.updateAvailable) return;
    final code = info.availableVersionCode ?? 0;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getInt(_kDismissed) == code) return;    // "Later" on this version: asked again with the next one
    if (!context.mounted) return;
    final update = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.system_update, size: 36),
        title: const Text('New update available'),
        content: const Text('A new version of ${Branding.appName} is ready on Google Play. '
            'Update now for the latest fixes and features.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Later')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Update')),
        ],
      ),
    );
    if (update == true) {
      await _run(info);
    } else {
      await prefs.setInt(_kDismissed, code);
    }
  }

  static Future<void> _run(AppUpdateInfo info) async {
    try {
      if (info.immediateUpdateAllowed) {
        await InAppUpdate.performImmediateUpdate();
      } else if (info.flexibleUpdateAllowed) {
        final r = await InAppUpdate.startFlexibleUpdate();
        if (r == AppUpdateResult.success) await InAppUpdate.completeFlexibleUpdate();
      }
    } catch (_) {
      // the player backed out of Play's screen, or Play failed: they can update from the store
    }
  }
}
