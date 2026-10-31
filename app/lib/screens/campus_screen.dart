import '../widgets/glass.dart' show tabPadding;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_colors.dart';
import '../constants.dart';
import '../services/location_service.dart';
import '../v3/company.dart';
import '../widgets/async_view.dart' show fmtCredits, fmtQty;
import '../widgets/cards.dart';
import '../widgets/popups.dart';
import '../widgets/slide_confirm.dart';
import '../widgets/top_banner.dart';
import 'luxury_screen.dart' show fmtMass;

/// The Campus: its picture, level and stage, the weekly visit, the upgrade to the next level, the
/// supervisors with their education, and moving it. Placing it happens on the map ("Place Campus here").
class CampusScreen extends StatefulWidget {
  const CampusScreen({super.key});
  @override
  State<CampusScreen> createState() => _CampusScreenState();
}

/// The server sends UTC times without a zone.
DateTime parseUtc(String s) => DateTime.parse(s.endsWith('Z') || s.contains('+') ? s : '${s}Z');

class _CampusScreenState extends State<CampusScreen> {
  Map<String, dynamic>? _sups;          // /api/v3/supervisors
  Map<String, dynamic>? _dm;            // /api/v3/darkmatter, once every supervisor is fully educated
  bool _busy = false;
  Timer? _tick;

