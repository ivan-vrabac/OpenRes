import '../../widgets/glass.dart' show tabPadding;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../constants.dart';
import '../../v3/company.dart';
import '../../v3/sell_sheet.dart';
import '../../widgets/async_view.dart' show fmtCredits;
import '../../widgets/cards.dart';
import '../../widgets/slide_confirm.dart';
import '../../widgets/top_banner.dart';

import '../../app_colors.dart';
import '../../widgets/popups.dart';

/// Central Storage (was the Warehouse in 1.2.3): everything the company has, in ONE total for all
/// items (owner 2026-10-31; electricity counts per kWh, Tantalum-180m is kept apart). Each item's bar
/// shows its share of the total. Tap an item to sell it: to the best buy orders, then the system.
class WarehouseTab extends StatefulWidget {
  const WarehouseTab({super.key});
  @override
  State<WarehouseTab> createState() => _WarehouseTabState();
}

class _WarehouseTabState extends State<WarehouseTab> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<Company>().refresh());
  }

  /// Stored units -> what the player sees (electricity is stored in Wh, shown in kWh).
  static double _shown(String item, num q) => item == 'electricity' ? q / 1000 : q.toDouble();
  static String _unit(String item) => item == 'electricity' ? ' kWh' : item == 'ta180m' ? ' mg' : '';

  double _price(Company co, String item) => ((co.catalog['items']?[item]?['price']) as num?)?.toDouble() ?? 0;
  bool _tradable(Company co, String item) => co.catalog['items']?[item]?['tradable'] == true;
  double _worth(Company co, MapEntry<String, double> e) => _shown(e.key, e.value) * _price(co, e.key);

  Future<void> _upgrade(Company co) async {
    final st = (co.state['storage'] as Map?)?.cast<String, dynamic>() ?? const {};
    final lv = (st['level'] as num?)?.toInt() ?? 1;
    final cost = (st['nextCost'] as num?)?.toDouble() ?? 0;
    final cap = (st['nextCapacity'] as num?)?.toDouble() ?? 0;
    final can = co.credits >= cost;
    final ok = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Central Storage level ${lv + 1}', textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          const SizedBox(height: 6),
          Text('Room for ${fmtNum(cap)} units in all. Electricity counts per kWh.', textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.t60)),
          const SizedBox(height: 16),
          SlideToConfirm(
            label: can ? 'Slide to upgrade' : 'Not enough credits',
            sublabel: fmtCredits(cost),
            icon: Icons.upgrade,
            enabled: can,
            radius: 14,
            onConfirm: () => popIfCurrent(ctx, true),
          ),
          const SizedBox(height: 4),
          Center(child: TextButton(onPressed: () => popIfCurrent(ctx, false), child: const Text('Cancel'))),
        ]),
      )),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final r = await co.call('/api/v3/storage/upgrade');
    if (!mounted) return;
    setState(() => _busy = false);
    if (!r.ok) {
      AppNotify.show(context, r.message ?? 'Upgrade failed', isError: true);
      return;
    }
    AppNotify.show(context, 'Central Storage level ${r.data['level']}');
    await co.refresh();
  }

  /// Sell from Central Storage (the shared sell sheet, also on the Market item page).
  Future<void> _sell(Company co, String item, double have) =>
      showSellSheet(context, co, item, have, busy: (b) { if (mounted) setState(() => _busy = b); });

  @override
  Widget build(BuildContext context) {
    final co = context.watch<Company>();
    if (co.state.isEmpty) return const Center(child: CircularProgressIndicator());
    final st = (co.state['storage'] as Map?)?.cast<String, dynamic>() ?? const {};
    final lv = (st['level'] as num?)?.toInt() ?? 1;
    final cap = (st['capacity'] as num?)?.toDouble() ?? 0;
    final nextCost = (st['nextCost'] as num?)?.toDouble() ?? 0;
    final entries = co.stock.entries
        .map((e) => MapEntry(e.key, (e.value as num).toDouble()))
        .where((e) => _shown(e.key, e.value) >= 0.01)
        .toList()
      ..sort((a, b) => _worth(co, b).compareTo(_worth(co, a)));
    final value = entries.fold<double>(0, (a, e) => a + _worth(co, e));
    final used = (st['used'] as num?)?.toDouble() ?? 0;
    final usedShare = cap <= 0 ? 0.0 : (used / cap).clamp(0.0, 1.0);
    final full = usedShare >= 0.999;

    const special = {'electricity', 'ta180m'};
    final raw = (co.catalog['raw'] as Map?) ?? const {};
    final groups = <String, List<MapEntry<String, double>>>{
      'Raw materials': [for (final e in entries) if (raw.containsKey(e.key) && !special.contains(e.key)) e],
      'Products': [for (final e in entries) if (!raw.containsKey(e.key) && !special.contains(e.key)) e],
      'Special': [for (final e in entries) if (special.contains(e.key)) e],
    };

    return RefreshIndicator(
      onRefresh: co.refresh,
      child: ListView(
        padding: tabPadding(context, 12),
        children: [
          Panel(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Central Storage', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                Text('Level $lv', style: TextStyle(fontSize: 12, color: AppColors.accent, fontWeight: FontWeight.w600)),
              ])),
              OutlinedButton.icon(
                icon: const Icon(Icons.upgrade, size: 16),
                label: Text(fmtCredits(nextCost)),
                onPressed: _busy ? null : () => _upgrade(co),
              ),
            ]),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: usedShare, minHeight: 8, backgroundColor: Colors.white12,
                  color: full ? Colors.orangeAccent : usedShare > 0.9 ? Colors.amber : AppColors.accent),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: Text('${fmtNum(used)} of ${fmtNum(cap)} units (${(usedShare * 100).toStringAsFixed(0)} %)',
                  style: const TextStyle(fontSize: 12))),
              Text('Worth ${fmtCredits(value)}', style: TextStyle(fontSize: 12, color: AppColors.t60)),
            ]),
            if (full)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('Storage is full: hexes and plants stop adding to it',
                    style: TextStyle(fontSize: 12, color: Colors.orangeAccent)),
              ),
          ])),
          const SizedBox(height: 16),
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Text('Central Storage is empty.\nBuild hexes on the map to produce raw materials.',
                  textAlign: TextAlign.center, style: TextStyle(color: AppColors.t54)),
            ),
          for (final g in groups.entries)
            if (g.value.isNotEmpty) ...[
              SectionLabel(g.key),
              for (final e in g.value) _itemCard(co, e, cap),
              const SizedBox(height: 12),
            ],
        ],
      ),
    );
  }

  Widget _itemCard(Company co, MapEntry<String, double> e, double cap) {
    final shown = _shown(e.key, e.value);
    final tradable = _tradable(co, e.key);
    final apart = e.key == 'ta180m';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: tradable && !_busy ? () => _sell(co, e.key, e.value) : null,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(children: [
              _ItemIcon(item: e.key, name: co.itemName(e.key)),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(co.itemName(e.key), maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                const SizedBox(height: 5),
                if (apart)
                  Text('Not for sale: for dark matter research', style: TextStyle(fontSize: 11, color: AppColors.t38))
                else
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: cap <= 0 ? 0 : (shown / cap).clamp(0.0, 1.0),
                      minHeight: 3, backgroundColor: Colors.white12, color: AppColors.accent,
                    ),
                  ),
              ])),
              const SizedBox(width: 12),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('${fmtNum(shown)}${_unit(e.key)}',
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.amber, fontSize: 14)),
                if (tradable)
                  Text(fmtCredits(shown * _price(co, e.key)), style: TextStyle(fontSize: 11, color: AppColors.t54)),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

class _ItemIcon extends StatelessWidget {
  final String item;
  final String name;
  const _ItemIcon({required this.item, required this.name});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 40, height: 40,
        child: item == 'electricity'
            ? const Icon(Icons.bolt, size: 34, color: Colors.amberAccent)
            : ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.asset(itemPicture(item), fit: BoxFit.cover, gaplessPlayback: true,
                    errorBuilder: (_, __, ___) => CircleAvatar(
                      radius: 20,
                      backgroundColor: AppColors.accent.withValues(alpha: 0.3),
                      child: Text(name.isNotEmpty ? name[0] : '?',
                          style: TextStyle(color: AppColors.accent, fontSize: 14, fontWeight: FontWeight.bold)),
                    )),
              ),
      );
}
