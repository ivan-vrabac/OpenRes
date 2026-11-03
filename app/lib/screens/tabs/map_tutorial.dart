// Part of the map tab.
part of 'map_tab.dart';

/// Credits when the Storage card showed: selling makes them grow, which ends that card.
double _sellBase = 0;

/// The tutorial (owner 2026-11-03). Guided, the first time: the player does each task for real (survey,
/// build, appoint, sell, buy books, train), with sugar beet as the resource, and can't skip or go back.
/// From Settings the same cards only explain, and can be skipped.
extension _MapTutorial on _MapTabState {
  List<Hex> get _myHexes => (context.read<PlayerProvider>().mines ?? const <Hex>[]).where((m) => m.op != 'campus').toList();

  void _loadHexes() => context.read<PlayerProvider>().loadMines();

  List<TutorialStep> _tutorialSteps({required bool guided, required bool welcome}) => [
        if (welcome) ...[
          const TutorialStep('Welcome to OpenRes',
              'The real world is your map. You run a company: find good land, lease hexes on it and sell what they make.\n\n'
              'You can see this tutorial again any time in More › Settings › Game › Tutorial.'),
          TutorialStep('Place your Campus',
              'Your Campus is your home on the map. Move the map until the crosshair is where you want it, inside the circle around you, then slide here to place it.',
              target: _surveyBtnKey, area: _bottomPanelKey, done: () => _co.hasCampus),
        ],
        TutorialStep('Sugar beet',
            'This is what your hexes produce. For a start it is sugar beet: it grows well almost everywhere and every company can use it. '
            'Later you pick other resources here, and other categories right next to it.',
            target: _resourceBtnKey),
        TutorialStep('Find the best spot',
            'Slide to survey the land around the crosshair. The map fills with colours: hotter colours mean better sugar beet. '
            'Drag the map to look around.',
            target: _surveyBtnKey, area: _bottomPanelKey, done: () => _survey != null),
        TutorialStep('The map buttons',
            'Along the top: the satellite hides or shows the survey colours, and the hexagon hides or shows hexes and Campuses. '
            'On the right: back to your location, zoom in and zoom out. Two fingers zoom too.',
            target: _topBarKey),
        TutorialStep('Build your first hex',
            'Drag the map until the crosshair is on a hot spot inside the circle around you. This button lights up when the hex is in range: tap it.',
            target: _buildBtnKey, area: _bottomPanelKey, done: () => _myHexes.isNotEmpty, poll: _loadHexes),
        if (!guided)
          const TutorialStep('Is it worth it?',
              'Before you build you see the quality, the Worth / hour, the build price and the 90 day lease. $_worthText'),
        TutorialStep('Hexes',
            'Everything you lease is here. A lease lasts 90 days: renew it in time, or the hex is gone. New hexes are cheap at first and '
            'reach the full price at Campus 10, so build plenty early.\n\n'
            'A supervisor runs a hex better, so it makes more: +25 % even untrained, up to +200 % with a Master\'s. '
            'Tap your sugar beet to appoint one.',
            target: tutorialHexesKey, tab: GameTabId.mines,
            done: () => _myHexes.any((m) => m.edu != null), poll: _loadHexes),
        TutorialStep('Storage',
            'Your hexes fill Central Storage around the clock. Tap your sugar beet and sell some. '
            'Storage has one total for all items and production stops when it is full, so upgrade it as you grow.',
            target: tutorialStorageKey, tab: GameTabId.warehouse,
            enter: () => _sellBase = _co.credits.toDouble(), done: () => _co.credits > _sellBase, poll: _co.refresh),
        TutorialStep('Market',
            'Here you buy what you need and sell what you make. Buying is tax-free; sellers pay 5 to 25 % sales tax, '
            'lowest on items few companies make. You can also place buy orders and let other companies sell to you.\n\n'
            'Supervisors learn from books. Tap Books to buy some.',
            target: tutorialBooksKey, tab: GameTabId.market,
            done: () => ((_co.stock['books'] as num?) ?? 0) >= 10, poll: _co.refresh),
        const TutorialStep('Campus',
            'Your Campus has 50 levels. Each one costs credits and materials from Storage, and unlocks new resources and plants. '
            'Visit it once a week, standing within 200 m: every missed week lowers your output by 10 %, down to 30 %.', tab: GameTabId.specialBuildings),
        TutorialStep('Train a supervisor',
            'Every Campus level gives 10 supervisors. Send one to a Course with your books: tap Train. Higher steps give a bigger boost. '
            'A supervisor in training keeps working on its hex at its old level, and gets the new boost when it finishes. '
            'Appoint always sends the best free one, so recall and appoint again to put a newly trained one on a hex.',
            target: campusTrainKey, tab: GameTabId.specialBuildings, done: () => campusEducated.value > 0),
        TutorialStep('The education queue',
            'One supervisor trains in the training slot, the others wait in the queue; more queue places come with Campus levels. '
            'Drag the waiting ones to change their order, and cancel one to get everything back. Tap here to see yours.',
            target: campusQueueKey, tab: GameTabId.specialBuildings, enter: () => campusQueueSeen.value = false,
            done: () => campusQueueSeen.value),
        const TutorialStep('Production',
            'Plants sit inside your Campus and turn raw materials into goods worth more, like wood into lumber into furniture. '
            'They need their inputs and electricity in Storage, so make power with solar farms, wind farms or a power plant.', tab: GameTabId.factories),
        const TutorialStep('Quests',
            'You get 3 quests a day. Finish all of them every day for a streak, with bonuses every 7 and 30 days. One missed day is forgiven, two end it. '
            'The daily reward works the same way.', tab: GameTabId.quests),
        const TutorialStep('Leaderboards',
            'Compete on company value, Campus, hexes, output, countries and Tantalum. Value and Campus count how active you are, so a company that stops playing slides down.', tab: GameTabId.leaderboard),
        const TutorialStep('Tantalum-180m',
            'The endgame, from Campus level 40: an Isotope lab turns tantalum and supercomputers into Tantalum-180m. It cannot be sold. '
            'Put it into dark matter research: every level adds 1 % output to everything.', tab: GameTabId.luxury),
        const TutorialStep('More',
            'The More tab holds every other page, plus Settings. In Settings you can pin your favourite tabs to the bottom bar. '
            'You can see this tutorial again any time: More › Settings › Game › Tutorial.', more: true),
      ];

