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

/// What the hands-on cards light up: the training buttons on the Campus page, the first resource on the
/// Hexes tab, the first item in Central Storage, Books on the Market.
final campusTrainKey = GlobalKey();
final tutorialHexesKey = GlobalKey();
final tutorialStorageKey = GlobalKey();
final tutorialBooksKey = GlobalKey();
final tutorialAppointKey = GlobalKey();        // inside a resource's hexes
final tutorialSystemBuyKey = GlobalKey();      // inside the Books page of the Market
final campusQueueKey = GlobalKey();

/// The education queue was opened (its card waits for it).
final campusQueueSeen = ValueNotifier<bool>(false);

/// The first, guided tutorial runs: no hex opens (no lease can be cancelled), the Books page sells 10.
bool get tutorialGuided => tutorialRun.value?.guided == true;

/// The target of the hands-on card showing now (null: none). A list it sits in stays still meanwhile.
final tutorialFocus = ValueNotifier<GlobalKey?>(null);

/// Supervisors in training or trained, as the Campus page last loaded them (the training card waits for it).
final campusEducated = ValueNotifier<int>(0);

/// The tutorial running now. The map writes the steps, the game screen shows them over all the tabs.
final tutorialRun = ValueNotifier<TutorialRun?>(null);

class TutorialRun {
  final List<TutorialStep> steps;
  final VoidCallback onDone;
  final bool guided;                       // the first one: every task done for real, no skipping, no going back
  final Listenable? changes;               // says when a step's [TutorialStep.done] may have changed
  const TutorialRun(this.steps, this.onDone, {this.guided = false, this.changes});
}

class TutorialStep {
  final String title, text;
  final GlobalKey? target;                 // what this step is about, lit up on the darkened screen
  final GameTabId? tab;                    // the tab it talks about (none: the map)
  final bool more;                         // the More tab, which has no id
  /// Guided only: the task is done (the card goes on by itself, it has no Next). Until then the target
  /// works under the card, and on the map the map does too.
  final bool Function()? done;
  final VoidCallback? enter;               // guided: when the card shows
  final VoidCallback? poll;                // guided: every few seconds until done (fresh data from the server)
  final GlobalKey? area;                   // on the map: the panel around the target, closed but for the target
  const TutorialStep(this.title, this.text,
      {this.target, this.tab, this.more = false, this.done, this.enter, this.poll, this.area});
}

/// The first steps for a new player (owner 2026-11-01), one card at a time. It covers the whole game, tab
/// bar too: the tabs change with the cards, and only with the cards. Guided (owner 2026-11-03): the player
/// does each task, no skipping and no going back. From Settings it only explains, and can be skipped.
class TutorialOverlay extends StatefulWidget {
  final List<TutorialStep> steps;
  final VoidCallback onDone;
  final void Function(TutorialStep step)? onStep;
  final Listenable? changes;
  final bool guided;
  final String finish;                     // the last card's button
  const TutorialOverlay({super.key, required this.steps, required this.onDone, this.onStep, this.changes,
      this.guided = false, this.finish = 'Start playing'});

  @override
  State<TutorialOverlay> createState() => _TutorialOverlayState();
}

class _TutorialOverlayState extends State<TutorialOverlay> {
  int _i = 0;
  Timer? _settled;
  Timer? _follow;                 // a task card keeps its target in sight and checks whether it is done
  Timer? _poll;
  bool _revealed = false;
  bool _finished = false;         // this card's task is done: Next shows, nothing else works any more

  TutorialStep get _step => widget.steps[_i];
  /// A task the player still has to do.
  bool get _task => widget.guided && _step.done != null && !_finished;

  @override
  void initState() {
    super.initState();
    widget.changes?.addListener(_check);
    _show();
  }

  @override
  void dispose() {
    _settled?.cancel();
    _follow?.cancel();
    _poll?.cancel();
    widget.changes?.removeListener(_check);
    tutorialFocus.value = null;
    super.dispose();
  }

  /// Done: the card shows Next, the player goes on when ready (owner 2026-11-03).
  void _check() {
    if (!mounted) return;
    if (_task && _step.done!()) {
      _finished = true;
      _follow?.cancel();
      _poll?.cancel();
      tutorialFocus.value = null;
    }
    setState(() {});
  }

  /// Where the step's target is, in this overlay's own coordinates.
  Rect? _hole() {
    final box = _step.target?.currentContext?.findRenderObject() as RenderBox?;
    final me = context.findRenderObject() as RenderBox?;
    if (box == null || me == null || !box.attached || !box.hasSize || !me.hasSize) return null;
    return (box.localToGlobal(Offset.zero, ancestor: me) & box.size).inflate(4);
  }

