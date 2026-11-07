import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'luxury_screen.dart' show fmtMass;
import 'package:provider/provider.dart';
import '../constants.dart' show fmtNum;
import '../models/player_provider.dart';
import '../services/game_api.dart';
import '../widgets/async_view.dart';
import '../widgets/picture_cache.dart';
import 'profile_screen.dart';

import '../app_colors.dart';
/// Leaderboards (server: systems/rankings.py): overall (company value, weighed by how often the company plays),
/// Campus level, countries, Tantalum-180m, and output per hour (one item, or everything at prices). The
/// activity share itself is not shown (owner 2026-11-06).
/// Compact one-line rows; tap a row for the company sheet. Big numbers are always short (1.25T).
class LeaderboardScreen extends StatelessWidget {
  final bool embedded;                     // a tab of the bottom bar: no back arrow
  const LeaderboardScreen({super.key, this.embedded = false});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: !embedded && ModalRoute.of(context)?.canPop == true ? AppBar(toolbarHeight: 36) : null,
      body: const DefaultTabController(
        length: 6,
        child: Column(children: [
          TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
            Tab(text: 'Overall'), Tab(text: 'Campus'), Tab(text: 'Hexes'), Tab(text: 'Countries'), Tab(text: 'Tantalum'),
            Tab(text: 'Production'),
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
  if (r['rank'] == null) {                     // not on this board (yet): owner 2026-11-06
    return Text('N/A', textAlign: TextAlign.right, style: TextStyle(color: AppColors.accent, fontSize: 11,
        fontWeight: FontWeight.bold));
  }
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
          child: Row(children: [
            _flag(r['country'] as String?),
            Flexible(child: Text(r['name'] as String? ?? '?', overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: isMe ? AppColors.accent : AppColors.fg,
                    fontWeight: isMe ? FontWeight.bold : FontWeight.normal))),
          ]),
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

// The flags as the boards show them: decoded this wide (the image cache knows them by path and width).
const _rowFlagW = 54, _countryFlagW = 72;
var _flagsWarm = false;

/// Decode every flag once, at the sizes the leaderboards use, and keep them (widgets/picture_cache.dart), so
/// they never pop in (owner 2026-11-06: even after the app was closed). About 2 MB.
Future<void> warmFlags(BuildContext context) async {
  if (_flagsWarm) return;
  _flagsWarm = true;
  try {
    for (final path in await assetsIn(const ['assets/images_countryflags/'])) {
      if (!context.mounted) return;
      for (final w in const [_rowFlagW, _countryFlagW]) {
        await pinPicture(ResizeImage.resizeIfNeeded(w, null, AssetImage(path)), context);
      }
    }
  } catch (_) {
    _flagsWarm = false;                       // try again next time
  }
}

/// A small country flag before a name (nothing when the country is unknown).
Widget _flag(String? cc) => cc == null || cc.isEmpty
    ? const SizedBox.shrink()
    : Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ClipRRect(borderRadius: BorderRadius.circular(2), child: Image.asset(
            'assets/images_countryflags/${cc.toLowerCase()}.png', width: 18, height: 12, fit: BoxFit.cover,
            cacheWidth: _rowFlagW, gaplessPlayback: true,       // decoded small: shows at once, stays cached
            errorBuilder: (_, __, ___) => const SizedBox.shrink())),
      );

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
  // owner 2026-11-06: coming back to the leaderboards showed a spinner and the flags loading again; every
  // board's last answer is kept, in memory and on the phone (so also after the app was closed), shown at
  // once and quietly refreshed. Saved per company, so another account on the phone never sees yours.
  static final _kept = <String, Map<String, dynamic>>{};
  String get _diskKey => 'lb|${context.read<PlayerProvider>().player?.hid ?? ''}|$_key';

  Future<void> _fromDisk() async {
    final key = _key, disk = _diskKey;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(disk);
      if (raw == null || !mounted || data != null || _key != key) return;
      final saved = jsonDecode(raw) as Map<String, dynamic>;
      _kept[key] = saved;
      setState(() { data = saved; loading = false; });
    } catch (_) {}                             // nothing saved, or unreadable: the fresh answer comes anyway
  }

