import 'dart:async';

import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../models/tab_config.dart';

/// Settings › Tutorial: show it again (the game screen goes back to the map, then says [tutorialStart]).
final tutorialAsked = ValueNotifier<bool>(false);
final tutorialStart = ValueNotifier<int>(0);

/// No Campus yet (or not known yet): the player stays on the map, also before the first card shows. The
/// game screen keeps it up to date; what the overlay can't cover closes itself.
final tutorialLocked = ValueNotifier<bool>(true);

/// The supervisors on the Campus page, for their card.
final campusSupervisorsKey = GlobalKey();

/// The tutorial running now. The map writes the steps, the game screen shows them over all the tabs.
final tutorialRun = ValueNotifier<TutorialRun?>(null);

class TutorialRun {
  final List<TutorialStep> steps;
  final VoidCallback onDone;
  final Listenable? changes;               // says when [passed] may have changed
  final bool Function()? passed;           // the Campus is down: until then no skipping, see TutorialStep.waits
  const TutorialRun(this.steps, this.onDone, {this.changes, this.passed});
}

class TutorialStep {
  final String title, text;
  final GlobalKey? target;                 // what this step is about, lit up on the darkened screen
  final GameTabId? tab;                    // the tab it talks about (none: the map)
  final bool more;                         // the More tab, which has no id
  final bool waits;                        // goes on by itself once done: the player does it on the live map
  const TutorialStep(this.title, this.text, [this.target, this.tab, this.more = false, this.waits = false]);
}

/// The first steps for a new player (owner 2026-11-01), one card at a time. It covers the whole game, tab
/// bar too: the tabs change with the cards, and only with the cards. Skipping needs a Campus (owner
/// 2026-11-02). A step that [TutorialStep.waits] leaves the map free, down to its target, and has no Next.
class TutorialOverlay extends StatefulWidget {
  final List<TutorialStep> steps;
  final VoidCallback onDone;
  final void Function(TutorialStep step)? onStep;
  final Listenable? changes;
  final bool Function()? passed;
  const TutorialOverlay({super.key, required this.steps, required this.onDone, this.onStep, this.changes, this.passed});

  @override
  State<TutorialOverlay> createState() => _TutorialOverlayState();
}

class _TutorialOverlayState extends State<TutorialOverlay> {
  int _i = 0;
  Timer? _settled;
  Timer? _follow;                 // a waiting step keeps its target in sight
  bool _wasWaiting = false;

  bool get _passed => widget.passed?.call() ?? true;
  bool get _waiting => widget.steps[_i].waits && !_passed;

  /// A step about a button on the map: the map and that button work while the card is up (owner
  /// 2026-11-03), so the player does it for real; Next still goes on.
  bool get _hands {
    final s = widget.steps[_i];
    return s.target != null && s.tab == null && !s.more;
  }

  @override
  void dispose() {
    _settled?.cancel();
    _follow?.cancel();
    widget.changes?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (_wasWaiting && !_waiting) {
      _go(_i + 1);
    } else {
      setState(() {});
    }
  }

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
    widget.changes?.addListener(_changed);
    _show();
  }

  /// The list this step's target is in, if any. Only a vertical one: the nearest scrollable of something on
  /// the map is the page view of the tabs, which only the cards may move.
  ScrollPosition? _list() {
    final c = widget.steps[_i].target?.currentContext;
    final s = c == null ? null : Scrollable.maybeOf(c);
    return s != null && axisDirectionToAxis(s.axisDirection) == Axis.vertical ? s.position : null;
  }

  /// A page scrolled to this step's target goes back to its top.
  void _scrollBack() {
    final pos = _list();
    if (pos != null && pos.pixels > 0) {
      pos.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
    }
  }

  void _skip() {
    _scrollBack();
    widget.onDone();
  }

  /// Bring the target into view, below the top bar, and follow it with the hole.
  void _reveal() {
    final pos = _list();
    final box = widget.steps[_i].target?.currentContext?.findRenderObject();
    if (pos == null || box == null) {
      setState(() {});
      return;
    }
    pos.ensureVisible(box, alignment: 0.12, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut)
        .then((_) { if (mounted) setState(() {}); });
  }

  void _go(int to) {
    _scrollBack();
    if (to >= widget.steps.length) return widget.onDone();
    setState(() => _i = to);
    _show();
  }

  void _show() {
    _wasWaiting = _waiting;
    _follow?.cancel();
    if (_wasWaiting || _hands) {
      _follow = Timer.periodic(const Duration(milliseconds: 500), (_) { if (mounted) setState(() {}); });
    }
    widget.onStep?.call(widget.steps[_i]);
    // the hole needs the layout, and a tab change has to finish first
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) setState(() {}); });
    _settled?.cancel();
    _settled = Timer(const Duration(milliseconds: 350), () { if (mounted) _reveal(); });
  }

  @override
  Widget build(BuildContext context) {
    final step = widget.steps[_i];
    final hole = _hole();
    final last = _i == widget.steps.length - 1;
    final height = MediaQuery.sizeOf(context).height;
    final waiting = _waiting;
    final free = waiting || (_hands && hole != null);
    // its target gone (the location gate replaces the map): out of the way, that screen has to work
    if (waiting && hole == null) return const Positioned.fill(child: Stack());
    // the card stays away from what it talks about
    final cardOnTop = hole != null && hole.center.dy > height / 2;
    return Positioned.fill(child: Stack(children: [
      if (free) ...[
        // the map stays free; the buttons beside the target and the tab bar below it are closed
        Positioned(left: 0, right: 0, top: hole!.bottom, bottom: 0, child: _closed),
        Positioned(left: 0, width: hole.left, top: hole.top, height: hole.height, child: _closed),
        Positioned(left: hole.right, right: 0, top: hole.top, height: hole.height, child: _closed),
        Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _Scrim(hole, AppColors.accent, dim: false)))),
      ] else
        Positioned.fill(child: AbsorbPointer(child: CustomPaint(painter: _Scrim(hole, AppColors.accent)))),
      Positioned(
        left: 16, right: 16,
        top: waiting ? 96 : cardOnTop ? 150 : null,
        bottom: waiting || cardOnTop ? null : 150,
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
                if (!last && _passed) TextButton(onPressed: _skip, child: const Text('Skip tutorial')),
                const Spacer(),
                if (_i > 0) TextButton(onPressed: () => _go(_i - 1), child: const Text('Back')),
                const SizedBox(width: 4),
                if (!waiting) FilledButton(onPressed: () => _go(_i + 1), child: Text(last ? 'Start playing' : 'Next')),
              ]),
            ]),
          ),
        ),
      ),
    ]));
  }
}

const _closed = AbsorbPointer(child: ColoredBox(color: Colors.black54));

class _Scrim extends CustomPainter {
  final Rect? hole;
  final Color accent;
  final bool dim;
  const _Scrim(this.hole, this.accent, {this.dim = true});

  @override
  void paint(Canvas canvas, Size size) {
    final all = Path()..addRect(Offset.zero & size);
    final h = hole;
    if (h == null) {
      canvas.drawPath(all, Paint()..color = Colors.black54);
      return;
    }
    final r = RRect.fromRectAndRadius(h, const Radius.circular(12));
    if (dim) canvas.drawPath(Path.combine(PathOperation.difference, all, Path()..addRRect(r)), Paint()..color = Colors.black54);
    canvas.drawRRect(r, Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = accent);
  }

  @override
  bool shouldRepaint(_Scrim old) => old.hole != hole || old.accent != accent || old.dim != dim;
}
