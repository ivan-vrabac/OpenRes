import '../widgets/glass.dart' show tabPadding;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/player_provider.dart';
import '../services/game_api.dart';
import '../widgets/async_view.dart';
import '../widgets/top_banner.dart';

import '../app_colors.dart';
/// Daily quests (they end at midnight) and the streak (0.2.3 redo, owner 2026-10-31): the streak card with this
/// week's days and the bonuses every 7 and 30 days (a streak day itself pays nothing), then the
/// quests as cards with their icon in a progress ring and a Claim button with the reward.
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await GameApi.call('/api/v1/quests', _sid);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = r.ok ? null : r.message;
      if (r.ok) _d = r.data;
    });
  }

  Future<void> _claim(Map<String, dynamic> q) async {
    setState(() => _claiming = q['id'] as int);
    final r = await GameApi.call('/api/v1/quests/claim', _sid, {'id': q['id']});
    if (!mounted) return;
    setState(() => _claiming = null);
    if (!r.ok) {
      AppNotify.show(context, r.message ?? 'Failed', isError: true);
    } else {
      final ms = (r.data['milestones'] as List? ?? const []).cast<Map<String, dynamic>>();
      final extra = ms.isEmpty
          ? ''
          : ' · Streak: ${fmtCredits(ms.fold<num>(0, (a, m) => a + (m['credits'] as num? ?? 0)))}';
      AppNotify.show(context, 'Reward: ${fmtCredits(r.data['credits'] as num)}$extra');
      context.read<PlayerProvider>().refresh();
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
        final streak = d['streak'] as int? ?? 0;
        final reward = (d['reward'] as Map<String, dynamic>? ?? const {})['credits'] as num? ?? 0;
        final ms = ((d['rewardPlan'] as Map?)?['milestones'] as List? ?? const []).cast<Map<String, dynamic>>();
        final today = qs.isEmpty ? '' : qs.map((q) => q['day'] as String).reduce((a, b) => a.compareTo(b) > 0 ? a : b);
        final done = qs.where((q) => q['day'] == today && q['claimed'] == true).length;
        final ofToday = qs.where((q) => q['day'] == today).length;
        return RefreshIndicator(
          onRefresh: _load,
          child: ListView(padding: tabPadding(context, 12), children: [
            _streakCard(streak, ms),
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
            for (final q in qs) _questCard(q, reward),
            const SizedBox(height: 10),
            Text('Finish all of today\'s quests before midnight (UTC) for a streak day. Missing one day won\'t '
                'end your streak, missing two in a row will. Your streak days count for the Quest solver achievement.',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: AppColors.t38)),
          ]),
        );
      },
    );
  }

  /// The streak: the days in the current week of it, the bonus every 7 and every 30 days.
  Widget _streakCard(int streak, List<Map<String, dynamic>> ms) {
    num bonus(int every) => ms.firstWhere((m) => m['every'] == every, orElse: () => const {'credits': 0})['credits'] as num;
    final inWeek = streak % 7;
    final to30 = 30 - streak % 30;
    final hot = streak > 0;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(colors: [
          (hot ? Colors.deepOrange : Colors.blueGrey).withValues(alpha: 0.30),
          Colors.white.withValues(alpha: 0.04),
        ], begin: Alignment.topLeft, end: Alignment.bottomRight),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.local_fire_department, size: 44, color: hot ? Colors.orangeAccent : Colors.white24),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('$streak', style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, height: 1)),
            Text(streak == 1 ? 'day in a row' : 'days in a row', style: TextStyle(fontSize: 12, color: AppColors.t54)),
          ])),
        ]),
        const SizedBox(height: 14),
        // this week of the streak: a dot per day, the 7th is the bonus
        Row(children: [
          for (var i = 1; i <= 7; i++) ...[
            Expanded(child: Container(
              height: 26,
              decoration: BoxDecoration(
                color: i <= inWeek ? Colors.orangeAccent.withValues(alpha: 0.85) : Colors.white.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(child: i == 7
                  ? Icon(Icons.card_giftcard, size: 15, color: i <= inWeek ? Colors.black : AppColors.t54)
                  : Text('$i', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold,
                      color: i <= inWeek ? Colors.black : AppColors.t38))),
            )),
            if (i < 7) const SizedBox(width: 4),
          ],
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: Text('Every 7 days', style: TextStyle(fontSize: 12, color: AppColors.t70))),
          Text(fmtCredits(bonus(7)), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.amber)),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(child: Text('Every 30 days ($to30 to go)', style: TextStyle(fontSize: 12, color: AppColors.t70))),
          Text(fmtCredits(bonus(30)), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.amber)),
        ]),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(value: (streak % 30) / 30, minHeight: 4,
              backgroundColor: Colors.white12, color: Colors.amber),
        ),
      ]),
    );
  }

  Widget _questCard(Map<String, dynamic> q, num reward) {
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
          ])),
          const SizedBox(width: 8),
          if (!claimed)
            FilledButton(
              style: FilledButton.styleFrom(visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12)),
              onPressed: q['claimable'] == true && _claiming == null ? () => _claim(q) : null,
              child: _claiming == q['id']
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(q['claimable'] == true ? 'Claim ${fmtCredits(reward)}' : fmtCredits(reward)),
            ),
        ]),
      ),
    );
  }
}
