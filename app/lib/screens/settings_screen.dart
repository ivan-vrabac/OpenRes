import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/cards.dart';
import '../app_colors.dart';
import '../widgets/top_banner.dart';
import '../services/storage_service.dart';
import '../services/screen_mode.dart';
import 'login_screen.dart';
import '../widgets/hold_button.dart';
import '../services/game_api.dart';
import '../services/google_auth.dart';
import '../services/play_games.dart';
import '../branding.dart';
import '../models/player_provider.dart';
import '../models/tab_config.dart';
import '../services/location_service.dart';
import '../services/update_service.dart';
import '../widgets/update_dialog.dart';
import '../constants.dart' show fmtNum, kNumDecimals, kInvertAskBid;
import 'game_screen.dart' show tabMeta;

import '../widgets/glass.dart';
import '../widgets/popups.dart';
import '../ring_looks.dart';
// ── Notification settings ──────────────────────────────────────────────────────
bool kNotifEnabled       = true;
bool kNoFpsLimit         = false;

/// Asks Android for the screen's fastest mode, or leaves it to Android. Returns that mode's Hz.
Future<double?> applyNoFpsLimit(bool on) async {
  try {
    return await const MethodChannel('openres/display').invokeMethod<double>('noFpsLimit', {'on': on});
  } catch (_) {
    return null;
  }
}

// ── App color palette ──────────────────────────────────────────────────────────
// owner 2026-10-23: no separate accent; background, text and icon colours (AppColors) + strength
double kSurfaceTone   = 0.5; // 0.0 = very dark, 1.0 = less dark
double kBgStrength    = 0.3; // how strongly backgrounds and panels take the background colour

ThemeData _buildAppTheme() {
  final accent = AppColors.accent, fg = AppColors.fg, bg = AppColors.bg;
  final scheme = ColorScheme.fromSeed(
      seedColor: accent, brightness: Brightness.dark, dynamicSchemeVariant: DynamicSchemeVariant.vibrant);
  late final Color scaffold, surface, c1, c2, c3;
  if (AppColors.isBlack) {
    // true OLED black: black screens, panels just visible enough to separate
    scaffold = Colors.black;
    surface = const Color(0xFF000000);
    c1 = const Color(0xFF121212);
    c2 = const Color(0xFF1C1C1C);
    c3 = const Color(0xFF262626);
  } else {
    final base = Color.lerp(const Color(0xFF0A0A0A), const Color(0xFF2D2D3D), kSurfaceTone)!;
    final k = kBgStrength;
    scaffold = Color.lerp(base, bg, k * 0.6)!;
    surface = Color.lerp(base, bg, k * 0.9)!;
    c1 = Color.lerp(base, bg, (k * 1.2).clamp(0.0, 1.0))!;
    c2 = Color.lerp(base, bg, (k * 1.5).clamp(0.0, 1.0))!;
    c3 = Color.lerp(base, bg, (k * 1.8).clamp(0.0, 1.0))!;
  }
  // outlines are mixed from the text colour, so panels never melt into the background
  final outline = Color.lerp(c2, fg, 0.35)!;
  final cs = scheme.copyWith(
    primary: accent,
    onPrimary: accent.computeLuminance() > 0.45 ? Colors.black : Colors.white,
    secondary: accent,
    surface: surface,
    onSurface: fg,
    onSurfaceVariant: fg.withValues(alpha: 0.75),
    surfaceContainerLowest: scaffold,
    surfaceContainerLow: c1,
    surfaceContainer: c1,
    surfaceContainerHigh: c2,
    surfaceContainerHighest: c3,
    outline: outline,
    outlineVariant: outline.withValues(alpha: 0.6),
  );
  final base = ThemeData(colorScheme: cs, useMaterial3: true, scaffoldBackgroundColor: scaffold);
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: fg, displayColor: fg),
    iconTheme: base.iconTheme.copyWith(color: accent),
    listTileTheme: base.listTileTheme.copyWith(iconColor: accent, textColor: fg),
    appBarTheme: base.appBarTheme.copyWith(backgroundColor: surface, foregroundColor: fg,
        iconTheme: IconThemeData(color: accent), actionsIconTheme: IconThemeData(color: accent)),
    cardTheme: base.cardTheme.copyWith(color: c1, shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12), side: BorderSide(color: outline.withValues(alpha: 0.7)))),
    bottomSheetTheme: base.bottomSheetTheme.copyWith(backgroundColor: c1, modalBackgroundColor: c1),
    dialogTheme: base.dialogTheme.copyWith(backgroundColor: c2),
    dividerColor: outline.withValues(alpha: 0.5),
    navigationBarTheme: base.navigationBarTheme.copyWith(backgroundColor: surface),
  );
}

final appThemeNotifier = ValueNotifier<ThemeData>(_buildAppTheme());

class SettingsScreen extends StatefulWidget {
  final TabConfig config;
  final ValueChanged<TabConfig> onSave;

