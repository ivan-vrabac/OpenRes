import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

/// What stands between the player and the map (owner 2026-10-31: no map without precise location;
/// approximate location moves a player kilometres for free).
enum LocationGate { ok, serviceOff, denied, deniedForever, approximate }

LocationGate locationGate(bool serviceOn, LocationPermission permission, LocationAccuracyStatus accuracy) {
  if (!serviceOn) return LocationGate.serviceOff;
  if (permission == LocationPermission.deniedForever) return LocationGate.deniedForever;
  if (permission == LocationPermission.denied || permission == LocationPermission.unableToDetermine) {
    return LocationGate.denied;
  }
  return accuracy == LocationAccuracyStatus.reduced ? LocationGate.approximate : LocationGate.ok;
}

/// One smoothed position (see [LocationService]).
class LiveFix {
  final LatLng pos;
  final double accuracy;     // m, of the smoothed position
  final double rawAccuracy;  // m, as the phone reported the last fix
  final double vx, vy;       // m/s east / north
  final DateTime at;
  final bool mock;
  const LiveFix(this.pos, this.accuracy, this.rawAccuracy, this.vx, this.vy, this.at, this.mock);

  double get speed => sqrt(vx * vx + vy * vy);
  /// Direction of travel (degrees from north), when moving fast enough to know it.
  double? get course => speed < 1.0 ? null : (atan2(vx, vy) * 180 / pi + 360) % 360;

  /// Where we are [t] after this fix, following the current velocity (at most 2 s ahead).
  LatLng predict(DateTime t) {
    final dt = (t.difference(at).inMilliseconds / 1000.0).clamp(0.0, 2.0);
    if (dt == 0 || speed < 0.2) return pos;
    return LatLng(pos.latitude + vy * dt / LocationService.mPerDegLat,
        pos.longitude + vx * dt / (LocationService.mPerDegLat * cos(pos.latitude * pi / 180)));
  }
}

/// The app's one source of position (owner 2026-10-24: the best possible GPS), shared by the map,
/// HQ screen and scans:
/// - Android's Fused Location Provider (GPS + Wi-Fi + cell + sensors, like Google Maps) at one fix
///   a second (LocationBridge.kt); geolocator where Google Play services are missing;
/// - Google's "turn on Location Accuracy" dialog when that setting is off;
/// - a Kalman filter with velocity (constant-velocity model per axis): every fix weighted by its
///   accuracy, the phone's speed and bearing used as a velocity measurement, outliers rejected,
///   and the position held still while the accelerometer says the phone isn't moving;
/// - the compass heading from Google's Fused Orientation Provider;
/// - optionally (Settings > Performance, asks for the "physical activity" permission) Google's
///   Activity Recognition: standing / walking / in a vehicle tunes the filter.
/// The phone reads the location every [intervalSeconds] (the 1-10 s GPS refresh setting: the big
/// battery saver), and nothing at all while the app is in the background.
class LocationService with WidgetsBindingObserver {
  LocationService._();
  static final instance = LocationService._();

  /// The GPS refresh setting (1-10 s): how often the phone reads the location.
  static int intervalSeconds = 3;

  static const mPerDegLat = 111320.0;
  static const _loc = EventChannel('openres/location');
  static const _head = EventChannel('openres/heading');
  static const _motion = EventChannel('openres/motion');
  static const _ctl = MethodChannel('openres/location_ctl');
  static const _activityCh = EventChannel('openres/activity');

  /// The latest smoothed fix (null until the first one).
  final fix = ValueNotifier<LiveFix?>(null);
  /// Compass heading in degrees (true north), ~20 per second.
  final heading = ValueNotifier<double?>(null);
  /// Whether the phone is moving (accelerometer); null while unknown.
  bool? moving;
  /// still / walking / running / bicycle / vehicle (Activity Recognition, when enabled).
  String? activity;
  /// Activity Recognition is on (the player enabled it and gave the permission).
  bool useActivity = false;

