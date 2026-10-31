import 'package:flutter/material.dart';

import '../services/game_api.dart';
import 'popups.dart';
import 'top_banner.dart';

/// Report a player to the moderators (owner 2026-10-25, Google Play UGC policy: company names are
/// written by players). Moved here from the chat widget when chat was removed (0.2.3).
Future<void> reportPlayer(BuildContext context, String sid, String pid) async {
  const reasons = {
    'insult': 'Offensive company name or insults',
    'hate': 'Hate or discrimination',
    'sexual': 'Sexual content',
    'spam': 'Spam or advertising',
    'cheating': 'Cheating',
    'other': 'Something else',
  };
  final reason = await showAppSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const ListTile(title: Text('Report', style: TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text('A moderator will look at it. The player is not told who reported them.')),
      for (final e in reasons.entries)
        ListTile(dense: true, title: Text(e.value), onTap: () => popIfCurrent(ctx, e.key)),
    ])),
  );
  if (reason == null || !context.mounted) return;
  final r = await GameApi.call('/api/v1/report', sid, {'kind': 'player', 'pid': pid, 'reason': reason});
  if (context.mounted) {
    AppNotify.show(context, r.ok ? 'Thank you. A moderator will look at it.' : (r.message ?? 'Could not send the report'),
        isError: !r.ok);
  }
}
