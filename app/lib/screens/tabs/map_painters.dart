// Part of the map tab (split off map_tab.dart, 2026-11-01).
part of 'map_tab.dart';

// The map's small drawings: hex shapes, crosshairs, the survey data holder and the 30 s
// shared-hex countdown.

// ── Heatmap data from server ───────────────────────────────────────────────────

/// The last survey: where and how big; grids are fetched per resource (OpenRes 0.3).
class _Survey {
  final LatLngBounds bounds;
  final LatLng center;
  final double radius;
  const _Survey(this.bounds, this.center, this.radius);
}



// ── Resource colors for scan clouds and mine dots ──────────────────────────────

const Color _kFrame = Color(0xFFD8D4CA);   // hex frame: one colour, no coloured inner outlines


class _HexOutlinePainter extends CustomPainter {
  final Color color;
  const _HexOutlinePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r  = size.width / 2;
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final a = i * math.pi / 3;
      final x = cx + r * math.cos(a);
      final y = cy - r * math.sin(a);
      if (i == 0) path.moveTo(x, y); else path.lineTo(x, y);
    }
    path.close();
    final sw = (r * 0.12).clamp(0.5, 1.5);
    canvas.drawPath(path, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = sw);
  }

  @override
  bool shouldRepaint(_HexOutlinePainter old) => old.color != color;
}

// ── GPS position painter: compass tick marks around a white center dot ─────────

class _PosCrosshairPainter extends CustomPainter {
  final double? headingDeg;
  const _PosCrosshairPainter({this.headingDeg});
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final tickPaint = Paint()
      ..color = Colors.yellow
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;
    const innerR = 12.0;
    const outerR = 18.0;
    const innerRSmall = 14.0;
    const outerRSmall = 17.0;
    // Main ticks (every 45°)
    for (int i = 0; i < 8; i++) {
      final a = i * math.pi / 4;
      canvas.drawLine(
        Offset(cx + innerR * math.cos(a), cy + innerR * math.sin(a)),
        Offset(cx + outerR * math.cos(a), cy + outerR * math.sin(a)),
        tickPaint,
      );
    }
    // Small ticks between main ones (every 45°, offset by 22.5°)
    final smallPaint = Paint()
      ..color = Colors.yellow.withValues(alpha: 0.6)
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;
    for (int i = 0; i < 8; i++) {
      final a = (i + 0.5) * math.pi / 4;
      canvas.drawLine(
        Offset(cx + innerRSmall * math.cos(a), cy + innerRSmall * math.sin(a)),
        Offset(cx + outerRSmall * math.cos(a), cy + outerRSmall * math.sin(a)),
        smallPaint,
      );
    }
    // White heading tick — slightly longer, drawn on top
    if (headingDeg != null) {
      final a = headingDeg! * math.pi / 180 - math.pi / 2;
      canvas.drawLine(
        Offset(cx + innerR * math.cos(a), cy + innerR * math.sin(a)),
        Offset(cx + (outerR + 3) * math.cos(a), cy + (outerR + 3) * math.sin(a)),
        Paint()..color = Colors.white..strokeWidth = 1.5..style = PaintingStyle.stroke,
      );
    }
    // Yellow center dot
    canvas.drawCircle(Offset(cx, cy), 1.5,
        Paint()..color = Colors.yellow..style = PaintingStyle.fill);
  }
  @override
  bool shouldRepaint(_PosCrosshairPainter old) => old.headingDeg != headingDeg;
}

// ── Thin red crosshair painter ────────────────────────────────────────────────

class _CrosshairPainter extends CustomPainter {
  const _CrosshairPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.red.withValues(alpha: 0.75)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;
    final cx = size.width / 2;
    final cy = size.height / 2;
    const gap = 3.0;
    // horizontal
    canvas.drawLine(Offset(0, cy), Offset(cx - gap, cy), paint);
    canvas.drawLine(Offset(cx + gap, cy), Offset(size.width, cy), paint);
    // vertical
    canvas.drawLine(Offset(cx, 0), Offset(cx, cy - gap), paint);
    canvas.drawLine(Offset(cx, cy + gap), Offset(cx, size.height), paint);
  }
  @override
  bool shouldRepaint(covariant CustomPainter _) => false;
}

// ── Hex icon painter for mine toggle button — clean outline only ──────────────

class _HexIconPainter extends CustomPainter {
  final Color color;
  const _HexIconPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2, cy = size.height / 2;
    final r = size.width / 2 - 1.5;
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final a = i * math.pi / 3 - math.pi / 6;
      final x = cx + r * math.cos(a), y = cy + r * math.sin(a);
      if (i == 0) path.moveTo(x, y); else path.lineTo(x, y);
    }
    path.close();
    canvas.drawPath(path, Paint()
      ..color = color ..style = PaintingStyle.stroke ..strokeWidth = 2.0);
  }
  @override
  bool shouldRepaint(_HexIconPainter old) => old.color != color;
}



/// One row of the map's anchored menus (categories, resources).
class _MenuRow<T> {
  final T value;
  final String label;
  final String? note;
  final Widget leading;
  final bool locked, selected;
  const _MenuRow({required this.value, required this.label, required this.leading, this.note,
      this.locked = false, this.selected = false});
}