  const SettingsScreen({super.key, required this.config, required this.onSave});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

double kCloudOpacity = 0.55;

bool   kShowRingLabels   = true;   // ring looks live in ring_looks.dart

const List<String> kHeatmapSchemes      = ['classic', 'cold', 'contrast'];
const List<String> kHeatmapSchemeLabels = ['Classic', 'Cold', 'Contrast'];
String kHeatmapScheme = 'classic';

// Notifier so the map tab re-renders the heatmap immediately on palette change.
final heatmapSchemeNotifier = ValueNotifier<String>('classic');

// GPS refresh interval (seconds)
int kGpsIntervalSeconds = 3;

// Map panel background opacity (1.0 = fully opaque, matches bottom nav)
double kMapPanelOpacity = 0.2;           // owner 2026-10-31: glass panels very transparent by default
final mapPanelOpacityNotifier = ValueNotifier<double>(0.2);

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(toolbarHeight: 36, title: const Text('Settings')),
      body: ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 16), children: [
        const SectionLabel('Look'),
        RowGroup([
          _tile(Icons.tab, 'Bottom bar',
              '${widget.config.bottomTabs.length} tab${widget.config.bottomTabs.length == 1 ? '' : 's'} pinned',
              () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => _BottomBarSettings(config: widget.config, onSave: widget.onSave)))),
          _tile(Icons.palette_outlined, 'App Appearance', 'Colors · map panels · full screen',
              () => Navigator.push(context, MaterialPageRoute(builder: (_) => const _AppAppearancePage()))),
          _tile(Icons.thermostat, 'Survey Heatmap', 'Opacity · palette',
              () => Navigator.push(context, MaterialPageRoute(builder: (_) => const _ScanHeatmapPage()))),
          _tile(Icons.pin, 'Numbers', 'Decimal places in short numbers',
              () => Navigator.push(context, MaterialPageRoute(builder: (_) => const _NumbersDisplayPage()))),
        ]),
        const SizedBox(height: 16),
        const SectionLabel('Game'),
        RowGroup([
          _tile(Icons.notifications_outlined, 'Notifications', 'What the game tells you about',
              () => Navigator.push(context, MaterialPageRoute(builder: (_) => const _NotificationsPage()))),
          _tile(Icons.speed, 'Performance', 'Frame rate · GPS',
              () => Navigator.push(context, MaterialPageRoute(builder: (_) => const _PerformancePage()))),
          if (UpdateService.supported)
            _tile(Icons.system_update, 'Updates',
                'Version ${Branding.buildName} (build ${Branding.buildNumber})', () => UpdateDialog.open(context)),
        ]),
        const SizedBox(height: 16),
        const SectionLabel('Account'),
        RowGroup([
          _tile(Icons.manage_accounts_outlined, 'Account', 'Company name · connected accounts · delete',
              () => Navigator.push(context, MaterialPageRoute(builder: (_) => const _AccountPage()))),
        ]),
      ]),
    );
  }

  Widget _tile(IconData icon, String title, String subtitle, VoidCallback onTap) =>
      NavRow(icon: Icon(icon, color: AppColors.accent), title: title, subtitle: subtitle, onTap: onTap);
}

// ── Account ────────────────────────────────────────────────────────────────────

/// Company name, how the company signs in, deletion. Connections all end in one Google identity on the
/// server (auth_identities has a provider column, so Sign in with Apple can join them on iOS). There is
/// no disconnect: it would lock the player out of the company.
class _AccountPage extends StatefulWidget {
  const _AccountPage();
  @override
  State<_AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<_AccountPage> {
  Map<String, dynamic>? _status;
  bool _games = false;
  bool _busy = false;

  String get _sid => context.read<PlayerProvider>().sid;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await GameApi.call('/api/v1/auth/status', _sid, {});
    if (!mounted || !r.ok) return;
    setState(() => _status = r.data);
    final token = await PlayGames.idToken();
    if (token != null) await _checkGames(token);
  }

  /// Is the phone's Play Games profile the Google account of this company?
  Future<bool> _checkGames(String token) async {
    final r = await GameApi.call('/api/v1/auth/status', _sid, {'id_token': token});
    final same = r.ok && r.data['match'] == true;
    if (mounted) setState(() => _games = same);
    return same;
  }

  /// A company with a password: the password once, then this Google account signs it in.
  Future<void> _link(String token) async {
    final ctl = TextEditingController();
    final password = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Your password'),
        content: TextField(controller: ctl, obscureText: true, autofocus: true,
            decoration: const InputDecoration(labelText: 'Password', helperText: 'Not needed any more after this',
                border: OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => popIfCurrent(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => popIfCurrent(ctx, ctl.text), child: const Text('Connect')),
        ],
      ),
    );
    if (password == null || password.isEmpty || !mounted) return;
    final r = await GameApi.call('/api/v1/auth/google/link', _sid, {'id_token': token, 'password': password});
    if (!mounted) return;
    AppNotify.show(context, r.ok ? 'Connected' : r.message ?? 'Failed', isError: !r.ok);
    if (r.ok) _load();
  }

  Future<void> _connect(Future<String?> Function() token, String failed, {bool games = false}) async {
    setState(() => _busy = true);
    try {
      final t = await token();
      if (!mounted) return;
      if (t == null) {
        AppNotify.show(context, failed, isError: true);
      } else if (_status?['google'] != true) {
        await _link(t);
      } else if (games && !await _checkGames(t) && mounted) {
        AppNotify.show(context, 'This Play Games profile uses a different Google account than your company.', isError: true);
      }
    } catch (e) {
      if (mounted) AppNotify.show(context, GoogleAuth.errorText(e), isError: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  Widget _connection(IconData icon, String title, bool on, String off, VoidCallback onConnect) => NavRow(
        icon: Icon(icon, color: on ? Colors.greenAccent : AppColors.accent),
        title: title,
        subtitle: on ? 'Connected' : off,
        arrow: !on,
        onTap: on || _busy ? () {} : onConnect,
      );

  @override
  Widget build(BuildContext context) {
    final s = _status;
    final email = (s?['email'] as String?) ?? '';
    return Scaffold(
      appBar: AppBar(toolbarHeight: 36, title: const Text('Account')),
      body: ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 16), children: [
        const SectionLabel('Company'),
        RowGroup([
          NavRow(icon: Icon(Icons.badge_outlined, color: AppColors.accent), title: 'Change company name',
              subtitle: 'First change free, then credits',
              onTap: () => showAppDialog(context: context, builder: (_) => const _RenameDialog())),
        ]),
        const SizedBox(height: 16),
        const SectionLabel('Connected accounts'),
        if (s == null)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
        else
          RowGroup([
            if (GoogleAuth.enabled)
              _connection(Icons.account_circle, s['google'] == true && email.isNotEmpty ? 'Google: $email' : 'Google',
                  s['google'] == true, 'Sign in with your Google account',
                  () => _connect(() => GoogleAuth.idToken(pick: true), 'Google sign-in was cancelled')),
            if (PlayGames.enabled)
              _connection(Icons.sports_esports, 'Google Play Games', _games, 'Achievements and quick sign-in',
                  () => _connect(() => PlayGames.idToken(ask: true), 'Play Games sign-in did not work', games: true)),
          ]),
        const SizedBox(height: 16),
        RowGroup([
          NavRow(
            icon: const Icon(Icons.delete_forever_outlined, color: Colors.redAccent),
            title: 'Delete account',
            titleColor: Colors.redAccent,
            subtitle: 'Remove this company and all its data',
            onTap: () => showAppDialog(context: context, builder: (_) => const _DeleteAccountDialog()),
          ),
        ]),
      ]),
    );
  }
}

// ── Shared helpers ─────────────────────────────────────────────────────────────

