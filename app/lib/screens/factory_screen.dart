import '../widgets/cards.dart';
import '../widgets/glass.dart' show tabPadding;
import 'dart:async';
import '../widgets/async_view.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/top_banner.dart';
import '../constants.dart';
import '../v3/company.dart';
import '../widgets/popups.dart';
import '../widgets/slide_confirm.dart';

import '../app_colors.dart';

/// Production & Assembly (was Factories in 1.2.3): the plants inside the Campus. A plant runs its
/// recipe all the time while it's switched on, each level once more in parallel, from what is in
/// Central Storage (inputs and electricity) into Central Storage (/api/v3/plants).
/// 0.2.3 redo (owner 2026-10-31): electricity balance on top, plants as picture cards with their
/// status (ACTIVE / STANDBY / IDLE) and recipe as pictures; a plant opens a sheet with its recipe
/// choice and slide to upgrade; plants to build open a sheet with slide to build.
class FactoryScreen extends StatefulWidget {
  const FactoryScreen({super.key});
  @override
  State<FactoryScreen> createState() => _FactoryScreenState();
}

class _FactoryScreenState extends State<FactoryScreen> {
  List<Map<String, dynamic>>? _plants;
  bool _loading = true;
  bool _busy = false;
  Timer? _refreshTimer;
  // player's own order of plants (keys), kept on this device
  static const _kOrder = 'plant_order';
  List<String> _order = [];
  bool _arranging = false;

