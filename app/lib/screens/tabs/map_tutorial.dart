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
        const TutorialStep('Keep some money back',
            'Hexes fill Central Storage around the clock. Sell from Storage or the Market, and keep enough credits to renew your leases: a hex is gone when its lease ends. Daily quests and the daily reward help you grow.'),
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
