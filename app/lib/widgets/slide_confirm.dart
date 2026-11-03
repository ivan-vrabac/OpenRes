import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_colors.dart';

/// Slide the knob to the end of the track to confirm (owner 2026-10-31: a safety switch for paid
/// actions like a survey, instead of a big button a stray tap can press). Lets go before the end:
/// the knob springs back and nothing happens.
///
/// The knob is the icon's box with a pointed right side, then two chevrons that fade out, so the
/// knob itself reads "> >"; near the end the chevrons squash into the box (owner 2026-10-31).
/// Only the knob repaints while sliding (a RepaintBoundary keeps the glass panel's blur out of it).
/// While [busy] the knob waits at the end with its icon slowly turning, and goes back when the action
/// is finished (owner 2026-10-31: a big survey takes longer, the slider shows it is still working).
class SlideToConfirm extends StatefulWidget {
  final String label;
  final String? sublabel;
  final IconData icon;
  final bool enabled;
  final bool busy;
  final double height;
  final double radius;
  final VoidCallback onConfirm;
  /// The tutorial waits for it: every couple of seconds the knob slides a bit and eases back, like
  /// someone impatient showing which way it goes (owner 2026-11-03).
  final bool hint;
  const SlideToConfirm({super.key, required this.label, this.sublabel, required this.icon, required this.onConfirm,
      this.enabled = true, this.busy = false, this.height = 66, this.radius = 10, this.hint = false});

  @override
  State<SlideToConfirm> createState() => _SlideToConfirmState();
}

// knob geometry: body, point depth, gap and chevron width
const double _bodyW = 40, _point = 10, _gap = 3, _band = 7;
const double _tailW = 2 * (_gap + _band);         // the two chevrons
const double _pad = 4;
// a soft dark edge around the label's letters
const _shade = [Shadow(color: Color(0xCC000000), blurRadius: 3), Shadow(color: Color(0x99000000), blurRadius: 1)];

class _SlideToConfirmState extends State<SlideToConfirm> with TickerProviderStateMixin {
  final _x = ValueNotifier<double>(0);            // knob offset, px
  double _max = 1;
  double _from = 0;
  bool _drag = false;
  late final AnimationController _back = AnimationController(vsync: this, duration: const Duration(milliseconds: 220))
    ..addListener(() => _x.value = _from * (1 - Curves.easeOut.transform(_back.value)));
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(seconds: 3));
  late final AnimationController _nudge = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
    ..addListener(() {
      if (!_drag && !_back.isAnimating) {
        _x.value = _max * _reach * math.sin(math.pi * Curves.easeInOut.transform(_nudge.value));
      }
    });
  Timer? _nudges;
  Timer? _firstNudge;
  double _reach = 0.28;

  void _syncHint() {
    final want = widget.hint && _on;
    if (want && _nudges == null) {
      // the first one comes at once and goes further, then calmer ones
      _reach = 0.5;
      _firstNudge = Timer(const Duration(milliseconds: 500), () {
        if (mounted && !_drag && _x.value == 0) _nudge.forward(from: 0);
      });
      _nudges = Timer.periodic(const Duration(milliseconds: 2400), (_) {
        _reach = 0.28;
        if (mounted && !_drag && _x.value == 0) _nudge.forward(from: 0);
      });
    } else if (!want && _nudges != null) {
      _nudges!.cancel();
      _nudges = null;
      _firstNudge?.cancel();
      _nudge.stop();
      if (!_drag && _x.value > 0) _goBack();
    }
  }

  void _goBack() {
    _from = _x.value;
    _back.forward(from: 0);
  }

  @override
  void initState() {
    super.initState();
    if (widget.busy) _spin.repeat();
    _syncHint();
  }

  @override
  void didUpdateWidget(SlideToConfirm old) {
    super.didUpdateWidget(old);
    if (widget.busy && !old.busy) _spin.repeat();
    if (!widget.busy && old.busy) {
      _spin.reset();
      if (_x.value > 0) _goBack();
    }
    _syncHint();
  }

  @override
  void dispose() {
    _nudges?.cancel();
    _firstNudge?.cancel();
    _nudge.dispose();
    _spin.dispose();
    _back.dispose();
    _x.dispose();
    super.dispose();
  }

  bool get _on => widget.enabled && !widget.busy;

  void _release() {
    if (_x.value >= _max * 0.92 && _on) {
      widget.onConfirm();
      // stays at the end if that made it busy (didUpdateWidget sends it back afterwards)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !widget.busy && !_back.isAnimating) _goBack();
      });
      return;
    }
    _goBack();
  }

  @override
  Widget build(BuildContext context) {
    final on = _on;
    // busy (the action runs) keeps the normal look while the knob springs back; only a slider that
    // can't be used greys out (owner 2026-10-31: it went see-through after a survey)
    final look = widget.enabled || widget.busy;
    return RepaintBoundary(
      child: LayoutBuilder(builder: (context, c) {
        final knobH = widget.height - _pad * 2;
        // the box itself reaches the end; the chevrons squash on the way there
        _max = (c.maxWidth - _pad * 2 - _bodyW - _point).clamp(1.0, double.infinity);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // only a drag that starts on the knob moves it
          onHorizontalDragStart: on ? (d) {
            _drag = d.localPosition.dx <= _pad + _x.value + _bodyW + _point + _tailW;
            if (_drag) { _back.stop(); _nudge.stop(); }
          } : null,
          onHorizontalDragUpdate: on ? (d) { if (_drag) _x.value = (_x.value + d.delta.dx).clamp(0.0, _max); } : null,
          onHorizontalDragEnd: on ? (_) { if (_drag) _release(); _drag = false; } : null,
          child: Container(
            height: widget.height,
            decoration: BoxDecoration(
              color: look ? AppColors.accentDark : Colors.grey.shade800.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(widget.radius),
            ),
            child: ValueListenableBuilder<double>(
              valueListenable: _x,
              builder: (context, x, _) {
                final t = (x / _max).clamp(0.0, 1.0);
                final squash = ((_max - x) / (_tailW * 2)).clamp(0.0, 1.0);   // 1: full chevrons, 0: a square box
                return Stack(children: [
                  // the part already slid over brightens
                  if (x > 0)
                    Positioned(
                      // up to the knob's tip: at the end the trail fills the whole track
                      left: 0, top: 0, bottom: 0, width: _pad * 2 + x + _bodyW + _point,
                      child: Container(decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.12 * t + 0.04),
                        borderRadius: BorderRadius.circular(widget.radius),
                      )),
                    ),
                  Positioned(
                    left: _pad + x, top: _pad,
                    child: SizedBox(
                      width: _bodyW + _point + _tailW * squash, height: knobH,
                      child: CustomPaint(
                        painter: _KnobPainter(radius: (widget.radius - _pad).clamp(2.0, knobH / 2), on: look,
                            squash: squash),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: SizedBox(
                            // centred on the box: on the arrow at the start, on the square at the end
                            width: _bodyW + _point * (1 - 0.6 * squash),
                            child: Center(child: RotationTransition(
                              turns: _spin,
                              child: Icon(widget.icon, size: 22, color: look ? Colors.white : AppColors.t38),
                            )),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // the label, centred on the whole track like the button it replaced, drawn over the knob:
                  // white with a dark shadow reads on the track and on the black knob alike (owner 2026-11-03)
                  Positioned.fill(
                    child: Opacity(
                      opacity: (1 - t * 1.6).clamp(0.0, 1.0),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                                color: look ? Colors.white.withValues(alpha: 0.92) : AppColors.t38,
                                shadows: look ? _shade : null)),
                        if (widget.sublabel != null)
                          Text(widget.sublabel!, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11, color: look ? Colors.white70 : Colors.white24,
                                  shadows: look ? _shade : null)),
                      ]),
                    ),
                  ),
                ]);
              },
            ),
          ),
        );
      }),
    );
  }
}