Widget _settingsSectionHeader(String title) => Padding(
  padding: const EdgeInsets.only(top: 12, bottom: 4, left: 16),
  child: Text(title.toUpperCase(),
      style: TextStyle(fontSize: 10, color: AppColors.t38, letterSpacing: 1.1)),
);

// ── Survey Heatmap settings page ───────────────────────────────────────────────

class _ScanHeatmapPage extends StatefulWidget {
  const _ScanHeatmapPage();
  @override
  State<_ScanHeatmapPage> createState() => _ScanHeatmapPageState();
}

class _ScanHeatmapPageState extends State<_ScanHeatmapPage> {
  late double _cloudOpacity;
  late String _heatmapScheme;

  @override
  void initState() {
    super.initState();
    _cloudOpacity = kCloudOpacity;
    _heatmapScheme = kHeatmapScheme;
  }

  Future<void> _setCloudOpacity(double v) async {
    setState(() => _cloudOpacity = v);
    kCloudOpacity = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('res_cloud_opacity', v);
  }

  Future<void> _setHeatmapScheme(String s) async {
    setState(() { _heatmapScheme = s; kHeatmapScheme = s; });
    heatmapSchemeNotifier.value = s;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('heatmap_scheme', s);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(toolbarHeight: 36, title: const Text('Survey Heatmap')),
      body: ListView(children: [
        _settingsSectionHeader('Opacity'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              '${(_cloudOpacity * 100).round()}%, '
              '${_cloudOpacity < 0.3 ? "subtle" : _cloudOpacity < 0.6 ? "medium" : "bright"}',
              style: TextStyle(fontSize: 12, color: AppColors.accent),
            ),
            Row(children: [
              Text('10%', style: TextStyle(color: AppColors.t38, fontSize: 11)),
              Expanded(
                child: Slider(
                  value: _cloudOpacity,
                  min: 0.10, max: 0.90, divisions: 16,
                  activeColor: AppColors.accent,
                  label: '${(_cloudOpacity * 100).round()}%',
                  onChanged: _setCloudOpacity,
                ),
              ),
              Text('90%', style: TextStyle(color: AppColors.t38, fontSize: 11)),
            ]),
          ]),
        ),
        _settingsSectionHeader('Color Palette'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (int i = 0; i < kHeatmapSchemes.length; i++) ...[
              GestureDetector(
                onTap: () => _setHeatmapScheme(kHeatmapSchemes[i]),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: _heatmapScheme == kHeatmapSchemes[i]
                        ? AppColors.accent.withValues(alpha: 0.20)
                        : Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _heatmapScheme == kHeatmapSchemes[i]
                          ? AppColors.accent.withValues(alpha: 0.6)
                          : Colors.white12,
                    ),
                  ),
                  child: Row(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: SizedBox(
                        width: 80, height: 20,
                        child: CustomPaint(painter: _PalettePreviewPainter(palette: kHeatmapSchemes[i])),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(kHeatmapSchemeLabels[i], style: TextStyle(
                      fontSize: 13,
                      color: _heatmapScheme == kHeatmapSchemes[i] ? AppColors.accent : AppColors.t70,
                    )),
                    const Spacer(),
                    if (_heatmapScheme == kHeatmapSchemes[i])
                      Icon(Icons.check, size: 16, color: AppColors.accent),
                  ]),
                ),
              ),
            ],
            Text('Updates the current heatmap immediately.',
                style: TextStyle(fontSize: 11, color: AppColors.t38)),
          ]),
        ),
      ]),
    );
  }
}

// ── Map panels (a section of App Appearance) ─────────────────────────────────────

/// Glass (floating panels) or classic bars, and whether the top bar shows (owner 2026-10-31).
class _InterfaceSection extends StatelessWidget {
  const _InterfaceSection();

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: UiLook.all,
        builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _settingsSectionHeader('Interface'),
          SwitchListTile(
            title: const Text('Top bar'),
            subtitle: Text('Company name, Campus level and credits', style: TextStyle(fontSize: 12, color: AppColors.t54)),
            value: UiLook.showHud.value,
            onChanged: (v) => UiLook.set(hud: v),
          ),
          SwitchListTile(
            title: const Text('See-through tab bar on the map'),
            subtitle: Text('The map shows under the bottom tabs; other pages bring their own background',
                style: TextStyle(fontSize: 12, color: AppColors.t54)),
            value: UiLook.clearTabs.value,
            onChanged: (v) => UiLook.set(clear: v),
          ),
        ]),
      );
}

class _MapPanelsSection extends StatefulWidget {
  const _MapPanelsSection();
  @override
  State<_MapPanelsSection> createState() => _MapPanelsSectionState();
}

class _MapPanelsSectionState extends State<_MapPanelsSection> {
  late double _panelOpacity;

  @override
  void initState() {
    super.initState();
    _panelOpacity = kMapPanelOpacity;
  }

  Future<void> _setPanelOpacity(double v) async {
    setState(() => _panelOpacity = v);
    kMapPanelOpacity = v;
    mapPanelOpacityNotifier.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('map_panel_opacity', v);
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _settingsSectionHeader('Map Panels'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              'How see-through the panels over the map are (survey buttons, resource picker, top bar). '
              'At 100% the panels match the bottom navigation bar exactly.',
              style: TextStyle(fontSize: 12, color: AppColors.t54),
            ),
            const SizedBox(height: 12),
            Text(
              '${(_panelOpacity * 100).round()}%, '
              '${_panelOpacity >= 0.95 ? "opaque (matches nav bar)" : _panelOpacity >= 0.6 ? "semi-transparent" : "very transparent"}',
              style: TextStyle(fontSize: 12, color: AppColors.accent),
            ),
            Row(children: [
              Text('20%', style: TextStyle(color: AppColors.t38, fontSize: 11)),
              Expanded(
                child: Slider(
                  value: _panelOpacity,
                  min: 0.20, max: 1.0, divisions: 16,
                  activeColor: AppColors.accent,
                  label: '${(_panelOpacity * 100).round()}%',
                  onChanged: _setPanelOpacity,
                ),
              ),
              Text('100%', style: TextStyle(color: AppColors.t38, fontSize: 11)),
            ]),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _setPanelOpacity(0.2),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Reset to default'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.accent,
                side: BorderSide(color: AppColors.accent),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
            ),
          ]),
        ),
      ]);
  }
}

