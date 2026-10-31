import 'package:flutter/material.dart';
import 'luxury_screen.dart' show fmtMass;
import 'package:provider/provider.dart';
import '../constants.dart' show fmtNum;
import '../models/player_provider.dart';
import '../services/game_api.dart';
import '../widgets/async_view.dart';
import 'profile_screen.dart';

import '../app_colors.dart';
/// Leaderboards (server: systems/rankings.py): overall (company value x activity), Campus level
/// (x activity), countries, Tantalum-180m, and output per hour (one item, or everything at prices).
/// Compact one-line rows; tap a row for the company sheet. Big numbers are always short (1.25T).
class LeaderboardScreen extends StatelessWidget {
  const LeaderboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: ModalRoute.of(context)?.canPop == true ? AppBar(toolbarHeight: 36) : null,
      body: const DefaultTabController(
        length: 6,
        child: Column(children: [
          TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
            Tab(text: 'Overall'), Tab(text: 'Campus'), Tab(text: 'Hexes'), Tab(text: 'Countries'), Tab(text: 'Tantalum'),
            Tab(text: 'Output'),
          ]),
          Expanded(child: TabBarView(children: [
            _OverallBoard(), _CampusBoard(), _HexBoard(), _CountryBoard(), _LuxuryBoard(), _ResourceBoard(),
          ])),
        ]),
      ),
    );
  }
}

/// Leaderboard numbers stay short whatever Settings › Numbers says, so they always fit.
String _short(num n) => fmtNum(n, decimals: 2);

/// A one-line explanation under a board's controls.
Widget _note(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Text(text, style: TextStyle(fontSize: 11, color: AppColors.t38)),
    );

void _openProfile(BuildContext context, Map<String, dynamic> r) {
  final pid = r['isMe'] == true ? null : r['pid'] as String?;
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProfileScreen(pid: pid)));
}

/// The rank: a medal for the first three.
Widget _rankMark(Map<String, dynamic> r, bool isMe) {
  final n = (r['rank'] as num).toInt();
  final medal = n == 1 ? Colors.amber : n == 2 ? const Color(0xFFCFD8DC) : n == 3 ? const Color(0xFFCD7F32) : null;
  if (medal == null) {
    return Text('#$n', textAlign: TextAlign.right,
        style: TextStyle(color: isMe ? AppColors.accent : AppColors.t54, fontSize: 12, fontWeight: FontWeight.bold));
  }
  return Align(alignment: Alignment.centerRight, child: CircleAvatar(
    radius: 11,
    backgroundColor: medal.withValues(alpha: 0.22),
    child: Text('$n', style: TextStyle(color: medal, fontSize: 12, fontWeight: FontWeight.bold)),
  ));
}

/// One compact row: rank · name (+ optional middle widget) · value.
Widget _row(BuildContext context, Map<String, dynamic> r, {Widget? middle, required String value, String? unit}) {
  final isMe = r['isMe'] == true;
  return InkWell(
    onTap: () => _openProfile(context, r),
    child: Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      color: isMe ? AppColors.accent.withValues(alpha: 0.12) : null,
      child: Row(children: [
        SizedBox(width: 38, child: _rankMark(r, isMe)),
        const SizedBox(width: 8),
        Expanded(
          flex: 5,
          child: Text(r['name'] as String? ?? '?', overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: isMe ? AppColors.accent : AppColors.fg,
                  fontWeight: isMe ? FontWeight.bold : FontWeight.normal)),
        ),
        if (middle != null) Expanded(flex: 4, child: middle),
        SizedBox(
          width: 92,
          child: Text(unit == null ? value : '$value $unit', textAlign: TextAlign.right,
              style: TextStyle(color: isMe ? AppColors.accent : AppColors.t70, fontSize: 13, fontWeight: FontWeight.bold)),
        ),
      ]),
    ),
  );
}

/// Column titles above a board (owner 2026-10-24): Rank · Player · middle column · value.
Widget _infoRow(String middle, String value, {String who = 'Company'}) => Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(children: [
        SizedBox(width: 38, child: Text('Rank', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppColors.t54))),
        const SizedBox(width: 8),
        Expanded(flex: 5, child: Text(who, style: TextStyle(fontSize: 11, color: AppColors.t54))),
        Expanded(flex: 4, child: Text(middle, style: TextStyle(fontSize: 11, color: AppColors.t54))),
        SizedBox(width: 92, child: Text(value, textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppColors.t54))),
      ]),
    );

