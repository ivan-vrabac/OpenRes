import '../widgets/glass.dart' show tabPadding;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/player_provider.dart';
import '../services/game_api.dart';
import '../widgets/async_view.dart';
import '../widgets/top_banner.dart';

import '../app_colors.dart';
import '../services/kept.dart';
import '../constants.dart' show fmtNum;
import '../v3/company.dart';
import '../v3/streak.dart';
/// The Rewards tab (owner 2026-11-06): the daily reward with the game's only streak on top, then today's
/// quests, a side hustle: each one pays when it is done, and they end at midnight (UTC). One of them is
/// always quick.
class QuestsScreen extends StatefulWidget {
  const QuestsScreen({super.key});
  @override
  State<QuestsScreen> createState() => _QuestsScreenState();
}

class _QuestsScreenState extends State<QuestsScreen> {
  Map<String, dynamic>? _d;
  bool _loading = true;
  String? _error;
  int? _claiming;

  String get _sid => context.read<PlayerProvider>().sid;

  // the last answer, shown at once (owner 2026-11-07: a spinner flashed when the tab opened)
  String get _keptKey => Kept.key(context.read<PlayerProvider>().player?.hid ?? '', 'quests');

  @override
  void initState() {
    super.initState();
    _d = Kept.now(_keptKey);
    _loading = _d == null;
    if (_d == null) {
      Kept.fromDisk(_keptKey).then((d) {
        if (mounted && d != null && _d == null) setState(() { _d = d; _loading = false; });
      });
    }
    _load();
  }

  Future<void> _load() async {
    final r = await GameApi.call('/api/v1/quests', _sid);
    if (!mounted) return;
    if (r.ok) Kept.save(_keptKey, r.data);
    setState(() {
      _loading = false;
      _error = r.ok || _d != null ? null : r.message;      // a failed refresh keeps what is shown
      if (r.ok) _d = r.data;
    });
  }

  Future<void> _claim(Map<String, dynamic> q) async {
    setState(() => _claiming = q['id'] as int);
    final r = await GameApi.call('/api/v1/quests/claim', _sid, {'id': q['id']});
    if (!mounted) return;
    setState(() => _claiming = null);
    if (!r.ok) {
      AppNotify.show(context, r.message ?? 'Could not claim the reward. Try again.', isError: true);
    } else {
      final ms = (r.data['milestones'] as List? ?? const []).cast<Map<String, dynamic>>();
      final extra = ms.isEmpty
          ? ''
          : ' · Streak: ${fmtCredits(ms.fold<num>(0, (a, m) => a + (m['credits'] as num? ?? 0)))}';
      final books = (r.data['books'] as num? ?? 0);
      AppNotify.show(context, 'Reward: ${fmtCredits(r.data['credits'] as num)}'
          '${books > 0 ? ' and ${books.round()} books' : ''}$extra');
      context.read<PlayerProvider>().refresh();
      context.read<Company>().refresh();
    }
    _load();
  }

  String _left(String iso) {
    final d = DateTime.parse('${iso}Z').difference(DateTime.now().toUtc());
    if (d.isNegative) return 'expired';
    return d.inHours >= 1 ? '${d.inHours} h left' : '${d.inMinutes} min left';
  }

  /// Each kind of quest has its own icon and colour.
  static (IconData, Color) _look(String code) => switch (code) {
        'build_hexes' => (Icons.hexagon_outlined, Colors.lightGreenAccent),
        'survey' => (Icons.satellite_alt, Colors.lightBlueAccent),
        'plant' => (Icons.factory_outlined, Colors.amberAccent),
        'educate' => (Icons.school_outlined, Colors.purpleAccent),
        'trade' => (Icons.storefront_outlined, Colors.tealAccent),
        'renew' => (Icons.autorenew, Colors.orangeAccent),
        'visit' => (Icons.location_city, Colors.pinkAccent),
        'place_campus' => (Icons.add_location_alt_outlined, Colors.pinkAccent),
        'appoint' => (Icons.person_pin_circle_outlined, Colors.cyanAccent),
        'buy_order' => (Icons.add_shopping_cart, Colors.tealAccent),
        'explore' => (Icons.travel_explore, Colors.lightBlueAccent),
        _ => (Icons.flag_outlined, AppColors.accent),
      };

