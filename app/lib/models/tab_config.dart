import 'package:shared_preferences/shared_preferences.dart';

/// Every tab the game knows about.
enum GameTabId {
  map,
  mines,
  warehouse,
  factories,
  market,
  leaderboard,
  headquarters,
  specialBuildings,   // the Campus (was Special Buildings, with the HQ inside)
  luxury,
  quests,
  stats,
}

const _kPrefKey = 'bottom_bar_tabs';

/// Default tabs in the bottom bar, which scrolls ('more' is always appended): the tutorial's order, so its
/// Next goes to the neighbouring tab (owner 2026-11-02). The rest is under More.
const List<GameTabId> kDefaultBottomTabs = [
  GameTabId.map,
  GameTabId.mines,
  GameTabId.warehouse,
  GameTabId.market,
  GameTabId.specialBuildings,
  GameTabId.factories,
  GameTabId.quests,
  GameTabId.leaderboard,
  GameTabId.luxury,
];

class TabConfig {
  /// Tabs shown in the bottom bar (excluding the implicit "More" button)
  final List<GameTabId> bottomTabs;

  const TabConfig(this.bottomTabs);

  static Future<TabConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_kPrefKey);
    if (raw == null) return const TabConfig(kDefaultBottomTabs);
    final ids = <GameTabId>[];
    for (final s in raw) {
      // the HQ moved into Special Buildings; chat, contacts, social, loans, auctions,
      // archeology and news are gone (0.2.3), so those saved names are skipped
      final id = s == 'headquarters' ? GameTabId.specialBuildings
          : GameTabId.values.where((e) => e.name == s).firstOrNull;
      if (id != null && !ids.contains(id)) ids.add(id);
    }
    if (ids.isEmpty) return const TabConfig(kDefaultBottomTabs);
    return TabConfig(ids);
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kPrefKey, bottomTabs.map((e) => e.name).toList());
  }

  TabConfig withBottomTabs(List<GameTabId> tabs) => TabConfig(tabs);
}
