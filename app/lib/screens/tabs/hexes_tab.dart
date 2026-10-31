import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_colors.dart';
import '../../constants.dart' show fmtNum;
import '../../models/player.dart';
import '../../models/player_provider.dart';
import '../../services/game_api.dart';
import '../../v3/company.dart';
import '../../v3/hex_sheet.dart';
import '../../widgets/async_view.dart' show HexClipper, HexPicture;
import '../../widgets/glass.dart' show tabPadding;
import '../../widgets/slide_confirm.dart';
import '../../widgets/top_banner.dart';

/// Hexes (0.2.3 redo, owner 2026-10-31; the 1.2.3 mine list followed the original game): a summary,
/// the leases that end soon with one slide to renew them, then a honeycomb of your resources. A
/// resource opens its hexes as cards: lease bar, quality, output, supervisor, renew.
class HexesTab extends StatefulWidget {
  const HexesTab({super.key});
  @override
  State<HexesTab> createState() => _HexesTabState();
}

const _kDueDays = 7;                     // "ends soon"

/// Lease left: red under 7 days, amber under 30, green otherwise.
Color _leaseColor(double days) => days < _kDueDays ? Colors.redAccent : days < 30 ? Colors.amber : Colors.greenAccent;

String _picture(Hex m) => m.item == 'electricity'
    ? 'assets/game/operations/${m.op}.png'
    : 'assets/game/items/${m.item}.png';

double _price(Company co, String item) {
  final p = ((co.catalog['items'] as Map?)?[item]?['price'] as num?)?.toDouble() ?? 0;
  return item == 'electricity' ? p / 1000 : p;                       // hexes make Wh
}

/// Renew several leases at once (only those that can be renewed now); true when done.
Future<bool> _renew(BuildContext context, List<Hex> hexes) async {
  final ids = hexes.where((m) => m.renewInHours <= 0).map((m) => m.id).toList();
  if (ids.isEmpty) return false;
  final prov = context.read<PlayerProvider>();
  final r = await GameApi.call('/api/v3/hex/renew', prov.sid, {'ids': ids.join(',')});
  if (!context.mounted) return false;
  AppNotify.show(context, r.ok ? 'Renewed ${ids.length} lease${ids.length == 1 ? '' : 's'}: 90 days each'
      : (r.message ?? 'Could not renew'), isError: !r.ok);
  context.read<Company>().refresh();
  await prov.loadMines();
  return r.ok;
}

class _HexesTabState extends State<HexesTab> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) context.read<PlayerProvider>().loadMines(); });
  }

  @override
  Widget build(BuildContext context) {
    final prov = context.watch<PlayerProvider>();
    final co = context.watch<Company>();
    final all = prov.mines?.where((m) => m.op != 'campus').toList();
    if (all == null) return const Center(child: CircularProgressIndicator());
    final groups = <String, List<Hex>>{};
    for (final m in all) {
      groups.putIfAbsent(m.item, () => []).add(m);
    }
    final order = groups.keys.toList()
      ..sort((a, b) => (groups[b]!.length).compareTo(groups[a]!.length));
    final value = all.fold<double>(0, (s, m) => s + m.rateHr * _price(co, m.item));
    final due = all.where((m) => m.leaseDays < _kDueDays).toList();
    final dueNow = due.where((m) => m.renewInHours <= 0).toList();
    final dueCost = dueNow.fold<int>(0, (s, m) => s + m.renewPrice);

    return RefreshIndicator(
      onRefresh: prov.loadMines,
      child: ListView(padding: tabPadding(context, 12), children: [
        Row(children: [
          Expanded(child: _stat('Hexes', fmtNum(all.length), Icons.hexagon_outlined)),
          const SizedBox(width: 8),
          Expanded(child: _stat('Worth / hour', 'ꞓ${fmtNum(value.round())}', Icons.trending_up)),
          const SizedBox(width: 8),
          Expanded(child: _stat('Resources', fmtNum(groups.length), Icons.category_outlined)),
        ]),
        if (due.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.redAccent.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.redAccent.withValues(alpha: 0.35))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                const Icon(Icons.timer_outlined, color: Colors.redAccent, size: 18),
                const SizedBox(width: 6),
                Expanded(child: Text('${due.length} lease${due.length == 1 ? ' ends' : 's end'} within $_kDueDays days',
                    style: const TextStyle(fontWeight: FontWeight.bold))),
              ]),
              const SizedBox(height: 4),
              Text('A hex whose lease runs out is lost. Renewing sets it back to 90 days.',
                  style: TextStyle(fontSize: 12, color: AppColors.t54)),
              if (dueNow.isNotEmpty) ...[
                const SizedBox(height: 10),
                SlideToConfirm(
                  label: 'Renew ${dueNow.length}',
                  sublabel: 'ꞓ${fmtNum(dueCost)}',
                  icon: Icons.autorenew,
                  height: 56,
                  radius: 14,
                  enabled: co.credits >= dueCost,
                  onConfirm: () => _renew(context, dueNow),
                ),
              ],
            ]),
          ),
        ],
        const SizedBox(height: 16),
        if (all.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Text('No hexes yet. Survey on the map, then build where the colours are hot.',
                textAlign: TextAlign.center, style: TextStyle(color: AppColors.t54)),
          )
        else
          LayoutBuilder(builder: (context, c) {
            final w = (c.maxWidth - 16) / 3;
            return Wrap(spacing: 8, runSpacing: 12, alignment: WrapAlignment.center, children: [
              for (final item in order)
                SizedBox(width: w, child: _ResourceHex(item: item, hexes: groups[item]!, co: co,
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => _HexGroupPage(item: item))))),
            ]);
          }),
      ]),
    );
  }

  Widget _stat(String label, String value, IconData icon) => Container(
        height: 64,
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(14)),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 14, color: AppColors.accent),
            const SizedBox(width: 4),
            FittedBox(child: Text(value, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15))),
          ]),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 10, color: AppColors.t54)),
        ]),
      );
}