/// The icon's box with a pointed right side, then two chevrons fading out: "> >". [squash] (1..0)
/// narrows the chevrons and their gaps until they disappear into the box.
class _KnobPainter extends CustomPainter {
  final double radius;
  final bool on;
  final double squash;
  const _KnobPainter({required this.radius, required this.on, required this.squash});

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height, mid = h / 2;
    final base = on ? Colors.white : Colors.white38;
    // the point flattens and the right corners round off as the chevrons squash: at the end the
    // box is a rounded square reaching the same place the tip did
    final tip = _point * squash, rr = radius * (1 - squash), bw = _bodyW + _point - tip;
    final body = Path()
      ..moveTo(radius, 0)
      ..lineTo(bw - rr, 0);
    if (rr > 0.5) body.arcToPoint(Offset(bw, rr), radius: Radius.circular(rr));
    body
      ..lineTo(bw + tip, mid)
      ..lineTo(bw, h - rr);
    if (rr > 0.5) body.arcToPoint(Offset(bw - rr, h), radius: Radius.circular(rr));
    body
      ..lineTo(radius, h)
      ..arcToPoint(Offset(0, h - radius), radius: Radius.circular(radius))
      ..lineTo(0, radius)
      ..arcToPoint(Offset(radius, 0), radius: Radius.circular(radius))
      ..close();
    // a black knob, a white icon: the strongest contrast (owner 2026-11-03: black to white, not see-through)
    canvas.drawPath(body, Paint()..color = on ? Colors.black : Colors.black.withValues(alpha: 0.4));
    canvas.drawPath(body, Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = base.withValues(alpha: 0.35));
    if (squash <= 0.01) return;
    final gap = _gap * squash, band = _band * squash;
    var x = bw + gap;                         // the chevrons follow the box's (flattening) point
    for (final a in const [0.22, 0.10]) {
      final p = Path()
        ..moveTo(x, 0)
        ..lineTo(x + band, 0)
        ..lineTo(x + band + tip, mid)
        ..lineTo(x + band, h)
        ..lineTo(x, h)
        ..lineTo(x + tip, mid)
        ..close();
      canvas.drawPath(p, Paint()..color = base.withValues(alpha: a * squash));
      x += band + gap;
    }
  }

  @override
  bool shouldRepaint(_KnobPainter old) => old.radius != radius || old.on != on || old.squash != squash;
}
