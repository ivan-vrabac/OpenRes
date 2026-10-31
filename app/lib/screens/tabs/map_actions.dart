part of 'map_tab.dart';

/// What a player does on the map: survey, build a hex, place the Campus.
extension _MapActions on _MapTabState {
  Future<void> _scan() async {
    if (_scanning) return;
    final scanCenter = _mapCenter ?? _pos;
    if (scanCenter == null) return;
    final radius = _surveyRadius.clamp(100.0, _co.surveyMaxRadius.toDouble());
    _scanInFlight = true; // blocks GPS camera follow until the overlay is ready
    _update(() => _scanning = true);
    final res = await _co.call('/api/v3/survey',
        {'lat': scanCenter.latitude, 'lng': scanCenter.longitude, 'radius': radius.round()});
    if (!mounted) { _scanInFlight = false; return; }
    if (!res.ok) {
      _scanInFlight = false;
      _update(() => _scanning = false);
      _snack(res.message ?? 'Survey failed', error: true);
      return;
    }
    final old = Map<String, ui.Image>.from(_colorizedImages);
    _update(() => _colorizedImages = {});
    for (final img in old.values) img.dispose();
    try {
      await _co.refresh();
      await _loadSurvey();
      // the map may have started loading it first: the slider waits for the picture either way
      while (_surveyLoading && mounted) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    } finally {
      _scanInFlight = false;
      if (mounted) _update(() => _scanning = false);   // only now the slider goes back
    }
    if (mounted) _refreshNearbyMines(scanCenter);
  }

  Future<void> _buildMine(Map<String, dynamic> r,
      {LatLng? buildAt, LatLng? curPos}) async {
    if (_building) return;
    final target = buildAt ?? _snapBuildPos(_mapCenter ?? _pos!);
    _update(() { _building = true; });
    final res = await _co.call('/api/v3/hex/build', {
      'lat': target.latitude, 'lng': target.longitude,
      'plat': curPos?.latitude ?? _pos?.latitude, 'plng': curPos?.longitude ?? _pos?.longitude,
      'op': r['op'], 'item': r['item'],
    });
    if (!mounted) return;
    _update(() { _building = false; });
    if (!res.ok) {
      _snack(res.message ?? 'Build failed', error: true);
    } else {
      _snack('${_co.itemName(r['item'] as String)} built!');
      _world.addLocal({'lat': target.latitude, 'lng': target.longitude, 'type': 'mine', 'isMine': true,
          'op': r['op'], 'item': r['item'], 'wip': true});
      _co.refresh();
      _world.refresh();
    }
  }

  /// The Campus goes on the ghost at the crosshair, like a hex.
  Future<void> _placeCampus() async {
    final me = _pos, c = _mapCenter ?? _pos;
    if (me == null || c == null) { _snack('Waiting for your location…', error: true); return; }
    final moving = _movingCampus;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(moving ? 'Move your Campus here?' : 'Place your Campus here?'),
        actionsAlignment: MainAxisAlignment.center,
        content: Text(moving
            ? 'Your Campus moves to these 7 hexes. The move takes 24 hours. Plants pause until it is '
                'finished, hexes keep producing, and you can cancel it at any time before then. The next '
                'move is possible 30 days after this one is finished.'
            : 'Your Campus takes these 7 hexes. You can move it once a month.'),
        actions: [
          TextButton(onPressed: () => popIfCurrent(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => popIfCurrent(ctx, true), child: Text(moving ? 'Move here' : 'Place it')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final at = _snapCampus(c);
    final r = await _co.call(moving ? '/api/v3/campus/move' : '/api/v3/campus/place',
        {'lat': at.latitude, 'lng': at.longitude, 'plat': me.latitude, 'plng': me.longitude});
    if (!mounted) return;
    if (!r.ok) { _snack(r.message ?? 'Could not place it', error: true); return; }
    _snack(moving ? 'Campus move started: 24 hours' : 'Campus placed. Welcome to OpenRes!');
    _update(() => _movingCampus = false);
    await _co.refresh();
    _world.refresh();
  }
}
