part of 'map_tab.dart';

/// The menus of the survey panel: where they open, what they pick.
extension _MapMenus on _MapTabState {
  /// A menu that grows upwards out of the button `key` (modal: only one menu at a time).
  Future<T?> _anchoredMenu<T>(GlobalKey key, List<_MenuRow<T>> rows) {
    final btn = key.currentContext?.findRenderObject() as RenderBox?;
    final screen = MediaQuery.of(context).size;
    final at = btn?.localToGlobal(Offset.zero) ?? Offset(screen.width - 60, screen.height - 90);
    final topRoom = at.dy - MediaQuery.of(context).padding.top - 16;
    final onLeft = at.dx < screen.width / 2;
    return Navigator.of(context).push<T>(PageRouteBuilder(
      opaque: false,
      barrierDismissible: true,
      barrierColor: Colors.black26,
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (ctx, anim, _) => Stack(children: [
        Positioned(
          left: onLeft ? math.max(4.0, at.dx) : null,
          right: onLeft ? null : math.max(4.0, screen.width - at.dx - 52),
          bottom: screen.height - at.dy + 6,
          child: ScaleTransition(
            alignment: onLeft ? Alignment.bottomLeft : Alignment.bottomRight,
            scale: CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(10),
              color: Theme.of(ctx).colorScheme.surfaceContainerHigh,
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: topRoom, maxWidth: screen.width - 24),
                child: IntrinsicWidth(
                  child: SingleChildScrollView(
                    reverse: true,                       // the bottom row next to the button shows first
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      for (final row in rows)
                        InkWell(
                          onTap: row.locked ? null : () => popIfCurrent(ctx, row.value),
                          child: Container(
                            color: row.selected ? AppColors.accent.withValues(alpha: 0.15) : null,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            child: Row(children: [
                              SizedBox(width: 28, height: 28, child: Opacity(opacity: row.locked ? 0.35 : 1, child: row.leading)),
                              const SizedBox(width: 10),
                              Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(row.label, style: TextStyle(
                                    color: row.locked ? AppColors.t38 : row.selected ? AppColors.accent : null)),
                                if (row.note != null)
                                  Text(row.note!, style: const TextStyle(fontSize: 10, color: Colors.orange)),
                              ]),
                              if (row.locked) ...[
                                const SizedBox(width: 8),
                                Icon(Icons.lock_outline, size: 14, color: AppColors.t38),
                              ],
                            ]),
                          ),
                        ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ]),
    ));
  }

  /// Categories; one whose first resource your Campus hasn't unlocked yet is locked.
  Future<void> _openCategoryMenu() async {
    if (tutorialLocked.value) return;
    final level = math.max(1, _co.campusLevel);
    final entries = _entries((_co.catalog['raw'] as Map?)?.cast<String, dynamic>() ?? const {});
    final pick = await _anchoredMenu<String>(_categoryBtnKey, [
      for (final c in _MapTabState._kCategories)
        () {
          final first = entries.where((e) => e.cat == c).map((e) => e.unlock).fold<int?>(null,
              (a, u) => a == null || u < a ? u : a) ?? 1;
          return _MenuRow(value: c, label: c, selected: c == _category, locked: first > level,
              note: first > level ? 'Unlocks at Campus $first' : null,
              leading: Icon(_MapTabState._kCategoryIcon[c], size: 22, color: c == _category ? AppColors.accent : AppColors.t70));
        }(),
    ]);
    if (pick == null || !mounted) return;
    final before = _category;
    _update(() => _category = pick);
    if (await _openResourceMenu() || !mounted) return;
    // no resource picked: back to the category of the resource in use
    _update(() => _category = entries.where((e) => e.key == _selectedMineType).firstOrNull?.cat ?? before);
  }

  /// The resources of the chosen category, highest unlock at the top (the cheapest next to the
  /// button); locked ones say at which Campus level they unlock. True when one was picked.
  Future<bool> _openResourceMenu() async {
    if (tutorialLocked.value) return false;
    final co = _co;
    final level = math.max(1, co.campusLevel);
    final list = _entries((co.catalog['raw'] as Map?)?.cast<String, dynamic>() ?? const {})
        .where((e) => e.cat == _category).toList()
      ..sort((a, b) {
        final c = b.unlock.compareTo(a.unlock);
        return c != 0 ? c : _MapTabState._entryName(co, a.key).compareTo(_MapTabState._entryName(co, b.key));
      });
    final pick = await _anchoredMenu<String>(_resourceBtnKey, [
      for (final e in list)
        _MenuRow(value: e.key, label: _MapTabState._entryName(co, e.key), selected: e.key == _selectedMineType,
            locked: e.unlock > level, note: e.unlock > level ? 'Unlocks at Campus ${e.unlock}' : null,
            leading: Center(child: HexPicture(_MapTabState._hexImage({'item': e.item, 'op': e.op}), size: 28))),
    ]);
    if (pick == null || !mounted) return false;
    _update(() {
      _selectedMineType = pick;
      _rebuildHeatmapOverlays();
    });
    _saveLastMineType(pick);
    _colorizeAndRebuild();
    return true;
  }

  /// Survey settings: the radius (up to what the Campus allows), remembered.
  Future<void> _surveySettings() async {
    final maxR = _co.surveyMaxRadius.toDouble();
    var radius = _surveyRadius.clamp(100.0, maxR);
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) => AlertDialog(
        title: const Text('Survey settings', textAlign: TextAlign.center),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          // owner 2026-10-31: who makes the surveys and why they grow with the Campus
          Text('Surveys are made by the Government. It looks at how advanced your company is and allows '
              'bigger surveys as you grow; oddly enough, what it looks at is your Campus.',
              style: TextStyle(color: AppColors.t70, fontSize: 13)),
          const SizedBox(height: 14),
          Text('Radius: ${radius.round()} m', style: const TextStyle(fontWeight: FontWeight.bold)),
          if (maxR > 100)                    // at Campus 1 the survey is 100 m: nothing to choose
            Slider(value: radius, min: 100, max: maxR, divisions: ((maxR - 100) / 100).round().clamp(1, 100),
                onChanged: (v) => set(() => radius = v)),
          Text('Survey tax: ꞓ${fmtNum(_co.surveyTax(radius))}', style: TextStyle(color: AppColors.t70)),
          const SizedBox(height: 8),
          Text('Your Campus allows up to ${maxR.round()} m: 100 m for every Campus level (5 km at Campus 50).',
              style: TextStyle(color: AppColors.t54, fontSize: 12)),
        ]),
        actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        actions: [
          Row(children: [
            Expanded(child: OutlinedButton(onPressed: () => popIfCurrent(ctx, false), child: const Text('Cancel'))),
            const SizedBox(width: 12),
            Expanded(child: FilledButton(onPressed: () => popIfCurrent(ctx, true), child: const Text('Save'))),
          ]),
        ],
      )),
    );
    if (ok != true || !mounted) return;
    _update(() => _surveyRadius = radius);
    final p = await SharedPreferences.getInstance();
    await p.setDouble('v3_survey_radius', radius);
  }
}
