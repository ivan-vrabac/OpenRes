// Part of the map tab.
part of 'map_tab.dart';

/// The tutorial's steps: what a new player needs to make money, on the real buttons of the map.
extension _MapTutorial on _MapTabState {
  List<TutorialStep> get _welcomeSteps => [
        const TutorialStep('Welcome to OpenRes',
            'The real world is your map. You run a company: find good land, lease hexes on it and sell what they make.'),
        TutorialStep('Place your Campus',
            'Your Campus is your home on the map. Move the map until the crosshair is where you want it, inside the Build range circle around you, then slide here.',
            _surveyBtnKey),
      ];

  List<TutorialStep> get _gameSteps => [
        TutorialStep('Pick a category', 'Start here: ores, forestry, farming, fish, energy and more.', _categoryBtnKey),
        TutorialStep('Pick a resource', 'Then choose what to produce. New resources unlock as your Campus grows.', _resourceBtnKey),
        TutorialStep('Find the best spot',
            'Slide to survey the land around the crosshair. The map fills with colours: hotter colours mean better quality for the resource you picked. Every place is different, so look around before you build.',
            _surveyBtnKey),
        TutorialStep('Build in range',
            'Put the crosshair on a hot spot inside the Build range circle. This button lights up when the hex is in range.',
            _buildBtnKey),
        const TutorialStep('Is it worth it?',
            'Before you build you see the quality, the Worth / hour, the build price and the 90 day lease. '
            'Add the build price and the lease, then divide by Worth / hour: that is how many hours it takes to earn it back. '
            'A lease lasts 2,160 hours, so aim well below that, because sales tax takes a part when you sell.'),
        const TutorialStep('Hexes',
            'The Hexes tab lists everything you lease. Keep enough credits to renew: a hex is gone when its lease ends. '
            'Cancelling a lease destroys the hex and gives back 30 % of the lease that is left.'),
        const TutorialStep('Storage',
            'Hexes work around the clock and fill Central Storage. It has one total for all items, so upgrade it as you grow. '
            'When it is full, production stops. You can sell from here too.'),
        const TutorialStep('Market',
            'Sell to the best buy orders or to the system, or place your own buy orders. The seller pays 5 to 25 % sales tax, '
            'lowest on items few companies make, so a rare resource can pay better than a popular one. Buying is tax-free.'),
        const TutorialStep('Campus',
            'Your Campus has 50 levels. Each one costs credits and materials from Storage, and unlocks new resources and plants. '
            'Visit it once a week, standing within 200 m: every missed week lowers your output by 10 %, down to 30 %.'),
        const TutorialStep('Supervisors',
            'Every Campus level gives 10 supervisors. Appoint one on a hex to make it produce more, and educate them with books and credits to raise it further. Put the best ones on your best hexes.'),
        const TutorialStep('Production',
            'Plants sit inside your Campus and turn raw materials into goods worth more, like wood into lumber into furniture. '
            'They need their inputs and electricity in Storage, so make power with solar farms, wind farms or a power plant.'),
        const TutorialStep('Quests',
            'You get 3 quests a day. Finish all of them every day for a streak, with bonuses every 7 and 30 days. One missed day is forgiven, two end it. '
            'The daily reward works the same way.'),
        const TutorialStep('Leaderboards',
            'Open them from your profile card in More. Compete on company value, Campus, hexes, output, countries and Tantalum. Value and Campus count how active you are, so a company that stops playing slides down.'),
        const TutorialStep('Tantalum-180m',
            'The endgame, from Campus level 40: an Isotope lab turns tantalum and supercomputers into Tantalum-180m. It cannot be sold. '
            'Put it into dark matter research: every level adds 1 % output to everything.'),
        const TutorialStep('More',
            'The More tab holds every other page, plus Settings. In Settings you can pin your favourite tabs to the bottom bar, and see this tutorial again.'),
      ];

  void _onTutorialAsked() {
    if (!tutorialAsked.value || !mounted) return;
    tutorialAsked.value = false;
    StorageService.saveTutorial(0).then((_) => _maybeTutorial());
  }

  Future<void> _maybeTutorial() async {
    if (!mounted || _tutorial != null) return;
    final seen = await StorageService.getTutorial();
    if (!mounted) return;
    final steps = !_co.hasCampus ? (seen < 1 ? _welcomeSteps : null) : (seen < 2 ? _gameSteps : null);
    if (steps != null) _update(() => _tutorial = steps);
  }

  void _tutorialDone() {
    StorageService.saveTutorial(_co.hasCampus ? 2 : 1);
    _update(() => _tutorial = null);
  }
}