  /// The list this step's target is in, if any. Only a vertical one: the nearest scrollable of something on
  /// the map is the page view of the tabs, which only the cards may move.
  ScrollPosition? _list() {
    final c = _step.target?.currentContext;
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
    tutorialFocus.value = null;
    widget.onDone();
  }

  /// Bring the target into view, below the top bar, and follow it with the hole.
  void _reveal() {
    final box = _step.target?.currentContext?.findRenderObject();
    if (box != null) _revealed = true;
    final pos = _list();
    if (pos == null || box == null) {
      setState(() {});
      return;
    }
    pos.ensureVisible(box, alignment: 0.12, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut)
        .then((_) { if (mounted) setState(() {}); });
  }

  void _go(int to) {
    _scrollBack();
    if (to >= widget.steps.length) {
      _follow?.cancel();
      _poll?.cancel();
      tutorialFocus.value = null;
      return widget.onDone();
    }
    setState(() => _i = to);
    _show();
  }

  void _show() {
    _follow?.cancel();
    _poll?.cancel();
    _revealed = false;
    _finished = false;
    final task = _task;
    tutorialFocus.value = task ? _step.target : null;
    widget.onStep?.call(_step);
    if (task) {
      _step.enter?.call();
      if (_step.done!()) {
        // already done (the app was closed halfway): Next at once
        _finished = true;
        tutorialFocus.value = null;
      } else {
      _follow = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (!mounted) return;
        if (!_revealed) _reveal();     // a target that shows up later (a list still loading)
        _check();
      });
      if (_step.poll != null) {
        _poll = Timer.periodic(const Duration(seconds: 3), (_) { if (mounted) _step.poll!(); });
      }
      }
    }
    // the hole needs the layout, and a tab change has to finish first
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) setState(() {}); });
    _settled?.cancel();
    _settled = Timer(const Duration(milliseconds: 350), () { if (mounted) _reveal(); });
  }

  @override
  Widget build(BuildContext context) {
    final step = _step;
    final hole = _hole();
    final last = _i == widget.steps.length - 1;
    final size = MediaQuery.sizeOf(context);
    final task = _task;
    final onMap = step.tab == null && !step.more;
    // its target gone on the map (the location gate replaces the map): out of the way, that screen has to work
    if (task && onMap && hole == null) return const Positioned.fill(child: Stack());
    // the card stays away from what it talks about
    final cardOnTop = hole != null && hole.center.dy > size.height / 2 && hole.height < size.height / 2;
    final topBar = MediaQuery.paddingOf(context).top + 46;
    final areaBox = step.area?.currentContext?.findRenderObject() as RenderBox?;
    final me = context.findRenderObject() as RenderBox?;
    final areaTop = areaBox == null || me == null || !areaBox.attached || !areaBox.hasSize
        ? null : areaBox.localToGlobal(Offset.zero, ancestor: me).dy;
    return Positioned.fill(child: Stack(children: [
      if (task && hole != null) ...[
        // only the target works (and the map around it); the rest is closed
        Positioned(left: 0, right: 0, top: hole.bottom, bottom: 0, child: _closed),
        Positioned(left: 0, width: hole.left, top: hole.top, height: hole.height, child: _closed),
        Positioned(left: hole.right, right: 0, top: hole.top, height: hole.height, child: _closed),
        // on a tab everything above is closed; on the map just its buttons along the top
        Positioned(left: 0, right: 0, top: 0, height: onMap ? topBar : hole.top, child: _closed),
        // the rest of the panel the target sits in (the buttons above a short one)
        if (areaTop != null && areaTop < hole.top)
          Positioned(left: 0, right: 0, top: areaTop, height: hole.top - areaTop, child: _closed),
        Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _Scrim(hole, AppColors.accent, dim: false)))),
      ] else
        Positioned.fill(child: AbsorbPointer(child: CustomPaint(painter: _Scrim(hole, AppColors.accent)))),
      Positioned(
        left: 16, right: 16,
        top: task && onMap ? topBar + 50 : cardOnTop ? 150 : null,
        bottom: (task && onMap) || cardOnTop ? null : 150,
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
                if (!widget.guided && !last) TextButton(onPressed: _skip, child: const Text('Skip tutorial')),
                const Spacer(),
                if (!widget.guided && _i > 0) TextButton(onPressed: () => _go(_i - 1), child: const Text('Back')),
                const SizedBox(width: 4),
                if (!task)
                  FilledButton(onPressed: () => _go(_i + 1), child: Text(last ? widget.finish : 'Next'))
                else
                  const SizedBox(height: 40),
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
