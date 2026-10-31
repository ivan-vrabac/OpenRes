import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_colors.dart';
import '../services/game_api.dart';
import '../widgets/popups.dart';

/// Terms of use and privacy policy (owner 2026-10-25). The texts come from the server
/// (server/legal/*.md) so they can change without an app update. When their version is new to
/// this phone, the app shows them on start: accept and play, or decline and the app closes.
class Legal {
  static Map<String, dynamic>? _doc;

  /// {version, terms, privacy}, or null when the server can't be reached.
  static Future<Map<String, dynamic>?> load() async {
    if (_doc != null) return _doc;
    final r = await GameApi.call('/api/v1/legal', '');
    if (r.ok) _doc = r.data;
    return _doc;
  }

  static Future<String?> accepted() async => (await SharedPreferences.getInstance()).getString('legal_accepted');

  /// Let the server know this account accepted (kept as proof; harmless to repeat).
  static Future<void> report(String sid) async {
    final v = await accepted();
    if (v != null && sid.isNotEmpty) await GameApi.call('/api/v1/legal/accept', sid, {'version': v});
  }

  /// True when the player may go on (accepted now or before). Declining closes the app.
  static Future<bool> ensure(BuildContext context) async {
    final doc = await load();
    final had = await accepted();
    if (doc == null) return had != null;          // offline: whoever accepted before may play
    if (had == doc['version']) return true;
    if (!context.mounted) return false;
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
        fullscreenDialog: true, builder: (_) => _AcceptScreen(doc: doc, update: had != null)));
    if (ok == true) {
      await (await SharedPreferences.getInstance()).setString('legal_accepted', doc['version'] as String);
      return true;
    }
    await SystemNavigator.pop();                  // declined: the app closes
    return false;
  }

  /// More › Terms of use / Privacy policy.
  static Future<void> show(BuildContext context, {required bool privacy}) async {
    final doc = await load();
    if (!context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
          appBar: AppBar(toolbarHeight: 36, title: Text(privacy ? 'Privacy policy' : 'Terms of use')),
          body: doc == null
              ? Center(child: Text('Could not reach the server.', style: TextStyle(color: AppColors.t54)))
              : LegalText(doc[privacy ? 'privacy' : 'terms'] as String),
        )));
  }
}

class _AcceptScreen extends StatelessWidget {
  final Map<String, dynamic> doc;
  final bool update;
  const _AcceptScreen({required this.doc, required this.update});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            title: Text(update ? 'Updated terms' : 'Before you play', style: const TextStyle(fontSize: 17)),
            bottom: const TabBar(tabs: [Tab(text: 'Terms of use'), Tab(text: 'Privacy policy')]),
          ),
          body: TabBarView(children: [LegalText(doc['terms'] as String), LegalText(doc['privacy'] as String)]),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('By tapping "I agree" you accept the Terms of use and the Privacy policy.',
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: AppColors.t54)),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: OutlinedButton(
                      onPressed: () => popIfCurrent(context, false), child: const Text("I don't agree"))),
                  const SizedBox(width: 12),
                  Expanded(child: FilledButton(
                      onPressed: () => popIfCurrent(context, true), child: const Text('I agree'))),
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// A small Markdown subset: # title, ## heading, "- " bullets, **bold**, paragraphs.
class LegalText extends StatelessWidget {
  final String md;
  const LegalText(this.md, {super.key});

  static List<TextSpan> _inline(String s, TextStyle base) {
    final out = <TextSpan>[];
    final parts = s.split('**');
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].isEmpty) continue;
      out.add(TextSpan(text: parts[i], style: i.isOdd ? base.copyWith(fontWeight: FontWeight.bold) : base));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final body = TextStyle(fontSize: 13.5, height: 1.45, color: AppColors.t70);
    final blocks = <Widget>[];
    for (final raw in md.split(RegExp(r'\n\s*\n'))) {
      final b = raw.trim();
      if (b.isEmpty) continue;
      if (b.startsWith('# ')) {
        blocks.add(Padding(padding: const EdgeInsets.only(bottom: 6),
            child: Text(b.substring(2), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))));
      } else if (b.startsWith('## ')) {
        blocks.add(Padding(padding: const EdgeInsets.only(top: 10, bottom: 4),
            child: Text(b.substring(3), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold))));
      } else if (b.startsWith('- ')) {
        for (final item in b.split(RegExp(r'\n(?=- )'))) {
          blocks.add(Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('•  ', style: body),
              Expanded(child: Text.rich(TextSpan(children: _inline(item.substring(2).replaceAll('\n', ' '), body)))),
            ]),
          ));
        }
      } else {
        blocks.add(Padding(padding: const EdgeInsets.only(bottom: 8),
            child: Text.rich(TextSpan(children: _inline(b.replaceAll('\n', ' '), body)))));
      }
    }
    return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: blocks);
  }
}