  Company get _co => context.read<Company>();

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => _order = p.getStringList(_kOrder) ?? []);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    _refreshTimer = Timer.periodic(const Duration(seconds: 60), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    final r = await _co.call('/api/v3/plants');
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (r.ok) _plants = r.list('plants');
    });
  }

  void _snack(String msg, {bool error = false}) => AppNotify.show(context, msg, isError: error);

  Future<void> _act(String path, Map<String, Object?> params, [String? done]) async {
    setState(() => _busy = true);
    final r = await _co.call(path, params);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!r.ok) {
      _snack(r.message ?? 'Something went wrong', error: true);
      return;
    }
    if (done != null) _snack(done);
    await Future.wait([_load(silent: true), _co.refresh()]);
  }

  List<Map<String, dynamic>> get _mine {
    final list = (_plants ?? const []).where((p) => (p['level'] as num) > 0).toList();
    int pos(Map<String, dynamic> p) {
      final i = _order.indexOf(p['key'] as String);
      return i < 0 ? 1 << 30 : i;
    }
    final idx = {for (var i = 0; i < list.length; i++) list[i]['key']: i};
    list.sort((a, b) { final c = pos(a).compareTo(pos(b)); return c != 0 ? c : idx[a['key']]!.compareTo(idx[b['key']]!); });
    return list;
  }

  Widget _arrangeView(List<Map<String, dynamic>> mine) => Scaffold(
        appBar: AppBar(toolbarHeight: 40, title: const Text('Arrange plants'), actions: [
          TextButton(onPressed: () => setState(() => _arranging = false), child: const Text('Done')),
        ]),
        body: ReorderableListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: mine.length,
          onReorderItem: (from, to) async {
            final keys = mine.map((p) => p['key'] as String).toList();
            keys.insert(to, keys.removeAt(from));
            setState(() => _order = keys);
            final p = await SharedPreferences.getInstance();
            await p.setStringList(_kOrder, keys);
          },
          itemBuilder: (_, i) {
            final p = mine[i];
            final rec = (p['recipes'] as List)[(p['recipe'] as num).toInt()] as Map<String, dynamic>;
            return Card(
              key: ValueKey(p['key']),
              margin: const EdgeInsets.only(bottom: 6),
              child: ListTile(
                dense: true,
                leading: SizedBox(width: 32, height: 32, child: Image.asset(plantPicture(p['key'] as String),
                    errorBuilder: (_, __, ___) => const Icon(Icons.factory_outlined))),
                title: Text(p['name'] as String),
                subtitle: Text('Makes ${_co.itemName(rec['output'] as String).toLowerCase()}'),
                trailing: Text('Lv ${p['level']}'),
              ),
            );
          },
        ),
      );

  @override
  Widget build(BuildContext context) {
    final co = context.watch<Company>();
    final canPop = ModalRoute.of(context)?.canPop == true;
    final mine = _mine;
    if (_arranging && !_loading) return _arrangeView(mine);
    if (_loading && _plants == null) {
      return Scaffold(
        appBar: canPop ? AppBar(toolbarHeight: 36) : null,
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_plants == null) {
      return Scaffold(
        appBar: canPop ? AppBar(toolbarHeight: 36) : null,
        body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Could not load your plants.', style: TextStyle(color: AppColors.t54)),
          const SizedBox(height: 8),
          FilledButton(onPressed: _load, child: const Text('Try again')),
        ])),
      );
    }
    final open = _plants!.where((p) => (p['level'] as num) == 0 && p['unlocked'] == true).toList();
    final locked = _plants!.where((p) => p['unlocked'] != true).toList()
      ..sort((a, b) => (a['unlock'] as num).compareTo(b['unlock'] as num));
    final counts = {for (final s in _Status.values) s: mine.where((p) => _status(co, p) == s).length};
    return Scaffold(
      appBar: canPop ? AppBar(toolbarHeight: 36) : null,
      body: RefreshIndicator(
        onRefresh: () => Future.wait([_load(), co.refresh()]),
        child: ListView(padding: tabPadding(context, 12), children: [
          if (!co.hasCampus)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text('Place your Campus on the map first: the plants are built inside it.',
                  style: TextStyle(color: Colors.orangeAccent, fontSize: 13)),
            ),
          _EnergyCard(co: co, plants: mine),
          const SizedBox(height: 14),
          if (mine.isNotEmpty) ...[
            Row(children: [
              const Expanded(child: SectionLabel('Your plants')),
              for (final s in _Status.values)
                if (counts[s]! > 0) Padding(padding: const EdgeInsets.only(left: 6, bottom: 8),
                    child: _statusBadge(s, '${counts[s]} ${s.label}')),
              if (mine.length > 1)
                IconButton(
                  tooltip: 'Arrange',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => _arranging = true),
                  icon: Icon(Icons.swap_vert, size: 18, color: AppColors.t54),
                ),
            ]),
            _grid([
              for (final p in mine)
                _PlantCard(key: ValueKey(p['key']), plant: p, co: co, status: _status(co, p),
                    onTap: () => _plantSheet(p)),
            ]),
            const SizedBox(height: 16),
          ],
          if (open.isNotEmpty) ...[
            const SectionLabel('Build a plant'),
            _grid([for (final p in open) _NewPlantCard(plant: p, co: co, onTap: () => _buildSheet(p))]),
            const SizedBox(height: 16),
          ],
          if (locked.isNotEmpty) ...[
            const SectionLabel('Later, with a bigger Campus'),
            _grid([for (final p in locked) _NewPlantCard(plant: p, co: co, onTap: () => _buildSheet(p))]),
          ],
        ]),
      ),
    );
  }

  /// Two cards per row.
  Widget _grid(List<Widget> cards) => LayoutBuilder(builder: (context, c) {
        final w = (c.maxWidth - 10) / 2;
        return Wrap(spacing: 10, runSpacing: 10, children: [for (final card in cards) SizedBox(width: w, child: card)]);
      });

  /// A plant: its picture and status, on or off, its recipe, and slide to upgrade.
  Future<void> _plantSheet(Map<String, dynamic> p0) => showAppSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
          final co = context.read<Company>();
          final p = (_plants ?? const []).firstWhere((x) => x['key'] == p0['key'], orElse: () => p0);
          final level = (p['level'] as num).toInt();
          final running = p['running'] == true;
          final recipes = (p['recipes'] as List).cast<Map<String, dynamic>>();
          final ri = (p['recipe'] as num).toInt();
          final rec = recipes[ri];
          final cost = (p['nextCost'] as num).toDouble();
          final st = _status(co, p);
          Future<void> act(String path, Map<String, Object?> params, [String? done]) async {
            await _act(path, params, done);
            set(() {});
          }
          return SafeArea(child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                ClipRRect(borderRadius: BorderRadius.circular(12),
                    child: Image.asset(plantPicture(p['key'] as String), width: 72, height: 72, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Icon(Icons.factory, size: 56, color: AppColors.accent))),
                const SizedBox(width: 14),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p['name'] as String, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Row(children: [
                    _statusBadge(st, st.label),
                    const SizedBox(width: 6),
                    Text('Level $level', style: TextStyle(color: AppColors.t54, fontSize: 12)),
                  ]),
                ])),
                Switch(value: running, onChanged: _busy ? null
                    : (on) => act('/api/v3/plants/run', {'key': p['key'], 'on': on ? 1 : 0})),
              ]),
              const SizedBox(height: 6),
              Text(st.explain(_short(co, rec)), style: TextStyle(fontSize: 12, color: st.color)),
              if (recipes.length > 1) ...[
                const SizedBox(height: 12),
                Text('Makes', style: TextStyle(fontSize: 12, color: AppColors.t54)),
                const SizedBox(height: 6),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (var i = 0; i < recipes.length; i++)
                    ChoiceChip(
                      avatar: _itemIcon(recipes[i]['output'] as String, size: 20),
                      label: Text(co.itemName(recipes[i]['output'] as String)),
                      selected: i == ri,
                      onSelected: _busy || i == ri ? null
                          : (_) => act('/api/v3/plants/recipe', {'key': p['key'], 'recipe': i}),
                    ),
                ]),
              ],
              const SizedBox(height: 12),
              _recipeFlow(co, rec, level),
              const SizedBox(height: 8),
              Text('Adds ꞓ${fmtNum(((rec['profitPerHour'] as num) * level).round())} of value per hour',
                  style: TextStyle(fontSize: 12, color: AppColors.t54)),
              const SizedBox(height: 16),
              SlideToConfirm(
                label: 'Upgrade to level ${level + 1}',
                sublabel: 'ꞓ${fmtNum(cost)}',
                icon: Icons.upgrade,
                height: 60,
                radius: 14,
                enabled: !_busy && co.credits >= cost,
                onConfirm: () => act('/api/v3/plants/upgrade', {'key': p['key']}, '${p['name']} level ${level + 1}'),
              ),
              if (co.credits < cost)
                Padding(padding: const EdgeInsets.only(top: 6),
                    child: Text('Not enough credits yet', textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: Colors.redAccent.withValues(alpha: 0.8)))),
              const SizedBox(height: 4),
              Center(child: TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close'))),
            ]),
          ));
        }),
      );

  /// A plant not built yet: what it can make, and slide to build (or the Campus level it needs).
  Future<void> _buildSheet(Map<String, dynamic> p) => showAppSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) {
          final co = context.read<Company>();
          final locked = p['unlocked'] != true;
          final cost = (p['nextCost'] as num).toDouble();
          final recipes = (p['recipes'] as List).cast<Map<String, dynamic>>();
          return SafeArea(child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                ClipRRect(borderRadius: BorderRadius.circular(12),
                    child: Image.asset(plantPicture(p['key'] as String), width: 72, height: 72, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Icon(Icons.factory, size: 56, color: AppColors.accent))),
                const SizedBox(width: 14),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p['name'] as String, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
                  Text(locked ? 'Unlocks at Campus ${p['unlock']}'
                      : 'Adds ꞓ${fmtNum((recipes.first['profitPerHour'] as num).round())} of value per hour at level 1',
                      style: TextStyle(fontSize: 12, color: locked ? Colors.orangeAccent : AppColors.t54)),
                ])),
              ]),
              const SizedBox(height: 12),
              Text(recipes.length > 1 ? 'Makes one of these' : 'Makes', style: TextStyle(fontSize: 12, color: AppColors.t54)),
              const SizedBox(height: 6),
              for (final rec in recipes)
                Padding(padding: const EdgeInsets.only(bottom: 8), child: _recipeFlow(co, rec, 1)),
              const SizedBox(height: 8),
              if (!locked)
                SlideToConfirm(
                  label: 'Build',
                  sublabel: 'ꞓ${fmtNum(cost)}',
                  icon: Icons.construction,
                  height: 60,
                  radius: 14,
                  enabled: !_busy && co.credits >= cost,
                  onConfirm: () {
                    Navigator.of(ctx).pop();
                    _act('/api/v3/plants/build', {'key': p['key']}, '${p['name']} built');
                  },
                ),
              const SizedBox(height: 4),
              Center(child: TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close'))),
            ]),
          ));
        },
      );
}

