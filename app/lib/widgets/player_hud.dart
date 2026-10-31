import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../constants.dart' show fmtNum;
import 'async_view.dart' show CreditsIcon;
import '../models/player_provider.dart';
import '../v3/company.dart';
import 'glass.dart';

import '../app_colors.dart';
/// The top bar: company name, Campus level and credits. A floating glass panel or a full-width bar
/// (Settings › App Appearance › Interface); it can also be hidden there.
class PlayerHud extends StatelessWidget {
  /// Tap on the bar: the game screen opens your company sheet.
  final VoidCallback? onTap;
  const PlayerHud({super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    final prov = context.watch<PlayerProvider>();
    final player = prov.player;
    if (player == null) return const SizedBox();
    final campus = context.watch<Company>().campusLevel;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: MapPanel(
        height: 38,
        radius: 19,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          Expanded(
            child: Text(player.name,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                overflow: TextOverflow.ellipsis),
          ),
          if (campus > 0) ...[
            Icon(Icons.location_city, size: 15, color: AppColors.t54),
            const SizedBox(width: 3),
            Text('$campus', style: TextStyle(fontSize: 12, color: AppColors.t70)),
            const SizedBox(width: 12),
          ],
          // a negative balance (after penalties) is shown in red
          CreditsIcon(size: 15, color: AppColors.t54),
          const SizedBox(width: 3),
          Text('ꞓ${fmtNum(prov.credits)}', style: TextStyle(fontSize: 12,
              color: prov.credits < 0 ? Colors.redAccent : AppColors.t70,
              fontWeight: prov.credits < 0 ? FontWeight.bold : null)),
        ]),
      ),
    );
  }
}