  Company get _co => context.read<Company>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadSups());
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && (_queue.isNotEmpty)) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  List<Map<String, dynamic>> get _queue => ((_sups?['queue'] as List?) ?? const []).cast<Map<String, dynamic>>();

  Future<void> _loadSups() async {
    if (!_co.hasCampus) return;
    final r = await _co.call('/api/v3/supervisors');
    if (!mounted || !r.ok) return;
    setState(() => _sups = r.data);
    if (r.data['allEducated'] == true) {
      final dm = await _co.call('/api/v3/darkmatter');
      if (mounted && dm.ok) setState(() => _dm = dm.data);
    }
    // a finished education changes the counts: reload once it's done
    final next = _queue.map((q) => parseUtc(q['finish'] as String)).fold<DateTime?>(null,
        (a, b) => a == null || b.isBefore(a) ? b : a);
    if (next != null) {
      final wait = next.difference(DateTime.now().toUtc()) + const Duration(seconds: 2);
      Future.delayed(wait.isNegative ? const Duration(seconds: 2) : wait, () {
        if (mounted) _loadSups();
      });
    }
  }

  void _snack(String msg, {bool error = false}) => AppNotify.show(context, msg, isError: error);

  Future<void> _act(String path, [Map<String, Object?> params = const {}, String? done]) async {
    setState(() => _busy = true);
    final r = await _co.call(path, params);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!r.ok) {
      _snack(r.message ?? 'Something went wrong', error: true);
      return;
    }
    if (done != null) _snack(done);
    await _co.refresh();
    await _loadSups();
  }

  Future<void> _upgrade() async {
    final lv = _co.campusLevel;
    await _act('/api/v3/campus/upgrade', const {}, 'Campus level ${lv + 1}!');
  }

  /// A good GPS position (up to 10 s), or null with a message.
  Future<({double lat, double lng})?> _here() async {
    final loc = LocationService.instance;
    if (!await loc.start()) {
      _snack('This needs precise location', error: true);
      return null;
    }
    setState(() => _busy = true);
    // the GPS may be off away from the Map tab: read it for this one position, a fresh one
    final wasAway = loc.away;
    loc.setAway(false);
    final asked = DateTime.now().subtract(const Duration(seconds: 5));
    bool good(LiveFix? f) => f != null && f.accuracy <= 30 && f.at.isAfter(asked);
    final end = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(end) && !good(loc.fix.value)) {
      await Future.delayed(const Duration(milliseconds: 250));
    }
    final f = loc.fix.value;
    final pos = f != null && f.at.isAfter(asked) ? f.pos : null;
    loc.setAway(wasAway);
    if (!mounted) return null;
    setState(() => _busy = false);
    if (pos == null) {
      _snack('Could not get your location', error: true);
      return null;
    }
    return (lat: pos.latitude, lng: pos.longitude);
  }

  Future<void> _visit() async {
    final p = await _here();
    if (p == null) return;
    await _act('/api/v3/campus/visit', {'lat': p.lat, 'lng': p.lng},
        'Visit done: your company works at full speed this week');
  }

  /// Educate the next supervisor to `step` (one who has the step before, not queued, on a hex first).
  Future<void> _educate(int step) async {
    final queued = _queue.map((q) => q['sup']).toSet();
    final sups = ((_sups?['supervisors'] as List?) ?? const []).cast<Map<String, dynamic>>()
        .where((s) => (s['edu'] as num).toInt() == step - 1 && !queued.contains(s['id'])).toList()
      ..sort((a, b) => (a['hex'] == null ? 1 : 0).compareTo(b['hex'] == null ? 1 : 0));
    if (sups.isEmpty) return;
    await _act('/api/v3/education/start', {'sup': sups.first['id']});
  }

  @override
  Widget build(BuildContext context) {
    final co = context.watch<Company>();
    return Scaffold(
      appBar: ModalRoute.of(context)?.canPop == true ? AppBar(toolbarHeight: 36) : null,
      body: RefreshIndicator(
        onRefresh: () async {
          await co.refresh();
          await _loadSups();
        },
        child: ListView(padding: tabPadding(context, 12), children: [
          if (!co.hasCampus)
            _noCampus()
          else ...[
            _hero(co),
            const SizedBox(height: 12),
            _visitCard(co),
            const SizedBox(height: 18),
            const SectionLabel('Next level'),
            _upgradeCard(co),
            const SizedBox(height: 18),
            const SectionLabel('Supervisors'),
            _supervisorsCard(co),
            if (_sups?['allEducated'] == true) ...[
              const SizedBox(height: 18),
              const SectionLabel('Research'),
              _darkMatterCard(),
            ],
            const SizedBox(height: 18),
            const SectionLabel('Location'),
            _moveCard(co),
          ],
        ]),
      ),
    );
  }

  Widget _panel(Widget child, {Color? color}) => Panel(color: color, child: child);

  Widget _noCampus() => _panel(Column(children: [
        Image.asset(campusPicture(1), height: 180, fit: BoxFit.contain, filterQuality: FilterQuality.medium),
        const SizedBox(height: 10),
        const Text('No Campus yet', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        const SizedBox(height: 6),
        Text('Your Campus is your company\'s home: 7 hexes that grow from a camp of tents into a corporate '
            'campus. Open the map and place it like a hex, within 100 m of you.',
            textAlign: TextAlign.center, style: TextStyle(color: AppColors.t60, fontSize: 13)),
      ]));

  // ── Top: the picture, level and stage, the company at a glance ──
  Widget _hero(Company co) {
    final c = co.campus!;
    final lv = co.campusLevel;
    final s = _sups;
    final total = (s?['total'] as num?)?.toInt() ?? (co.state['supervisors'] as num?)?.toInt() ?? 0;
    final assigned = (s?['assigned'] as num?)?.toInt();
    final eff = (co.efficiency * 100).round();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Stack(children: [
        Center(child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 290),
          child: AspectRatio(
            aspectRatio: 75 / 77.94,
            child: Image.asset(campusPicture(lv), fit: BoxFit.contain, filterQuality: FilterQuality.medium),
          ),
        )),
        Positioned(top: 0, right: 0, child: IconButton(
          tooltip: 'All levels',
          icon: Icon(Icons.info_outline, color: AppColors.t70),
          onPressed: () => showCampusLevels(context),
        )),
      ]),
      const SizedBox(height: 6),
      Text(c['stage'] as String? ?? 'Campus', textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
      Text('Level $lv${lv >= 50 ? ' (highest)' : ''}', textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.w600, fontSize: 13)),
      const SizedBox(height: 12),
      Row(children: [
        StatTile('$eff %', 'Efficiency', color: eff >= 100 ? Colors.greenAccent : Colors.orangeAccent),
        const SizedBox(width: 8),
        StatTile(assigned == null ? '$total' : '$assigned / $total', 'On hexes'),
        const SizedBox(width: 8),
        StatTile('${_queue.length} / ${(s?['slots'] as num?)?.toInt() ?? 1}', 'Education'),
      ]),
    ]);
  }

  // ── The weekly visit ──
  Widget _visitCard(Company co) {
    final eff = co.efficiency;
    final last = co.campus!['lastVisit'] as String?;
    final days = last == null ? null : DateTime.now().toUtc().difference(parseUtc(last)).inHours / 24;
    final dueIn = days == null ? null : 7 - days;
    final ok = eff >= 1;
    final color = ok ? Colors.greenAccent : Colors.orangeAccent;
    return _panel(
      color: color.withValues(alpha: 0.07),
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(ok ? Icons.check_circle_outline : Icons.warning_amber_rounded, color: color),
          const SizedBox(width: 8),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Weekly visit', style: TextStyle(fontWeight: FontWeight.bold)),
            Text(
              !ok ? 'Visit to get back to 100 %'
                  : dueIn != null && dueIn > 0 ? 'Next visit within ${fmtDuration(dueIn)}' : 'Due now',
              style: TextStyle(fontSize: 12, color: ok ? AppColors.t60 : color),
            ),
          ])),
          OutlinedButton.icon(
            onPressed: _busy ? null : _visit,
            icon: const Icon(Icons.directions_walk, size: 16),
            label: const Text('Visit'),
          ),
        ]),
        if (dueIn != null) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(value: (dueIn / 7).clamp(0.0, 1.0), minHeight: 5,
                backgroundColor: Colors.white12, color: color),
          ),
        ],
        const SizedBox(height: 8),
        Text('Come within 200 m once a week. Every missed week costs 10 % of everything your company '
            'makes (never below 30 %).', style: TextStyle(fontSize: 11, color: AppColors.t38)),
      ]),
    );
  }

  // ── Moving the Campus ──
  Widget _moveCard(Company co) {
    final c = co.campus!;
    final moving = (c['moving'] as Map?)?.cast<String, dynamic>();
    final next = c['nextMove'] as String?;
    final now = DateTime.now().toUtc();
    return _panel(Row(children: [
      Icon(Icons.local_shipping_outlined, color: moving != null ? Colors.orangeAccent : AppColors.accent),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Move your Campus', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(
          moving != null
              ? 'Moved in ${fmtDuration(parseUtc(moving['finish'] as String).difference(now).inSeconds / 86400)}. '
                  'Your plants pause until then.'
              : next != null
                  ? 'You can move again on ${next.substring(0, 10)}.'
                  : 'Once a month, like placing a hex: within 100 m of you. Takes 24 hours.',
          style: TextStyle(fontSize: 12, color: moving != null ? Colors.orangeAccent : AppColors.t54),
        ),
      ])),
      if (moving != null || next == null) const SizedBox(width: 8),
      if (moving != null)
        OutlinedButton(
          onPressed: _busy ? null : () => _act('/api/v3/campus/move/cancel', const {}, 'Campus move cancelled'),
          child: const Text('Cancel move'),
        )
      else if (next == null)
        OutlinedButton(onPressed: _busy ? null : () => campusMoveAsked.value = true, child: const Text('Choose place')),
    ]));
  }

  // ── Upgrade: what it takes, in rings like the quests ──
  Widget _upgradeCard(Company co) {
    final lv = co.campusLevel;
    final next = co.campus!['next'] as Map<String, dynamic>?;
    if (next == null) {
      return _panel(const Row(children: [
        Icon(Icons.star, color: Colors.amber, size: 20),
        SizedBox(width: 8),
        Expanded(child: Text('Your Campus is at the highest level',
            style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold))),
      ]));
    }
    final credits = (next['credits'] as num).toDouble();
    final mats = (next['materials'] as Map).cast<String, dynamic>();
    final needStorage = (next['storage'] as num).toInt();
    final storageLv = ((co.state['storage'] as Map?)?['level'] as num?)?.toInt() ?? 1;
    final stock = co.stock;
    double have(String item) => ((stock[item] as num?) ?? 0).toDouble();
    final ready = co.credits >= credits && storageLv >= needStorage &&
        mats.entries.every((e) => have(e.key) + 1e-9 >= (e.value as num));
    final unlocks = _unlocks(co, lv + 1);
    final stages = ((co.catalog['campusStages'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final nextStage = stages.where((s) => (s['from'] as num).toInt() > lv).firstOrNull;

    Widget ring(Widget icon, String name, double got, double want, String text) {
      final done = got + 1e-9 >= want;
      return Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 56, height: 56, child: Stack(alignment: Alignment.center, children: [
          SizedBox.expand(child: CircularProgressIndicator(
            value: want <= 0 ? 1 : (got / want).clamp(0.0, 1.0),
            strokeWidth: 3,
            backgroundColor: Colors.white12,
            color: done ? Colors.greenAccent : AppColors.accent,
          )),
          SizedBox(width: 40, height: 40, child: ClipOval(child: Center(child: icon))),
        ])),
        const SizedBox(height: 6),
        Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
        done
            ? const Icon(Icons.check, size: 14, color: Colors.greenAccent)
            : Text(text, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, color: AppColors.t54)),
      ]);
    }

    final tiles = <Widget>[
      ring(Icon(Icons.toll, size: 28, color: AppColors.t70), 'Credits', co.credits.toDouble(), credits,
          '${fmtCredits(co.credits)} / ${fmtCredits(credits)}'),
      for (final e in mats.entries)
        ring(Image.asset(itemPicture(e.key), width: 40, height: 40, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Icon(Icons.inventory_2_outlined, size: 20, color: AppColors.t38)),
            co.itemName(e.key), have(e.key), (e.value as num).toDouble(),
            '${fmtQty(have(e.key))} / ${fmtQty(e.value as num)}'),
      ring(Icon(Icons.warehouse_outlined, size: 26, color: AppColors.t70), 'Storage', storageLv.toDouble(),
          needStorage.toDouble(), 'Level $storageLv / $needStorage'),
    ];

    return _panel(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Level ${lv + 1}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      if (nextStage != null)
        Text('${nextStage['name']} at level ${nextStage['from']}', style: TextStyle(color: AppColors.t54, fontSize: 12)),
      if (unlocks.isNotEmpty) ...[
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final u in unlocks)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: AppColors.accent.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
              child: Text(u, style: TextStyle(color: AppColors.accent, fontSize: 11, fontWeight: FontWeight.w600)),
            ),
        ]),
      ],
      const SizedBox(height: 14),
      LayoutBuilder(builder: (ctx, box) {
        final w = (box.maxWidth - 2 * 8) / 3;
        return Wrap(spacing: 8, runSpacing: 12, alignment: WrapAlignment.center, children: [
          for (final t in tiles) SizedBox(width: w, child: t),
        ]);
      }),
      const SizedBox(height: 14),
      SlideToConfirm(
        label: ready ? 'Slide to upgrade' : 'Not enough yet',
        sublabel: fmtCredits(credits),
        icon: Icons.upgrade,
        enabled: ready && !_busy,
        busy: _busy,
        radius: 14,
        onConfirm: _upgrade,
      ),
    ]));
  }

  /// What reaching `level` unlocks: plants and hex tiers (from the catalog).
  static List<String> _unlocks(Company co, int level) {
    final out = <String>[];
    final plants = (co.catalog['plants'] as Map?)?.cast<String, dynamic>() ?? const {};
    for (final e in plants.entries) {
      if ((e.value['unlock'] as num?)?.toInt() == level && level > 1) out.add(e.value['name'] as String);
    }
    final raw = (co.catalog['raw'] as Map?)?.cast<String, dynamic>() ?? const {};
    final items = [for (final e in raw.entries) if ((e.value['unlock'] as num?)?.toInt() == level && level > 1) co.itemName(e.key)];
    if (items.isNotEmpty) out.add('${items.join(', ')} hexes');
    const slotLevels = [10, 20, 30, 40, 50];
    if (slotLevels.contains(level)) out.add('One more education slot');
    return out;
  }

  // ── Supervisors: one ladder, how many on each step and the education to the next ──
  Widget _supervisorsCard(Company co) {
    final s = _sups;
    if (s == null) {
      return _panel(const Center(child: Padding(padding: EdgeInsets.all(8),
          child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))));
    }
    final slots = (s['slots'] as num).toInt();
    final queue = _queue;
    final steps = (s['steps'] as List).cast<Map<String, dynamic>>();
    final byStep = (s['byStep'] as List).map((e) => (e as num).toInt()).toList();
    final books = ((co.stock['books'] as num?) ?? 0).toDouble();
    final queuedFor = <int, int>{};                      // step -> supervisors queued for it
    for (final q in queue) {
      final to = (q['to'] as num).toInt();
      queuedFor[to] = (queuedFor[to] ?? 0) + 1;
    }
    final now = DateTime.now().toUtc();

    Widget learning(Map<String, dynamic> q, bool first) {
      final to = (q['to'] as num).toInt();
      final left = parseUtc(q['finish'] as String).difference(now);
      final whole = (steps[to]['hours'] as num).toDouble() * 3600;
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(first ? Icons.school : Icons.hourglass_empty, size: 16, color: AppColors.accent),
            const SizedBox(width: 6),
            Expanded(child: Text('Supervisor #${q['sup']} to ${steps[to]['name']}', style: const TextStyle(fontSize: 12))),
            Text(left.isNegative ? 'done' : fmtDuration(left.inSeconds / 86400),
                style: TextStyle(fontSize: 12, color: AppColors.t60)),
          ]),
          if (first) ...[
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: whole <= 0 ? 1 : (1 - left.inSeconds / whole).clamp(0.0, 1.0),
                minHeight: 4, backgroundColor: Colors.white12, color: AppColors.accent,
              ),
            ),
          ],
        ]),
      );
    }

    Widget rung(int k) {
      final st = steps[k];
      final boost = ((st['boost'] as num) * 100).round();
      final count = k < byStep.length ? byStep[k] : 0;
      String? detail, why;
      var can = false;
      if (k > 0) {
        final ready = byStep[k - 1] - (queuedFor[k] ?? 0);
        final needBooks = (st['books'] as num).toDouble();
        final cost = (st['credits'] as num).toDouble();
        detail = '${_hours(st['hours'] as num)} · ${fmtNum(needBooks)} books · ${fmtCredits(cost)}';
        why = ready <= 0 ? 'No one ready for this'
            : queue.length >= slots ? 'Education queue is full'
            : books < needBooks ? 'Needs ${fmtNum(needBooks)} books, you have ${fmtNum(books)}'
            : co.credits < cost ? 'Not enough credits'
            : null;
        can = why == null && !_busy;
      }
      return Padding(
        padding: EdgeInsets.only(top: k == 0 ? 0 : 10),
        child: Row(children: [
          Container(
            width: 34, height: 34, alignment: Alignment.center,
            decoration: BoxDecoration(
              color: count > 0 ? AppColors.accent.withValues(alpha: 0.18) : Colors.white.withValues(alpha: 0.05),
              shape: BoxShape.circle,
            ),
            child: Text('$count', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13,
                color: count > 0 ? AppColors.accent : AppColors.t38)),
          ),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${st['name']}  +$boost %', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            if (detail != null) Text(detail, style: TextStyle(fontSize: 11, color: AppColors.t54)),
            if (why != null) Text(why, style: TextStyle(fontSize: 11, color: AppColors.t38)),
          ])),
          if (k > 0)
            OutlinedButton(
              onPressed: can ? () => _educate(k) : null,
              style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
              child: const Text('Start'),
            ),
        ]),
      );
    }

    return _panel(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('A supervisor on a hex makes it produce more, and education makes them better. Every Campus '
          'level brings 10 more. Appoint them from a hex or the Hexes list.',
          style: TextStyle(fontSize: 11, color: AppColors.t38)),
      const SizedBox(height: 12),
      for (var i = 0; i < queue.length; i++) learning(queue[i], i == 0),
      for (var k = 0; k < steps.length; k++) rung(k),
    ]));
  }

  // ── Dark matter research: the endgame, once every supervisor is fully educated ──
  Widget _darkMatterCard() {
    final dm = _dm;
    if (dm == null) return const SizedBox.shrink();
    final level = (dm['level'] as num).toInt();
    final next = (dm['nextMg'] as num).toDouble();
    final held = (dm['heldMg'] as num).toDouble();
    final bonus = (dm['bonus'] as num).toDouble();
    return _panel(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Icon(Icons.blur_on, size: 28, color: AppColors.accent),
        const SizedBox(width: 8),
        const Expanded(child: Text('Dark matter', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15))),
        Text('Level $level', style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold, fontSize: 13)),
      ]),
      const SizedBox(height: 6),
      Text('Put Tantalum-180m into research: every level adds 1 % to everything your company makes, for good.',
          style: TextStyle(fontSize: 12, color: AppColors.t60)),
      const SizedBox(height: 10),
      Text('Now +${(bonus * 100).round()} % · you have ${fmtMass(held)} of ${fmtMass(next)}',
          style: TextStyle(fontSize: 12, color: AppColors.t70)),
      const SizedBox(height: 4),
      ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          value: next <= 0 ? 1 : (held / next).clamp(0.0, 1.0),
          minHeight: 4,
          backgroundColor: Colors.white12,
          color: held >= next ? Colors.greenAccent : AppColors.accent,
        ),
      ),
      const SizedBox(height: 12),
      SlideToConfirm(
        label: held >= next ? 'Slide to invest' : 'Not enough yet',
        sublabel: fmtMass(next),
        icon: Icons.science_outlined,
        enabled: held >= next && !_busy,
        busy: _busy,
        radius: 14,
        onConfirm: () => _act('/api/v3/darkmatter/invest', const {}, 'Dark matter research level ${level + 1}'),
      ),
    ]));
  }

  static String _hours(num h) => h < 1 ? '${(h * 60).round()} min' : '${h % 1 == 0 ? h.toInt() : h} h';
}