// ── Performance settings page ──────────────────────────────────────────────────

class _PerformancePage extends StatefulWidget {
  const _PerformancePage();
  @override
  State<_PerformancePage> createState() => _PerformancePageState();
}

class _PerformancePageState extends State<_PerformancePage> {
  late int _gpsInterval;
  double? _maxHz;

  Future<void> _setNoFpsLimit(bool on) async {
    final hz = await applyNoFpsLimit(on);
    if (!mounted) return;
    setState(() { kNoFpsLimit = on; _maxHz = hz; });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('no_fps_limit', on);
  }

  @override
  void initState() {
    super.initState();
    _gpsInterval = kGpsIntervalSeconds;
    applyNoFpsLimit(kNoFpsLimit).then((hz) { if (mounted) setState(() => _maxHz = hz); });
  }

  Future<void> _setGpsInterval(int seconds) async {
    setState(() { _gpsInterval = seconds; kGpsIntervalSeconds = seconds; });
    LocationService.instance.setInterval(seconds);      // how often the phone reads the location
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('gps_interval', seconds);
  }

  Future<void> _setActivity(bool on) async {
    final got = await LocationService.instance.setActivity(on);
    if (!mounted) return;
    setState(() {});
    if (on && !got) {
      AppNotify.show(context, 'Allow "Physical activity" for this app to use it', isError: true);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('gps_activity', got);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(toolbarHeight: 36, title: const Text('Performance')),
      body: ListView(children: [
        _settingsSectionHeader('Display'),
        SwitchListTile(
          dense: true,
          title: const Text('No FPS limit'),
          subtitle: Text('Run at the fastest refresh rate of the screen'
              '${_maxHz == null ? '' : ' (${_maxHz!.round()} Hz)'}. Smoother, uses more battery.',
              style: TextStyle(fontSize: 11, color: AppColors.t38)),
          value: kNoFpsLimit,
          activeColor: AppColors.accent,
          onChanged: _setNoFpsLimit,
        ),
        _settingsSectionHeader('GPS'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('GPS refresh interval',
                style: TextStyle(fontSize: 13, color: AppColors.t70)),
            const SizedBox(height: 4),
            Text(
              '$_gpsInterval second${_gpsInterval == 1 ? '' : 's'}, '
              '${_gpsInterval <= 2 ? "very frequent" : _gpsInterval <= 4 ? "balanced (recommended)" : _gpsInterval <= 9 ? "power saving" : "minimal updates"}',
              style: TextStyle(fontSize: 12, color: AppColors.accent),
            ),
            Row(children: [
              Text('1s', style: TextStyle(color: AppColors.t38, fontSize: 11)),
              Expanded(
                child: Slider(
                  value: _gpsInterval.toDouble(),
                  min: 1, max: 10, divisions: 9,
                  activeColor: AppColors.accent,
                  label: '${_gpsInterval}s',
                  onChanged: (v) => _setGpsInterval(v.round()),
                ),
              ),
              Text('10s', style: TextStyle(color: AppColors.t38, fontSize: 11)),
            ]),
            Text(
              'How often the phone reads your location (GPS, Wi-Fi, cell towers and motion sensors '
              'combined, like Google Maps). 1 s is the most precise and uses the most battery; '
              'longer saves battery, the dot still glides in between. No GPS at all while the app is '
              'in the background. For the best fix keep Google Location Accuracy and Wi-Fi scanning on.',
              style: TextStyle(fontSize: 11, color: AppColors.t38),
            ),
            if (!Branding.isPlay) ...[
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Activity recognition (best accuracy)', style: TextStyle(fontSize: 13)),
              subtitle: Text('Knows when you stand, walk or ride a bus or car and tunes the GPS for it. '
                  'Asks for the "Physical activity" permission.',
                  style: TextStyle(fontSize: 11, color: AppColors.t38)),
              value: LocationService.instance.useActivity,
              onChanged: _setActivity,
            ),
            ],
          ]),
        ),
      ]),
    );
  }
}

// ── Numbers & Display settings page ───────────────────────────────────────────

class _NumbersDisplayPage extends StatefulWidget {
  const _NumbersDisplayPage();
  @override
  State<_NumbersDisplayPage> createState() => _NumbersDisplayPageState();
}

class _NumbersDisplayPageState extends State<_NumbersDisplayPage> {
  late int _numDecimals;

  @override
  void initState() {
    super.initState();
    _numDecimals = kNumDecimals;
  }

  Future<void> _setDecimals(int d) async {
    setState(() => _numDecimals = d);
    // ignore: invalid_use_of_visible_for_testing_member
    kNumDecimals = d;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('numDecimals', d);
  }

  String _preview(int d) {
    if (d < 0) return '1,234  1,234,567  1,234,567,890';
    String fmt(double n, String suf) => '${n.toStringAsFixed(d)}$suf';
    return '${fmt(1.2345, 'K')}  ${fmt(1.2345, 'M')}  ${fmt(1.2345, 'B')}  ${fmt(1.2345, 'T')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(toolbarHeight: 36, title: const Text('Numbers')),
      body: ListView(children: [
        _settingsSectionHeader('Short numbers'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Decimal places',
                style: TextStyle(fontSize: 13, color: AppColors.t70)),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'e.g. ${_preview(_numDecimals)}',
                style: TextStyle(fontSize: 13, color: AppColors.accent,
                    fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Text('0', style: TextStyle(color: AppColors.t38, fontSize: 11)),
              Expanded(
                child: Slider(
                  value: _numDecimals < 0 ? 5 : _numDecimals.toDouble(),
                  min: 0, max: 5, divisions: 5,
                  label: _numDecimals < 0 ? 'Full' : '$_numDecimals',
                  onChanged: (v) => _setDecimals(v.round() == 5 ? -1 : v.round()),
                ),
              ),
              Text('Full', style: TextStyle(color: AppColors.t38, fontSize: 11)),
            ]),
          ]),
        ),
        _settingsSectionHeader('Market'),
        SwitchListTile(
          title: const Text('Invert ASK / BID colours'),
          subtitle: Text(kInvertAskBid ? 'ASK green · BID red' : 'ASK red · BID green',
              style: TextStyle(color: AppColors.t38, fontSize: 12)),
          value: kInvertAskBid,
          onChanged: (v) async {
            setState(() => kInvertAskBid = v);
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('invert_ask_bid', v);
          },
        ),
      ]),
    );
  }
}

