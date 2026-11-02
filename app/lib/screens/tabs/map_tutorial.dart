// Part of the map tab.
part of 'map_tab.dart';

/// The tutorial's steps: what a new player needs to make money, on the real buttons of the map.
extension _MapTutorial on _MapTabState {
  List<TutorialStep> get _welcomeSteps => [
        const TutorialStep('Welcome to OpenRes',
            'The real world is your map. You run a company: find good land, lease hexes on it and sell what they make.'),
        TutorialStep('Place your Campus',
            'Your Campus is your home on the map. Move the map until the crosshair is where you want it, inside the circle around you, then slide here to place it.',
            _surveyBtnKey, null, false, true),
      ];

  List<TutorialStep> get _gameSteps => [
        TutorialStep('Pick a category', 'Start here: ores, forestry, farming, fish, energy and more.', _categoryBtnKey),
        TutorialStep('Pick a resource', 'Then choose what to produce. New resources unlock as your Campus grows.', _resourceBtnKey),
        TutorialStep('Find the best spot',
            'Slide to survey the land around the crosshair. The map fills with colours: hotter colours mean better quality for the resource you picked. Every place is different, so look around before you build.',
            _surveyBtnKey),
        TutorialStep('Build in range',
            'Put the crosshair on a hot spot inside the circle around you. This button lights up when the hex is in range.',
            _buildBtnKey),
        const TutorialStep('Is it worth it?',
            'Before you build you see the quality, the Worth / hour, the build price and the 90 day lease. '
            'Add the build price and the lease, then divide by Worth / hour: that is how many hours it takes to earn it back. '
            'A lease lasts 2,160 hours, so aim well below that, because sales tax takes a part when you sell.'),
        const TutorialStep('Hexes',
            'The Hexes tab lists everything you lease. Keep enough credits to renew: a hex is gone when its lease ends. '
            'Cancelling a lease destroys the hex and gives back 30 % of the lease that is left. New hexes are cheap at first and reach the full price at Campus 10, so build plenty early.', null, GameTabId.mines),
        const TutorialStep('Storage',
            'Hexes work around the clock and fill Central Storage. It has one total for all items, so upgrade it as you grow. '
            'When it is full, production stops. You can sell from here too.', null, GameTabId.warehouse),
        const TutorialStep('Market',
            'Sell to the best buy orders or to the system, or place your own buy orders. The seller pays 5 to 25 % sales tax, '
            'lowest on items few companies make, so a rare resource can pay better than a popular one. Buying is tax-free.', null, GameTabId.market),
        const TutorialStep('Campus',
            'Your Campus has 50 levels. Each one costs credits and materials from Storage, and unlocks new resources and plants. '
            'Visit it once a week, standing within 200 m: every missed week lowers your output by 10 %, down to 30 %.', null, GameTabId.specialBuildings),
        const TutorialStep('Supervisors',
            'Every Campus level gives 10 supervisors. Appoint one on a hex to make it produce more, and educate them with books and credits to raise it further. Put the best ones on your best hexes.', null, GameTabId.specialBuildings),
        const TutorialStep('Production',
            'Plants sit inside your Campus and turn raw materials into goods worth more, like wood into lumber into furniture. '
            'They need their inputs and electricity in Storage, so make power with solar farms, wind farms or a power plant.', null, GameTabId.factories),
        const TutorialStep('Quests',
            'You get 3 quests a day. Finish all of them every day for a streak, with bonuses every 7 and 30 days. One missed day is forgiven, two end it. '
            'The daily reward works the same way.', null, GameTabId.quests),
        const TutorialStep('Leaderboards',
            'Compete on company value, Campus, hexes, output, countries and Tantalum. Value and Campus count how active you are, so a company that stops playing slides down.', null, GameTabId.leaderboard),
        const TutorialStep('Tantalum-180m',
            'The endgame, from Campus level 40: an Isotope lab turns tantalum and supercomputers into Tantalum-180m. It cannot be sold. '
            'Put it into dark matter research: every level adds 1 % output to everything.', null, GameTabId.luxury),
        const TutorialStep('More',
            'The More tab holds every other page, plus Settings. In Settings you can pin your favourite tabs to the bottom bar, and see this tutorial again.', null, null, true),
      ];

  void _onTutorialStart() {
    if (mounted) StorageService.saveTutorial(0).then((_) => _maybeTutorial());
  }

  Future<void> _maybeTutorial() async {
    if (!mounted || tutorialRun.value != null) return;
    if (_co.state.isEmpty) {                   // not known yet whether there is a Campus
      Future.delayed(const Duration(milliseconds: 200), _maybeTutorial);
      return;
    }
    final seen = await StorageService.getTutorial();
    if (!mounted || tutorialRun.value != null) return;
    // no Campus: always, from the start, and it can't be left before the Campus is down (owner 2026-11-02).
    // With one (Settings, or the app closed halfway) just the game part, which can be skipped.
    final steps = !_co.hasCampus ? [..._welcomeSteps, ..._gameSteps] : (seen < 2 ? _gameSteps : null);
    if (steps != null) tutorialRun.value = TutorialRun(steps, _tutorialDone, changes: _co, passed: () => _co.hasCampus);
  }

  void _tutorialDone() {
    StorageService.saveTutorial(2);
    tutorialRun.value = null;
  }
}