  StreamSubscription? _locSub, _headSub, _motionSub, _actSub;
  bool _started = false, _settingsChecked = false, _paused = false;
  /// No screen needs the location now (owner 2026-10-31: GPS only while the Map tab is open, or
  /// while a screen asks for a position): the streams are off, as in the background.
  bool _away = false;
  bool get away => _away;
  // the native bridge (LocationBridge.kt) exists on Android only; known before start()
  static bool get _native => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  final _f = _Filter();

  bool get running => _started;

  /// Shown before Android's location prompt (Google Play user data policy: prominent disclosure
  /// first, permission only after the player agrees). Returns whether to go on.
  static Future<bool> Function()? disclose;

  /// Where things stand right now; asks nothing.
  Future<LocationGate> gate() async {
    final on = await Geolocator.isLocationServiceEnabled();
    final p = await Geolocator.checkPermission();
    final granted = p == LocationPermission.whileInUse || p == LocationPermission.always;
    final a = granted ? await Geolocator.getLocationAccuracy() : LocationAccuracyStatus.unknown;
    return locationGate(on, p, a);
  }

  /// Asks Android for precise location; when it won't ask any more, opens the app's settings.
  Future<void> askPrecise() async {
    await Geolocator.requestPermission();
    if (await gate() != LocationGate.ok) await Geolocator.openAppSettings();
  }

