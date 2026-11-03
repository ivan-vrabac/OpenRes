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
import '../../services/storage_service.dart';
import '../../models/tab_config.dart';
import '../../widgets/tutorial.dart';

part 'map_actions.dart';
part 'map_buttons.dart';
part 'map_gate.dart';
part 'map_menus.dart';
part 'map_painters.dart';
part 'map_sheets.dart';
part 'map_tutorial.dart';
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
  String _selectedMineType = 'sugar_beet';   // owner 2026-11-03: good for everyone, so the first pick   // the resource the heatmap and the build button use
                                       // (an item key, or 'solar_farm' / 'wind_farm')
  String _category = 'Agriculture';    // the picker's category
  final _categoryBtnKey = GlobalKey();
  final _resourceBtnKey = GlobalKey();
  final _surveyBtnKey = GlobalKey();
  final _buildBtnKey = GlobalKey();
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

  /// Where you are for every range decision: the same gliding position the range circle is drawn around
  /// (owner 2026-11-01: the circle, the ghost hex and the build check each used their own position, and
  /// _pos only moves at the GPS interval, so they disagreed while walking).
  LatLng? get _here => _live.value ?? _pos;

  /// A hex is in range when its centre is inside the circle: the one rule for ghost, button and build.
  bool _inBuildRange(LatLng hex) {
    final me = _here;
    return me != null && _distM(me, hex) <= _kBuildRange;
  }

  static const double _kBuildRange = 100;

  /// setState for the parts of this screen in other files.
  void _update(VoidCallback fn) => setState(fn);

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
    tutorialStart.addListener(_onTutorialStart);
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
    tutorialStart.removeListener(_onTutorialStart);
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
    _maybeTutorial();
    _onFix();
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
    if (_mapCenter != null) _crosshairDist.value = _distM(p, _mapCenter!);   // walking moves the range too
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
    _world.want(cam.visibleBounds, cam.zoom, centerLng: cam.center.longitude,
        maxAge: _survey != null ? const Duration(seconds: 5) : null);
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

  // Reload mines (smoke and markers) after a scan, keeping the scan result,
  // heatmap, prospect token and last scan position.
  void _refreshNearbyMines(LatLng scanCenter) => _world.refresh();

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
          // up and down the view stops at the map's edge (no blank background),
          // left and right the world repeats without end
          cameraConstraint: const CameraConstraint.containLatitude(85, -85),
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
              _crosshairDist.value = _distM(_here!, _mapCenter!);
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
              if (!kRingLooks['local']!.show) return const SizedBox.shrink();
              return CircleLayer(circles: [ringCircle(live ?? _pos!, _kBuildRange, 'local')]);
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
            ValueListenableBuilder<LatLng?>(valueListenable: _live, builder: (ghCtx, _, __) {
              final cam = MapCamera.of(ghCtx);
              if (cam.zoom < kHexZoom) return const SizedBox.shrink();
              // Recompute browse position from current camera centre (not stale _mapCenter).
              final camCenter = cam.center;
              // the hex you would build on: shown exactly while its centre is inside the range circle
              final placing = _placingCampus;
              final browseSnapLive = placing ? _snapCampus(camCenter) : _snapBuildPos(camCenter);
              if (!_inBuildRange(browseSnapLive)) return const SizedBox.shrink();
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
              // closed while the tutorial waits for the Campus
              ValueListenableBuilder<bool>(valueListenable: tutorialLocked, builder: (_, locked, row) => IgnorePointer(
                  ignoring: locked, child: Opacity(opacity: locked ? 0.35 : 1, child: row)), child: Row(mainAxisSize: MainAxisSize.min, children: [
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
              ])),
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
                key: _surveyBtnKey,
                child: ValueListenableBuilder<double>(valueListenable: _crosshairDist, builder: (_, liveDist, __) {
                  // the Campus goes down like a hex: the ghost at the crosshair, within 100 m of you
                  final c = _mapCenter ?? _pos;
                  if (_placingCampus) {
                    final at = c == null ? null : _snapCampus(c);
                    final inReach = at != null && _inBuildRange(at);
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
                    ValueListenableBuilder<double>(key: _buildBtnKey, valueListenable: _crosshairDist, builder: (_, __, ___) {
                    final c = _mapCenter ?? _pos;
                    final buildReady = co.hasCampus && !_movingCampus && _showMines && selectedResult != null &&
                        c != null && _inBuildRange(_snapBuildPos(c));
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

  // ── Widgets ────────────────────────────────────────────────────────────────

  /// Corners of the buttons in the panels: round like the ends of the glass pills (owner 2026-10-31).
  static const double _btnR = 18;
  static const double _innerR = 10;

}

