import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart' show Geolocator;
import 'package:latlong2/latlong.dart' hide Path;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../branding.dart';
import '../../constants.dart';
import '../../models/player_provider.dart';
import '../../ring_looks.dart';
import '../../screens/settings_screen.dart' show kCloudOpacity,
    kShowRingLabels,
    kGpsIntervalSeconds,
    kHeatmapScheme,
    kMapPanelOpacity,
    heatmapSchemeNotifier,
    mapPanelOpacityNotifier;
import '../../services/location_service.dart';
import '../../widgets/live_location_layer.dart';
import '../../widgets/glass.dart';
import '../../widgets/slide_confirm.dart';
import '../../widgets/async_view.dart' show HexPicture;
import '../../map_kit/campus_pins.dart';
import '../../map_kit/heatmap.dart';
import '../../map_kit/map_objects.dart';
import '../../map_kit/map_world.dart';
import '../../map_kit/smoke.dart';
import '../../map_kit/snap.dart';
import '../../widgets/top_banner.dart';
import '../../v3/company.dart';
import '../../v3/hex_sheet.dart';

import '../../app_colors.dart';
import '../../widgets/popups.dart';

part 'map_painters.dart';
part 'map_sheets.dart';
// ── MapTab ─────────────────────────────────────────────────────────────────────

/// The map (crosshair, ghost hex, snapping, ranges, follow, zoom levels, rings, toggles, resource
/// picker) on the redesigned game's data: hexes, Campus compounds, surveys, leases.
class MapTab extends StatefulWidget {
  const MapTab({super.key});
  @override
  State<MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<MapTab> with WidgetsBindingObserver {
  final _mapCtrl = MapController();
  LatLng? _pos;        // GPS position
  /// Where the dot is drawn right now (glides every frame; _pos only moves at the GPS interval).
  /// The rings around the player follow this one (owner 2026-10-25: they lagged behind the dot).
  final _live = ValueNotifier<LatLng?>(null);
  LatLng? _lastLoadPos; // GPS position at last _loadMarkers call
  LatLng? _mapCenter;  // Map center = crosshair target
  // Updated on every pan frame without setState — drives the live distance display.
  final _crosshairDist = ValueNotifier<double>(0.0);
  bool _following    = true;
  bool _scanning     = false;
  bool _showClouds   = false;
  bool get _showCampuses => _showMines;      // one button for hexes and Campuses (owner 2026-10-31)
  bool _showMines    = true;
  bool _movingCampus = false;                // choosing the Campus's new place
  bool _mockDetected = false;
  LocationGate? _gate;                       // null until known; the map opens only on ok

  /// Everything drawn on the map: hexes, Campuses, clouds.
  late final _world = MapWorld((path, args) => _co.call(path, args), _hexImage);
  _Survey? _survey;
  List<OverlayImage> _cachedHeatmapOverlays = [];
  String _selectedMineType = 'wood';   // the resource the heatmap and the build button use
                                       // (an item key, or 'solar_farm' / 'wind_farm')
  String _category = 'Raw ores';       // the picker's category
  final _categoryBtnKey = GlobalKey();
  final _resourceBtnKey = GlobalKey();
  double _surveyRadius = 5000;         // chosen in the survey settings (clamped by the Campus level)

  static const _kCategories = ['Raw ores', 'Forestry', 'Agriculture', 'Livestock', 'Fish', 'Power'];
  static const _kCategoryIcon = <String, IconData>{
    'Raw ores': Icons.landscape, 'Forestry': Icons.forest, 'Agriculture': Icons.grass,
    'Livestock': Icons.pets, 'Fish': Icons.set_meal, 'Power': Icons.bolt,
  };
  static const _kOpCategory = {
    'mine': 'Raw ores', 'oil_well': 'Raw ores', 'logging_camp': 'Forestry', 'farm': 'Agriculture',
    'ranch': 'Livestock', 'fish_farm': 'Fish', 'solar_farm': 'Power', 'wind_farm': 'Power',
  };

  /// Everything the picker offers: (key, operation, item, category, Campus level that unlocks it).
  List<({String key, String op, String item, String cat, int unlock})> _entries(Map<String, dynamic> raw) => [
        for (final e in raw.entries)
          if (e.key != 'electricity')
            (key: e.key, op: e.value['op'] as String, item: e.key,
             cat: _kOpCategory[e.value['op']] ?? 'Raw ores', unlock: (e.value['unlock'] as num).toInt()),
        if (raw['electricity'] != null) ...[
          (key: 'solar_farm', op: 'solar_farm', item: 'electricity', cat: 'Power',
           unlock: (raw['electricity']['unlock'] as num).toInt()),
          (key: 'wind_farm', op: 'wind_farm', item: 'electricity', cat: 'Power',
           unlock: (raw['electricity']['unlock'] as num).toInt()),
        ],
      ];

  /// A menu that grows upwards out of the button `key` (modal: only one menu at a time).
  Future<T?> _anchoredMenu<T>(GlobalKey key, List<_MenuRow<T>> rows) {
    final btn = key.currentContext?.findRenderObject() as RenderBox?;
    final screen = MediaQuery.of(context).size;
    final at = btn?.localToGlobal(Offset.zero) ?? Offset(screen.width - 60, screen.height - 90);
    final topRoom = at.dy - MediaQuery.of(context).padding.top - 16;
    final onLeft = at.dx < screen.width / 2;
    return Navigator.of(context).push<T>(PageRouteBuilder(
      opaque: false,
      barrierDismissible: true,
      barrierColor: Colors.black26,
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (ctx, anim, _) => Stack(children: [
        Positioned(
          left: onLeft ? math.max(4.0, at.dx) : null,
          right: onLeft ? null : math.max(4.0, screen.width - at.dx - 52),
          bottom: screen.height - at.dy + 6,
          child: ScaleTransition(
            alignment: onLeft ? Alignment.bottomLeft : Alignment.bottomRight,
            scale: CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(10),
              color: Theme.of(ctx).colorScheme.surfaceContainerHigh,
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: topRoom, maxWidth: screen.width - 24),
                child: IntrinsicWidth(
                  child: SingleChildScrollView(
                    reverse: true,                       // the bottom row next to the button shows first
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      for (final row in rows)
                        InkWell(
                          onTap: row.locked ? null : () => popIfCurrent(ctx, row.value),
                          child: Container(
                            color: row.selected ? AppColors.accent.withValues(alpha: 0.15) : null,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            child: Row(children: [
                              SizedBox(width: 28, height: 28, child: Opacity(opacity: row.locked ? 0.35 : 1, child: row.leading)),
                              const SizedBox(width: 10),
                              Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(row.label, style: TextStyle(
                                    color: row.locked ? AppColors.t38 : row.selected ? AppColors.accent : null)),
                                if (row.note != null)
                                  Text(row.note!, style: const TextStyle(fontSize: 10, color: Colors.orange)),
                              ]),
                              if (row.locked) ...[
                                const SizedBox(width: 8),
                                Icon(Icons.lock_outline, size: 14, color: AppColors.t38),
                              ],
                            ]),
                          ),
                        ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ]),
    ));
  }

  /// Categories; one whose first resource your Campus hasn't unlocked yet is locked.
  Future<void> _openCategoryMenu() async {
    final level = math.max(1, _co.campusLevel);
    final entries = _entries((_co.catalog['raw'] as Map?)?.cast<String, dynamic>() ?? const {});
    final pick = await _anchoredMenu<String>(_categoryBtnKey, [
      for (final c in _kCategories)
        () {
          final first = entries.where((e) => e.cat == c).map((e) => e.unlock).fold<int?>(null,
              (a, u) => a == null || u < a ? u : a) ?? 1;
          return _MenuRow(value: c, label: c, selected: c == _category, locked: first > level,
              note: first > level ? 'Unlocks at Campus $first' : null,
              leading: Icon(_kCategoryIcon[c], size: 22, color: c == _category ? AppColors.accent : AppColors.t70));
        }(),
    ]);
    if (pick == null || !mounted) return;
    final before = _category;
    setState(() => _category = pick);
    if (await _openResourceMenu() || !mounted) return;
    // no resource picked: back to the category of the resource in use
    setState(() => _category = entries.where((e) => e.key == _selectedMineType).firstOrNull?.cat ?? before);
  }

  /// The resources of the chosen category, highest unlock at the top (the cheapest next to the
  /// button); locked ones say at which Campus level they unlock. True when one was picked.
  Future<bool> _openResourceMenu() async {
    final co = _co;
    final level = math.max(1, co.campusLevel);
    final list = _entries((co.catalog['raw'] as Map?)?.cast<String, dynamic>() ?? const {})
        .where((e) => e.cat == _category).toList()
      ..sort((a, b) {
        final c = b.unlock.compareTo(a.unlock);
        return c != 0 ? c : _entryName(co, a.key).compareTo(_entryName(co, b.key));
      });
    final pick = await _anchoredMenu<String>(_resourceBtnKey, [
      for (final e in list)
        _MenuRow(value: e.key, label: _entryName(co, e.key), selected: e.key == _selectedMineType,
            locked: e.unlock > level, note: e.unlock > level ? 'Unlocks at Campus ${e.unlock}' : null,
            leading: Center(child: HexPicture(_hexImage({'item': e.item, 'op': e.op}), size: 28))),
    ]);
    if (pick == null || !mounted) return false;
    setState(() {
      _selectedMineType = pick;
      _rebuildHeatmapOverlays();
    });
    _saveLastMineType(pick);
    _colorizeAndRebuild();
    return true;
  }

  /// What the survey heatmap shows for a picker key.
  static String _surveyLayer(String key) => key == 'solar_farm' ? 'sun' : key == 'wind_farm' ? 'wind' : key;
  Timer? _worldTimer;
  Timer? _moveThrottle;
  bool _building = false;  // guard against concurrent construction taps
  ui.Image? _puff;
  DateTime _lastPosApplied = DateTime.fromMillisecondsSinceEpoch(0);
  // Palette colorization: grayscale PNGs stored in _heatmapScans; decoded+colored ui.Images here.
  Map<String, ui.Image> _colorizedImages = {};
  // Scan-in-flight flag: prevents GPS camera follow from displacing the heatmap anchor.
  bool _scanInFlight = false;

  Company get _co => context.read<Company>();

  /// The far-zoom clouds follow the Icon & Symbol colour (remade when it changes, see build).
  Color? _puffColor;
  void _makePuff() {
    final c = AppColors.accent;
    if (c == _puffColor) return;
    _puffColor = c;
    makePuffImage(c).then((img) { if (mounted && _puffColor == c) setState(() => _puff = img); });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _makePuff();
    _initLocation();
    _loadLastMineType();
    _loadMapToggles();
    heatmapSchemeNotifier.addListener(_onPaletteChanged);
    mapPanelOpacityNotifier.addListener(_onPanelOpacityChanged);
    mapFocus.addListener(_onMapFocus);
    campusMoveAsked.addListener(_onMoveAsked);
    // the map keeps itself up to date: whatever moved the camera, whatever failed (not away from the
    // Map tab); every 5 s while a survey is open, a friend's new hex can be built over for 30 s only
    _worldTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!LocationService.instance.away) _loadMarkers();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onMapFocus();
      _onMoveAsked();
      _loadMarkers();
      Future.delayed(const Duration(milliseconds: 250), () {
        if (!mounted) return;
        if (context.read<PlayerProvider>().sid.isEmpty) return;
        unawaited(_loadSurvey());
        _loadMarkers();
      });
    });
  }