abstract class _BoardState<T extends StatefulWidget> extends State<T> with AutomaticKeepAliveClientMixin {
  Map<String, dynamic>? data;
  bool loading = true;
  String? error;
  bool country = false;   // only my country (ranks recounted by the server)
  int page = 0;           // 100 players per page
  String get path;
  Map<String, dynamic> get params => const {};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => loading = true);
    final r = await GameApi.call(path, context.read<PlayerProvider>().sid,
        {...params, 'page': page, if (country) 'country': 1});
    if (!mounted) return;
    setState(() { loading = false; error = r.ok ? null : r.message; if (r.ok) data = r.data; });
  }

  /// "My country" filter and page arrows, shown on every board.
  Widget controls({String? note}) {
    final d = data!;
    final pages = (d['pages'] as num? ?? 1).toInt();
    final hasCountry = (d['myCountry'] as String? ?? '').isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Row(children: [
        if (hasCountry)
          FilterChip(
            label: const Text('My country', style: TextStyle(fontSize: 11)),
            selected: country, visualDensity: VisualDensity.compact,
            onSelected: (v) { setState(() { country = v; page = 0; }); load(); },
          ),
        const SizedBox(width: 8),
        Expanded(child: Text(note ?? (d['myRank'] != null ? 'Your rank: #${d['myRank']}' : ''),
            style: TextStyle(color: AppColors.accent, fontSize: 12, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis)),
        IconButton(
          visualDensity: VisualDensity.compact, icon: const Icon(Icons.chevron_left),
          onPressed: page > 0 ? () { setState(() => page--); load(); } : null,
        ),
        Text('${page + 1}/$pages', style: const TextStyle(fontSize: 12)),
        IconButton(
          visualDensity: VisualDensity.compact, icon: const Icon(Icons.chevron_right),
          onPressed: page + 1 < pages ? () { setState(() => page++); load(); } : null,
        ),
      ]),
    );
  }

  Widget list(List<Map<String, dynamic>> rows, Widget Function(Map<String, dynamic>) tile, {Widget? header}) {
    final h = header != null ? 1 : 0;
    return RefreshIndicator(
      onRefresh: load,
      child: ListView.separated(
        itemCount: rows.length + h,
        separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white10),
        itemBuilder: (_, i) => h == 1 && i == 0 ? header! : tile(rows[i - h]),
      ),
    );
  }
}

class _OverallBoard extends StatefulWidget {
  const _OverallBoard();
  @override
  State<_OverallBoard> createState() => _OverallBoardState();
}

class _OverallBoardState extends _BoardState<_OverallBoard> {
  @override
  String get path => '/api/v1/rank/players';

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return AsyncView(loading: loading && data == null, error: error, onRetry: load, builder: () {
      final rows = (data!['rows'] as List).cast<Map<String, dynamic>>();
      return list(rows, (r) => _row(context, r, value: _short(r['score'] as num),
          middle: Text('${r['activity']} %', style: TextStyle(color: AppColors.t70, fontSize: 12))),
          header: Column(mainAxisSize: MainAxisSize.min, children: [
            controls(),
            _note('Score: company value (credits, storage and everything built) times the share of days played '
                'in the last 100 days.'),
            _infoRow('Active', 'Score'),
          ]));
    });
  }
}

class _CampusBoard extends StatefulWidget {
  const _CampusBoard();
  @override
  State<_CampusBoard> createState() => _CampusBoardState();
}

class _CampusBoardState extends _BoardState<_CampusBoard> {
  @override
  String get path => '/api/v1/rank/campus';

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return AsyncView(loading: loading && data == null, error: error, onRetry: load, builder: () {
      final rows = (data!['rows'] as List).cast<Map<String, dynamic>>();
      return list(rows, (r) => _row(context, r, value: 'Campus ${r['level']}',
          middle: Text('${r['activity']} %', style: TextStyle(color: AppColors.t70, fontSize: 12))),
          header: Column(mainAxisSize: MainAxisSize.min, children: [
            controls(),
            _note('Ranked by Campus level times the share of days played in the last 100 days.'),
            _infoRow('Active', 'Campus'),
          ]));
    });
  }
}

class _HexBoard extends StatefulWidget {
  const _HexBoard();
  @override
  State<_HexBoard> createState() => _HexBoardState();
}

class _HexBoardState extends _BoardState<_HexBoard> {
  @override
  String get path => '/api/v1/rank/hexes';

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return AsyncView(loading: loading && data == null, error: error, onRetry: load, builder: () {
      final rows = (data!['rows'] as List).cast<Map<String, dynamic>>();
      return list(rows, (r) => _row(context, r, value: _short(r['hexes'] as num),
          middle: Text('${r['items']}', style: TextStyle(color: AppColors.t70, fontSize: 12))),
          header: Column(mainAxisSize: MainAxisSize.min, children: [
            controls(),
            _infoRow('Resources', 'Hexes'),
          ]));
    });
  }
}

class _CountryBoard extends StatefulWidget {
  const _CountryBoard();
  @override
  State<_CountryBoard> createState() => _CountryBoardState();
}

