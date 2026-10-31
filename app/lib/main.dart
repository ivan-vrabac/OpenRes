import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'branding.dart';
import 'models/player_provider.dart';
import 'screens/settings_screen.dart' show loadNumDecimalsPrefs, appThemeNotifier;
import 'screens/splash_screen.dart';
import 'services/notification_service.dart';
import 'services/screen_mode.dart';
import 'v3/company.dart';
import 'widgets/glass.dart';

/// Keeps the navigator (and every open page) when the company provider is put around it.
final _rootKey = GlobalKey();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadNumDecimalsPrefs();
  await NotificationService.init();
  await UiLook.load();                        // glass or classic panels, top bar shown
  await ScreenMode.load();                    // full screen (Settings › Full screen)
  runApp(
    ChangeNotifierProvider(
      create: (_) => PlayerProvider(),
      child: const OpenResApp(),
    ),
  );
}

class OpenResApp extends StatelessWidget {
  const OpenResApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeData>(
      valueListenable: appThemeNotifier,
      builder: (_, theme, __) => MaterialApp(
        title: Branding.appTitle,
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: const SplashScreen(),
        navigatorObservers: [ScreenModeObserver()],
        // The app draws edge to edge; keep every screen above Android's navigation bar (owner
        // 2026-10-25: chat and private messages from More had their input under it).
        builder: (ctx, child) => ValueListenableBuilder<Company?>(
          valueListenable: Company.active,
          builder: (_, co, body) => co == null ? body! : ChangeNotifierProvider<Company>.value(value: co, child: body!),
          child: KeyedSubtree(
            key: _rootKey,
            child: Listener(
              // full screen: a swipe from the edge brought a bar back; hide it again after the touch
              onPointerUp: (_) => ScreenMode.nudge(),
              child: AnimatedBuilder(
                animation: Listenable.merge([ScreenMode.changed, ScreenModeObserver.pages]),
                builder: (ctx, inner) {
                  // A hidden bar that a swipe shows for a moment floats over the app: its room is not
                  // taken from the layout, so nothing jumps (owner 2026-10-31).
                  final mq = MediaQuery.of(ctx);
                  final data = mq.removePadding(removeTop: ScreenMode.hideStatus, removeBottom: ScreenMode.hideNav)
                      .removeViewPadding(removeTop: ScreenMode.hideStatus, removeBottom: ScreenMode.hideNav);
                  return MediaQuery(
                    data: data,
                    child: ColoredBox(
                      color: Theme.of(ctx).colorScheme.surface,
                      // the game's tab bar sits over Android's navigation bar itself (its colour, see-through
                      // on the map); pages opened on top keep clear of it
                      child: SafeArea(top: false, left: false, right: false,
                          bottom: ScreenModeObserver.pages.value > 1, child: inner!),
                    ),
                  );
                },
                child: child ?? const SizedBox(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
