import '../widgets/glass.dart' show tabPadding;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_colors.dart';
import '../v3/company.dart';
import '../widgets/async_view.dart' show TaIcon;
import '../widgets/cards.dart';

/// "3.82 g", "120 mg", "1.25 kg".
String fmtMass(num mg) {
  if (mg >= 1e6) return '${(mg / 1e6).toStringAsFixed(2)} kg';
  if (mg >= 1000) return '${(mg / 1000).toStringAsFixed(2)} g';
  return '${mg < 10 ? mg.toStringAsFixed(2) : mg.toStringAsFixed(0)} mg';
}

/// Luxury: Tantalum-180m, the rarest material in the game (only produced, never sold), what the
/// company holds and has made, and the leaderboard of everything ever produced (/api/v3/luxury).
class LuxuryScreen extends StatefulWidget {
  const LuxuryScreen({super.key});
  @override
  State<LuxuryScreen> createState() => _LuxuryScreenState();
}

class _LuxuryScreenState extends State<LuxuryScreen> {
  Map<String, dynamic>? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final r = await context.read<Company>().call('/api/v3/luxury');
    if (!mounted) return;
    setState(() {
      if (r.ok) {
        _data = r.data;
        _error = null;
      } else {
        _error = r.message ?? 'Could not load';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final canPop = ModalRoute.of(context)?.canPop == true;
    final d = _data;
    return Scaffold(
      appBar: canPop ? AppBar(toolbarHeight: 36) : null,
      body: d == null
          ? Center(child: _error == null
              ? const CircularProgressIndicator()
              : Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_error!, style: TextStyle(color: AppColors.t54)),
                  const SizedBox(height: 8),
                  FilledButton(onPressed: _load, child: const Text('Try again')),
                ]))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: tabPadding(context, 12), children: [
                Center(child: Image.asset(itemPicture('ta180m'), height: 170, fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => TaIcon(size: 100, color: AppColors.accent))),
                const SizedBox(height: 8),
                const Text('Tantalum-180m', textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text('The rarest natural isotope we know: no one has ever seen it decay. Your isotope lab makes it '
                    'from tantalum and supercomputers, counted in milligrams. It can\'t be sold, only made, and '
                    'later put into dark matter research.',
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: AppColors.t60)),
                const SizedBox(height: 14),
                Row(children: [
                  StatTile(fmtMass(d['heldMg'] as num), 'You have', color: AppColors.accent),
                  const SizedBox(width: 8),
                  StatTile(fmtMass(d['producedMg'] as num), 'Made in total'),
                  const SizedBox(width: 8),
                  StatTile(fmtMass(d['investedMg'] as num), 'In research'),
                ]),
                const SizedBox(height: 18),
                const SectionLabel('Most ever made'),
                if ((d['top'] as List).isEmpty)
                  Panel(child: Text('No one has made any yet. Be the first.',
                      textAlign: TextAlign.center, style: TextStyle(color: AppColors.t54)))
                else
                  RowGroup([
                    for (final (i, t) in (d['top'] as List).cast<Map<String, dynamic>>().indexed)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        child: Row(children: [
                          CircleAvatar(
                            radius: 13,
                            backgroundColor: i < 3 ? Colors.amber.withValues(alpha: 0.25) : Colors.white10,
                            child: Text('${i + 1}', style: TextStyle(fontSize: 12,
                                color: i < 3 ? Colors.amber : AppColors.t70, fontWeight: FontWeight.bold)),
                          ),
                          const SizedBox(width: 12),
                          Expanded(child: Text(t['name'] as String? ?? '', overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontWeight: t['you'] == true ? FontWeight.bold : FontWeight.normal,
                                  color: t['you'] == true ? AppColors.accent : null))),
                          Text(fmtMass(t['mg'] as num), style: const TextStyle(fontWeight: FontWeight.bold)),
                        ]),
                      ),
                  ]),
                const SizedBox(height: 8),
                Text('The ranking counts everything ever made, so putting it into research never costs you your place.',
                    style: TextStyle(fontSize: 11, color: AppColors.t38)),
              ]),
            ),
    );
  }
}