/// ACTIVE: switched on and working; STANDBY: switched on, waiting for inputs or electricity;
/// IDLE: switched off (owner 2026-10-31: these words instead of off/waiting/running).
enum _Status {
  active('ACTIVE', Colors.greenAccent),
  standby('STANDBY', Colors.orangeAccent),
  idle('IDLE', Colors.grey);

  final String label;
  final Color color;
  const _Status(this.label, this.color);

  String explain(List<String> short) => switch (this) {
        _Status.active => 'Working: it takes its inputs from Central Storage and puts what it makes back.',
        _Status.standby => 'Waiting for ${short.join(', ')} in Central Storage.',
        _Status.idle => 'Switched off. Switch it on to work.',
      };
}

/// What the recipe needs that Central Storage doesn't have enough of for one batch.
List<String> _short(Company co, Map<String, dynamic> rec) {
  final stock = co.stock;
  return [
    for (final e in (rec['inputs'] as Map).entries)
      if (((stock[e.key] as num?) ?? 0) < (e.value as num)) co.itemName(e.key as String).toLowerCase(),
    if ((rec['kwh'] as num) > 0 && ((stock['electricity'] as num?) ?? 0) < (rec['kwh'] as num) * 1000) 'electricity',
  ];
}

_Status _status(Company co, Map<String, dynamic> p) {
  if (p['running'] != true) return _Status.idle;
  final rec = (p['recipes'] as List)[(p['recipe'] as num).toInt()] as Map<String, dynamic>;
  return _short(co, rec).isEmpty ? _Status.active : _Status.standby;
}