  /// Asks for the permission (once) and starts the streams. Returns false without permission or
  /// with approximate location only.
  Future<bool> start() async {
    if (_started) return true;
    if (!await Geolocator.isLocationServiceEnabled()) {
      await _checkSettings();               // offers to switch location on
      if (!await Geolocator.isLocationServiceEnabled()) return false;
    }
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) {
      if (disclose != null && !await disclose!()) return false;
      p = await Geolocator.requestPermission();
    }
    if (p == LocationPermission.denied || p == LocationPermission.deniedForever) return false;
    if (await Geolocator.getLocationAccuracy() == LocationAccuracyStatus.reduced) return false;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_checkSettings());
    if (!_away) _listen();
    return true;
  }

  /// [away]: stop reading the location until a screen wants it again ([setAway] false).
  void setAway(bool away) {
    if (away == _away) return;
    _away = away;
    if (!_started || _paused) return;
    if (away) {
      _cancel();
    } else {
      _listen();
    }
  }

  void _listen() {
    if (_native) {
      _locSub = _loc.receiveBroadcastStream({'interval': intervalSeconds * 1000}).listen(
          (e) => _onNative((e as Map).cast<String, dynamic>()),
          onError: (_) => _fallback());
      _headSub = _head.receiveBroadcastStream().listen((e) {
        final m = (e as Map).cast<String, dynamic>();
        heading.value = (m['heading'] as num).toDouble();
      }, onError: (_) {});
      _motionSub = _motion.receiveBroadcastStream().listen((e) => moving = e as bool, onError: (_) {});
      if (useActivity) _listenActivity();
    } else {
      _fallback();
    }
  }

  void _listenActivity() {
    _actSub?.cancel();
    _actSub = _activityCh.receiveBroadcastStream().listen((e) => activity = e as String,
        onError: (_) => activity = null);
  }

  void _cancel() {
    _locSub?.cancel();
    _headSub?.cancel();
    _motionSub?.cancel();
    _actSub?.cancel();
    _locSub = _headSub = _motionSub = _actSub = null;
  }

  /// No GPS while the app is in the background (battery); straight back when it returns.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_started) return;
    if (state == AppLifecycleState.resumed && _paused) {
      _paused = false;
      if (!_away) _listen();
    } else if ((state == AppLifecycleState.paused || state == AppLifecycleState.hidden) && !_paused) {
      _paused = true;
      _cancel();
    }
  }

  /// The GPS refresh setting changed: read the location that often from now on.
  void setInterval(int seconds) {
    intervalSeconds = seconds.clamp(1, 10);
    if (!_started || _paused || _away) return;
    _cancel();
    _listen();
  }

  /// Turn Activity Recognition on (asks for the permission when [ask]) or off. Returns whether
  /// it is on.
  Future<bool> setActivity(bool on, {bool ask = true}) async {
    if (!on || !_native) {
      useActivity = false;
      activity = null;
      _actSub?.cancel();
      _actSub = null;
      return false;
    }
    bool granted = false;
    try {
      granted = await _ctl.invokeMethod<bool>('activityPermission', {'ask': ask}) ?? false;
    } catch (_) {}
    useActivity = granted;
    if (granted && _started && !_paused && !_away) _listenActivity();
    return granted;
  }

  Future<void> _checkSettings() async {
    if (_settingsChecked || kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    _settingsChecked = true;
    try {
      await _ctl.invokeMethod('checkSettings');
    } catch (_) {}
  }

  void _fallback() {
    _locSub?.cancel();
    _locSub = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(accuracy: LocationAccuracy.bestForNavigation, distanceFilter: 0,
          intervalDuration: Duration(seconds: intervalSeconds)),
    ).listen((p) => _add(p.latitude, p.longitude, p.accuracy, p.speed >= 0 ? p.speed : null,
        p.heading >= 0 ? p.heading : null, p.speedAccuracy > 0 ? p.speedAccuracy : null, null,
        DateTime.now(), p.isMocked));
  }

  void _onNative(Map<String, dynamic> m) {
    final age = (m['age'] as num? ?? 0).toInt();
    if (m['last'] != true && age > 10000) return;           // a stale fix (not for the first one)
    _add((m['lat'] as num).toDouble(), (m['lng'] as num).toDouble(), (m['acc'] as num).toDouble(),
        (m['speed'] as num?)?.toDouble(), (m['bearing'] as num?)?.toDouble(),
        (m['speedAcc'] as num?)?.toDouble(), (m['bearingAcc'] as num?)?.toDouble(),
        DateTime.now().subtract(Duration(milliseconds: age)), m['mock'] == true);
  }

  void _add(double lat, double lng, double acc, double? speed, double? bearing, double? speedAcc,
      double? bearingAcc, DateTime t, bool mock) {
    if (acc > 2000) return;                                 // no real fix
    // Activity Recognition, when on, knows better than the accelerometer whether we stand still
    final act = activity;
    final mv = act == null || act == 'unknown' ? moving : act != 'still';
    final r = _f.add(lat, lng, acc, speed, bearing, speedAcc, bearingAcc, t, mv, act == 'vehicle');
    if (r == null) return;
    fix.value = LiveFix(r.$1, r.$2, acc, r.$3, r.$4, t, mock);
  }

  void stop() {
    _cancel();
    WidgetsBinding.instance.removeObserver(this);
    _started = false;
  }

  /// For tests: feed one fix through the filter.
  @visibleForTesting
  void addForTest(double lat, double lng, double acc, double? speed, double? bearing, DateTime t,
          {bool? movingNow}) {
    moving = movingNow;
    _add(lat, lng, acc, speed, bearing, null, null, t, false);
  }
}

/// Constant-velocity Kalman filter, one [position, velocity] filter per axis (east, north), in
/// metres around a reference point.
class _Filter {
  double? _lat0, _lng0, _mx = LocationService.mPerDegLat;
  final _x = _Axis(), _y = _Axis();
  DateTime? _t;
  int _rejected = 0;

  void _reset(double lat, double lng, double acc, DateTime t) {
    _lat0 = lat;
    _lng0 = lng;
    _mx = LocationService.mPerDegLat * cos(lat * pi / 180);
    _x.reset(acc);
    _y.reset(acc);
    _t = t;
    _rejected = 0;
  }

