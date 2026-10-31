import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../services/location_service.dart';

/// The player's position on a map, Google Maps style (owner 2026-10-24): the dot glides every
/// frame towards where the filter says we are now (following the current velocity between fixes)
/// instead of jumping once per fix, the heading comes from the compass (Fused Orientation
/// Provider) and turns smoothly (no accuracy circle, owner 2026-10-25). [onFrame] gets the shown
/// position every frame it changes, so the map can follow it just as smoothly.
class LiveLocationLayer extends StatefulWidget {
  final Widget Function(double? heading) marker;
  final double size;
  final void Function(LatLng pos)? onFrame;
  const LiveLocationLayer({super.key, required this.marker, this.size = 44, this.onFrame});

  @override
  State<LiveLocationLayer> createState() => _LiveLocationLayerState();
}

class _LiveLocationLayerState extends State<LiveLocationLayer> with SingleTickerProviderStateMixin {
  final _svc = LocationService.instance;
  late final Ticker _ticker = createTicker(_tick);
  LatLng? _shown;
  double? _head;
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _last = elapsed;
    final f = _svc.fix.value;
    if (f == null) return;
    final target = f.predict(DateTime.now());
    final a = 1 - exp(-dt * 8);                     // ~0.15 s to catch up: smooth, never laggy
    var moved = false;
    final s = _shown;
    if (s == null || (s.latitude - target.latitude).abs() > 0.01 || (s.longitude - target.longitude).abs() > 0.01) {
      _shown = target;                              // first fix or a big jump: no slide across the map
      moved = true;
    } else {
      final n = LatLng(s.latitude + (target.latitude - s.latitude) * a,
          s.longitude + (target.longitude - s.longitude) * a);
      if ((n.latitude - s.latitude).abs() > 2e-8 || (n.longitude - s.longitude).abs() > 2e-8) {
        _shown = n;
        moved = true;
      }
    }
    // compass heading; the direction of travel when there is no compass
    final h = _svc.heading.value ?? f.course;
    var turned = false;
    if (h != null) {
      final cur = _head ?? h;
      final diff = ((h - cur + 540) % 360) - 180;   // shortest way round
      final next = (cur + diff * min(1.0, dt * 10) + 360) % 360;
      if (_head == null || diff.abs() > 0.3) {
        _head = next;
        turned = true;
      }
    }
    if (moved) widget.onFrame?.call(_shown!);
    if ((moved || turned) && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = _shown;
    if (p == null || _svc.fix.value == null) return const SizedBox.shrink();
    // no accuracy circle (owner 2026-10-25: not needed)
    return MarkerLayer(markers: [
      Marker(point: p, width: widget.size, height: widget.size, child: widget.marker(_head)),
    ]);
  }
}
