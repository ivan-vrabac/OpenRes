import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;

const double _pinW = 12, _pinH = 17;

LatLng _pos(Map<String, dynamic> c) => LatLng((c['lat'] as num).toDouble(), (c['lng'] as num).toDouble());

/// The Campus whose pin is under a point on the screen (within a finger's reach), if any.
Map<String, dynamic>? campusPinAt(List<Map<String, dynamic>> campuses, MapCamera cam, Offset point) {
  Map<String, dynamic>? best;
  var bestD = 20.0;
  for (final c in campuses) {
    final s = cam.latLngToScreenPoint(_pos(c));
    final d = (Offset(s.x, s.y - _pinH / 2) - point).distance;       // the middle of the pin
    if (d < bestD) { bestD = d; best = c; }
  }
  return best;
}

/// The far map (owner 2026-10-31): a pin with its tip on the exact spot of each Campus of
/// [campuses] (biggest first), yours in [accent].
class CampusPins extends StatelessWidget {
  final List<Map<String, dynamic>> campuses;
  final MapCamera camera;
  final Color accent;
  const CampusPins({super.key, required this.campuses, required this.camera, required this.accent});

  @override
  Widget build(BuildContext context) => CustomPaint(
      size: Size.infinite, painter: _PinPainter(campuses, camera, accent));
}

class _PinPainter extends CustomPainter {
  final List<Map<String, dynamic>> campuses;
  final MapCamera cam;
  final Color accent;
  _PinPainter(this.campuses, this.cam, this.accent);

  static final Path _pin = () {
    const r = _pinW / 2;
    return Path()
      ..moveTo(0, 0)
      ..quadraticBezierTo(-r, -_pinH * 0.45, -r, -_pinH + r)
      ..arcToPoint(const Offset(r, -_pinH + r), radius: const Radius.circular(r))
      ..quadraticBezierTo(r, -_pinH * 0.45, 0, 0)
      ..close();
  }();

  @override
  bool? hitTest(Offset position) => false;

  @override
  void paint(Canvas canvas, Size size) {
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.black87;
    // the biggest last, on top; yours above them all
    final order = [...campuses.reversed.where((c) => c['own'] != true), ...campuses.where((c) => c['own'] == true)];
    for (final c in order) {
      final s = cam.latLngToScreenPoint(_pos(c));
      if (s.x < -_pinW || s.x > size.width + _pinW || s.y < 0 || s.y > size.height + _pinH) continue;
      canvas.save();
      canvas.translate(s.x, s.y);
      canvas.drawPath(_pin, edge);
      canvas.drawPath(_pin, Paint()..color = c['own'] == true ? accent : Colors.white);
      canvas.drawCircle(const Offset(0, -_pinH + _pinW / 2), 2, Paint()..color = Colors.black87);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_PinPainter old) =>
      old.cam != cam || !identical(old.campuses, campuses) || old.accent != accent;
}