/// One resource in the honeycomb: its hex picture, how many hexes, what they make; a red ring when a
/// lease ends soon.
class _ResourceHex extends StatelessWidget {
  final String item;
  final List<Hex> hexes;
  final Company co;
  final VoidCallback onTap;
  const _ResourceHex({required this.item, required this.hexes, required this.co, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final rate = hexes.fold<double>(0, (s, m) => s + m.rateHr);
    final soon = hexes.any((m) => m.leaseDays < _kDueDays);
    final unit = item == 'electricity' ? ' kWh' : '';
    final perHour = item == 'electricity' ? rate / 1000 : rate;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(children: [
        Stack(alignment: Alignment.center, children: [
          // a red hex behind a slightly smaller picture: a ring when a lease ends soon
          ClipPath(
            clipper: const HexClipper(),
            child: Container(width: 92, height: 92 * 0.866, color: soon ? Colors.redAccent : Colors.transparent),
          ),
          HexPicture(_picture(hexes.first), size: soon ? 84 : 92),
          Positioned(
            bottom: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(8)),
              child: Text('×${hexes.length}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
            ),
          ),
        ]),
        const SizedBox(height: 4),
        Text(co.itemName(item), maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
        Text('${fmtNum(perHour)}$unit/h', style: TextStyle(fontSize: 11, color: AppColors.t54)),
      ]),
    );
  }
}

enum _Sort { lease, quality, output }

/// The hexes of one resource as cards; hold one to choose hexes to cancel.
class _HexGroupPage extends StatefulWidget {
  final String item;
  const _HexGroupPage({required this.item});
  @override
  State<_HexGroupPage> createState() => _HexGroupPageState();
}

class _HexGroupPageState extends State<_HexGroupPage> {
  _Sort _sort = _Sort.lease;
  bool _asc = true;                                // tap the chosen sort again to turn it around
  bool _busy = false;
  final _selected = <String>{};                    // hold a hex to start choosing hexes to cancel

