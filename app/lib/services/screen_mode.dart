import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Full screen (owner 2026-10-25): hide Android's navigation bar (the gesture pill or the buttons)
/// and, if wanted, the status bar. A swipe from the edge shows them for a moment; they hide again.
///
/// Android only re-hides bars by itself in sticky immersive mode (both bars hidden). With one bar
/// hidden, a swipe brings the bar back for good and no callback says so (owner 2026-10-31: in More
/// the gesture bar came back). So the bars are hidden again a moment after every touch ([nudge],
/// from the Listener at the app root), after every page change ([ScreenModeObserver]) and on resume.
class ScreenMode {
  static bool hideNav = true;
  static bool hideStatus = false;
  static Timer? _rehide;
  /// Bumps when a setting changes (the game screen makes room under the tabs when the bar is hidden).
  static final changed = ValueNotifier<int>(0);

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    hideNav = prefs.getBool('screen_hide_nav') ?? true;
    hideStatus = prefs.getBool('screen_hide_status') ?? false;
    SystemChrome.setSystemUIChangeCallback((visible) async {
      // bars shown by a swipe: hide them again after a moment
      if (visible && (hideNav || hideStatus)) {
        _rehide?.cancel();
        _rehide = Timer(const Duration(seconds: 3), apply);
      }
    });
    await apply();
  }

  /// Hide the bars again in a moment (called after touches and page changes; cheap when nothing hides).
  static void nudge([Duration after = const Duration(seconds: 2)]) {
    if (!hideNav && !hideStatus) return;
    _rehide?.cancel();
    _rehide = Timer(after, apply);
  }

  static Future<void> set({bool? nav, bool? status}) async {
    final prefs = await SharedPreferences.getInstance();
    if (nav != null) await prefs.setBool('screen_hide_nav', hideNav = nav);
    if (status != null) await prefs.setBool('screen_hide_status', hideStatus = status);
    changed.value++;
    await apply();
  }

  static Future<void> apply() async {
    // Android draws its bars over the app: no scrim, so a see-through tab bar shows the map below
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      systemNavigationBarColor: Color(0x00000000),
      systemNavigationBarDividerColor: Color(0x00000000),
      systemNavigationBarContrastEnforced: false,
    ));
    if (hideNav && hideStatus) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else if (hideNav || hideStatus) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: [
        if (!hideStatus) SystemUiOverlay.top,
        if (!hideNav) SystemUiOverlay.bottom,
      ]);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }
}

/// Re-hides the bars after a page is opened or closed (dialogs and pages can bring them back), and
/// counts the full pages open: on the first one (the game) the tab bar itself sits over Android's
/// navigation bar; pages opened on top keep clear of it (main.dart).
class ScreenModeObserver extends NavigatorObserver {
  static final pages = ValueNotifier<int>(0);

  static bool _page(Route? r) => r is PageRoute && r.opaque;

  @override
  void didPush(Route route, Route? previousRoute) {
    if (_page(route)) pages.value++;
    ScreenMode.nudge(const Duration(milliseconds: 400));
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    if (_page(route)) pages.value--;
    ScreenMode.nudge(const Duration(milliseconds: 400));
  }

  @override
  void didRemove(Route route, Route? previousRoute) {
    if (_page(route)) pages.value--;
  }
}
