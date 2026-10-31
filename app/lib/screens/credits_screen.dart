import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_colors.dart';
import '../widgets/top_banner.dart';

/// More › Image credits (owner 2026-10-25): the pictures come from Wikimedia Commons and other free
/// sources whose licenses (CC BY, CC BY-SA) require naming the author, the license and the source.
/// The list is the bundled assets/credits/image_credits.csv. One section per group (items, plants,
/// operations, land, flags and app icons; owner 2026-10-31: grouped unless you search), each credit
/// with its picture; tap one to copy its source link.
class CreditsScreen extends StatefulWidget {
  const CreditsScreen({super.key});
  @override
  State<CreditsScreen> createState() => _CreditsScreenState();
}

class _CreditsScreenState extends State<CreditsScreen> {
  List<Map<String, String>> _rows = const [];
  String _q = '';
  final _open = <String>{};

  @override
  void initState() {
    super.initState();
    rootBundle.loadString('assets/credits/image_credits.csv').then((s) {
      final rows = parseCsv(s);
      if (rows.length < 2 || !mounted) return;
      final head = rows.first;
      setState(() => _rows = [
            for (final r in rows.skip(1))
              {for (var i = 0; i < head.length && i < r.length; i++) head[i]: r[i]},
          ]);
    }).catchError((_) {});
  }

  bool _matches(Map<String, String> r) =>
      _q.isEmpty || '${r['picture']} ${r['author']} ${r['license']} ${r['title']}'.toLowerCase().contains(_q);

  Widget _tile(Map<String, String> r) {
    final file = r['file'] ?? '';
    return ListTile(
      dense: true,
      leading: file.isEmpty
          ? const SizedBox(width: 40)
          : ClipRRect(borderRadius: BorderRadius.circular(8),
              child: Image.asset('assets/game/$file', width: 40, height: 40, fit: BoxFit.cover, cacheWidth: 80,
                  errorBuilder: (_, __, ___) => const SizedBox(width: 40))),
      title: Text(r['picture'] ?? ''),
      subtitle: Text('${r['title'] ?? ''}\n${(r['author'] ?? '').isEmpty ? 'Unknown author' : r['author']} · '
          '${r['license'] ?? ''}${(r['changes'] ?? '').isNotEmpty ? ' · ${r['changes']}' : ''}',
          style: TextStyle(fontSize: 11, color: AppColors.t54)),
      isThreeLine: true,
      onTap: () {
        Clipboard.setData(ClipboardData(text: r['source'] ?? ''));
        AppNotify.show(context, 'Link copied');
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<Map<String, String>>>{};
    for (final r in _rows) {
      groups.putIfAbsent((r['group'] ?? '').isEmpty ? 'Other' : r['group']!, () => []).add(r);
    }
    final found = _rows.where(_matches).toList();
    return Scaffold(
      appBar: AppBar(toolbarHeight: 36, title: const Text('Image credits')),
      body: ListView(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text('The Campus pictures and the small icons were drawn for this game. The other pictures '
              'are photos used under the licenses below (cropped and resized). Tap one to copy its source link.',
              style: TextStyle(fontSize: 12, color: AppColors.t54)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            decoration: InputDecoration(isDense: true, prefixIcon: const Icon(Icons.search), hintText: 'Find a picture or author',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14))),
            onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
          ),
        ),
        if (_q.isNotEmpty) ...[
          for (final r in found) _tile(r),
          if (found.isEmpty)
            Padding(padding: const EdgeInsets.all(16),
                child: Text('Nothing found', style: TextStyle(color: AppColors.t38))),
        ] else
          // one section per group, opened when tapped (the pictures load only then)
          for (final g in groups.entries)
            ExpansionTile(
              key: PageStorageKey(g.key),
              title: Text(g.key, style: const TextStyle(fontWeight: FontWeight.w600)),
              trailing: Text('${g.value.length}', style: TextStyle(color: AppColors.t54)),
              initiallyExpanded: _open.contains(g.key),
              onExpansionChanged: (o) => o ? _open.add(g.key) : _open.remove(g.key),
              children: [for (final r in g.value) _tile(r)],
            ),
        if (_rows.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('This build has no third-party pictures.', style: TextStyle(color: AppColors.t38)),
          ),
        const SizedBox(height: 16),
      ]),
    );
  }
}

/// Minimal CSV (RFC 4180: quoted fields, "" inside quotes, newlines inside quotes).
List<List<String>> parseCsv(String s) {
  final rows = <List<String>>[];
  var row = <String>[];
  final f = StringBuffer();
  var q = false;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (q) {
      if (c == '"') {
        if (i + 1 < s.length && s[i + 1] == '"') {
          f.write('"');
          i++;
        } else {
          q = false;
        }
      } else {
        f.write(c);
      }
    } else if (c == '"') {
      q = true;
    } else if (c == ',') {
      row.add(f.toString());
      f.clear();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < s.length && s[i + 1] == '\n') i++;
      row.add(f.toString());
      f.clear();
      if (row.any((x) => x.isNotEmpty)) rows.add(row);
      row = <String>[];
    } else {
      f.write(c);
    }
  }
  if (f.isNotEmpty || row.isNotEmpty) {
    row.add(f.toString());
    if (row.any((x) => x.isNotEmpty)) rows.add(row);
  }
  return rows;
}
