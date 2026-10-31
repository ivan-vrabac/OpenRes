// Part of the map tab (split off map_tab.dart, 2026-11-01).
part of 'map_tab.dart';

/// The sheets the map opens: building a hex, and the hexes that share one spot.
extension _MapSheets on _MapTabState {
  // ── Build dialog ───────────────────────────────────────────────────────────

  Future<void> _showBuildDialog(Map<String, dynamic> r) async {
    final pos = _pos;
    if (pos == null) { _snack('Waiting for your location…', error: true); return; }
    final target = _snapBuildPos(_mapCenter ?? pos);
    final distToTarget = _distM(pos, target);
    final res = await _co.call('/api/v3/hex/info', {'lat': target.latitude, 'lng': target.longitude});
    if (!mounted || !res.ok) return;
    final item = r['item'] as String, op = r['op'] as String;
    final here = ((res.data['options'] as Map)[op] as Map?)?[item] as Map?;
    final name = _co.itemName(item);
    if (here == null) {
      _snack('No ${name.toLowerCase()} here (${res.data['land']}). Check the survey: hotter colours are better.', error: true);
      return;
    }
    final quality = (here['quality'] as num).toInt();
    final cost = (here['build'] as num).toInt();
    final unlocked = here['unlocked'] == true;
    final qColor = quality > 70 ? Colors.greenAccent : quality > 40 ? Colors.amber : Colors.orange;
    final inLocalRange = distToTarget <= 100;
    final unit = item == 'electricity' ? ' kWh' : '';
    // the hex to build (owner 2026-10-31: the old text dialog looked like the original game): its
    // picture, quality bar, output and costs, and slide to build like the survey
    Widget tile(String label, String value, {Color? color}) => Expanded(
          child: Container(
            margin: const EdgeInsets.all(3),
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(10)),
            child: Column(children: [
              FittedBox(fit: BoxFit.scaleDown, child: Text(value,
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: color))),
              const SizedBox(height: 2),
              Text(label, style: TextStyle(fontSize: 10, color: AppColors.t54)),
            ]),
          ),
        );
    showAppSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              HexPicture(_MapTabState._hexImage({'item': item, 'op': op}), size: 72),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                Text('${_co.opName(op)} · ${res.data['land']}', style: TextStyle(color: AppColors.t54, fontSize: 12)),
              ])),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              Text('Quality', style: TextStyle(fontSize: 12, color: AppColors.t54)),
              const Spacer(),
              Text('$quality %', style: TextStyle(color: qColor, fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: quality / 100, minHeight: 8,
                  backgroundColor: Colors.white12, color: qColor),
            ),
            const SizedBox(height: 10),
            Row(children: [
              tile('Makes / hour', '${fmtNum(here['perHour'] as num? ?? 0)}$unit'),
              tile('Worth / hour', 'ꞓ${fmtNum(here['valuePerHour'] as num? ?? 0)}', color: Colors.greenAccent),
            ]),
            Row(children: [
              tile('Build', 'ꞓ${fmtNum(cost)}', color: Colors.amber),
              tile('Lease 90 days, renew', 'ꞓ${fmtNum(here['lease'] as num)}'),
            ]),
            if (quality < 30)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('Quality is low. Check the survey: hotter colours are better.',
                    textAlign: TextAlign.center, style: TextStyle(color: Colors.orange, fontSize: 12)),
              ),
            if (!inLocalRange)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('The hex is ${distToTarget.round()} m away: build within 100 m.', textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
              ),
            if (!unlocked)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Unlocked at Campus level ${here['unlockLevel']}', textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
              ),
            const SizedBox(height: 14),
            SlideToConfirm(
              label: 'Build here',
              sublabel: 'ꞓ${fmtNum(cost)}',
              icon: Icons.construction,
              height: 60,
              radius: 14,
              enabled: inLocalRange && unlocked,
              onConfirm: () {
                popIfCurrent(ctx);
                final freshPos = _pos;
                if (freshPos == null || _distM(freshPos, target) > 100) {
                  _snack('Building failed: the hex is out of range.', error: true);
                  return;
                }
                _buildMine({'item': item, 'op': op}, buildAt: target, curPos: freshPos);
              },
            ),
            const SizedBox(height: 4),
            Center(child: TextButton(onPressed: () => popIfCurrent(ctx), child: const Text('Cancel'))),
          ]),
        ),
      ),
    );
  }

  /// The hexes sharing the spot under the tap; with more than one, a picker. True when it handled the tap.
  Future<bool> _pickFromStack(LatLng tapped) async {
    Map<String, dynamic>? nearest;
    double bestD = 15;
    for (final m in _world.hexes) {
      if (m['type'] != 'mine' || m['wip'] == true) continue;
      final d = _distM(tapped, LatLng((m['lat'] as num).toDouble(), (m['lng'] as num).toDouble()));
      if (d <= bestD) { bestD = d; nearest = m; }
    }
    if (nearest == null) return false;
    final stack = _world.hexes.where((m) =>
        m['type'] == 'mine' && m['wip'] != true &&
        _distM(LatLng((m['lat'] as num).toDouble(), (m['lng'] as num).toDouble()),
            LatLng((nearest!['lat'] as num).toDouble(), (nearest['lng'] as num).toDouble())) < 1).toList();
    if (stack.length < 2) return false;
    // the hexes on one spot as cards with their hex pictures, like the build sheet (owner 2026-10-31)
    final picked = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Hexes on this spot', textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
          const SizedBox(height: 4),
          Text('Companies that build within 30 s of each other share a hex.', textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.t54)),
          const SizedBox(height: 12),
          ...stack.map((m) {
            final own = m['isMine'] == true;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: own ? AppColors.accent.withValues(alpha: 0.12) : Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => Navigator.of(ctx).pop(m),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(children: [
                      HexPicture(_MapTabState._hexImage(m), size: 48),
                      const SizedBox(width: 12),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(_co.itemName(m['item'] as String? ?? ''),
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                        Text('${_co.opName(m['op'] as String? ?? '')} · ${own ? 'yours' : 'another company'}',
                            style: TextStyle(fontSize: 12, color: own ? AppColors.accent : AppColors.t54)),
                      ])),
                      if (own) Icon(Icons.chevron_right, color: AppColors.t54),
                    ]),
                  ),
                ),
              ),
            );
          }),
          Center(child: TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close'))),
        ]),
      )),
    );
    if (picked == null || !mounted) return true;
    if (picked['isMine'] == true && picked['id'] != null) {
      _openOwnHex((picked['id'] as num).toInt());
    } else {
      _snack('${_co.itemName(picked['item'] as String? ?? '')} of another company');
    }
    return true;
  }
}
