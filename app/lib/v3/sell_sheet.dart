import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../constants.dart' show fmtNum;
import '../widgets/async_view.dart' show GameItemIcon;
import '../widgets/popups.dart';
import '../widgets/top_banner.dart';
import 'company.dart';

/// How far below the best price the player still sells (owner 2026-10-31: asked instead of an
/// "All" button; the slider already reaches 100 %). -1: any price, down to the system's.
const _kDrops = [0.0, 0.05, 0.10, 0.25, -1.0];
String _dropLabel(double d) =>
    d < 0 ? 'Down to system price' : d == 0 ? 'Best price only' : 'Up to ${(d * 100).round()} % less';

/// Stored units to what the player sees (electricity is stored in Wh, shown in kWh).
double _shown(String item, num q) => item == 'electricity' ? q / 1000 : q.toDouble();
String _unit(String item) => item == 'electricity' ? ' kWh' : '';

/// Sell [item] from Central Storage (Storage tab and the Market item page): into the best buy
/// orders of other companies first, the rest to the system at its price, never below the chosen
/// lowest price; the seller pays the sales tax (server: /api/v3/sell). [have] is in stored units.
/// [busy] reports while the server is asked. Returns whether something was sold.
Future<bool> showSellSheet(BuildContext context, Company co, String item, double have,
    {void Function(bool)? busy}) async {
  final shownHave = _shown(item, have);
  var qty = shownHave.floorToDouble();
  if (qty <= 0) return false;
  busy?.call(true);
  final q = await co.call('/api/v3/sell/quote', {'item': item});
  busy?.call(false);
  if (!context.mounted) return false;
  if (!q.ok) {
    AppNotify.show(context, q.message ?? 'Could not load the prices', isError: true);
    return false;
  }
  final system = (q.data['system'] as num).toDouble();
  final taxRate = (q.data['taxRate'] as num? ?? 0).toDouble();       // the seller pays it
  // the buy orders, best first, then the system (takes everything at its price)
  final levels = <(double, double, String?)>[
    for (final l in (q.data['levels'] as List).cast<Map<String, dynamic>>())
      ((l['price'] as num).toDouble(), (l['qty'] as num).toDouble(), l['name'] as String?),
    (system, double.infinity, null),
  ];
  final best = levels.first.$1;
  // steps that stay above the system price, then the system price itself (the lowest there is)
  final drops = [for (final d in _kDrops) if (d <= 0 || best * (1 - d) > system) d];
  var drop = 0.0;
  double minPrice() => drop < 0 ? 0 : best * (1 - drop);

  /// (to orders, to the system, credits after tax, left in storage) for the current amount and drop.
  (double, double, double, double) plan() {
    var left = qty, toOrders = 0.0, toSystem = 0.0, credits = 0.0;
    for (final (price, avail, name) in levels) {
      if (left <= 0 || price < minPrice() - 1e-9) break;
      final take = name == null ? left : (left.floorToDouble() < avail ? left.floorToDouble() : avail);
      if (take <= 0) continue;
      credits += take * price;
      left -= take;
      if (name == null) { toSystem += take; } else { toOrders += take; }
    }
    return (toOrders, toSystem, credits * (1 - taxRate), left);
  }

  final raw = (co.catalog['raw'] as Map?)?.containsKey(item) ?? false;
  final ok = await showAppSheet<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final (toOrders, toSystem, credits, left) = plan();
      final sold = qty - left;
      final more = qty > (levels.first.$3 == null ? double.infinity : levels.first.$2);   // more than the best order takes
      final u = _unit(item);
      String pr(double v) => 'ꞓ${v < 10 ? v.toStringAsFixed(2) : fmtNum(v)}';
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            GameItemIcon(item, size: 36, hex: raw),
            const SizedBox(width: 10),
            Expanded(child: Text('Sell ${co.itemName(item).toLowerCase()}',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
          ]),
          const SizedBox(height: 4),
          Text(levels.first.$3 != null
              ? 'Best price ${pr(best)}${u.isEmpty ? '' : ' per$u'}: ${levels.first.$3} buys ${fmtNum(levels.first.$2)}'
              : 'System price ${pr(system)}${u.isEmpty ? '' : ' per$u'} (no buy orders above it)',
              style: TextStyle(color: AppColors.t54, fontSize: 12)),
          Text('You have ${fmtNum(shownHave)}$u', style: TextStyle(color: AppColors.t54, fontSize: 12)),
          const SizedBox(height: 16),
          if (shownHave >= 2)
            Slider(
              value: qty.clamp(1, shownHave.floorToDouble()),
              min: 1,
              max: shownHave.floorToDouble(),
              onChanged: (v) => set(() => qty = v.roundToDouble()),
            ),
          Row(children: [
            Expanded(child: Text('${fmtNum(sold)}$u', style: const TextStyle(fontSize: 16))),
            Text('ꞓ${fmtNum(credits.floor())}',
                style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 16)),
          ]),
          Text([
            if (toOrders > 0) '${fmtNum(toOrders)} to buy orders',
            if (toSystem > 0) '${fmtNum(toSystem)} to the system at ${pr(system)}',
            if (left > 0) '${fmtNum(left)} stays in storage',
            if (sold > 0 && taxRate > 0) 'after ${(taxRate * 100).round()}% sales tax',
          ].join(' · '), style: TextStyle(color: left > 0 ? Colors.orangeAccent : AppColors.t54, fontSize: 11)),
          const SizedBox(height: 12),
          Row(children: [
            // the lowest price still accepted, asked when the best order can't take everything
            Expanded(child: OutlinedButton(
              onPressed: !more ? null : () => set(() => drop = drops[(drops.indexOf(drop) + 1) % drops.length]),
              child: FittedBox(child: Text(more ? _dropLabel(drop) : 'At the best price')),
            )),
            const SizedBox(width: 12),
            Expanded(child: FilledButton(
                onPressed: sold > 0 ? () => popIfCurrent(ctx, true) : null, child: const Text('Sell'))),
          ]),
        ]),
      );
    }),
  );
  if (ok != true || !context.mounted) return false;
  busy?.call(true);
  final stored = item == 'electricity' ? qty * 1000 : qty;
  final r = await co.call('/api/v3/sell', {'item': item, 'qty': stored, 'minPrice': minPrice()});
  busy?.call(false);
  if (!context.mounted) return false;
  if (!r.ok) {
    AppNotify.show(context, r.message ?? 'Could not sell', isError: true);
    return false;
  }
  final unsold = (r.data['unsold'] as num? ?? 0).toDouble();
  AppNotify.show(context, 'Sold for ꞓ${fmtNum(r.data['credits'] as num)}'
      '${unsold > 0 ? ' · ${fmtNum(_shown(item, unsold))}${_unit(item)} stays in storage' : ''}');
  await co.refresh();
  return true;
}
