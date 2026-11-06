import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../constants.dart' show fmtNum;
import '../widgets/popups.dart';
import '../widgets/top_banner.dart';
import 'company.dart';

/// The daily reward and its streak, the game's only streak (owner 2026-11-06). Once a day, when the game
/// opens, a dialog shows what today brings (credits, books, the bonus on every 7th and 30th day), where the
/// streak stands and what comes next. The Rewards tab shows the same card (/api/v3/streak).
Future<void> offerLoginStreak(BuildContext context, Company co) async {
  final s = await co.call('/api/v3/streak');
  if (!context.mounted || !s.ok || s.data['claimed'] == true) return;
  final claim = await showAppDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      content: SingleChildScrollView(child: DailyRewardCard(status: s.data, co: co, framed: false)),
      actions: [
        TextButton(onPressed: () => popIfCurrent(ctx, false), child: const Text('Later')),
        FilledButton(onPressed: () => popIfCurrent(ctx, true), child: const Text('Claim')),
      ],
    ),
  );
  if (claim != true || !context.mounted) return;
  await claimDailyReward(context, co);
}

/// Claims today's reward and says what came in.
Future<bool> claimDailyReward(BuildContext context, Company co) async {
  final r = await co.call('/api/v3/streak/claim');
  if (!context.mounted) return false;
  if (!r.ok) {
    AppNotify.show(context, r.message ?? 'Could not claim', isError: true);
    return false;
  }
  final total = (r.data['credits'] as num) + ((r.data['bonus'] as num?) ?? 0);
  AppNotify.show(context, 'Day ${r.data['day']}: ꞓ${fmtNum(total)} added');
  await co.refresh();
  return true;
}

/// Today's reward, the streak this week, the next bonus and the best streak. [status] is /api/v3/streak
/// (or the "daily" part of /api/v1/quests). [onClaim]: a Claim button in the card (the Rewards tab).
class DailyRewardCard extends StatelessWidget {
  const DailyRewardCard({super.key, required this.status, required this.co, this.onClaim, this.framed = true});
  final Map<String, dynamic> status;
  final Company co;
  final VoidCallback? onClaim;
  final bool framed;

  @override
  Widget build(BuildContext context) {
    final claimed = status['claimed'] == true;
    final day = (status['day'] as num? ?? 1).toInt();            // today's streak day (claimed or not)
    final credits = status['credits'] as num? ?? 0;
    final bonus = status['bonus'] as num? ?? 0;
    final mats = (status['materials'] as Map? ?? const {}).cast<String, dynamic>();
    final next = (status['nextBonus'] as Map? ?? const {}).cast<String, dynamic>();
    final best = (status['best'] as num? ?? 0).toInt();
    final missed = status['missedOne'] == true;
    final inWeek = (day - 1) % 7 + 1;                           // where today sits in its week, 1 to 7
    final weekDone = claimed ? inWeek : inWeek - 1;
    final body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Icon(Icons.local_fire_department, size: 44, color: day > 1 || claimed ? Colors.orangeAccent : Colors.white38),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Day $day', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, height: 1.1)),
          Text(claimed ? 'Today\'s reward is yours. Come back tomorrow.' : 'Daily reward',
              style: TextStyle(fontSize: 12, color: AppColors.t54)),
        ])),
        if (best > 1)
          Column(children: [
            Text('$best', style: const TextStyle(fontWeight: FontWeight.bold)),
            Text('best', style: TextStyle(fontSize: 10, color: AppColors.t54)),
          ]),
      ]),
      if (missed && !claimed)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('You missed yesterday, your streak is still alive. Claim today to keep it.',
              style: TextStyle(fontSize: 12, color: Colors.orangeAccent.shade100)),
        ),
      const SizedBox(height: 12),
      // what today brings
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(claimed ? 'You got today' : 'Today you get', style: TextStyle(fontSize: 11, color: AppColors.t54)),
          const SizedBox(height: 4),
          _line(Icons.toll, 'ꞓ${fmtNum(credits)}', null),
          if (bonus > 0) _line(Icons.card_giftcard, 'ꞓ${fmtNum(bonus)}', day % 30 == 0 ? '30 day bonus' : '7 day bonus'),
          for (final e in mats.entries)
            _line(Icons.menu_book_outlined, '${fmtNum(e.value as num)} ${co.itemName(e.key).toLowerCase()}', null),
        ]),
      ),
      const SizedBox(height: 12),
      // this week of the streak: one box a day, the 7th is the bonus
      Row(children: [
        for (var i = 1; i <= 7; i++) ...[
          Expanded(child: Container(
            height: 28,
            decoration: BoxDecoration(
              color: i <= weekDone ? Colors.orangeAccent.withValues(alpha: 0.85)
                  : i == inWeek ? Colors.orangeAccent.withValues(alpha: 0.25) : Colors.white.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(8),
              border: i == inWeek && !claimed ? Border.all(color: Colors.orangeAccent) : null,
            ),
            child: Center(child: i == 7
                ? Icon(Icons.card_giftcard, size: 15, color: i <= weekDone ? Colors.black : AppColors.t54)
                : Text('${day - inWeek + i}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold,
                    color: i <= weekDone ? Colors.black : AppColors.t54))),
          )),
          if (i < 7) const SizedBox(width: 4),
        ],
      ]),
      const SizedBox(height: 10),
      if (next['day'] != null)
        Row(children: [
          Expanded(child: Text('Next bonus on day ${next['day']}', style: TextStyle(fontSize: 12, color: AppColors.t70))),
          Text('ꞓ${fmtNum(next['credits'] as num? ?? 0)}', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.amber)),
        ]),
      const SizedBox(height: 6),
      Text('Claim once a day. The reward grows on days 7, 14 and 30, with a bonus every 7th and 30th day. '
          'One missed day is forgiven, two in a row start again from day 1.',
          style: TextStyle(fontSize: 11, color: AppColors.t38)),
      if (onClaim != null && !claimed) ...[
        const SizedBox(height: 10),
        FilledButton.icon(onPressed: onClaim, icon: const Icon(Icons.redeem), label: const Text('Claim today\'s reward')),
      ],
    ]);
    if (!framed) return body;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(colors: [
          Colors.deepOrange.withValues(alpha: claimed ? 0.18 : 0.32),
          Colors.white.withValues(alpha: 0.04),
        ], begin: Alignment.topLeft, end: Alignment.bottomRight),
      ),
      child: body,
    );
  }

  Widget _line(IconData icon, String text, String? tag) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Icon(icon, size: 18, color: Colors.amber),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          if (tag != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(color: Colors.amber.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(6)),
              child: Text(tag, style: const TextStyle(fontSize: 10, color: Colors.amber)),
            ),
          ],
        ]),
      );
}