// ── App Appearance settings page ───────────────────────────────────────────────


// backgrounds: black (OLED) first, default grey (blueGrey) among them
// the look a new install starts with (owner 2026-10-31): OLED black, warm white text, orange icons
const kDefaultBg = Colors.black;
const kDefaultText = Color(0xFFFFF8E1);
const kDefaultIcon = Colors.deepOrangeAccent;

const _kBgPresetColors = <Color>[
  Colors.black, Color(0xFF424242), Colors.blueGrey, Colors.brown, Colors.indigo, Colors.blue, Colors.lightBlue,
  Colors.cyan, Colors.teal, Colors.green, Color(0xFF1B5E20), Colors.lime, Colors.amber, Colors.orange,
  Colors.deepOrange, Colors.red, Color(0xFFB71C1C), Colors.pink, Colors.purple, Colors.deepPurple,
];

const _kIconPresetColors = <Color>[
  Colors.tealAccent, Colors.cyanAccent, Colors.lightBlueAccent, Colors.blueAccent, Colors.indigoAccent,
  Colors.deepPurpleAccent, Colors.purpleAccent, Colors.pinkAccent, Colors.redAccent, Colors.deepOrangeAccent,
  Colors.orangeAccent, Colors.amberAccent, Colors.yellowAccent, Colors.limeAccent, Colors.lightGreenAccent,
  Colors.greenAccent, Colors.white, Color(0xFFBDBDBD),
];

// readable text colours on dark backgrounds
const _kTextPresetColors = <Color>[
  Colors.white, Color(0xFFE0E0E0), Color(0xFFFFF8E1), Color(0xFFFFE082), Color(0xFFFFCC80),
  Color(0xFFB2DFDB), Color(0xFF80DEEA), Color(0xFFB3E5FC), Color(0xFFC5CAE9), Color(0xFFE1BEE7),
  Color(0xFFF8BBD0), Color(0xFFC8E6C9), Color(0xFFDCEDC8),
];

class _AppAppearancePage extends StatefulWidget {
  const _AppAppearancePage();
  @override
  State<_AppAppearancePage> createState() => _AppAppearancePageState();
}

class _AppAppearancePageState extends State<_AppAppearancePage> {
  Future<void> _apply() async {
    setState(() {});
    appThemeNotifier.value = _buildAppTheme();
    // screens that read AppColors directly repaint now, not only when they are reopened
    WidgetsBinding.instance.addPostFrameCallback((_) {
      void mark(Element e) { e.markNeedsBuild(); e.visitChildren(mark); }
      WidgetsBinding.instance.rootElement?.visitChildren(mark);
    });
    final prefs = await SharedPreferences.getInstance();
    Future<void> put(String key, Color? c) => c == null ? prefs.remove(key) : prefs.setInt(key, c.toARGB32());
    await put('app_bg_color', AppColors.background);
    await put('app_text_color', AppColors.text);
    await put('app_icon_color', AppColors.icon);
    await prefs.setDouble('app_bg_strength', kBgStrength);
    await prefs.setDouble('app_surface_tone', kSurfaceTone);
  }

  Future<void> _reset() async {
    AppColors.background = kDefaultBg;
    AppColors.text = kDefaultText;
    AppColors.icon = kDefaultIcon;
    kBgStrength = 0.3;
    kSurfaceTone = 0.5;
    await _apply();
  }

  Widget _swatches(Color current, List<Color> presets, void Function(Color) onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Wrap(spacing: 8, runSpacing: 8, children: [
        for (final c in presets)
          GestureDetector(
            onTap: () => onTap(c),
            child: Container(
              width: 34, height: 34,
              decoration: BoxDecoration(
                color: c, shape: BoxShape.circle,
                border: Border.all(
                    color: current.toARGB32() == c.toARGB32() ? AppColors.fg : AppColors.fg.withValues(alpha: 0.3),
                    width: current.toARGB32() == c.toARGB32() ? 3 : 1),
              ),
              child: current.toARGB32() == c.toARGB32()
                  ? Icon(Icons.check, size: 18, color: c.computeLuminance() > 0.45 ? Colors.black : Colors.white)
                  : null,
            ),
          ),
      ]),
    );
  }

  Widget _slider(String left, String right, double value, double max, ValueChanged<double> onChanged) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          Text(left, style: TextStyle(color: AppColors.t54, fontSize: 11)),
          Expanded(child: Slider(value: value, min: 0.0, max: max, divisions: 10, onChanged: onChanged)),
          Text(right, style: TextStyle(color: AppColors.t54, fontSize: 11)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(toolbarHeight: 36, title: const Text('App Appearance')),
      body: ListView(children: [
        _settingsSectionHeader('Background Colour'),
        _swatches(AppColors.bg, _kBgPresetColors, (c) { AppColors.background = c; _apply(); }),
        if (!AppColors.isBlack) ...[
          _slider('Subtle', 'Strong', kBgStrength, 0.6, (v) { kBgStrength = v; _apply(); }),
          _slider('Darker', 'Lighter', kSurfaceTone, 1.0, (v) { kSurfaceTone = v; _apply(); }),
        ] else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('Black: true black screens (saves battery on OLED displays).',
                style: TextStyle(fontSize: 11, color: AppColors.t54)),
          ),
        _settingsSectionHeader('Text Colour'),
        _swatches(AppColors.fg, _kTextPresetColors, (c) { AppColors.text = c; _apply(); }),
        _settingsSectionHeader('Icon & Symbol Colour'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('Icons, buttons, sliders and highlights.', style: TextStyle(fontSize: 11, color: AppColors.t54)),
        ),
        _swatches(AppColors.accent, _kIconPresetColors, (c) { AppColors.icon = c; _apply(); }),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton.icon(
            onPressed: _reset,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Reset to Default'),
            style: OutlinedButton.styleFrom(
              foregroundColor: cs.primary,
              side: BorderSide(color: cs.primary),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
          ),
        ),
        const _InterfaceSection(),
        const _MapPanelsSection(),
        const _FullScreenSection(),
        const SizedBox(height: 16),
      ]),
    );
  }
}

// ── Full screen (a section of App Appearance) ────────────────────────────────────

