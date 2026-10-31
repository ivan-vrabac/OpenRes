import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../constants.dart' show fmtNum;
import '../widgets/popups.dart';
import '../widgets/top_banner.dart';
import 'company.dart';

/// The login streak: once a day, when the game opens, a dialog offers today's reward (credits and
/// books, more at days 7, 14 and 30). Missing a day starts the streak again (/api/v3/streak).
Future<void> offerLoginStreak(BuildContext context, Company co) async {
  final s = await co.call('/api/v3/streak');
  if (!context.mounted || !s.ok || s.data['claimed'] == true) return;
  final day = (s.data['day'] as num).toInt();
  final credits = s.data['credits'] as num;
  final mats = (s.data['materials'] as Map? ?? const {}).cast<String, dynamic>();
  final table = s.list('table');
  final claim = await showAppDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(day == 1 ? 'Daily reward' : 'Day $day in a row!'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.local_fire_department, size: 40, color: AppColors.accent),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('ꞓ${fmtNum(credits)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            for (final e in mats.entries)
              Text('${fmtNum(e.value as num)} ${co.itemName(e.key).toLowerCase()}', style: TextStyle(color: AppColors.t70)),
          ])),
        ]),
        const SizedBox(height: 12),
        Text('Come back every day: the reward grows on days ${table.skip(1).map((t) => t['from']).join(', ')}. '
            'Missing a day starts this reward again from day 1. Your quest streak is separate.',
            style: TextStyle(fontSize: 12, color: AppColors.t54)),
      ]),
      actions: [
        TextButton(onPressed: () => popIfCurrent(ctx, false), child: const Text('Later')),
        FilledButton(onPressed: () => popIfCurrent(ctx, true), child: const Text('Claim')),
      ],
    ),
  );
  if (claim != true || !context.mounted) return;
  final r = await co.call('/api/v3/streak/claim');
  if (!context.mounted) return;
  AppNotify.show(context, r.ok ? 'Day ${r.data['day']}: ꞓ${fmtNum(r.data['credits'] as num)} added' : (r.message ?? 'Could not claim'),
      isError: !r.ok);
  if (r.ok) await co.refresh();
}