  Future<void> _loadMapToggles() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _showMines = p.getBool('map_show_mines') ?? true;
    });
  }

  void _onPaletteChanged() {
    if (_survey != null && mounted) {
      for (final img in _colorizedImages.values) img.dispose();
      _colorizedImages = {};
      _colorizeAndRebuild();
    }
  }

  void _onPanelOpacityChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadLastMineType() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString('v3_last_resource');
    final radius = p.getDouble('v3_survey_radius');
    if (!mounted) return;
    setState(() {
      if (saved != null) _selectedMineType = saved;
      _category = p.getString('v3_last_category') ?? _category;
      if (radius != null) _surveyRadius = radius;
      _rebuildHeatmapOverlays();
    });
  }

  Future<void> _saveLastMineType(String item) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('v3_last_resource', item);
    await p.setString('v3_last_category', _category);
  }

  /// Survey settings: the radius (up to what the Campus allows), remembered.
  Future<void> _surveySettings() async {
    final maxR = _co.surveyMaxRadius.toDouble();
    var radius = _surveyRadius.clamp(100.0, maxR);
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) => AlertDialog(
        title: const Text('Survey settings', textAlign: TextAlign.center),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          // owner 2026-10-31: who makes the surveys and why they grow with the Campus
          Text('Surveys are made by the Government. It looks at how advanced your company is and allows '
              'bigger surveys as you grow; oddly enough, what it looks at is your Campus.',
              style: TextStyle(color: AppColors.t70, fontSize: 13)),
          const SizedBox(height: 14),
          Text('Radius: ${radius.round()} m', style: const TextStyle(fontWeight: FontWeight.bold)),
          if (maxR > 100)                    // at Campus 1 the survey is 100 m: nothing to choose
            Slider(value: radius, min: 100, max: maxR, divisions: ((maxR - 100) / 100).round().clamp(1, 100),
                onChanged: (v) => set(() => radius = v)),
          Text('Survey tax: ꞓ${fmtNum(_co.surveyTax(radius))}', style: TextStyle(color: AppColors.t70)),
          const SizedBox(height: 8),
          Text('Your Campus allows up to ${maxR.round()} m: 100 m for every Campus level (5 km at Campus 50).',
              style: TextStyle(color: AppColors.t54, fontSize: 12)),
        ]),
        actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        actions: [
          Row(children: [
            Expanded(child: OutlinedButton(onPressed: () => popIfCurrent(ctx, false), child: const Text('Cancel'))),
            const SizedBox(width: 12),
            Expanded(child: FilledButton(onPressed: () => popIfCurrent(ctx, true), child: const Text('Save'))),
          ]),
        ],
      )),
    );
    if (ok != true || !mounted) return;
    setState(() => _surveyRadius = radius);
    final p = await SharedPreferences.getInstance();
    await p.setDouble('v3_survey_radius', radius);
  }

  /// Someone asked to see a place (the activity log): centre on it, close up, and stop following GPS.
  /// The Campus screen's "Choose place": back at your position, with the 7-hex ghost at the crosshair.
  void _onMoveAsked() {
    if (!campusMoveAsked.value || !mounted) return;
    campusMoveAsked.value = false;
    final p = _pos;
    setState(() { _movingCampus = true; _following = p != null; });
    if (p != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _mapCtrl.move(p, 17);
      });
    }
  }

  void _onMapFocus() {
    final p = mapFocus.value;
    if (p == null || !mounted) return;
    mapFocus.value = null;
    setState(() { _following = false; _mapCenter = p; });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _mapCtrl.move(p, 17);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    mapFocus.removeListener(_onMapFocus);
    campusMoveAsked.removeListener(_onMoveAsked);
    _live.dispose();
    _worldTimer?.cancel();
    _moveThrottle?.cancel();
    _world.dispose();
    LocationService.instance.fix.removeListener(_onFix);
    _crosshairDist.dispose();
    heatmapSchemeNotifier.removeListener(_onPaletteChanged);
    mapPanelOpacityNotifier.removeListener(_onPanelOpacityChanged);
    for (final img in _colorizedImages.values) img.dispose();
    super.dispose();
  }

  Future<void> _initLocation() async {
    // one shared, smoothed position for the whole app (services/location_service.dart)
    LocationService.disclose ??= () async => await showAppDialog<bool>(
          context: context,
          builder: (ctx) => PopScope(
            canPop: false,
            child: AlertDialog(
              icon: Icon(Icons.location_on, size: 40, color: AppColors.accent),
              title: const Text('Your location'),
              content: const Text(
                  'OpenRes is played on a real map, so it uses your location while the app is open: to show '
                  'the map around you and to check distances when you survey, build or visit your Campus.\n\n'
                  'Your position is sent to the game server only with those actions. It is never used for '
                  'ads or sold, and it is not collected while the app is closed. Other players see only the '
                  'hexes and campuses you place, not where you are.\n\n'
                  'More in More › Privacy policy.'),
              actions: [
                TextButton(onPressed: () => popIfCurrent(ctx, false), child: const Text('Not now')),
                FilledButton(onPressed: () => popIfCurrent(ctx, true), child: const Text('Continue')),
              ],
            ),
          ),
        ) == true;
    final started = await LocationService.instance.start();
    if (!mounted) return;
    await _checkGate();
    if (!started || !mounted) return;
    LocationService.instance.fix.removeListener(_onFix);
    LocationService.instance.fix.addListener(_onFix);
    _onFix();
  }

  Future<void> _checkGate() async {
    final g = await LocationService.instance.gate();
    if (mounted && g != _gate) setState(() => _gate = g);
  }

  /// Back from Android's settings: the player may have turned precise location on or off.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final was = _gate;
    _checkGate().then((_) {
      if (mounted && _gate == LocationGate.ok && was != LocationGate.ok) _initLocation();
    });
  }

  Future<void> _fixGate() async {
    switch (_gate) {
      case LocationGate.serviceOff:
        await Geolocator.openLocationSettings();
      case LocationGate.deniedForever:
        await Geolocator.openAppSettings();
      case LocationGate.approximate:
        await LocationService.instance.askPrecise();
        await _initLocation();
      default:
        await _initLocation();
    }
  }

  /// Instead of the map while location is off, not allowed or only approximate.
  Widget _gateScreen() {
    final (title, text, button) = switch (_gate) {
      LocationGate.serviceOff => ('Turn on location', 'OpenRes is played on the real map, so the phone\'s location has to be on.', 'Open location settings'),
      LocationGate.approximate => ('Turn on precise location', 'OpenRes needs your exact position: hexes and surveys depend on where you really stand. Approximate location can be kilometres off.', 'Use precise location'),
      LocationGate.deniedForever => ('Allow precise location', 'In the app\'s settings, open Permissions, Location, choose Allow only while using the app and turn on Use precise location.', 'Open app settings'),
      _ => ('Allow precise location', 'OpenRes is played on the real map, so it needs your exact position while the app is open.', 'Allow location'),
    };
    return Positioned.fill(child: Container(
      color: AppColors.bg,
      padding: const EdgeInsets.all(32),
      child: _gate == null ? const SizedBox.shrink() : Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.location_off, size: 56, color: AppColors.accent),
        const SizedBox(height: 16),
        Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: AppColors.t70)),
        const SizedBox(height: 22),
        FilledButton(onPressed: _fixGate, child: Text(button)),
      ])),
    ));
  }

  void _onFix() {
    final f = LocationService.instance.fix.value;
    if (!mounted || f == null || _gate != LocationGate.ok) return;
    // Google Play's reviewers test on emulators with simulated GPS: their account is exempt
    if (f.mock && context.read<PlayerProvider>().player?.name != 'PlayReview') {
      setState(() => _mockDetected = true);
      return;
    }
    // the dot and the camera move every frame (LiveLocationLayer); the game's position, which
    // loads markers and is sent with actions, at the chosen GPS interval
    final now = DateTime.now();
    if (now.difference(_lastPosApplied).inSeconds < kGpsIntervalSeconds && _pos != null) return;
    _lastPosApplied = now;
    final ll = f.pos;
    setState(() {
      _pos = ll;
      _mapCenter ??= ll;
    });
    if (_lastLoadPos == null || _distM(_lastLoadPos!, ll) > 50) {
      _lastLoadPos = ll;
      _loadMarkers();
    }
  }

  /// Follow the player smoothly: the camera moves with the gliding dot (not during a scan, which
  /// would shift the heatmap anchor).
  LatLng? _camAt;
  void _followFrame(LatLng p) {
    _live.value = p;
    if (!_following || _scanInFlight || !mounted) return;
    if (_camAt != null && _distM(_camAt!, p) < 0.2) return;
    _camAt = p;
    _mapCtrl.move(p, _mapCtrl.camera.zoom);
  }

  Future<void> _colorizeAndRebuild({bool autoShow = false}) async {
    final survey = _survey;
    if (survey == null || !mounted) return;
    final what = _selectedMineType;
    if (_colorizedImages.containsKey(what)) {
      setState(() { if (autoShow) _showClouds = true; _rebuildHeatmapOverlays(); });
      return;
    }
    final r = await _co.call('/api/v3/survey/map', {'what': _surveyLayer(what)});
    if (!mounted || !r.ok) return;
    final n = (r.data['n'] as num).toInt();
    final img = await colorizeValues(base64Decode(r.data['values'] as String), n, heatmapLut(kHeatmapScheme));
    if (!mounted) { img.dispose(); return; }
    setState(() {
      _colorizedImages[what] = img;
      if (autoShow) _showClouds = true;
      _rebuildHeatmapOverlays();
    });
  }

  bool _surveyLoading = false;

  /// The company's last survey (kept by the server until the next one).
  Future<void> _loadSurvey() async {
    final sv = _co.survey;
    if (sv == null || _surveyLoading) return;
    _surveyLoading = true;
    try { await _loadSurveyNow(); } finally { _surveyLoading = false; }
  }

  Future<void> _loadSurveyNow() async {
    final r = await _co.call('/api/v3/survey/map', {'what': 'land'});
    if (!mounted || !r.ok) return;
    double d(String k) => (r.data[k] as num).toDouble();
    setState(() {
      _survey = _Survey(LatLngBounds(LatLng(d('south'), d('west')), LatLng(d('north'), d('east'))),
          LatLng(d('lat'), d('lng')), d('radius'));
    });
    await _colorizeAndRebuild(autoShow: true);
  }

  static const double _kCountryZoom = 9;

  /// Keep the view covered: cheap, only asks the server when something is missing or old.
  void _loadMarkers() {
    if (!mounted || _gate != LocationGate.ok || context.read<PlayerProvider>().sid.isEmpty) return;
    late final MapCamera cam;
    try { cam = _mapCtrl.camera; } catch (_) { return; }
    _world.want(cam.visibleBounds, cam.zoom, maxAge: _survey != null ? const Duration(seconds: 5) : null);
  }

  double _distM(LatLng a, LatLng b) {
    final lat1 = a.latitude  * math.pi / 180;
    final lat2 = b.latitude  * math.pi / 180;
    final dLat = (b.latitude  - a.latitude)  * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final h = math.sin(dLat/2)*math.sin(dLat/2) +
              math.cos(lat1)*math.cos(lat2)*math.sin(dLng/2)*math.sin(dLng/2);
    return 12742000 * math.asin(math.sqrt(h.clamp(0, 1)));
  }


  String _fmtDist(double m) {
    if (m < 1000) return '${m.round()} m';
    if (m < 10000) return '${(m / 1000).toStringAsFixed(2)} km';
    return '${(m / 1000).toStringAsFixed(1)} km';
  }

  /// Where a hex or the Campus would go at [target] (map_kit/snap.dart).
  LatLng _snapBuildPos(LatLng target) => snapBuildPos(target, [
        for (final m in _world.hexes)
          SnapHex(LatLng((m['lat'] as num).toDouble(), (m['lng'] as num).toDouble()),
              own: m['isMine'] == true, sharedOpen: _overlapOpen(m)),
      ]);

  static bool _overlapOpen(Map<String, dynamic> m) {
    if (m['isMine'] == true) return false;
    final until = m['overlapUntil'];
    return until is DateTime && until.isAfter(DateTime.now());
  }

  // the last answer: the ghost and the slider ask for the same spot every frame
  (LatLng, List<Map<String, dynamic>>, bool, LatLng)? _campusSnap;

  /// A moving Campus may overlap where it stands now.
  LatLng _snapCampus(LatLng target) {
    final c = _campusSnap;
    if (c != null && c.$1 == target && identical(c.$2, _world.hexes) && c.$3 == _movingCampus) return c.$4;
    final at = snapCampusPos(target, [
      for (final m in _world.hexes)
        if (!(_movingCampus && m['type'] == 'campuscell' && m['isMine'] == true))
          LatLng((m['lat'] as num).toDouble(), (m['lng'] as num).toDouble()),
    ]);
    _campusSnap = (target, _world.hexes, _movingCampus, at);
    return at;
  }

  bool get _placingCampus => _movingCampus || !_co.hasCampus;

  void _rebuildHeatmapOverlays() {
    final overlays = <OverlayImage>[];
    if (_showClouds && _colorizedImages.isNotEmpty && _survey != null) {
      final img = _colorizedImages[_selectedMineType];
      if (img != null) {
        overlays.add(OverlayImage(
          bounds: _survey!.bounds,
          imageProvider: UiImageProvider(img),
          opacity: kCloudOpacity,
          gaplessPlayback: true,
        ));
      }
    }
    _cachedHeatmapOverlays = overlays;
  }

  Future<void> _scan() async {
    if (_scanning) return;
    final scanCenter = _mapCenter ?? _pos;
    if (scanCenter == null) return;
    final radius = _surveyRadius.clamp(100.0, _co.surveyMaxRadius.toDouble());
    _scanInFlight = true; // blocks GPS camera follow until the overlay is ready
    setState(() => _scanning = true);
    final res = await _co.call('/api/v3/survey',
        {'lat': scanCenter.latitude, 'lng': scanCenter.longitude, 'radius': radius.round()});
    if (!mounted) { _scanInFlight = false; return; }
    if (!res.ok) {
      _scanInFlight = false;
      setState(() => _scanning = false);
      _snack(res.message ?? 'Survey failed', error: true);
      return;
    }
    final old = Map<String, ui.Image>.from(_colorizedImages);
    setState(() => _colorizedImages = {});
    for (final img in old.values) img.dispose();
    try {
      await _co.refresh();
      await _loadSurvey();
      // the map may have started loading it first: the slider waits for the picture either way
      while (_surveyLoading && mounted) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    } finally {
      _scanInFlight = false;
      if (mounted) setState(() => _scanning = false);   // only now the slider goes back
    }
    if (mounted) _refreshNearbyMines(scanCenter);
  }

  // Reload mines (smoke and markers) after a scan, keeping the scan result,
  // heatmap, prospect token and last scan position.
  void _refreshNearbyMines(LatLng scanCenter) => _world.refresh();

  Future<void> _buildMine(Map<String, dynamic> r,
      {LatLng? buildAt, LatLng? curPos}) async {
    if (_building) return;
    final target = buildAt ?? _snapBuildPos(_mapCenter ?? _pos!);
    setState(() { _building = true; });
    final res = await _co.call('/api/v3/hex/build', {
      'lat': target.latitude, 'lng': target.longitude,
      'plat': curPos?.latitude ?? _pos?.latitude, 'plng': curPos?.longitude ?? _pos?.longitude,
      'op': r['op'], 'item': r['item'],
    });
    if (!mounted) return;
    setState(() { _building = false; });
    if (!res.ok) {
      _snack(res.message ?? 'Build failed', error: true);
    } else {
      _snack('${_co.itemName(r['item'] as String)} built!');
      _world.addLocal({'lat': target.latitude, 'lng': target.longitude, 'type': 'mine', 'isMine': true,
          'op': r['op'], 'item': r['item'], 'wip': true});
      _co.refresh();
      _world.refresh();
    }
  }

  void _snack(String msg, {bool error = false}) =>
      AppNotify.show(context, msg, isError: error);

  /// Another player's hex or Campus under the tap: what it is.
  void _onForeignTap(LatLng tapped) {
    Map<String, dynamic>? best;
    double bestD = double.infinity;
    for (final m in _showMines ? _world.hexes : const <Map<String, dynamic>>[]) {
      if (m['type'] != 'mine' || m['isMine'] == true || m['wip'] == true) continue;
      final d = _distM(tapped, LatLng((m['lat'] as num).toDouble(), (m['lng'] as num).toDouble()));
      if (d <= 15 && d < bestD) { best = m; bestD = d; }
    }
    if (best != null) {
      _snack('${_co.itemName(best['item'] as String? ?? '')} · ${_co.opName(best['op'] as String? ?? '')} of another company');
      return;
    }
    if (_showCampuses && _mapCtrl.camera.zoom >= kHexZoom) {
      for (final m in _world.moves) {
        final d = _distM(tapped, LatLng((m['lat'] as num).toDouble(), (m['lng'] as num).toDouble()));
        if (d <= 40) { _snack('${m['name']} · Campus moving here'); return; }
      }
      for (final h in _world.campuses) {
        final d = _distM(tapped, LatLng((h['lat'] as num).toDouble(), (h['lng'] as num).toDouble()));
        if (d <= 40) { _snack('${h['name']} · Campus level ${h['level']}'); return; }
      }
    }
  }

  Future<void> _onMapTap(LatLng tapped) async {
    if (!_showMines) {          // hidden hexes can't be tapped; Campuses only when shown
      _onForeignTap(tapped);
      return;
    }
    if (await _pickFromStack(tapped)) return;
    // own hex within 15 m, the closest one
    Map<String, dynamic>? best;
    double bestD = 15;
    for (final m in _world.hexes) {
      if (m['type'] != 'mine' || m['isMine'] != true || m['id'] == null) continue;
      final d = _distM(tapped, LatLng((m['lat'] as num).toDouble(), (m['lng'] as num).toDouble()));
      if (d <= bestD) { bestD = d; best = m; }
    }
    if (best == null) { _onForeignTap(tapped); return; }
    _openOwnHex((best['id'] as num).toInt());
  }

  void _openOwnHex(int id) {
    showHexSheet(context, id).then((_) {
      if (mounted) _world.refresh();
    });
  }

  static String _entryName(Company co, String key) =>
      key == 'solar_farm' ? 'Solar farm' : key == 'wind_farm' ? 'Wind farm' : co.itemName(key);

  static String _hexImage(Map<String, dynamic> m) {
    final item = m['item'] as String? ?? '';
    return item == 'electricity' ? operationPicture(m['op'] as String? ?? '') : itemPicture(item);
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (AppColors.accent != _puffColor) WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _makePuff(); });
    final center     = _pos ?? const LatLng(45.815, 15.982);

    final co         = context.watch<Company>();
    // the company's data can arrive after the map opened: show its last survey as soon as it does
    if (_survey == null && co.survey != null && !_surveyLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _loadSurvey(); });
    }

    // every hex product, highest unlock level at the top (like 0.2), then by name
    final raw = (co.catalog['raw'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    final entries = _entries(raw);
    final sel = entries.where((e) => e.key == _selectedMineType).firstOrNull;
    final scanRadius = _surveyRadius.clamp(100.0, co.surveyMaxRadius.toDouble());
    final scanCost = co.surveyTax(scanRadius);
    final selectedResult = sel != null ? <String, dynamic>{'item': sel.item, 'op': sel.op} : null;


    return Stack(children: [

      // ── Flutter Map ────────────────────────────────────────────────────────
      FlutterMap(
        mapController: _mapCtrl,
        options: MapOptions(
          initialCenter: center,
          initialZoom: 15,
          minZoom: 3,
          maxZoom: 19,
          backgroundColor: const Color(0xFF343434),
          // contain (not containCenter) constrains the VIEWPORT edges — the user
          // can never scroll past the tile coverage area and see the blank background.
          cameraConstraint: CameraConstraint.contain(
            bounds: LatLngBounds(
              const LatLng(-85, -180),
              const LatLng(85,   180),
            ),
          ),
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.all & ~InteractiveFlag.rotate & ~InteractiveFlag.doubleTapZoom,
          ),
          onPositionChanged: (camera, hasGesture) {
            double lat = camera.center.latitude;
            double lng = camera.center.longitude;
            while (lng >  180) lng -= 360;
            while (lng < -180) lng += 360;
            _mapCenter = LatLng(lat, lng);
            if (_pos != null) {
              _crosshairDist.value = _distM(_pos!, _mapCenter!);
            }
            // the map layers read the camera themselves: a pan or a pinch rebuilds only them
            if (hasGesture && _following && mounted) setState(() => _following = false);
            // asks for what the view is missing while moving, at most 4 times a second
            _moveThrottle ??= Timer(const Duration(milliseconds: 250), () {
              _moveThrottle = null;
              _loadMarkers();
            });
          },
          onTap: (tapPos, latLng) {
            final far = _showCampuses && tapPos.relative != null && _mapCtrl.camera.zoom < _kCountryZoom;
            final c = far ? campusPinAt(_world.topCampuses, _mapCtrl.camera, tapPos.relative!) : null;
            if (c == null) { _onMapTap(latLng); return; }
            setState(() => _following = false);
            _mapCtrl.move(LatLng((c['lat'] as num).toDouble(), (c['lng'] as num).toDouble()), 16);
            _snack('${c['name']} · Campus level ${c['level']}');
          },
        ),
        children: [

          // Dark greyscale OSM tiles
          ColorFiltered(
            colorFilter: const ColorFilter.matrix([
              -0.2126, -0.7152, -0.0722, 0, 255,
              -0.2126, -0.7152, -0.0722, 0, 255,
              -0.2126, -0.7152, -0.0722, 0, 255,
                    0,       0,       0, 1,   0,
            ]),
            child: TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: Branding.appId,
              maxNativeZoom: 19,
            ),
          ),

          // Rings around the player (owner 2026-10-24): look per ring in Settings › Scan Rings
          // (show, colour, opacity, fill); building rings only with the building.
          if (_pos != null) ...[
            ValueListenableBuilder<LatLng?>(valueListenable: _live, builder: (ctx, live, _) {
              final me = live ?? _pos!;
              final rings = <(String, double, String)>[
                ('local', 100.0, 'Build range'),
              ];
              rings.removeWhere((r) => !kRingLooks[r.$1]!.show);
              final refLat = me.latitude * math.pi / 180;
              // the live camera zoom (the tab's own copy can lag while pinching)
              final ppm = (256 * math.pow(2, MapCamera.of(ctx).zoom)) /
                  (40075017.0 * math.cos(refLat).abs().clamp(0.001, 1.0));
              // labels never overlap (owner 2026-10-24): each one sits on its ring at the first angle
              // (top, bottom, the diagonals, the sides) where it doesn't touch a label already placed
              final placed = <Rect>[];
              final labels = <Marker>[];
              const angles = [90.0, 270.0, 60.0, 120.0, 240.0, 300.0, 30.0, 150.0, 210.0, 330.0, 0.0, 180.0];
              for (final r in [...rings]..sort((a, b) => a.$2.compareTo(b.$2))) {
                final rpx = r.$2 * ppm;
                if (!kShowRingLabels || rpx <= 40) continue;
                final w = r.$3.length * 5.2 + 8, h = 13.0;
                for (final deg in angles) {
                  final a = deg * math.pi / 180;
                  final rect = Rect.fromCenter(center: Offset(rpx * math.cos(a), -rpx * math.sin(a)), width: w, height: h);
                  if (placed.any((p) => p.inflate(2).overlaps(rect))) continue;
                  placed.add(rect);
                  labels.add(Marker(
                    point: LatLng(me.latitude + r.$2 * math.sin(a) / 111320.0,
                        me.longitude + r.$2 * math.cos(a) / (111320.0 * math.cos(refLat).abs().clamp(0.001, 1.0))),
                    width: w, height: h,
                    child: Center(child: Text(r.$3, maxLines: 1, style: TextStyle(color: kRingLooks[r.$1]!.color, fontSize: 9,
                        shadows: const [Shadow(color: Colors.black, blurRadius: 2)]))),
                  ));
                  break;
                }
              }
              return Stack(children: [
                CircleLayer(circles: [for (final r in rings) ringCircle(me, r.$2, r.$1)]),
                if (labels.isNotEmpty) MarkerLayer(markers: labels),
              ]);
            }),
            // TC scan ring around the crosshair: reads the live camera every frame (plain pans
            // don't rebuild the map tab, so a ring placed from _mapCenter would stay behind)
            Builder(builder: (ctx) {
              final cam = MapCamera.of(ctx);
              final c = cam.center;
              final d = _distM(_live.value ?? _pos!, c);
              if (!kRingLooks['scan']!.show) return const SizedBox.shrink();
              if (!co.hasCampus || d.isNaN) return const SizedBox.shrink();
              return CircleLayer(circles: [ringCircle(c, scanRadius, 'scan')]);
            }),
          ],

          // Accumulated scan heatmap — stable cached list, rebuilt only when scan data changes.
          if (_cachedHeatmapOverlays.isNotEmpty)
            OverlayImageLayer(overlayImages: _cachedHeatmapOverlays),

          // Far out hexes and Campuses are clouds, up close they are one layer
          if (_showMines)
            ListenableBuilder(listenable: _world, builder: (ctx, _) {
              final cam = MapCamera.of(ctx);
              return Stack(children: [
                if (cam.zoom < kHexZoom)
                  CustomPaint(
                    painter: SmokePainter(data: _world.smoke, puff: _puff, center: cam.center, zoom: cam.zoom),
                    size: Size.infinite,
                  ),
                MapObjectsLayer(world: _world, frame: _kFrame, accent: AppColors.accent),
              ]);
            }),

          // Ghost hex — uses live MapCamera so position and size stay correct during pan/zoom.
          if (_showMines || _placingCampus)
            Builder(builder: (ghCtx) {
              final cam = MapCamera.of(ghCtx);
              if (cam.zoom < kHexZoom) return const SizedBox.shrink();
              // Recompute browse position from current camera centre (not stale _mapCenter).
              final camCenter = cam.center;
              final distCam = _pos != null ? _distM(_pos!, camCenter) : double.infinity;
              // the hex you would build on: within 100 m of you
              final placing = _placingCampus;
              final browseSnapLive = distCam > 100 ? null : placing ? _snapCampus(camCenter) : _snapBuildPos(camCenter);
              if (browseSnapLive == null) return const SizedBox.shrink();
              final refLat = camCenter.latitude * math.pi / 180;
              final ppm = (256 * math.pow(2, cam.zoom)) /
                  (40075017.0 * math.cos(refLat).abs().clamp(0.001, 1.0));
              if (placing) {
                return MarkerLayer(markers: [
                  Marker(
                    point: browseSnapLive,
                    width: kCampusWidthM * ppm,
                    height: kCampusHeightM * ppm,
                    alignment: Alignment.center,
                    child: CustomPaint(painter: CampusGhostPainter(ppm: ppm, color: Colors.white.withValues(alpha: 0.7))),
                  ),
                ]);
              }
              final ghostPx = (2 * 15.0 * ppm).clamp(4.0, 200.0);
              return MarkerLayer(markers: [
                Marker(
                  point: browseSnapLive,
                  width: ghostPx,
                  height: ghostPx * 0.866,
                  alignment: Alignment.center,
                  child: CustomPaint(painter: _HexOutlinePainter(color: Colors.white.withValues(alpha: 0.5))),
                ),
              ]);
            }),
          // far out: a pin on the spot of the biggest Campus of each country
          if (_showCampuses)
            ListenableBuilder(listenable: _world, builder: (ctx, _) {
              final cam = MapCamera.of(ctx);
              if (cam.zoom >= _kCountryZoom || _world.topCampuses.isEmpty) return const SizedBox.shrink();
              return CampusPins(campuses: _world.topCampuses, camera: cam, accent: AppColors.accent);
            }),
          // GPS position: glides between fixes, compass heading, accuracy circle
          LiveLocationLayer(
            marker: (h) => CustomPaint(painter: _PosCrosshairPainter(headingDeg: h)),
            onFrame: _followFrame,
          ),
        ],
      ),

      // ── Thin red crosshair ─────────────────────────────────────────────────
      const Positioned.fill(
        child: IgnorePointer(
          child: Center(
            child: SizedBox(
              width: 20, height: 20,
              child: CustomPaint(painter: _CrosshairPainter()),
            ),
          ),
        ),
      ),

      // ── Top control bar ─────────────────────────────────────────────────────
      Positioned(
        top: MediaQuery.of(context).padding.top,
        left: 0, right: 0,
        child: MapPanel(
          height: 42,
          radius: 21,                                   // a pill: the round buttons sit in its ends
          padding: const EdgeInsets.symmetric(horizontal: 1),
          margin: const EdgeInsets.fromLTRB(8, 0, 8, 0),
          child: Row(
            children: [
              const SizedBox(width: 4),
              // Scan/heatmap visibility toggle — no-op when no scan available
              _mapBtnW(
                Icon(Icons.satellite_alt, size: 20, color: _showClouds ? Colors.white : AppColors.accent),
                () {
                  if (!_showClouds && _survey == null) return;
                  setState(() { _showClouds = !_showClouds; _rebuildHeatmapOverlays(); });
                },
                active: _showClouds, tip: 'Heatmap',
              ),
              const SizedBox(width: 4),
              // hexes and Campuses (a Campus is a hex too) shown or hidden together
              _mapBtnW(
                CustomPaint(
                  painter: _HexIconPainter(
                    color: _showMines ? Colors.white : AppColors.accent),
                ),
                () async {
                  setState(() => _showMines = !_showMines);
                  final p = await SharedPreferences.getInstance();
                  await p.setBool('map_show_mines', _showMines);
                },
                active: _showMines, tip: 'Hexes and Campuses',
              ),
              const Spacer(),
              // Navigation
              _mapBtn(Icons.my_location, () {
                setState(() => _following = true);
                if (_pos != null) _mapCtrl.move(_pos!, 15);
              }, active: _following, tip: 'My location'),
              const SizedBox(width: 8),
              // Zoom
              _mapBtn(Icons.add, () {
                final z = (_mapCtrl.camera.zoom + 1).clamp(3.0, 19.0);
                _mapCtrl.move(_mapCtrl.camera.center, z);
              }, tip: 'Zoom in'),
              const SizedBox(width: 4),
              _mapBtn(Icons.remove, () {
                final z = (_mapCtrl.camera.zoom - 1).clamp(3.0, 19.0);
                _mapCtrl.move(_mapCtrl.camera.center, z);
              }, tip: 'Zoom out'),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),

      // ── Distance display ─────────────────────────────────────────────────────
      if (_pos != null && _mapCenter != null)
        Positioned(
          bottom: MediaQuery.of(context).padding.bottom + 90,
          left: 8,
          child: IgnorePointer(
            child: ValueListenableBuilder<double>(
              valueListenable: _crosshairDist,
              builder: (ctx, dist, _) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: Theme.of(ctx).colorScheme.surface.withValues(alpha: kMapPanelOpacity.clamp(0.0, 1.0)),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _fmtDist(dist),
                  style: TextStyle(color: AppColors.t70, fontSize: 11),
                ),
              ),
            ),
          ),
        ),

      // ── Map data attribution (required by the OSM tile usage policy) ─────────
      Positioned(
          bottom: MediaQuery.of(context).padding.bottom + 90,
          right: 8,
          child: IgnorePointer(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text('© OpenStreetMap contributors',
                  style: TextStyle(color: AppColors.t54, fontSize: 9)),
            ),
          ),
        ),

      // ── Bottom panel (scan + build) ─────────────────────────────────────────
      Positioned(
        bottom: MediaQuery.of(context).padding.bottom, left: 0, right: 0,
        child: MapPanel(
          margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          padding: const EdgeInsets.all(6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [

              // ── Left: the resource of the chosen category ───────────────
              SizedBox(
                key: _resourceBtnKey,
                width: 52,
                height: 66,
                child: GestureDetector(
                  onTap: _openResourceMenu,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.07),
                      borderRadius: BorderRadius.circular(_innerR),
                    ),
                    child: Center(
                      child: sel != null
                          ? HexPicture(_hexImage({'item': sel.item, 'op': sel.op}), size: 42)
                          : Icon(Icons.terrain, size: 22, color: AppColors.t70),
                    ),
                  ),
                ),
              ),

              const SizedBox(width: 8),

              // ── Survey categories (same style as the settings button) ─────────
              SizedBox(
                key: _categoryBtnKey,
                width: 52, height: 66,
                child: Material(
                  color: Colors.white.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(_innerR),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(_innerR),
                    onTap: _openCategoryMenu,
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(_kCategoryIcon[_category], size: 20, color: AppColors.accent),
                      const SizedBox(height: 2),
                      Text(_category, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 9, color: AppColors.t54)),
                    ]),
                  ),
                ),
              ),

              const SizedBox(width: 8),

              // ── Center: scan button ───────────────────────────────────────
              Expanded(
                child: ValueListenableBuilder<double>(valueListenable: _crosshairDist, builder: (_, liveDist, __) {
                  // the Campus goes down like a hex: the ghost at the crosshair, within 100 m of you
                  final c = _mapCenter ?? _pos;
                  if (_placingCampus) {
                    final at = c == null ? null : _snapCampus(c);
                    final inReach = _pos != null && at != null && _distM(_pos!, at) <= 100;
                    final now = co.campus;
                    final same = _movingCampus && at != null && now != null &&
                        _distM(at, LatLng((now['lat'] as num).toDouble(), (now['lng'] as num).toDouble())) < 1;
                    return SlideToConfirm(
                      label: _movingCampus ? 'Move here' : 'Place here',
                      sublabel: _pos == null ? 'No location yet' : !inReach ? 'Too far' : same ? 'Already here' : '7 hexes',
                      icon: Icons.apartment,
                      enabled: inReach && !same,
                      radius: _innerR,
                      onConfirm: _placeCampus,
                    );
                  }
                  // a survey can go anywhere (at the crosshair)
                  // slide to survey (a safety switch: a stray tap can't spend credits; owner 2026-10-31)
                  return SlideToConfirm(
                    label: 'Survey here',
                    sublabel: 'ꞓ${fmtNum(scanCost)}',
                    icon: Icons.satellite_alt,
                    enabled: !_scanning,
                    busy: _scanning,
                    radius: _innerR,
                    onConfirm: _scan,
                  );
                }),
              ),

              const SizedBox(width: 8),

              // ── Survey settings: the radius (limited by the Campus level), remembered ──
              SizedBox(
                width: 44, height: 66,
                child: Material(
                  color: Colors.white.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(_innerR),
                  child: InkWell(
                    onTap: _movingCampus ? () => setState(() => _movingCampus = false)
                        : co.hasCampus ? _surveySettings : null,
                    borderRadius: BorderRadius.circular(_innerR),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(_movingCampus ? Icons.close : Icons.tune, size: 20,
                          color: co.hasCampus ? AppColors.accent : Colors.white24),
                      const SizedBox(height: 2),
                      Text(_movingCampus ? 'Cancel'
                          : scanRadius >= 1000 ? '${(scanRadius / 1000).toStringAsFixed(1)} km' : '${scanRadius.round()} m',
                          style: TextStyle(fontSize: 9, color: AppColors.t54)),
                    ]),
                  ),
                ),
              ),

              const SizedBox(width: 8),

              // ── Right, near the thumb: coords + build ─────────────────────────────────
              SizedBox(
                width: 52,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Coordinates copy button — always copies the crosshair position
                    GestureDetector(
                      onTap: () {
                        final pos = _mapCenter ?? _pos;
                        if (pos == null) return;
                        final coords =
                            '${pos.latitude.toStringAsFixed(6)},${pos.longitude.toStringAsFixed(6)}';
                        Clipboard.setData(ClipboardData(text: coords));
                        _snack('Copied');
                      },
                      child: Container(
                        height: 26,
                        decoration: BoxDecoration(
                          color: AppColors.accent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(_innerR),
                          border: Border.all(color: AppColors.accent.withValues(alpha: 0.5)),
                        ),
                        child: Center(
                          child: Icon(Icons.location_pin, size: 14, color: AppColors.accent),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    // Build icon: in range is checked live as the crosshair moves
                    ValueListenableBuilder<double>(valueListenable: _crosshairDist, builder: (_, __, ___) {
                    final c = _mapCenter ?? _pos;
                    final liveDist = (_pos != null && c != null) ? _distM(_pos!, _snapBuildPos(c)) : double.infinity;
                    final buildReady = co.hasCampus && !_movingCampus && _showMines && selectedResult != null && liveDist <= 100;
                    return GestureDetector(
                      onTap: buildReady ? () => _showBuildDialog(selectedResult) : null,
                      child: Container(
                        height: 36, width: 52,
                        decoration: BoxDecoration(
                          color: buildReady
                              ? Colors.amber.withValues(alpha: 0.15)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(_innerR),
                          border: buildReady
                              ? Border.all(color: Colors.amber.withValues(alpha: 0.6))
                              : Border.all(color: Colors.white12),
                        ),
                        child: Stack(alignment: Alignment.center, children: [
                          Icon(Icons.construction, size: 22,
                              color: buildReady ? Colors.amber : Colors.white24),
                        ]),
                      ),
                    );
                    }),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),

      // ── No precise location: no map ──
      if (_gate != LocationGate.ok) _gateScreen(),

      // ── GPS mock/spoof blocker ──────────────────────────────────────────────
      if (_mockDetected)
        Positioned.fill(
          child: Container(
            color: Colors.black,
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.gps_off, color: Colors.redAccent, size: 64),
                    SizedBox(height: 16),
                    Text('Cheating Not Allowed',
                        style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 20,
                            fontWeight: FontWeight.bold)),
                    SizedBox(height: 12),
                    Text(
                      'A GPS emulator or location spoofer has been detected.\n\n'
                      'If you are not cheating, please clear the app cache or reinstall.',
                      style: TextStyle(color: AppColors.t70, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
    ]);
  }

  /// The Campus goes on the ghost at the crosshair, like a hex.
  Future<void> _placeCampus() async {
    final me = _pos, c = _mapCenter ?? _pos;
    if (me == null || c == null) { _snack('Waiting for your location…', error: true); return; }
    final moving = _movingCampus;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(moving ? 'Move your Campus here?' : 'Place your Campus here?'),
        actionsAlignment: MainAxisAlignment.center,
        content: Text(moving
            ? 'Your Campus moves to these 7 hexes. The move takes 24 hours. Plants pause until it is '
                'finished, hexes keep producing, and you can cancel it at any time before then. The next '
                'move is possible 30 days after this one is finished.'
            : 'Your Campus takes these 7 hexes. You can move it once a month.'),
        actions: [
          TextButton(onPressed: () => popIfCurrent(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => popIfCurrent(ctx, true), child: Text(moving ? 'Move here' : 'Place it')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final at = _snapCampus(c);
    final r = await _co.call(moving ? '/api/v3/campus/move' : '/api/v3/campus/place',
        {'lat': at.latitude, 'lng': at.longitude, 'plat': me.latitude, 'plng': me.longitude});
    if (!mounted) return;
    if (!r.ok) { _snack(r.message ?? 'Could not place it', error: true); return; }
    _snack(moving ? 'Campus move started: 24 hours' : 'Campus placed. Welcome to OpenRes!');
    setState(() => _movingCampus = false);
    await _co.refresh();
    _world.refresh();
  }

  // ── Widgets ────────────────────────────────────────────────────────────────

  /// Corners of the buttons in the panels: round like the ends of the glass pills (owner 2026-10-31).
  static const double _btnR = 18;
  static const double _innerR = 10;

  Widget _mapBtn(IconData icon, VoidCallback onTap, {bool active = false, String? tip}) {
    final w = Material(
      color: active ? AppColors.accentDark : Colors.white.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(_btnR),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(_btnR),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: 20,
              color: active ? Colors.white : AppColors.accent),
        ),
      ),
    );
    return tip != null ? Tooltip(message: tip, child: w) : w;
  }

  Widget _mapBtnW(Widget iconWidget, VoidCallback onTap, {bool active = false, String? tip}) {
    final w = Material(
      color: active ? AppColors.accentDark : Colors.white.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(_btnR),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(_btnR),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: SizedBox(width: 20, height: 20, child: iconWidget),
        ),
      ),
    );
    return tip != null ? Tooltip(message: tip, child: w) : w;
  }

}

