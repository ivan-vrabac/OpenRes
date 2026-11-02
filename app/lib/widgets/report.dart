import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../services/game_api.dart';
import 'popups.dart';
import 'top_banner.dart';

/// Report a player to the moderators (owner 2026-10-25, Google Play UGC policy: company names are
/// written by players). Moved here from the chat widget when chat was removed (0.2.3).
Future<void> reportPlayer(BuildContext context, String sid, String pid) async {
  final reason = await showAppSheet<String>(
    context: context,
    builder: (ctx) => ReportSheet(onPick: (key) => popIfCurrent(ctx, key)),
  );
  if (reason == null || !context.mounted) return;
  final r = await GameApi.call('/api/v1/report', sid, {'kind': 'player', 'pid': pid, 'reason': reason});
  if (context.mounted) {
    AppNotify.show(context, r.ok ? 'Thank you. A moderator will look at it.' : (r.message ?? 'Could not send the report'),
        isError: !r.ok);
  }
}

/// The reasons as separate buttons (owner 2026-11-02: a plain list read like a description).
class ReportSheet extends StatelessWidget {
  final void Function(String reason) onPick;
  const ReportSheet({super.key, required this.onPick});

  static const _reasons = [
    ('insult', Icons.report_outlined, Colors.redAccent, 'Offensive company name',
        'Insults, hate speech, bad words, mocking other people, sexualised words or propaganda'),
    ('cheating', Icons.gpp_bad_outlined, Colors.orangeAccent, 'Cheating', 'Faked location, bots or several companies'),
    ('other', Icons.more_horiz, Colors.lightBlueAccent, 'Something else', 'Anything else a moderator should look at'),
  ];

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(Icons.flag, color: AppColors.accent, size: 24),
              const SizedBox(width: 10),
              const Text('Report this company', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 6),
            Text('Why are you reporting it? A moderator will take a look, and the company is not told who reported it.',
                style: TextStyle(fontSize: 13, height: 1.35, color: AppColors.t54)),
            const SizedBox(height: 16),
            for (final (key, icon, color, title, text) in _reasons) ...[
              _ReasonButton(icon: icon, color: color, title: title, text: text, onTap: () => onPick(key)),
              const SizedBox(height: 10),
            ],
          ]),
        ),
      );
}

class _ReasonButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title, text;
  final VoidCallback onTap;
  const _ReasonButton({required this.icon, required this.color, required this.title, required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: color.withValues(alpha: 0.45), width: 1.2));
    return Material(
      color: color.withValues(alpha: 0.10),
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
          child: Row(children: [
            Container(
              width: 42, height: 42,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.18), shape: BoxShape.circle),
              child: Icon(icon, color: color, size: 23),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(text, style: TextStyle(fontSize: 12, height: 1.3, color: AppColors.t54)),
            ])),
            Icon(Icons.chevron_right, color: color),
          ]),
        ),
      ),
    );
  }
}
