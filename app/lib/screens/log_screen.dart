import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../app_colors.dart';
import '../constants.dart' show fmtNum;
import '../models/player_provider.dart';
import '../services/api_service.dart';
import '../v3/company.dart';
import '../widgets/cards.dart';

/// Activity log (Account > Activity log): what your company did in the last 7 days, newest first,
/// one block per day. Coordinates are links: tapping one shows the place on the map.
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});
  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  final List<Map<String, dynamic>> _entries = [];
  bool _loading = true;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    setState(() => _loading = true);
    final r = await ApiService.getLog(context.read<PlayerProvider>().sid, offset: more ? _entries.length : 0);
    if (!mounted) return;
    setState(() {
      if (!more) _entries.clear();
      _entries.addAll(((r?['entries'] as List?) ?? const []).cast<Map<String, dynamic>>());
      _total = (r?['total'] as num?)?.toInt() ?? _entries.length;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final canPop = ModalRoute.of(context)?.canPop == true;
    // one card per day, newest first
    final days = <String, List<(Map<String, dynamic>, DateTime?)>>{};
    for (final e in _entries) {
      final ts = DateTime.tryParse('${e['ts']}Z')?.toLocal();
      (days[ts == null ? '' : _dayName(ts)] ??= []).add((e, ts));
    }
    return Scaffold(
      appBar: canPop ? AppBar(toolbarHeight: 40, title: const Text('Activity log')) : null,
      body: _loading && _entries.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(12, 10, 12, 16), children: [
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 10),
                  child: Text('The last 7 days. Tap a place to see it on the map.',
                      style: TextStyle(fontSize: 12, color: AppColors.t54)),
                ),
                if (_entries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Center(child: Text('Nothing yet', style: TextStyle(color: AppColors.t54))),
                  ),
                for (final d in days.entries) ...[
                  SectionLabel(d.key),
                  RowGroup([for (final (e, ts) in d.value) _tile(e, ts)]),
                  const SizedBox(height: 14),
                ],
                if (_entries.length < _total)
                  OutlinedButton(
                    onPressed: _loading ? null : () => _load(more: true),
                    child: const Text('Show older'),
                  ),
              ]),
            ),
    );
  }

  static String _dayName(DateTime t) {
    final now = DateTime.now();
    final days = DateTime(now.year, now.month, now.day).difference(DateTime(t.year, t.month, t.day)).inDays;
    return days == 0 ? 'Today' : days == 1 ? 'Yesterday' : '${t.year}-${_2(t.month)}-${_2(t.day)}';
  }

  static String _2(int v) => v.toString().padLeft(2, '0');

  Widget _tile(Map<String, dynamic> e, DateTime? ts) {
    final type = e['type'] as String? ?? '';
    final data = (e['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final lat = (data['lat'] as num?)?.toDouble(), lng = (data['lng'] as num?)?.toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 24, child: Icon(_icon(type), size: 20, color: _color(type))),
        const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_label(type, data), style: const TextStyle(fontSize: 13)),
          if (lat != null && lng != null)
            InkWell(
              onTap: () => showOnMap(LatLng(lat, lng)),
              child: Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.place_outlined, size: 13, color: AppColors.accent),
                  const SizedBox(width: 2),
                  Text('${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
                      style: TextStyle(fontSize: 11, color: AppColors.accent)),
                ]),
              ),
            ),
        ])),
        const SizedBox(width: 8),
        Text(ts == null ? '' : '${_2(ts.hour)}:${_2(ts.minute)}', style: TextStyle(fontSize: 11, color: AppColors.t38)),
      ]),
    );
  }

  static String _c(dynamic v) => 'ꞓ${fmtNum((v as num?) ?? 0)}';

  static String _label(String t, Map<String, dynamic> d) {
    switch (t) {
      case 'hex_built': return 'Built a ${d['name']} hex (quality ${d['quality']}) for ${_c(d['cost'])}';
      case 'hex_renewed':
        return d['n'] == 1 ? 'Renewed the lease of a ${d['name']} hex for ${_c(d['cost'])}'
            : 'Renewed ${d['n']} leases for ${_c(d['cost'])}';
      case 'hex_cancelled':
        return d['n'] == 1 ? 'Gave up a ${d['name']} hex (${_c(d['refund'])} back)'
            : 'Gave up ${d['n']} hexes (${_c(d['refund'])} back)';
      case 'hex_switched': return 'Switched a hex to ${d['name']} (quality ${d['quality']}) for ${_c(d['cost'])}';
      case 'survey': return 'Government survey, ${fmtNum((d['radius'] as num? ?? 0).round())} m, for ${_c(d['cost'])}';
      case 'campus_placed': return 'Campus placed';
      case 'campus_visit': return 'Campus visited';
      case 'campus_move': return 'Campus move started';
      case 'campus_move_cancelled': return 'Campus move cancelled';
      case 'campus_moved': return 'Campus moved';
      case 'campus_upgrade': return 'Campus level ${d['level']} for ${_c(d['cost'])}';
      case 'storage_upgrade': return 'Central Storage level ${d['level']} for ${_c(d['cost'])}';
      case 'plant': return d['level'] == 1 ? 'Built a ${d['name']} for ${_c(d['cost'])}'
          : '${d['name']} level ${d['level']} for ${_c(d['cost'])}';
      case 'education': return 'A supervisor started a ${d['step']} (${_c(d['cost'])}, ${fmtNum(d['books'] as num? ?? 0)} books)';
      case 'sold': return 'Sold ${fmtNum(d['qty'] as num? ?? 0)}${d['unit'] == 'kWh' ? ' kWh' : ''} ${d['name']} for ${_c(d['credits'])}';
      case 'daily_reward': return 'Daily reward, day ${d['day']}: ${_c(d['credits'])}';
      case 'dark_matter': return 'Dark matter research level ${d['level']}';
      case 'marketbuy':
        return 'Bought ${fmtNum(d['qty'] as num? ?? 0)} ${d['name'] ?? ''} '
            'for ${_c(d['cost'])}${d['from'] != null ? ' from ${d['from']}' : ''}';
      case 'marketsold':
        return 'Sold ${fmtNum(d['qty'] as num? ?? 0)} ${d['name'] ?? ''} '
            'to ${d['to'] ?? 'a buyer'} for ${_c(d['earned'])}';
      case 'rename': return 'Renamed the company to ${d['name'] ?? d['company_name'] ?? ''}';
      default: return t;
    }
  }

  static IconData _icon(String t) => switch (t) {
        'hex_built' => Icons.add_location_alt_outlined,
        'hex_renewed' => Icons.autorenew,
        'hex_cancelled' => Icons.remove_circle_outline,
        'hex_switched' => Icons.swap_horiz,
        'survey' => Icons.satellite_alt,
        'campus_placed' || 'campus_visit' || 'campus_moved' => Icons.location_city_outlined,
        'campus_move' || 'campus_move_cancelled' => Icons.local_shipping_outlined,
        'campus_upgrade' || 'storage_upgrade' => Icons.upgrade,
        'plant' => Icons.factory_outlined,
        'education' => Icons.school_outlined,
        'sold' || 'marketsold' => Icons.payments_outlined,
        'marketbuy' => Icons.shopping_cart_outlined,
        'daily_reward' => Icons.local_fire_department_outlined,
        'dark_matter' => Icons.blur_on,
        _ => Icons.circle_outlined,
      };

  static Color _color(String t) => switch (t) {
        'hex_cancelled' || 'campus_move_cancelled' => Colors.orangeAccent,
        'sold' || 'marketsold' || 'marketbuy' || 'daily_reward' => Colors.amber,
        'campus_upgrade' || 'storage_upgrade' || 'plant' => Colors.lightBlueAccent,
        _ => AppColors.accent,
      };
}