  /// Settings › Tutorial: the cards only, to read; they can be skipped.
  void _onTutorialStart() {
    if (!mounted || tutorialRun.value != null || !_co.hasCampus) return;
    tutorialRun.value = TutorialRun(_tutorialSteps(guided: false, welcome: false), () => tutorialRun.value = null);
  }

  Future<void> _maybeTutorial() async {
    if (!mounted || tutorialRun.value != null) return;
    if (_co.state.isEmpty) {                   // not known yet whether there is a Campus
      Future.delayed(const Duration(milliseconds: 200), _maybeTutorial);
      return;
    }
    final seen = await StorageService.getTutorial();
    final at = await StorageService.getTutorialAt();
    if (!mounted || tutorialRun.value != null) return;
    // no Campus: guided from the start. Closed halfway (a checkpoint saved): guided again, from that card
    // (owner 2026-11-03). A Campus but never seen (an older install): the cards to read, once.
    final guided = !_co.hasCampus || (at != null && seen < 2);
    if (!guided && seen >= 2) return;
    final steps = _tutorialSteps(guided: guided, welcome: !_co.hasCampus);
    if (guided) {
      _update(() {                             // the tutorial's resource
        _category = 'Agriculture';
        _selectedMineType = 'sugar_beet';
        _rebuildHeatmapOverlays();
      });
    }
    // no Campus (a new or reset company): from the first card, whatever was saved before
    final start = guided && at != null && _co.hasCampus ? steps.indexWhere((s) => s.title == at) : -1;
    tutorialRun.value = TutorialRun(steps, _tutorialDone, guided: guided, changes: _co, start: start < 0 ? 0 : start,
        onShow: guided ? (s) => StorageService.saveTutorialAt(s.title) : null);
  }

  void _tutorialDone() {
    StorageService.saveTutorial(2);
    StorageService.saveTutorialAt(null);
    tutorialRun.value = null;
  }
}

/// Is it worth it? In the build sheet while the tutorial waits for the first hex, and on its card from Settings.
const _worthText = 'Add the build price and the lease, then divide by Worth / hour: that is how many hours it takes to earn it back. '
    'A lease lasts 2,160 hours, so aim well below that, because sales tax takes a part when you sell.';