class _FullScreenSection extends StatefulWidget {
  const _FullScreenSection();
  @override
  State<_FullScreenSection> createState() => _FullScreenSectionState();
}

class _FullScreenSectionState extends State<_FullScreenSection> {
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _settingsSectionHeader('Full Screen'),
        SwitchListTile(
          title: const Text('Hide navigation bar'),
          subtitle: Text('The gesture pill or the back/home buttons. Swipe up from the bottom edge to use them.',
              style: TextStyle(fontSize: 12, color: AppColors.t54)),
          value: ScreenMode.hideNav,
          onChanged: (v) async { await ScreenMode.set(nav: v); if (mounted) setState(() {}); },
        ),
        SwitchListTile(
          title: const Text('Hide status bar'),
          subtitle: Text('Clock, battery and notification icons. Swipe down from the top edge to see them.',
              style: TextStyle(fontSize: 12, color: AppColors.t54)),
          value: ScreenMode.hideStatus,
          onChanged: (v) async { await ScreenMode.set(status: v); if (mounted) setState(() {}); },
        ),
        SwitchListTile(
          title: const Text('Map behind the status bar'),
          subtitle: Text('When the status bar shows, the map runs behind it instead of a solid strip.',
              style: TextStyle(fontSize: 12, color: AppColors.t54)),
          value: UiLook.underStatusBar.value,
          onChanged: (v) async { await UiLook.set(underStatus: v); if (mounted) setState(() {}); },
        ),
      ]);
  }
}

// ── Notifications settings page ────────────────────────────────────────────────

class _NotificationsPage extends StatefulWidget {
  const _NotificationsPage();
  @override
  State<_NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<_NotificationsPage> {
  late bool _enabled;
  // server-side kinds with a daily maximum (systems/notify.py); 0 = unlimited
  List<Map<String, dynamic>> _kinds = [];
  List<int> _choices = const [1, 3, 5, 10, 20, 50, 0];
  List<int> _thresholds = const [75];
  int _storageHigh = 75;                     // % of Central Storage that sends "filling up"

  void _apply(Map<String, dynamic> d) {
    _kinds = (d['kinds'] as List).cast<Map<String, dynamic>>();
    _choices = (d['choices'] as List).map((e) => (e as num).toInt()).toList();
    _thresholds = (d['thresholds'] as List).map((e) => (e as num).toInt()).toList();
    _storageHigh = (d['storageHigh'] as num).toInt();
  }

  Future<void> _loadKinds() async {
    final r = await GameApi.call('/api/v1/notify/prefs', context.read<PlayerProvider>().sid);
    if (!mounted || !r.ok) return;
    setState(() => _apply(r.data));
  }

  Future<void> _setKind(String kind, bool enabled, int maxPerDay) async {
    final r = await GameApi.call('/api/v1/notify/set', context.read<PlayerProvider>().sid,
        {'kind': kind, 'enabled': enabled ? 1 : 0, 'maxPerDay': maxPerDay});
    if (!mounted) return;
    if (r.ok) setState(() => _apply(r.data));
  }

  Future<void> _setStorageHigh(int percent) async {
    final r = await GameApi.call('/api/v1/notify/storage_high', context.read<PlayerProvider>().sid,
        {'percent': percent});
    if (!mounted) return;
    if (r.ok) setState(() => _apply(r.data));
  }

  @override
  void initState() {
    super.initState();
    _loadKinds();
    _enabled      = kNotifEnabled;
  }

  Future<void> _set(String key, bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, v);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(toolbarHeight: 36, title: const Text('Notifications')),
      body: ListView(children: [
        SwitchListTile(
          dense: true,
          title: const Text('Enable notifications'),
          subtitle: Text('Master on/off for all game alerts',
              style: TextStyle(fontSize: 11, color: AppColors.t38)),
          value: _enabled,
          activeColor: AppColors.accent,
          onChanged: (v) async {
            setState(() { _enabled = v; kNotifEnabled = v; });
            await _set('notif_enabled', v);
          },
        ),
        _settingsSectionHeader('Event Types'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text('Each kind can be switched off and limited per day (or Unlimited).',
              style: TextStyle(fontSize: 11, color: AppColors.t38)),
        ),
        for (final k in _kinds)
          ListTile(
            dense: true,
            title: Text(k['label'] as String),
            subtitle: Row(children: [
              Text('Per day: ', style: TextStyle(fontSize: 11, color: AppColors.t54)),
              DropdownButton<int>(
                isDense: true,
                value: (k['maxPerDay'] as num).toInt(),
                items: [for (final c in _choices) DropdownMenuItem(value: c, child: Text(c == 0 ? 'Unlimited' : '$c',
                    style: const TextStyle(fontSize: 12)))],
                onChanged: !_enabled || k['enabled'] != true ? null
                    : (v) => _setKind(k['kind'] as String, true, v ?? 0),
              ),
              if (k['kind'] == 'storage_high') ...[
                const SizedBox(width: 12),
                Text('Above: ', style: TextStyle(fontSize: 11, color: AppColors.t54)),
                DropdownButton<int>(
                  isDense: true,
                  value: _storageHigh,
                  items: [for (final t in _thresholds) DropdownMenuItem(value: t, child: Text('$t %',
                      style: const TextStyle(fontSize: 12)))],
                  onChanged: !_enabled || k['enabled'] != true ? null
                      : (v) { if (v != null) _setStorageHigh(v); },
                ),
              ],
            ]),
            trailing: Switch(
              value: _enabled && k['enabled'] == true,
              onChanged: _enabled ? (v) => _setKind(k['kind'] as String, v, (k['maxPerDay'] as num).toInt()) : null,
            ),
          ),
        const SizedBox(height: 16),

      ]),
    );
  }
}

