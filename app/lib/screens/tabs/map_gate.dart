part of 'map_tab.dart';

/// The location gate: the map needs precise location, and says how to give it.
extension _MapGate on _MapTabState {
  Future<void> _checkGate() async {
    final g = await LocationService.instance.gate();
    if (mounted && g != _gate) _update(() => _gate = g);
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
}
