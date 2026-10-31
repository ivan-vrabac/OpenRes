import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_colors.dart';
import '../widgets/popups.dart';
import '../widgets/top_banner.dart';
import 'company.dart';
import '../constants.dart' show fmtNum;

/// One of your hexes: product, quality, supervisor, lease (renew, cancel), switching product.
Future<void> showHexSheet(BuildContext context, int id) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bg,
      builder: (_) => ChangeNotifierProvider.value(value: context.read<Company>(), child: _HexSheet(id: id)),
    );

class _HexSheet extends StatefulWidget {
  const _HexSheet({required this.id});
  final int id;
  @override
  State<_HexSheet> createState() => _HexSheetState();
}

class _HexSheetState extends State<_HexSheet> {
  Map<String, dynamic>? _hex;
  bool _busy = false;

  Company get co => context.read<Company>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await co.call('/api/v3/hex/detail', {'id': widget.id});
    if (!mounted) return;
    if (!r.ok) {
      popIfCurrent(context);
      return AppNotify.show(context, r.message ?? 'Hex not found', isError: true);
    }
    setState(() => _hex = (r.data['hex'] as Map).cast<String, dynamic>());
  }

  Future<void> _do(String path, Map<String, Object?> params, String done) async {
    setState(() => _busy = true);
    final r = await co.call(path, params);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!r.ok) return AppNotify.show(context, r.message ?? 'Failed', isError: true);
    AppNotify.show(context, done);
    await co.refresh();
    if (path == '/api/v3/hex/cancel') {
      if (mounted) popIfCurrent(context);
    } else {
      _load();
    }
  }

  Future<void> _cancel() async {
    final h = _hex!;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel lease?'),
        content: Text('The hex is destroyed and the spot becomes free. You get back 30 % of the remaining lease: '
            '${fmtNum(h['cancelRefund'] as num)}.'),
        actions: [
          TextButton(onPressed: () => popIfCurrent(ctx, false), child: const Text('Keep it')),
          FilledButton(onPressed: () => popIfCurrent(ctx, true), child: const Text('Cancel lease')),
        ],
      ),
    );
    if (ok == true) _do('/api/v3/hex/cancel', {'ids': widget.id}, 'Lease cancelled');
  }

  Future<void> _switch() async {
    final h = _hex!;
    final r = await co.call('/api/v3/hex/info', {'lat': h['lat'], 'lng': h['lng']});
    if (!mounted || !r.ok) return;
    final opts = ((r.data['options'] as Map)[h['op']] as Map? ?? const {}).cast<String, dynamic>();
    final pick = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.bg,
      builder: (ctx) => SafeArea(child: ListView(shrinkWrap: true, children: [
        const ListTile(title: Text('Switch product (costs one lease renewal)')),
        for (final e in opts.entries)
          if (e.key != h['item'])
            ListTile(
              enabled: e.value['unlocked'] == true,
              leading: Image.asset(itemPictureOrEnergy(h['op'] as String, e.key), width: 36, height: 36),
              title: Text(co.itemName(e.key)),
              subtitle: Text('Quality ${e.value['quality']} % · ${fmtNum(e.value['lease'] as num)}'),
              onTap: () => popIfCurrent(ctx, e.key),
            ),
      ])),
    );
    if (pick != null) _do('/api/v3/hex/switch', {'id': widget.id, 'item': pick}, 'Now producing ${co.itemName(pick)}');
  }

  @override
  Widget build(BuildContext context) {
    final h = _hex;
    if (h == null) return const SizedBox(height: 200, child: Center(child: CircularProgressIndicator()));
    final days = (h['leaseDays'] as num).toDouble();
    final renewIn = (h['renewInHours'] as num).toDouble();
    final edu = h['edu'] as num?;
    final steps = (co.catalog['education'] as List?) ?? const [];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            ClipRRect(borderRadius: BorderRadius.circular(8),
                child: Image.asset(itemPictureOrEnergy(h['op'] as String, h['item'] as String), width: 56, height: 56)),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(co.itemName(h['item'] as String), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              Text('${co.opName(h['op'] as String)} · quality ${h['quality']} %', style: TextStyle(color: AppColors.t70)),
              Text('Worth ${fmtNum(h['valuePerHour'] as num)} an hour without a supervisor',
                  style: TextStyle(color: AppColors.t54, fontSize: 12)),
            ])),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: Text(edu == null ? 'No supervisor: this hex makes the base amount'
                : 'Supervisor: ${steps.length > edu ? steps[edu.toInt()]['name'] : edu} '
                  '(+${((steps.length > edu ? steps[edu.toInt()]['boost'] : 0) * 100).round()} %)')),
            TextButton(
              onPressed: _busy ? null : () => edu == null
                  ? _do('/api/v3/supervisors/assign', {'hex': widget.id}, 'Supervisor appointed')
                  : _do('/api/v3/supervisors/unassign', {'hex': widget.id}, 'The supervisor went back to the Campus'),
              child: Text(edu == null ? 'Appoint' : 'Recall'),
            ),
          ]),
          const SizedBox(height: 8),
          Text('Lease expires in: ${fmtDuration(days)}',
              style: TextStyle(color: days < 30 ? Colors.redAccent : null, fontWeight: FontWeight.bold)),
          Text('Renewing sets it back to 90 days. The price grows with the days used, full from day 30: '
              'renewing near the end gives more days for the same price.',
              style: TextStyle(color: AppColors.t54, fontSize: 12)),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: FilledButton(
              onPressed: _busy || renewIn > 0 ? null : () => _do('/api/v3/hex/renew', {'ids': widget.id}, 'Lease renewed'),
              child: Text(renewIn > 0 ? 'Renewable in ${renewIn.ceil()} h' : 'Renew: ${fmtNum(h['renewPrice'] as num)}'),
            )),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: _busy ? null : _cancel, child: const Text('Cancel lease')),
          ]),
          if (h['op'] != 'mine' && h['op'] != 'oil_well')
            TextButton.icon(onPressed: _busy ? null : _switch, icon: const Icon(Icons.swap_horiz), label: const Text('Switch product')),
        ]),
      ),
    );
  }
}
