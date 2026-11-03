import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

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
  final int start;                         // the checkpoint: the card the player was on
  final void Function(TutorialStep step)? onShow;   // saves the checkpoint
  const TutorialRun(this.steps, this.onDone, {this.guided = false, this.changes, this.start = 0, this.onShow});
}

class TutorialStep {
  final String title, text;
  final GlobalKey? target;                 // what this step is about, lit up on the darkened screen
  final GameTabId? tab;                    // the tab it talks about (none: the map)
  final bool more;                         // the More tab, which has no id
  /// Guided only: the task is done (then the card shows Next). Until then the target works under the
  /// card, and on the map the map does too.
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
///
/// Smooth (owner 2026-11-03): the lit hole follows its target on every frame the app draws anyway (no
/// frames of its own), glides from one target to the next on the same page, and on a new tab the card and
/// hole wait until the page has settled, then fade in. The card fades between steps.
class TutorialOverlay extends StatefulWidget {
  final List<TutorialStep> steps;
  final VoidCallback onDone;
  final void Function(TutorialStep step)? onStep;
  final void Function(TutorialStep step)? onShow;
  final Listenable? changes;
  final bool guided;
  final int start;
  final String finish;                     // the last card's button
  const TutorialOverlay({super.key, required this.steps, required this.onDone, this.onStep, this.onShow,
      this.changes, this.guided = false, this.start = 0, this.finish = 'Start playing'});

  @override
  State<TutorialOverlay> createState() => _TutorialOverlayState();
}

class _TutorialOverlayState extends State<TutorialOverlay> with SingleTickerProviderStateMixin {
  late int _i = widget.start.clamp(0, widget.steps.length - 1);
  Timer? _settled;
  Timer? _follow;                 // a task card checks whether it is done
  Timer? _poll;
  bool _revealed = false;
  bool _finished = false;         // this card's task is done: Next shows, nothing else works any more
  bool _ready = false;            // the page has settled: the hole and the card show
  bool _alive = true;
  Rect? _shown;                   // the hole as drawn
  Rect? _from;                    // where the glide to the next target starts
  late final AnimationController _glide;

  TutorialStep get _step => widget.steps[_i];
  /// A task the player still has to do.
  bool get _task => widget.guided && _step.done != null && !_finished;
  double get _topBar => MediaQuery.paddingOf(context).top + 46;

  @override
  void initState() {
    super.initState();
    _glide = AnimationController(vsync: this, duration: const Duration(milliseconds: 280))..addListener(_track);
    widget.changes?.addListener(_check);
    // after every frame the app draws (scrolling, a page sliding, a card growing): the hole follows
    SchedulerBinding.instance.addPersistentFrameCallback((_) {
      if (_alive) SchedulerBinding.instance.addPostFrameCallback((_) => _track());
    });
    _show(null);
  }

  @override
  void dispose() {
    _alive = false;
    _settled?.cancel();
    _follow?.cancel();
    _poll?.cancel();
    _glide.dispose();
    widget.changes?.removeListener(_check);
    tutorialFocus.value = null;
    super.dispose();
  }

  /// Done: the card shows Next, the player goes on when ready (owner 2026-11-03).
  void _check() {
    if (!mounted || !_task || !_step.done!()) return;
    _follow?.cancel();
    _poll?.cancel();
    tutorialFocus.value = null;
    setState(() => _finished = true);
  }

  /// Where the step's target is, in this overlay's own coordinates. On a tab never over the top bar.
  Rect? _hole() {
    final box = _step.target?.currentContext?.findRenderObject() as RenderBox?;
    final me = context.findRenderObject() as RenderBox?;
    if (box == null || me == null || !box.attached || !box.hasSize || !me.hasSize) return null;
    var r = (box.localToGlobal(Offset.zero, ancestor: me) & box.size).inflate(4);
    final onMap = _step.tab == null && !_step.more;
    if (!onMap && r.top < _topBar) {
      if (r.bottom <= _topBar) return null;
      r = Rect.fromLTRB(r.left, _topBar, r.right, r.bottom);
    }
    return r;
  }

