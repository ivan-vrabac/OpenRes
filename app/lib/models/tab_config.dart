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

/// Default tabs shown in the bottom bar (must include at most 4; 'more' is always appended)
const List<GameTabId> kDefaultBottomTabs = [
  GameTabId.map,
  GameTabId.mines,
  GameTabId.specialBuildings,
  GameTabId.warehouse,
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