  Future<void> _run(Future<void> Function() fn) async {
    if (_busy) return;
    setState(() => _busy = true);
    try { await fn(); } finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _call(String path, Map<String, Object?> p, String ok) => _run(() async {
        final prov = context.read<PlayerProvider>();
        final r = await GameApi.call(path, prov.sid, p);
        if (!mounted) return;
        AppNotify.show(context, r.ok ? ok : (r.message ?? 'Failed'), isError: !r.ok);
        context.read<Company>().refresh();
        await prov.loadMines();
      });

  void _pickSort(_Sort s) => setState(() {
        if (_sort == s) {
          _asc = !_asc;
        } else {
          _sort = s;
          _asc = s == _Sort.lease;                 // soonest lease first, best quality / output first
        }
      });

  static String _lease(double days) {
    final d = days.floor(), h = ((days - d) * 24).floor();
    return d > 0 ? '$d d $h h' : '$h h';
  }

  @override
  Widget build(BuildContext context) {
    final prov = context.watch<PlayerProvider>();
    final co = context.watch<Company>();
    final hexes = (prov.mines ?? const <Hex>[]).where((m) => m.item == widget.item && m.op != 'campus').toList();
    int cmp(Hex a, Hex b) => switch (_sort) {
          _Sort.lease => a.leaseDays.compareTo(b.leaseDays),
          _Sort.quality => a.quality.compareTo(b.quality),
          _Sort.output => a.rateHr.compareTo(b.rateHr),
        };
    hexes.sort((a, b) => _asc ? cmp(a, b) : cmp(b, a));
    _selected.retainAll(hexes.map((m) => m.id));
    final choosing = _selected.isNotEmpty;
    final renewable = hexes.where((m) => m.renewInHours <= 0).toList();
    final cost = renewable.fold<int>(0, (s, m) => s + m.renewPrice);
    final waitH = hexes.isEmpty ? 0.0 : hexes.map((m) => m.renewInHours).reduce((a, b) => a < b ? a : b);
    final chosen = hexes.where((m) => _selected.contains(m.id)).toList();
    final refund = chosen.fold<int>(0, (s, m) => s + m.cancelRefund);
    final unit = widget.item == 'electricity' ? ' kWh' : '';
    double shown(double r) => widget.item == 'electricity' ? r / 1000 : r;
    final steps = (co.catalog['education'] as List?) ?? const [];
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 40,
        title: Text(choosing ? '${_selected.length} chosen' : co.itemName(widget.item)),
        leading: choosing ? IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_selected.clear)) : null,
        actions: [
          if (choosing)
            TextButton(onPressed: () => setState(() => _selected.addAll(hexes.map((m) => m.id))), child: const Text('All')),
        ],
      ),
      bottomNavigationBar: !choosing ? null : SafeArea(child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('The hexes are given back and anyone can build there. You get ꞓ${fmtNum(refund)} back '
              '(30 % of what is left of their leases).', textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.t54)),
          const SizedBox(height: 8),
          SlideToConfirm(
            label: 'Cancel ${chosen.length} lease${chosen.length == 1 ? '' : 's'}',
            sublabel: '+ꞓ${fmtNum(refund)}',
            icon: Icons.delete_outline,
            height: 56,
            radius: 14,
            enabled: !_busy,
            busy: _busy,
            onConfirm: () => _call('/api/v3/hex/cancel', {'ids': chosen.map((m) => m.id).join(',')},
                'Cancelled ${chosen.length} lease${chosen.length == 1 ? '' : 's'}: ꞓ${fmtNum(refund)} back')
                .then((_) { if (mounted) setState(_selected.clear); }),
          ),
        ]),
      )),
      body: hexes.isEmpty
          ? Center(child: Text('No hexes left here.', style: TextStyle(color: AppColors.t54)))
          : ListView(padding: const EdgeInsets.all(14), children: [
              Row(children: [
                HexPicture(_picture(hexes.first), size: 64),
                const SizedBox(width: 14),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${hexes.length} hex${hexes.length == 1 ? '' : 'es'}',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  Text('${fmtNum(shown(hexes.fold<double>(0, (s, m) => s + m.rateHr)))}$unit per hour · '
                      '${hexes.where((m) => m.edu != null).length} with a supervisor',
                      style: TextStyle(fontSize: 12, color: AppColors.t54)),
                ])),
              ]),
              const SizedBox(height: 12),
              if (hexes.length > 1 && !choosing)
                renewable.isEmpty
                    ? Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(14)),
                        child: Text('Renew all: a lease can be renewed a day after it was built or last renewed '
                            '(next in ${waitH.ceil()} h).', textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 12, color: AppColors.t54)),
                      )
                    : SlideToConfirm(
                        label: 'Renew all ${renewable.length}',
                        sublabel: 'ꞓ${fmtNum(cost)}',
                        icon: Icons.autorenew,
                        height: 56,
                        radius: 14,
                        enabled: !_busy && co.credits >= cost,
                        busy: _busy,
                        onConfirm: () => _run(() async { await _renew(context, renewable); }),
                      ),
              const SizedBox(height: 10),
              Row(children: [
                for (final (s, label) in const [(_Sort.lease, 'Lease'), (_Sort.quality, 'Quality'), (_Sort.output, 'Output')])
                  Padding(padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Row(mainAxisSize: MainAxisSize.min, children: [
                          Text(label),
                          if (_sort == s) Icon(_asc ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, size: 16),
                        ]),
                        selected: _sort == s, visualDensity: VisualDensity.compact,
                        onSelected: (_) => _pickSort(s))),
                const Spacer(),
                if (!choosing)
                  Text('Hold to choose', style: TextStyle(fontSize: 11, color: AppColors.t38)),
              ]),
              const SizedBox(height: 8),
              for (final m in hexes) _hexCard(co, m, steps, unit, shown, choosing),
            ]),
    );
  }

  Widget _hexCard(Company co, Hex m, List steps, String unit, double Function(double) shown, bool choosing) {
    final lc = _leaseColor(m.leaseDays);
    final sup = m.edu == null ? null : (m.edu! < steps.length ? steps[m.edu!]['name'] as String : 'Supervisor');
    final picked = _selected.contains(m.id);
    void toggle() => setState(() => picked ? _selected.remove(m.id) : _selected.add(m.id));
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: picked ? Colors.redAccent.withValues(alpha: 0.14) : Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onLongPress: toggle,
          onTap: choosing ? toggle : () async {
            await showHexSheet(context, int.parse(m.id));
            if (mounted) context.read<PlayerProvider>().loadMines();
          },
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                if (choosing) ...[
                  Icon(picked ? Icons.check_circle : Icons.radio_button_unchecked, size: 20,
                      color: picked ? Colors.redAccent : AppColors.t38),
                  const SizedBox(width: 8),
                ],
                Text('Q ${m.quality}%', style: TextStyle(fontWeight: FontWeight.bold,
                    color: m.quality > 70 ? Colors.greenAccent : m.quality > 40 ? Colors.amber : Colors.orange)),
                const SizedBox(width: 10),
                Text('${fmtNum(shown(m.rateHr))}$unit/h', style: TextStyle(color: AppColors.t70, fontSize: 13)),
                const Spacer(),
                Icon(Icons.person_outline, size: 15, color: sup == null ? AppColors.t38 : Colors.purpleAccent),
                const SizedBox(width: 3),
                Text(sup ?? 'No supervisor', style: TextStyle(fontSize: 12,
                    color: sup == null ? AppColors.t38 : Colors.purpleAccent)),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(value: (m.leaseDays / 90).clamp(0.0, 1.0), minHeight: 6,
                      backgroundColor: Colors.white12, color: lc),
                )),
                const SizedBox(width: 8),
                Text(_lease(m.leaseDays), style: TextStyle(fontSize: 12, color: lc, fontWeight: FontWeight.bold)),
              ]),
              if (!choosing) ...[
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: OutlinedButton.icon(
                    onPressed: _busy || m.renewInHours > 0 ? null
                        : () => _call('/api/v3/hex/renew', {'ids': m.id}, 'Lease renewed: 90 days'),
                    icon: const Icon(Icons.autorenew, size: 16),
                    label: FittedBox(child: Text(m.renewInHours > 0 ? 'In ${m.renewInHours.ceil()} h'
                        : 'Renew ꞓ${fmtNum(m.renewPrice)}')),
                  )),
                  const SizedBox(width: 8),
                  Expanded(child: OutlinedButton.icon(
                    onPressed: _busy ? null : () => m.edu == null
                        ? _call('/api/v3/supervisors/assign', {'hex': m.id}, 'Supervisor appointed')
                        : _call('/api/v3/supervisors/unassign', {'hex': m.id}, 'The supervisor went back to the Campus'),
                    icon: Icon(m.edu == null ? Icons.person_add_alt : Icons.person_remove_alt_1_outlined, size: 16),
                    label: Text(m.edu == null ? 'Appoint' : 'Recall'),
                  )),
                ]),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