/// Every Campus level: stage, supervisors, queue slots, survey radius, unlocks and what it costs.
/// 10 pages of 5 levels (owner 2026-10-30), opening on the page of your level; the page after
/// yours stays locked until you reach the last level of your page, so what comes later is a surprise.
/// Only 5 pictures are decoded at a time.
Future<void> showCampusLevels(BuildContext context) async {
  final co = context.read<Company>();
  final r = await co.call('/api/v3/campus/levels');
  if (!context.mounted || !r.ok) return;
  final levels = r.list('levels');
  final cur = (r.data['level'] as num? ?? 0).toInt();
  const per = 5;
  final pages = (levels.length / per).ceil();
  var page = ((cur.clamp(1, levels.length) - 1) ~/ per);
  bool open(int p) => p == 0 || cur >= p * per;        // level 5 opens page 2 (levels 6-10), ...
  await showAppSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final cs = Theme.of(ctx).colorScheme;
      final shown = levels.skip(page * per).take(per).toList();
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Expanded(child: Text('Campus levels', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
              IconButton(
                onPressed: page > 0 ? () => set(() => page--) : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Text('${page + 1} / $pages', style: TextStyle(color: AppColors.t70)),
              IconButton(
                onPressed: page < pages - 1 ? () => set(() => page++) : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ]),
            const SizedBox(height: 6),
            if (!open(page))
              Container(
                height: 5 * 92,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(10)),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.lock_outline, size: 48, color: AppColors.t38),
                  const SizedBox(height: 10),
                  Text('Reach Campus level ${page * per} to see what comes next',
                      textAlign: TextAlign.center, style: TextStyle(color: AppColors.t70)),
                ]),
              )
            else
              for (final l in shown)
                Builder(builder: (_) {
                  final lvl = (l['level'] as num).toInt();
                  final cost = l['cost'] as Map<String, dynamic>?;
                  final plants = (l['plants'] as List).cast<String>().map(co.plantName).toList();
                  final tiers = (l['tiers'] as List).map((t) => 'tier-$t hexes').toList();
                  return Container(
                    height: 84,
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: lvl == cur ? cs.primary.withValues(alpha: 0.15) : cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: lvl == cur ? cs.primary : cs.outline.withValues(alpha: 0.5)),
                    ),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.asset(campusPicture(lvl), width: 64, height: 66, fit: BoxFit.contain,
                            cacheWidth: 128, gaplessPlayback: true),
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: SingleChildScrollView(
                        physics: const ClampingScrollPhysics(),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('Level $lvl · ${l['stage']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                          Text('${l['supervisors']} supervisors · ${l['queueSlots']} education slot'
                              '${(l['queueSlots'] as num) > 1 ? 's' : ''} · surveys up to ${fmtNum((l['surveyRadius'] as num) / 1000)} km',
                              style: TextStyle(fontSize: 12, color: AppColors.t70)),
                          if (plants.isNotEmpty || tiers.isNotEmpty)
                            Text('Unlocks: ${[...plants, ...tiers].join(', ')}',
                                style: TextStyle(fontSize: 12, color: AppColors.accent)),
                          if (cost != null)
                            Text('Costs ꞓ${fmtNum(cost['credits'] as num)}, '
                                '${(cost['materials'] as Map).entries.map((e) => '${fmtNum(e.value as num)} ${co.itemName(e.key as String).toLowerCase()}').join(', ')}'
                                ', storage level ${cost['storage']}',
                                style: TextStyle(fontSize: 11, color: AppColors.t54)),
                        ]),
                      )),
                    ]),
                  );
                }),
          ]),
        ),
      );
    }),
  );
}