  /// (position, accuracy, vx, vy) or null when the fix was rejected as an outlier.
  (LatLng, double, double, double)? add(double lat, double lng, double acc, double? speed, double? bearing,
      double? speedAcc, double? bearingAcc, DateTime t, bool? moving, [bool vehicle = false]) {
    acc = max(acc, 3.0);
    if (_lat0 == null || _t == null || t.difference(_t!).inSeconds > 30) {
      _reset(lat, lng, acc, t);                     // first fix, or after a long gap (tunnel, app closed)
      return _out();
    }
    final dt = max(0.0, t.difference(_t!).inMilliseconds / 1000.0);
    final mx = (lng - _lng0!) * _mx!, my = (lat - _lat0!) * LocationService.mPerDegLat;
    if (mx.abs() > 20000 || my.abs() > 20000) {     // far from the reference: start over there
      _reset(lat, lng, acc, t);
      return _out();
    }
    final fast = (speed ?? 0) > 8 || vehicle;
    // standing still only when the sensors AND the GPS speed agree: a phone lying on a seat in a
    // smooth bus or train feels still but isn't
    final still = moving == false && speed != null && speed < 0.6;
    // how much the speed may change between fixes: little standing, more walking, most driving
    final q = still ? 0.05 : fast ? 3.0 : 1.2;
    _x.predict(dt, q);
    _y.predict(dt, q);
    _t = t;
    final r = acc * acc;
    // reject a fix more than 5 sigma from where we expect to be (jumps from bad Wi-Fi/cell fixes);
    // three in a row means we really moved: accept and start over from there
    final d2 = (mx - _x.p) * (mx - _x.p) / (_x.pp + r) + (my - _y.p) * (my - _y.p) / (_y.pp + r);
    if (d2 > 25 * 2) {
      if (++_rejected >= 3) {
        _reset(lat, lng, acc, t);
        return _out();
      }
      return null;
    }
    _rejected = 0;
    _x.updatePos(mx, r);
    _y.updatePos(my, r);
    if (still) {
      _x.updateVel(0, 0.01);                        // standing still: no drift
      _y.updateVel(0, 0.01);
    } else if (speed != null && bearing != null && speed >= 0.5) {
      final b = bearing * pi / 180;
      final sa = speedAcc ?? max(0.5, speed * 0.1);
      final ba = (bearingAcc ?? 15) * pi / 180;
      final rv = sa * sa + speed * speed * ba * ba;
      _x.updateVel(speed * sin(b), rv);
      _y.updateVel(speed * cos(b), rv);
    } else if (speed != null && speed < 0.3) {
      _x.updateVel(0, 0.25);                        // the phone says it's (nearly) not moving
      _y.updateVel(0, 0.25);
    }
    return _out();
  }

  (LatLng, double, double, double) _out() => (
        LatLng(_lat0! + _y.p / LocationService.mPerDegLat, _lng0! + _x.p / _mx!),
        sqrt(_x.pp + _y.pp),
        _x.v,
        _y.v,
      );
}

class _Axis {
  double p = 0, v = 0;
  double pp = 0, pv = 0, vv = 0;                    // covariance

  void reset(double acc) {
    p = 0;
    v = 0;
    pp = acc * acc;
    pv = 0;
    vv = 4;                                         // ±2 m/s unknown at first
  }

  void predict(double dt, double q) {
    p += v * dt;
    final dt2 = dt * dt, dt3 = dt2 * dt, dt4 = dt3 * dt, q2 = q * q;
    pp += 2 * dt * pv + dt2 * vv + dt4 / 4 * q2;
    pv += dt * vv + dt3 / 2 * q2;
    vv += dt2 * q2;
  }

  void updatePos(double z, double r) {
    final s = pp + r, kp = pp / s, kv = pv / s, y = z - p;
    p += kp * y;
    v += kv * y;
    final npp = (1 - kp) * pp, npv = (1 - kp) * pv, nvv = vv - kv * pv;
    pp = npp;
    pv = npv;
    vv = nvv;
  }

  void updateVel(double z, double r) {
    final s = vv + r, kp = pv / s, kv = vv / s, y = z - v;
    p += kp * y;
    v += kv * y;
    final npp = pp - kp * pv, npv = (1 - kv) * pv, nvv = (1 - kv) * vv;
    pp = npp;
    pv = npv;
    vv = nvv;
  }
}