  @override
  Widget build(BuildContext context) {
    return AsyncView(
      loading: _loading,
      error: _error,
      onRetry: _load,
      builder: () {
        final d = _d!;
        final qs = (d['quests'] as List).cast<Map<String, dynamic>>();
        final daily = (d['daily'] as Map?)?.cast<String, dynamic>();
        final reward = (d['reward'] as Map<String, dynamic>? ?? const {})['credits'] as num? ?? 0;
        final books = (d['reward'] as Map<String, dynamic>? ?? const {})['books'] as num? ?? 0;
        final co = context.read<Company>();
        final today = qs.isEmpty ? '' : qs.map((q) => q['day'] as String).reduce((a, b) => a.compareTo(b) > 0 ? a : b);
        final done = qs.where((q) => q['day'] == today && q['claimed'] == true).length;
        final ofToday = qs.where((q) => q['day'] == today).length;
        return RefreshIndicator(
          onRefresh: _load,
          child: ListView(padding: tabPadding(context, 12), children: [
            if (daily != null)
              DailyRewardCard(status: daily, co: co, onClaim: () async {
                if (await claimDailyReward(context, co)) _load();
              }),
            const SizedBox(height: 16),
            Row(children: [
              Text("TODAY'S QUESTS", style: TextStyle(fontSize: 11, color: AppColors.t38, letterSpacing: 1.2)),
              const Spacer(),
              Text('$done of $ofToday done', style: TextStyle(fontSize: 12, color: AppColors.t54)),
            ]),
            const SizedBox(height: 8),
            if (qs.isEmpty)
              Padding(padding: const EdgeInsets.all(24),
                  child: Center(child: Text('No quests right now', style: TextStyle(color: AppColors.t54)))),
            for (final q in qs) _questCard(q, reward, books),
            const SizedBox(height: 10),
            Text('Quests are extra: each one pays when you finish it, and one is always quick. They end at '
                'midnight (UTC) and new ones come every day. They don\'t affect your streak.',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: AppColors.t38)),
          ]),
        );
      },
    );
  }

  Widget _questCard(Map<String, dynamic> q, num reward, num books) {
    final (icon, color) = _look(q['code'] as String);
    final claimed = q['claimed'] == true;
    final progress = (q['progress'] as num).toDouble(), target = (q['target'] as num).toDouble();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: claimed ? Colors.greenAccent.withValues(alpha: 0.07) : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(children: [
          // the progress as a ring around the quest's icon
          SizedBox(width: 50, height: 50, child: Stack(alignment: Alignment.center, children: [
            SizedBox(width: 50, height: 50, child: CircularProgressIndicator(
              value: target <= 0 ? 0 : (progress / target).clamp(0.0, 1.0), strokeWidth: 4,
              backgroundColor: Colors.white10, color: claimed ? Colors.greenAccent : color)),
            Icon(claimed ? Icons.check : icon, color: claimed ? Colors.greenAccent : color, size: 22),
          ])),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(q['title'] as String, style: TextStyle(fontWeight: FontWeight.w600,
                color: claimed ? AppColors.t54 : null)),
            const SizedBox(height: 2),
            Text([
              '${progress.toInt()} of ${target.toInt()}',
              if (!claimed) _left(q['expiresAt'] as String),
            ].join(' · '), style: TextStyle(fontSize: 11, color: AppColors.t54)),
            // both rewards together under the title (owner 2026-11-07), the button only says Claim
            if (!claimed && (books > 0 || reward > 0))
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Wrap(spacing: 10, runSpacing: 2, children: [
                  if (books > 0) Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.menu_book_outlined, size: 13, color: Colors.amber),
                    const SizedBox(width: 3),
                    Text('+${fmtNum(books.round())} books', style: const TextStyle(fontSize: 12, color: Colors.amber)),
                  ]),
                  if (reward > 0) Row(mainAxisSize: MainAxisSize.min, children: [
                    const CreditsIcon(size: 13, color: Colors.greenAccent),
                    const SizedBox(width: 3),
                    Text('+${fmtNum(reward)}', style: const TextStyle(fontSize: 12, color: Colors.greenAccent)),
                  ]),
                ]),
              ),
          ])),
          const SizedBox(width: 8),
          if (!claimed && q['claimable'] == true)
            FilledButton(
              style: FilledButton.styleFrom(visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12)),
              onPressed: _claiming == null ? () => _claim(q) : null,
              child: _claiming == q['id']
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Claim'),
            ),
        ]),
      ),
    );
  }
}