Widget _statusBadge(_Status s, String text) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: s.color.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(6)),
      child: Text(text, style: TextStyle(color: s.color, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
    );

/// "12 lumber", "5 kWh", "0.4 mg tantalum-180m".
String _qty(Company co, String item, num q) {
  final name = co.itemName(item).toLowerCase();
  if (item == 'electricity') return '${fmtNum(q)} kWh';
  if (item == 'ta180m') return '${fmtNum(q)} mg $name';
  return '${fmtNum(q)} $name';
}

Widget _itemIcon(String item, {double size = 16}) => item == 'electricity'
    ? Icon(Icons.bolt, size: size, color: Colors.amberAccent)
    : SizedBox(
        width: size, height: size,
        child: ClipRRect(borderRadius: BorderRadius.circular(size / 5),
            child: Image.asset(itemPicture(item), fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Icon(Icons.inventory_2_outlined, size: size - 2, color: AppColors.t38))),
      );

/// Just the pictures: the inputs (and electricity), then the product (cards).
Widget _recipeIcons(Map<String, dynamic> rec, {double size = 22}) => Row(mainAxisSize: MainAxisSize.min, children: [
      for (final e in (rec['inputs'] as Map).keys) ...[_itemIcon(e as String, size: size), const SizedBox(width: 3)],
      if ((rec['kwh'] as num) > 0) ...[_itemIcon('electricity', size: size), const SizedBox(width: 3)],
      Icon(Icons.chevron_right, size: size * 0.8, color: AppColors.t38),
      _itemIcon(rec['output'] as String, size: size),
    ]);

/// The recipe per hour for `level` levels: each input with its amount, then the product.
Widget _recipeFlow(Company co, Map<String, dynamic> rec, int level) {
  final per = level / (rec['hours'] as num).toDouble();          // batches per hour
  final inputs = (rec['inputs'] as Map).cast<String, dynamic>();
  final kwh = (rec['kwh'] as num).toDouble();
  Widget chip(String item, num q, {bool out = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: out ? Colors.greenAccent.withValues(alpha: 0.10) : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _itemIcon(item, size: 22),
          const SizedBox(width: 6),
          Text(_qty(co, item, q), style: TextStyle(fontSize: 12, fontWeight: out ? FontWeight.bold : null)),
        ]),
      );
  return Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, runSpacing: 6, children: [
    for (final e in inputs.entries) chip(e.key, (e.value as num) * per),
    if (kwh > 0) chip('electricity', kwh * per),
    Icon(Icons.chevron_right, color: AppColors.t38),
    chip(rec['output'] as String, (rec['qty'] as num) * per, out: true),
    Text('per hour', style: TextStyle(fontSize: 11, color: AppColors.t54)),
  ]);
}

/// Electricity at a glance (owner 2026-10-31: don't forget energy): what solar and wind hexes and
/// power plants make, what the active plants use, what is stored and how long it lasts.
class _EnergyCard extends StatelessWidget {
  final Company co;
  final List<Map<String, dynamic>> plants;
  const _EnergyCard({required this.co, required this.plants});

