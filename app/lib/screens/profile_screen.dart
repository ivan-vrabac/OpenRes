import '../widgets/glass.dart' show tabPadding;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/player_provider.dart';
import '../services/game_api.dart';
import '../widgets/async_view.dart';
import '../widgets/top_banner.dart';
import '../widgets/report.dart';
import 'achievements_screen.dart';
import 'luxury_screen.dart' show fmtMass;
import '../v3/company.dart';

import '../app_colors.dart';
/// Public profile of a player ([pid]), or your own statistics when [pid] is null.
class ProfileScreen extends StatefulWidget {
  final String? pid;
  final bool embedded; // shown inside a tab (no app bar)
  const ProfileScreen({super.key, this.pid, this.embedded = false});

  static Future<void> open(BuildContext context, String pid) => Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ProfileScreen(pid: pid)));

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Map<String, dynamic>? _p;
  String? _error;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    final r = await GameApi.call('/api/v1/social/profile', context.read<PlayerProvider>().sid,
        {'pid': widget.pid});
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (r.ok) {
        _p = r.get<Map<String, dynamic>>('profile');
      } else {
        _error = r.message;
      }
    });
  }

  Future<void> _toggle(String kind, bool on) async {
    if (_busy || _p == null) return;
    setState(() => _busy = true);
    final r = await GameApi.call('/api/v1/social/contact', context.read<PlayerProvider>().sid,
        {'pid': _p!['pid'], 'kind': kind, 'action': on ? 'add' : 'remove'});
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r.ok) _p!['relations'] = r.get<List>('relations') ?? [];
    });
    if (!r.ok) AppNotify.show(context, r.message ?? 'Failed', isError: true);
  }

  /// One stat tile; every tile has the same height, an icon and a one-line label (owner 2026-10-31:
  /// the tiles had different heights and gaps).
  Widget _stat(String label, String value, IconData? icon, {Widget? mark}) => Expanded(
        child: Container(
          height: 72,
          margin: const EdgeInsets.all(4),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(8)),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            mark ?? Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 2),
            FittedBox(fit: BoxFit.scaleDown,
                child: Text(value, maxLines: 1, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
            const SizedBox(height: 2),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, color: AppColors.t54), textAlign: TextAlign.center),
          ]),
        ),
      );

  /// A rounded card around a section.
  Widget _card(Widget child, {String? title}) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(16)),
        child: title == null ? child : Column(children: [
          Text(title.toUpperCase(), style: TextStyle(fontSize: 11, color: AppColors.t38, letterSpacing: 1.2)),
          const SizedBox(height: 10),
          child,
        ]),
      );

  /// A small dark tag on a picture: "×12", "Lv 3".
  Widget _countTag(String text) => Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(8)),
        child: Text(text, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white)),
      );

  /// A card with pictures in a centred grid, each with its name under it.
  Widget _gridSection(String title, dynamic list, Widget Function(Map<String, dynamic>) picture) {
    final items = (list as List? ?? const []).cast<Map<String, dynamic>>();
    if (items.isEmpty) return const SizedBox.shrink();
    return _card(title: title, Wrap(alignment: WrapAlignment.center, spacing: 12, runSpacing: 12, children: [
      for (final it in items)
        SizedBox(width: 72, child: Column(mainAxisSize: MainAxisSize.min, children: [
          picture(it),
          const SizedBox(height: 4),
          Text(it['name'] as String? ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10, color: AppColors.t70)),
        ])),
    ]));
  }

  Widget _relationChip(String kind, String label, IconData icon, Color color) {
    final rel = (_p?['relations'] as List? ?? const []).contains(kind);
    return FilterChip(
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      showCheckmark: false,
      avatar: Icon(icon, size: 14, color: rel ? Colors.black : color),
      label: Text(label, style: TextStyle(fontSize: 12, color: rel ? Colors.black : null)),
      selected: rel,
      selectedColor: color,
      onSelected: _busy ? null : (v) => _toggle(kind, v),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = AsyncView(
      loading: _loading,
      error: _error,
      onRetry: _load,
      builder: () {
        final p = _p!;
        final isMe = p['isMe'] == true;
        final ach = (p['achievements'] as List? ?? const []).cast<Map<String, dynamic>>();
        return RefreshIndicator(
          onRefresh: _load,
          child: ListView(padding: tabPadding(context, 12), children: [
            Row(children: [
              // country flag in place of an avatar (letter avatar only when no country is set)
              (p['country'] as String? ?? '').isNotEmpty
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.asset('assets/images_countryflags/${(p['country'] as String).toLowerCase()}.png',
                          width: 52, height: 36, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const Icon(Icons.flag_outlined, size: 36)),
                    )
                  : CircleAvatar(radius: 26, child: Text((p['name'] as String? ?? '?').characters.first.toUpperCase(),
                      style: const TextStyle(fontSize: 20))),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p['name'] as String? ?? '', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                Text('Member since ${p['memberSince'] ?? '?'}',
                    style: TextStyle(color: AppColors.t54, fontSize: 12)),
              ])),
              if (!isMe)
                IconButton(
                  tooltip: 'Report',
                  icon: Icon(Icons.flag_outlined, color: AppColors.t38),
                  onPressed: () => reportPlayer(context, context.read<PlayerProvider>().sid, p['pid'] as String),
                ),
              if (!isMe)
                IconButton(
                  tooltip: (p['relations'] as List? ?? const []).contains('blacklist') ? 'Unblock' : 'Block',
                  icon: Icon(Icons.block,
                      color: (p['relations'] as List? ?? const []).contains('blacklist')
                          ? Colors.redAccent : AppColors.t38),
                  onPressed: _busy ? null : () => _toggle('blacklist',
                      !(p['relations'] as List? ?? const []).contains('blacklist')),
                ),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              _stat('Campus', '${p['campusLevel'] ?? 0}', Icons.location_city),
              _stat('Hexes', '${p['hexes'] ?? 0}', Icons.hexagon_outlined),
              _stat('Age', p['ageDays'] == null ? '?' : '${p['ageDays']} d', Icons.cake_outlined),
            ]),
            Row(children: [
              _stat('Made / hour', 'ꞓ${fmtQty(p['valuePerHour'] as num? ?? 0)}', Icons.trending_up),
              _stat('Tantalum-180m', fmtMass(p['tantalumMg'] as num? ?? 0), null,
                  mark: TaIcon(size: 16, color: Theme.of(context).colorScheme.primary)),
            ]),
            Row(children: [
              _stat('Overall rank', '#${p['rankPoints']}', Icons.emoji_events_outlined),
              _stat('Hexes rank', '#${p['rankHexes']}', Icons.leaderboard_outlined),
              _stat('Tantalum rank', p['rankTantalum'] == null ? 'N/A' : '#${p['rankTantalum']}',
                  Icons.workspace_premium_outlined),
            ]),
            // owner 2026-10-31: the Campus centred and bigger, hexes and plants as picture grids
            if (p['campusStage'] != null)
              _card(Column(children: [
                Image.asset(campusPicture((p['campusLevel'] as num).toInt()), width: 150, height: 156,
                    fit: BoxFit.contain, cacheWidth: 300),
                const SizedBox(height: 6),
                Text('Campus ${p['campusLevel']}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                Text('${p['campusStage']}', style: TextStyle(color: AppColors.t54, fontSize: 12)),
              ])),
            _gridSection('Hexes', p['hexesByItem'], (it) => Stack(alignment: Alignment.bottomCenter, children: [
              HexPicture(itemPicture(it['item'] as String), size: 60),
              _countTag('×${it['count']}'),
            ])),
            _gridSection('Plants', p['plants'], (it) => Stack(alignment: Alignment.bottomCenter, children: [
              ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.asset(plantPicture(it['key'] as String),
                  width: 60, height: 52, fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Icon(Icons.factory_outlined, size: 40, color: AppColors.t38))),
              _countTag('Lv ${it['level']}'),
            ])),
            if (!isMe) ...[
              const SizedBox(height: 12),
              // compact "Mark as:" row (block is the icon in the header)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  Text('Mark as:', style: TextStyle(color: AppColors.t54, fontSize: 12)),
                  const SizedBox(width: 6),
                  _relationChip('friend', 'Friend', Icons.person_add_alt, Colors.lightBlueAccent),
                  const SizedBox(width: 4),
                  _relationChip('enemy', 'Enemy', Icons.gpp_bad_outlined, Colors.orangeAccent),
                  const SizedBox(width: 4),
                  _relationChip('watch', 'Person of Interest', Icons.visibility_outlined, Colors.amber),
                ]),
              ),
            ],
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                leading: const Icon(Icons.star, color: Colors.amber),
                title: Text('Achievements: ${p['stars'] ?? ach.length} out of ${p['maxStars'] ?? 39}'),
                trailing: FilledButton.tonal(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => AchievementsScreen(pid: isMe ? null : p['pid'] as String?,
                            name: isMe ? null : p['name'] as String?))),
                    child: const Text('View')),
              ),
            ),
          ]),
        );
      },
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(toolbarHeight: 40, title: const Text('Company')),
      body: body,
    );
  }
}
