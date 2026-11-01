import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../models/tab_config.dart';

/// Settings › Tutorial: show it again (the game screen goes back to the map, then says [tutorialStart]).
final tutorialAsked = ValueNotifier<bool>(false);
final tutorialStart = ValueNotifier<int>(0);

/// The tutorial running now. The map writes the steps, the game screen shows them over all the tabs.
final tutorialRun = ValueNotifier<TutorialRun?>(null);

class TutorialRun {
  final List<TutorialStep> steps;
  final VoidCallback onDone;
  const TutorialRun(this.steps, this.onDone);
}

class TutorialStep {
  final String title, text;
  final GlobalKey? target;                 // what this step is about, lit up on the darkened screen
  final GameTabId? tab;                    // the tab it talks about (none: the map)
  final bool more;                         // the More tab, which has no id
  const TutorialStep(this.title, this.text, [this.target, this.tab, this.more = false]);
}

/// The first steps for a new player (owner 2026-11-01), one card at a time. It can always be skipped. It
/// covers the whole game, tab bar too: the tabs change with the cards, and only with the cards.
class TutorialOverlay extends StatefulWidget {
  final List<TutorialStep> steps;
  final VoidCallback onDone;
  final void Function(TutorialStep step)? onStep;
  const TutorialOverlay({super.key, required this.steps, required this.onDone, this.onStep});

  @override
  State<TutorialOverlay> createState() => _TutorialOverlayState();
}

class _TutorialOverlayState extends State<TutorialOverlay> {
  int _i = 0;

  /// Where the step's target is, in this overlay's own coordinates.
  Rect? _hole() {
    final box = widget.steps[_i].target?.currentContext?.findRenderObject() as RenderBox?;
    final me = context.findRenderObject() as RenderBox?;
    if (box == null || me == null || !box.hasSize || !me.hasSize) return null;
    return (box.localToGlobal(Offset.zero, ancestor: me) & box.size).inflate(4);
  }

  @override
  void initState() {
    super.initState();
    _show();
  }

  void _go(int to) {
    if (to >= widget.steps.length) return widget.onDone();
    setState(() => _i = to);
    _show();
  }

  void _show() {
    widget.onStep?.call(widget.steps[_i]);
    // the hole needs the layout, and a tab change has to finish first
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) setState(() {}); });
    Future.delayed(const Duration(milliseconds: 350), () { if (mounted) setState(() {}); });
  }

  @override
  Widget build(BuildContext context) {
    final step = widget.steps[_i];
    final hole = _hole();
    final last = _i == widget.steps.length - 1;
    final height = MediaQuery.sizeOf(context).height;
    // the card stays away from what it talks about
    final cardOnTop = hole != null && hole.center.dy > height / 2;
    return Positioned.fill(child: Stack(children: [
      Positioned.fill(child: AbsorbPointer(child: CustomPaint(painter: _Scrim(hole, AppColors.accent)))),
      Positioned(
        left: 16, right: 16,
        top: cardOnTop ? 150 : null,
        bottom: cardOnTop ? null : 150,
        child: Material(
          color: AppColors.bg,
          elevation: 8,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${_i + 1} of ${widget.steps.length}', style: TextStyle(fontSize: 12, color: AppColors.t54)),
              const SizedBox(height: 4),
              Text(step.title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(step.text, style: const TextStyle(fontSize: 15, height: 1.35)),
              const SizedBox(height: 8),
              Row(children: [
                if (!last) TextButton(onPressed: widget.onDone, child: const Text('Skip tutorial')),
                const Spacer(),
                if (_i > 0) TextButton(onPressed: () => _go(_i - 1), child: const Text('Back')),
                const SizedBox(width: 4),
                FilledButton(onPressed: () => _go(_i + 1), child: Text(last ? 'Start playing' : 'Next')),
              ]),
            ]),
          ),
        ),
      ),
    ]));
  }
}

class _Scrim extends CustomPainter {
  final Rect? hole;
  final Color accent;
  const _Scrim(this.hole, this.accent);

  @override
  void paint(Canvas canvas, Size size) {
    final all = Path()..addRect(Offset.zero & size);
    final h = hole;
    if (h == null) {
      canvas.drawPath(all, Paint()..color = Colors.black54);
      return;
    }
    final r = RRect.fromRectAndRadius(h, const Radius.circular(12));
    canvas.drawPath(Path.combine(PathOperation.difference, all, Path()..addRRect(r)), Paint()..color = Colors.black54);
    canvas.drawRRect(r, Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = accent);
  }

  @override
  bool shouldRepaint(_Scrim old) => old.hole != hole || old.accent != accent;
}