Future<void> loadNumDecimalsPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  kNumDecimals = prefs.getInt('numDecimals') ?? 1;
  kNoFpsLimit = prefs.getBool('no_fps_limit') ?? false;
  if (kNoFpsLimit) await applyNoFpsLimit(true);
  kInvertAskBid = prefs.getBool('invert_ask_bid') ?? false;
  kCloudOpacity = (prefs.getDouble('res_cloud_opacity') ?? 0.35).clamp(0.10, 0.90);
  kShowRingLabels = prefs.getBool('show_ring_labels') ?? true;
  await loadRingLooks();
  final raw = prefs.getString('heatmap_scheme') ?? 'classic';
  kHeatmapScheme = kHeatmapSchemes.contains(raw) ? raw : 'classic';
  heatmapSchemeNotifier.value = kHeatmapScheme;
  kGpsIntervalSeconds = (prefs.getInt('gps_interval') ?? 3).clamp(1, 10);
  LocationService.intervalSeconds = kGpsIntervalSeconds;
  if (prefs.getBool('gps_activity') == true && !Branding.isPlay) {
    unawaited(LocationService.instance.setActivity(true, ask: false));   // still allowed? then on
  }
  kMapPanelOpacity = (prefs.getDouble('map_panel_opacity') ?? 0.2).clamp(0.2, 1.0);
  mapPanelOpacityNotifier.value = kMapPanelOpacity;
  kNotifEnabled       = prefs.getBool('notif_enabled')        ?? true;
  kSurfaceTone = (prefs.getDouble('app_surface_tone') ?? 0.5).clamp(0.0, 1.0);
  final bgArgb = prefs.getInt('app_bg_color'), textArgb = prefs.getInt('app_text_color'),
      iconArgb = prefs.getInt('app_icon_color');
  AppColors.background = bgArgb == null ? kDefaultBg : Color(bgArgb);
  AppColors.text = textArgb == null ? kDefaultText : Color(textArgb);
  AppColors.icon = iconArgb == null ? kDefaultIcon : Color(iconArgb);
  kBgStrength = (prefs.getDouble('app_bg_strength') ?? 0.3).clamp(0.0, 0.6);
  appThemeNotifier.value = _buildAppTheme();
}

// ── Palette color stops (v = 0-255 grayscale quality byte) ────────────────────

const _kClassicStops = <List<int>>[
  [0,   0,   0,  80],
  [26,  0,  40, 180],
  [64,  0, 180, 200],
  [115, 0, 220,  80],
  [158,220, 220,   0],
  [199,230,  90,   0],
  [230,200,  20,   0],
  [255,120,   0,   0],
];

Color paletteColorAt(int v, String palette) {
  if (v == 0) return const Color(0x00000000);
  if (palette == 'contrast') {
    return Color.fromARGB(v, v, v, v);
  }
  // Cold is a genuine reversal of Classic: dark red at low quality, dark blue at high.
  final lookupV = palette == 'cold' ? (256 - v).clamp(1, 255) : v;
  final stops = _kClassicStops;
  for (int i = 1; i < stops.length; i++) {
    if (lookupV <= stops[i][0] || i == stops.length - 1) {
      final v0 = stops[i-1][0], r0 = stops[i-1][1], g0 = stops[i-1][2], b0 = stops[i-1][3];
      final v1 = stops[i][0],   r1 = stops[i][1],   g1 = stops[i][2],   b1 = stops[i][3];
      final t = v1 > v0 ? (lookupV - v0) / (v1 - v0) : 1.0;
      return Color.fromARGB(
        v,
        (r0 + (r1 - r0) * t).round().clamp(0, 255),
        (g0 + (g1 - g0) * t).round().clamp(0, 255),
        (b0 + (b1 - b0) * t).round().clamp(0, 255),
      );
    }
  }
  return const Color(0x00000000);
}

// ── Visual palette preview painter ────────────────────────────────────────────

class _PalettePreviewPainter extends CustomPainter {
  final String palette;
  const _PalettePreviewPainter({required this.palette});

  @override
  void paint(Canvas canvas, Size size) {
    // Checkerboard background
    const sq = 4.0;
    final p1 = Paint()..color = const Color(0xFF888888);
    final p2 = Paint()..color = const Color(0xFFAAAAAA);
    for (double y = 0; y < size.height; y += sq) {
      for (double x = 0; x < size.width; x += sq) {
        final even = ((x / sq).floor() + (y / sq).floor()) % 2 == 0;
        canvas.drawRect(
          Rect.fromLTWH(x, y, math.min(sq, size.width - x), math.min(sq, size.height - y)),
          even ? p1 : p2,
        );
      }
    }
    // Gradient strips (32 steps from v=8 to v=255)
    const steps = 32;
    final sw = size.width / steps;
    for (int s = 0; s < steps; s++) {
      final v = (8 + s * 247 ~/ steps).clamp(0, 255);
      final color = paletteColorAt(v, palette);
      canvas.drawRect(
        Rect.fromLTWH(s * sw, 0, sw + 1, size.height),
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_PalettePreviewPainter old) => old.palette != palette;
}

class _BottomBarSettings extends StatefulWidget {
  final TabConfig config;
  final ValueChanged<TabConfig> onSave;
  const _BottomBarSettings({required this.config, required this.onSave});
  @override
  State<_BottomBarSettings> createState() => _BottomBarSettingsState();
}

class _BottomBarSettingsState extends State<_BottomBarSettings> {
  late List<GameTabId> _bottom;
  late List<GameTabId> _overflow;

  // Tabs that must always be in the bottom bar and cannot be moved to overflow.
  static const _kFixed = {GameTabId.map, GameTabId.warehouse};
  // Tabs that should never appear in the configurable list at all.
  static const _kHidden = {GameTabId.leaderboard};

  @override
  void initState() {
    super.initState();
    _bottom = List.of(widget.config.bottomTabs);
    // Ensure fixed tabs are always present
    for (final id in _kFixed) {
      if (!_bottom.contains(id)) _bottom.insert(0, id);
    }
    _overflow = GameTabId.values
        .where((t) => tabMeta.containsKey(t) && !_bottom.contains(t) && !_kHidden.contains(t))
        .toList();
  }

  void _moveToBottom(GameTabId id) {
    setState(() {
      _overflow.remove(id);
      _bottom.add(id);
    });
  }

  void _moveToOverflow(GameTabId id) {
    if (_kFixed.contains(id)) return; // cannot remove fixed tabs
    setState(() {
      _bottom.remove(id);
      _overflow.add(id);
    });
  }

  void _save() {
    final cfg = widget.config.withBottomTabs(_bottom);
    cfg.save();
    widget.onSave(cfg);
    popIfCurrent(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(toolbarHeight: 36),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _sectionHeader('Pinned tabs (drag to reorder)'),
        if (_bottom.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('No tabs pinned: all appear in More',
                style: TextStyle(color: AppColors.t38)),
          ),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          onReorder: (oldIndex, newIndex) {
            setState(() {
              if (newIndex > oldIndex) newIndex--;
              final item = _bottom.removeAt(oldIndex);
              _bottom.insert(newIndex, item);
            });
          },
          children: [
            for (final id in _bottom)
              ListTile(
                key: ValueKey(id),
                leading: tabMeta[id]?.iconWidget(color: AppColors.accent) ??
                    Icon(Icons.circle_outlined, color: AppColors.accent),
                title: Text(tabMeta[id]?.label ?? id.name),
                subtitle: _kFixed.contains(id)
                    ? Text('Required', style: TextStyle(fontSize: 10, color: AppColors.accent))
                    : null,
                trailing: _kFixed.contains(id)
                    ? const Icon(Icons.lock_outline, size: 18, color: Colors.white24)
                    : Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.drag_handle, color: AppColors.t38),
                        IconButton(
                          icon: Icon(Icons.arrow_downward, size: 18,
                              color: AppColors.t54),
                          tooltip: 'Remove from bar',
                          onPressed: () => _moveToOverflow(id),
                        ),
                      ]),
              ),
          ],
        ),
        const SizedBox(height: 8),
        _sectionHeader('More / overflow'),
        ..._overflow.map((id) => ListTile(
          leading: tabMeta[id]?.iconWidget(color: AppColors.t38) ?? Icon(Icons.circle_outlined, color: AppColors.t38),
          title: Text(tabMeta[id]?.label ?? id.name),
          trailing: IconButton(
            icon: Icon(Icons.arrow_upward, size: 18, color: AppColors.accent),
            tooltip: 'Pin to bar',
            onPressed: () => _moveToBottom(id),
          ),
        )),
        const SizedBox(height: 8),
        _sectionHeader('Always present'),
        ListTile(
          leading: Icon(Icons.menu, color: AppColors.t38),
          title: const Text('More'),
          subtitle: Text('Profile, settings & overflow',
              style: TextStyle(color: AppColors.t38, fontSize: 11)),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: FilledButton(
            onPressed: _save,
            child: const Text('Save'),
          ),
        ),
        const SizedBox(height: 8),
      ]),
    );
  }

  Widget _sectionHeader(String title) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 4, left: 4),
    child: Text(title.toUpperCase(),
        style: TextStyle(fontSize: 10, color: AppColors.t38, letterSpacing: 1.1)),
  );
}