  @override
  Widget build(BuildContext context) {
    final income = (co.state['incomePerHour'] as Map?) ?? const {};
    final fromHexes = ((income['electricity'] as num?) ?? 0) / 1000;               // Wh per hour
    var fromPlants = 0.0, used = 0.0;
    for (final p in plants) {
      if (p['running'] != true) continue;
      final rec = (p['recipes'] as List)[(p['recipe'] as num).toInt()] as Map<String, dynamic>;
      final per = (p['level'] as num) / (rec['hours'] as num);
      if (rec['output'] == 'electricity') fromPlants += (rec['qty'] as num) * per;
      used += (rec['kwh'] as num) * per;
    }
    final made = fromHexes + fromPlants;
    final stored = ((co.stock['electricity'] as num?) ?? 0) / 1000;
    final net = made - used;
    final lasts = net < 0 && used > 0 ? stored / -net : null;
    final share = made + used <= 0 ? 0.5 : made / (made + used);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.amberAccent.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.amberAccent.withValues(alpha: 0.25))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Icon(Icons.bolt, color: Colors.amberAccent),
          const SizedBox(width: 6),
          const Expanded(child: Text('Electricity', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15))),
          Text('${fmtNum(stored)} kWh stored', style: TextStyle(fontSize: 12, color: AppColors.t70)),
        ]),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: share, minHeight: 8,
              backgroundColor: Colors.redAccent.withValues(alpha: 0.5), color: Colors.amberAccent),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: Text('Made ${fmtNum(made)} kWh/h', style: const TextStyle(fontSize: 12))),
          Text('Used ${fmtNum(used)} kWh/h', style: const TextStyle(fontSize: 12)),
        ]),
        const SizedBox(height: 4),
        Text(
          made + used == 0
              ? 'Solar and wind farms (Power on the map) and power plants make electricity; many plants need it.'
              : net >= 0
                  ? 'You make ${fmtNum(net)} kWh/h more than your plants use: the rest is stored.'
                  : stored < 1
                      ? 'Your plants need ${fmtNum(-net)} kWh/h more than you make and none is stored: '
                          'plants that need electricity wait (STANDBY). Build solar or wind farms, or a power plant.'
                      : 'Your plants need ${fmtNum(-net)} kWh/h more than you make. The stored electricity '
                          'covers that for ${lasts! < 1 ? 'less than an hour' : 'about ${fmtNum(lasts.round())} h'}; '
                          'after that, plants that need it wait (STANDBY).',
          style: TextStyle(fontSize: 11, color: net < 0 ? Colors.orangeAccent : AppColors.t54),
        ),
      ]),
    );
  }
}

/// One of your plants: picture with its status, name, level and the recipe as pictures.
class _PlantCard extends StatelessWidget {
  final Map<String, dynamic> plant;
  final Company co;
  final _Status status;
  final VoidCallback onTap;
  const _PlantCard({super.key, required this.plant, required this.co, required this.status, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = plant;
    final rec = (p['recipes'] as List)[(p['recipe'] as num).toInt()] as Map<String, dynamic>;
    return Material(
      color: Colors.white.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Stack(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(aspectRatio: 1.6, child: Opacity(
                  opacity: status == _Status.idle ? 0.45 : 1,
                  child: Image.asset(plantPicture(p['key'] as String), fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Icon(Icons.factory, size: 40, color: AppColors.accent)),
                )),
              ),
              Positioned(top: 6, left: 6, child: _statusBadge(status, status.label)),
              Positioned(
                top: 6, right: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                  child: Text('Lv ${p['level']}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold,
                      color: Colors.white)),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Text(p['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: _recipeIcons(rec, size: 20)),
          ]),
        ),
      ),
    );
  }
}

/// A plant you can build (or will, at a bigger Campus): picture, name, price or the level it needs.
class _NewPlantCard extends StatelessWidget {
  final Map<String, dynamic> plant;
  final Company co;
  final VoidCallback onTap;
  const _NewPlantCard({required this.plant, required this.co, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = plant;
    final locked = p['unlocked'] != true;
    final cost = (p['nextCost'] as num).toDouble();
    final rec = ((p['recipes'] as List).first as Map).cast<String, dynamic>();
    return Opacity(
      opacity: locked ? 0.5 : 1,
      child: Material(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(aspectRatio: 1.6, child: Image.asset(plantPicture(p['key'] as String), fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Icon(Icons.factory, size: 40, color: AppColors.accent))),
              ),
              const SizedBox(height: 8),
              Text(p['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: _recipeIcons(rec, size: 20)),
              const SizedBox(height: 4),
              Row(children: locked
                  ? [Icon(Icons.lock_outline, size: 13, color: Colors.orangeAccent), const SizedBox(width: 3),
                      Text('Campus ${p['unlock']}', style: const TextStyle(fontSize: 12, color: Colors.orangeAccent))]
                  : [CreditsIcon(size: 14, ok: co.credits >= cost), const SizedBox(width: 3),
                      Text(fmtNum(cost), style: TextStyle(fontSize: 12,
                          color: co.credits >= cost ? AppColors.t70 : Colors.redAccent))]),
            ]),
          ),
        ),
      ),
    );
  }
}
