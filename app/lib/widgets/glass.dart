import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_colors.dart';
import '../screens/settings_screen.dart' show mapPanelOpacityNotifier;

/// The panels over the map (Settings › App Appearance › Interface; owner 2026-10-31): rounded
/// "glass" panels floating over the map (the full-width "classic" bars are gone), a top bar that can
/// be hidden, a see-through tab bar, the map behind the status bar.
class UiLook {
  UiLook._();

  /// The top bar with the company name and credits.
  static final showHud = ValueNotifier<bool>(true);

  /// The bottom tab bar is see-through while the Map tab is open (fades to solid on the others).
  static final clearTabs = ValueNotifier<bool>(true);

  /// The map also runs behind Android's status bar (when the status bar is shown).
  static final underStatusBar = ValueNotifier<bool>(true);

  static Listenable get all => Listenable.merge([showHud, clearTabs, underStatusBar]);

  /// Height the floating top bar takes over the pages (bar + its margins).
  static const double hudInset = 50;

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    showHud.value = p.getBool('ui_show_hud') ?? true;
    clearTabs.value = p.getBool('ui_clear_tabs') ?? true;
    underStatusBar.value = p.getBool('ui_under_status') ?? true;
  }

  static Future<void> set({bool? hud, bool? clear, bool? underStatus}) async {
    final p = await SharedPreferences.getInstance();
    if (hud != null) await p.setBool('ui_show_hud', showHud.value = hud);
    if (clear != null) await p.setBool('ui_clear_tabs', clearTabs.value = clear);
    if (underStatus != null) await p.setBool('ui_under_status', underStatusBar.value = underStatus);
  }
}

/// Padding for a tab page's list: [all] around, plus the room of the status bar and the floating top
/// bar above and the tab bar below (given as MediaQuery padding by the game screen), so the list
/// starts below the top bar but scrolls up behind it, like the map (owner 2026-10-31: no black band).
/// On pages opened on top that room is 0.
EdgeInsets tabPadding(BuildContext context, double all) {
  final p = MediaQuery.paddingOf(context);
  return EdgeInsets.fromLTRB(all, all + p.top, all, all + p.bottom);
}

/// A panel over the map: a floating rounded glass panel (follows the panel opacity setting).
class MapPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double? height;
  /// Margin around the floating panel (glass only).
  final EdgeInsets margin;
  /// Corner radius in glass (half the height makes a pill).
  final double radius;
  const MapPanel({super.key, required this.child, this.padding = EdgeInsets.zero, this.height,
      this.margin = const EdgeInsets.fromLTRB(8, 6, 8, 6), this.radius = 16});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: mapPanelOpacityNotifier,
        builder: (context, _) {
          final surface = Theme.of(context).colorScheme.surface;
          final opacity = mapPanelOpacityNotifier.value.clamp(0.0, 1.0);
          return Padding(
            padding: margin,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                child: Container(
                  height: height,
                  padding: padding,
                  decoration: BoxDecoration(
                    color: surface.withValues(alpha: opacity * 0.55),
                    borderRadius: BorderRadius.circular(radius),
                    border: Border.all(color: AppColors.fg.withValues(alpha: 0.12)),
                  ),
                  child: child,
                ),
              ),
            ),
          );
        },
      );
}