// ── Account: name change and deletion (server: systems/account.py) ───────────────

class _RenameDialog extends StatefulWidget {
  const _RenameDialog();
  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  final _ctl = TextEditingController();
  Map<String, dynamic>? _info;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    GameApi.call('/api/v1/account/info', context.read<PlayerProvider>().sid).then((r) {
      if (mounted) setState(() => r.ok ? _info = r.data : _error = r.message);
    });
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    setState(() { _busy = true; _error = null; });
    final r = await GameApi.call('/api/v1/account/rename', context.read<PlayerProvider>().sid, {'name': _ctl.text.trim()});
    if (!mounted) return;
    setState(() => _busy = false);
    if (!r.ok) {
      setState(() => _error = r.message);
      return;
    }
    context.read<PlayerProvider>().refresh();
    popIfCurrent(context);
    AppNotify.show(context, 'Your company is now called ${r.data['name']}');
  }

  @override
  Widget build(BuildContext context) {
    final cost = (_info?['renameCost'] as num? ?? 0).toInt();
    final have = (_info?['credits'] as num? ?? 0).toInt();
    return AlertDialog(
      title: const Text('Change company name'),
      content: _info == null && _error == null
          ? const SizedBox(height: 60, child: Center(child: CircularProgressIndicator()))
          : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(cost == 0 ? 'Your first name change is free.'
                  : 'This change costs ꞓ${fmtNum(cost)} (you have ꞓ${fmtNum(have)}). '
                    'Every further change costs ꞓ${fmtNum(100000)} more.'),
              const SizedBox(height: 8),
              Text(_info?['rules'] as String? ?? '', style: TextStyle(fontSize: 12, color: AppColors.t60)),
              const SizedBox(height: 12),
              TextField(controller: _ctl, maxLength: 20,
                  decoration: const InputDecoration(labelText: 'New company name', border: OutlineInputBorder())),
              if (_error != null) Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ]),
      actions: [
        TextButton(onPressed: () => popIfCurrent(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy || _info == null ? null : _go, child: const Text('Change name')),
      ],
    );
  }
}

class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog();
  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  Map<String, dynamic>? _info;
  String? _error;

  @override
  void initState() {
    super.initState();
    GameApi.call('/api/v1/account/info', context.read<PlayerProvider>().sid).then((r) {
      if (mounted) setState(() => r.ok ? _info = r.data : _error = r.message);
    });
  }

  Future<void> _delete() async {
    final r = await GameApi.call('/api/v1/account/delete', context.read<PlayerProvider>().sid, {'confirm': 'DELETE'});
    if (!mounted) return;
    if (!r.ok) {
      setState(() => _error = r.message);
      return;
    }
    if (r.data['deleted'] == true) {
      await StorageService.clearHid();
      if (!mounted) return;
      context.read<PlayerProvider>().clear();
      Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const LoginScreen()), (_) => false);
    } else {
      popIfCurrent(context);
      AppNotify.show(context, 'Your company will be deleted on ${(r.data['deleteAt'] as String).substring(0, 10)}. '
          'Sign in before then to cancel.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final delayed = _info?['deletionDelayed'] == true;
    final at = _info?['deleteAt'] as String?;
    return AlertDialog(
      title: const Text('Delete account'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (at != null)
          Text('Your company is already scheduled for deletion on ${at.substring(0, 10)}. Signing in again cancels it.')
        else
          Text(delayed
              ? 'Your company and all its data (Campus, hexes, plants, storage) will be deleted in '
                '${_info?['delayDays'] ?? 30} days. Signing in during that time cancels the deletion. '
                'The company name becomes free again.'
              : 'Your company and all its data (Campus, hexes, plants, storage) will be deleted now. '
                'This cannot be undone. The company name becomes free again.'),
        if (_error != null) Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
        const SizedBox(height: 16),
        if (_info != null && at == null) HoldFilledButton(label: 'Hold 5 s to delete', onTriggered: _delete),
      ]),
      actions: [TextButton(onPressed: () => popIfCurrent(context), child: const Text('Cancel'))],
    );
  }
}