  void _toDisk(Map<String, dynamic> d) {
    final disk = _diskKey;
    SharedPreferences.getInstance().then((p) => p.setString(disk, jsonEncode(d))).catchError((_) => false);
  }
  String get _key => '$path|${params.entries.map((e) => '${e.key}=${e.value}').join('&')}|$country';

  Map<String, dynamic>? data;
  bool loading = true;
  String? error;
  bool country = false;   // only my country (ranks recounted by the server, from 1)
  String get path;
  Map<String, dynamic> get params => const {};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    data = _kept[_key];
    loading = data == null;
    if (data == null) _fromDisk();
    load();
  }

  Future<void> load() async {
    final key = _key;
    final kept = _kept[key];
    // a board seen before shows at once (no spinner) while the fresh one comes
    setState(() { if (kept != null) data = kept; loading = kept == null; });
    final r = await GameApi.call(path, context.read<PlayerProvider>().sid,
        {...params, if (country) 'country': 1});
    if (!mounted) return;
    if (r.ok) {
      _kept[key] = r.data;
      _toDisk(r.data);
    }
    setState(() {
      loading = false;
      if (r.ok) { data = r.data; error = null; } else if (data == null) { error = r.message; }
    });
  }

  /// "My country" filter, shown on every board (owner 2026-11-06: the top 100, no pages).
  Widget controls({String? note}) {
    final d = data!;
    final hasCountry = (d['myCountry'] as String? ?? '').isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Row(children: [
        if (hasCountry)
          FilterChip(
            label: const Text('My country', style: TextStyle(fontSize: 11)),
            selected: country, visualDensity: VisualDensity.compact,
            onSelected: (v) { setState(() => country = v); load(); },
          ),
        const SizedBox(width: 8),
        Expanded(child: Text(note ?? 'Top ${d['top'] ?? 100} · updates every 5 minutes',
            style: TextStyle(color: AppColors.t54, fontSize: 12), overflow: TextOverflow.ellipsis)),
      ]),
    );
  }

  /// The board (owner 2026-11-06): the header, then your own row first (highlighted, above #1; rank N/A when
  /// you are not on this board), then the top 100, where your row is highlighted too.
  Widget list(List<Map<String, dynamic>> rows, Widget Function(Map<String, dynamic>) tile,
      {Widget? header, String Function(num gap)? gapText}) {
    final top = (data?['top'] as num? ?? 100).toInt();
    final me = rows.where((r) => r['isMe'] == true).firstOrNull;
    final shown = [
      if (me != null) me,
      ...rows.where((r) => r['rank'] != null && (r['rank'] as num) <= top),
    ];
    final h = header != null ? 1 : 0;
    return RefreshIndicator(
      onRefresh: load,
      child: ListView.separated(
        itemCount: shown.length + h,
        separatorBuilder: (_, i) => Divider(height: me != null && i == h ? 6 : 1,
            thickness: me != null && i == h ? 2 : 1, color: me != null && i == h ? AppColors.accent.withValues(alpha: 0.4) : Colors.white10),
        itemBuilder: (_, i) => h == 1 && i == 0 ? header! : tile(shown[i - h]),
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
      return list(rows, (r) => _row(context, r, value: _short(r['score'] as num)),
          header: Column(mainAxisSize: MainAxisSize.min, children: [
            controls(),
            _note('Score: your company value (credits, storage and everything built).'),
            _infoRow('', 'Score'),
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
      return list(rows, (r) => _row(context, r, value: 'Campus ${r['level']}'),
          gapText: (g) => g == 1 ? '1 level' : '${g.round()} levels',
          header: Column(mainAxisSize: MainAxisSize.min, children: [
            controls(),
            _note('Ranked by Campus level.'),
            _infoRow('', 'Campus'),
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
                cacheWidth: _countryFlagW, gaplessPlayback: true,
                errorBuilder: (_, __, ___) => const SizedBox(width: 24))),
            const SizedBox(width: 8),
            Expanded(flex: 4, child: Text(cc == 'zz' ? 'Intl. waters' : cc.toUpperCase(), style: TextStyle(fontSize: 13,
                color: isMe ? AppColors.accent : AppColors.fg, fontWeight: isMe ? FontWeight.bold : FontWeight.normal))),
            Expanded(flex: 4, child: Text('${r['companies']}', style: TextStyle(color: AppColors.t70, fontSize: 12))),
            SizedBox(width: 92, child: Text(_short(r['score'] as num), textAlign: TextAlign.right,
                style: TextStyle(color: isMe ? AppColors.accent : AppColors.t70, fontSize: 13, fontWeight: FontWeight.bold))),
          ]),
        );
      }, header: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Text('Top ${data!['top'] ?? 100} · updates every 5 minutes', style: TextStyle(color: AppColors.t54, fontSize: 12)),
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
      // owner 2026-11-07: only what is in research, nothing else on the row
      return list(rows, gapText: (g) => fmtMass(g), (r) => _row(context, r, value: fmtMass(r['mg'] as num)),
          header: Column(mainAxisSize: MainAxisSize.min, children: [
        controls(),
        _infoRow('', 'In research'),
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
      return list(rows, gapText: (g) => all ? 'ꞓ${_short(g)} an hour' : '${_short(g.round())} an hour', (r) => _row(context, r,
          value: all ? 'ꞓ${_short(r['perHour'] as num)}' : _short((r['perHour'] as num).round()),
          middle: Text('${r['count']}', style: TextStyle(color: AppColors.t70, fontSize: 12))),
          header: Column(mainAxisSize: MainAxisSize.min, children: [
          // owner 2026-11-06: the buttons never move: no check mark, fixed width, and the item list's place is kept
          SizedBox(height: 52, child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
            child: Row(children: [
              SizedBox(width: 210, child: SegmentedButton<String>(
                segments: const [ButtonSegment(value: 'all', label: Text('All')),
                  ButtonSegment(value: 'raw', label: Text('Hexes')), ButtonSegment(value: 'product', label: Text('Plants'))],
                selected: {_kind},
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                onSelectionChanged: (v) { setState(() { _kind = v.first; _item = null; }); load(); },
              )),
              const SizedBox(width: 8),
              if (all) const Expanded(child: SizedBox.shrink()) else Expanded(
                child: DropdownButton<String>(
                  isExpanded: true,
                  isDense: true,                       // fits the fixed row (owner 2026-11-06: it was cut off)
                  // a small scrolling menu at the button, not the whole screen (owner 2026-11-06)
                  menuMaxHeight: MediaQuery.sizeOf(context).height * 0.4,
                  borderRadius: BorderRadius.circular(12),
                  hint: const Text('Choose an item'),
                  value: options.contains(item) ? item : null,
                  items: [
                    for (final o in options)
                      DropdownMenuItem(value: o, child: Row(children: [
                        GameItemIcon(o, size: 22, hex: _kind == 'raw'), const SizedBox(width: 6),
                        Flexible(child: Text(names[o] as String? ?? o, overflow: TextOverflow.ellipsis)),
                      ])),
                  ],
                  onChanged: (v) { setState(() => _item = v); load(); },
                ),
              ),
            ]),
          )),
          controls(),
          if (all) _note('Everything a company makes in an hour (hexes and plants), valued at market prices.'),
          _infoRow(all ? 'Hexes + levels' : _kind == 'raw' ? 'Hexes' : 'Levels', all ? 'Value / h' : 'Output / h'),
          ]));
    });
  }
}