  void _track() {
    if (!_alive || !mounted) return;
    final h = _ready ? _hole() : null;
    var d = h;
    if (h != null && _from != null) {
      d = Rect.lerp(_from, h, Curves.easeInOut.transform(_glide.value));
      if (_glide.isCompleted) _from = null;
    }
    if (d != _shown) setState(() => _shown = d);
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

  /// Bring the target into view, well below the top bar.
  Future<void> _reveal() async {
    final box = _step.target?.currentContext?.findRenderObject();
    if (box == null) return;
    _revealed = true;
    final pos = _list();
    if (pos != null) {
      await pos.ensureVisible(box, alignment: 0.3, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
    }
  }

  void _go(int to) {
    final prev = _step;
    _scrollBack();
    if (to >= widget.steps.length) {
      _follow?.cancel();
      _poll?.cancel();
      tutorialFocus.value = null;
      return widget.onDone();
    }
    setState(() => _i = to);
    _show(prev);
  }

  void _show(TutorialStep? prev) {
    _follow?.cancel();
    _poll?.cancel();
    _settled?.cancel();
    _revealed = false;
    _finished = false;
    final step = _step;
    final sameTab = prev != null && prev.tab == step.tab && prev.more == step.more;
    widget.onStep?.call(step);
    widget.onShow?.call(step);
    if (_task) {
      step.enter?.call();
      if (step.done!()) {
        _finished = true;                      // already done (back at a checkpoint): Next at once
      } else {
        _follow = Timer.periodic(const Duration(milliseconds: 500), (_) {
          if (!mounted) return;
          if (_ready && !_revealed) _reveal();     // a target that shows up later (a list still loading)
          _check();
        });
        if (step.poll != null) {
          _poll = Timer.periodic(const Duration(seconds: 3), (_) { if (mounted) step.poll!(); });
        }
      }
    }
    tutorialFocus.value = _task ? step.target : null;
    if (sameTab) {
      // the same page: the hole glides to its new target
      _from = _shown;
      _ready = true;
      _glide.forward(from: 0);
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _reveal(); });
    } else {
      // another tab: out of sight until the page has slid in and the target is in view
      _ready = false;
      _from = null;
      _shown = null;
      _settled = Timer(const Duration(milliseconds: 360), () async {
        if (!mounted) return;
        await _reveal();
        if (!mounted) return;
        setState(() => _ready = true);
        _track();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final step = _step;
    final hole = _shown;
    final last = _i == widget.steps.length - 1;
    final size = MediaQuery.sizeOf(context);
    final task = _task;
    final onMap = step.tab == null && !step.more;
    // its target gone on the map (the location gate replaces the map): out of the way, that screen has to work
    if (task && onMap && _ready && _hole() == null) return const Positioned.fill(child: Stack());
    // the card stays away from what it talks about
    final cardOnTop = (task && onMap) ||
        (hole != null && hole.center.dy > size.height / 2 && hole.height < size.height / 2);
    final topBar = _topBar;
    final areaBox = step.area?.currentContext?.findRenderObject() as RenderBox?;
    final me = context.findRenderObject() as RenderBox?;
    final areaTop = areaBox == null || me == null || !areaBox.attached || !areaBox.hasSize
        ? null : areaBox.localToGlobal(Offset.zero, ancestor: me).dy;
    final card = Material(
      key: ValueKey(_i),
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
            // the same height with or without the button: the card doesn't jump when it shows
            SizedBox(height: 48, child: task ? null : Center(child: FilledButton(
                onPressed: () => _go(_i + 1), child: Text(last ? widget.finish : 'Next')))),
          ]),
        ]),
      ),
    );
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
      Positioned.fill(child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 150, 16, 150),
        child: AnimatedAlign(
          alignment: cardOnTop ? Alignment.topCenter : Alignment.bottomCenter,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeInOut,
          child: IgnorePointer(
            ignoring: !_ready,
            child: AnimatedOpacity(
              opacity: _ready ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                layoutBuilder: (cur, prev) => Stack(alignment: cardOnTop ? Alignment.topCenter : Alignment.bottomCenter,
                    children: [...prev.map((p) => IgnorePointer(child: p)), if (cur != null) cur]),
                child: card,
              ),
            ),
          ),
        ),
      )),
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