class _CountryBoardState extends _BoardState<_CountryBoard> {
  @override
  String get path => '/api/v1/rank/countries';

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return AsyncView(loading: loading && data == null, error: error, onRetry: load, builder: () {
      final rows = (data!['rows'] as List).cast<Map<String, dynamic>>();
      return list(rows, (r) {
        final isMe = r['isMe'] == true;
        final cc = r['country'] as String;
        return Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          color: isMe ? AppColors.accent.withValues(alpha: 0.12) : null,
          child: Row(children: [
            SizedBox(width: 38, child: _rankMark(r, isMe)),
            const SizedBox(width: 8),
            ClipRRect(borderRadius: BorderRadius.circular(2), child: Image.asset(
                'assets/images_countryflags/$cc.png', width: 24, height: 16, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox(width: 24))),
            const SizedBox(width: 8),
            Expanded(flex: 4, child: Text(cc.toUpperCase(), style: TextStyle(fontSize: 13,
                color: isMe ? AppColors.accent : AppColors.fg, fontWeight: isMe ? FontWeight.bold : FontWeight.normal))),
            Expanded(flex: 4, child: Text('${r['companies']}', style: TextStyle(color: AppColors.t70, fontSize: 12))),
            SizedBox(width: 92, child: Text(_short(r['score'] as num), textAlign: TextAlign.right,
                style: TextStyle(color: isMe ? AppColors.accent : AppColors.t70, fontSize: 13, fontWeight: FontWeight.bold))),
          ]),
        );
      }, header: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Text(data!['myRank'] != null ? 'Your country: #${data!['myRank']} of ${data!['total']}' : '',
              style: TextStyle(color: AppColors.t54, fontSize: 12)),
        ),
        _note('The overall scores of every company of a country added up.'),
        _infoRow('Companies', 'Score', who: 'Country'),
      ]));
    });
  }
}

class _LuxuryBoard extends StatefulWidget {
  const _LuxuryBoard();
  @override
  State<_LuxuryBoard> createState() => _LuxuryBoardState();
}

class _LuxuryBoardState extends _BoardState<_LuxuryBoard> {
  @override
  String get path => '/api/v1/rank/tantalum';

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return AsyncView(loading: loading && data == null, error: error, onRetry: load, builder: () {
      final rows = (data!['rows'] as List).cast<Map<String, dynamic>>();
      return list(rows, (r) => _row(context, r, value: fmtMass(r['mg'] as num),
          middle: Text(fmtMass(r['investedMg'] as num? ?? 0), style: TextStyle(fontSize: 12, color: AppColors.t70))),
          header: Column(mainAxisSize: MainAxisSize.min, children: [
        controls(note: 'You have made ${fmtMass(data!['myMg'] as num? ?? 0)}'
            '${data!['myRank'] != null ? ' · #${data!['myRank']}' : ''}'),
        _infoRow('In research', 'Made in total'),
      ]));
    });
  }
}

class _ResourceBoard extends StatefulWidget {
  const _ResourceBoard();
  @override
  State<_ResourceBoard> createState() => _ResourceBoardState();
}

class _ResourceBoardState extends _BoardState<_ResourceBoard> {
  String _kind = 'all';
  String? _item;
  @override
  String get path => '/api/v1/rank/resource';
  @override
  Map<String, dynamic> get params => {'kind': _kind, if (_item != null) 'item': _item};

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return AsyncView(loading: loading && data == null, error: error, onRetry: load, builder: () {
      final rows = (data!['rows'] as List).cast<Map<String, dynamic>>();
      final all = _kind == 'all';
      final options = all ? const <String>[] : ((data!['options'] as Map)[_kind] as List).cast<String>();
      final names = (data!['names'] as Map? ?? const {}).cast<String, dynamic>();
      final item = data!['item'] as String? ?? '';
      return list(rows, (r) => _row(context, r,
          value: all ? 'ꞓ${_short(r['perHour'] as num)}' : _short((r['perHour'] as num).round()),
          middle: Text('${r['count']}', style: TextStyle(color: AppColors.t70, fontSize: 12))),
          header: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
            child: Row(children: [
              SegmentedButton<String>(
                segments: const [ButtonSegment(value: 'all', label: Text('All')),
                  ButtonSegment(value: 'raw', label: Text('Hexes')), ButtonSegment(value: 'product', label: Text('Plants'))],
                selected: {_kind},
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                onSelectionChanged: (v) { setState(() { _kind = v.first; _item = null; page = 0; }); load(); },
              ),
              const SizedBox(width: 8),
              if (!all) Expanded(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: options.contains(item) ? item : null,
                  items: [
                    for (final o in options)
                      DropdownMenuItem(value: o, child: Row(children: [
                        GameItemIcon(o, size: 22, hex: _kind == 'raw'), const SizedBox(width: 6),
                        Flexible(child: Text(names[o] as String? ?? o, overflow: TextOverflow.ellipsis)),
                      ])),
                  ],
                  onChanged: (v) { setState(() { _item = v; page = 0; }); load(); },
                ),
              ),
            ]),
          ),
          controls(),
          if (all) _note('Everything a company makes in an hour (hexes and plants), valued at market prices.'),
          _infoRow(all ? 'Hexes + levels' : _kind == 'raw' ? 'Hexes' : 'Levels', all ? 'Value / h' : 'Output / h'),
          ]));
    });
  }
}
