import '../services/play_update.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/tab_config.dart';
import '../models/player_provider.dart';
import '../services/game_api.dart';
import '../services/chat_bridge.dart';
import '../services/location_service.dart';
import '../services/notification_service.dart';
import 'credits_screen.dart';
import 'legal_screen.dart';
import '../services/storage_service.dart';
import '../widgets/async_view.dart' show TaIcon;
import '../services/integrity.dart';
import '../widgets/cards.dart';
import '../widgets/glass.dart';
import '../widgets/player_hud.dart';
import '../widgets/tutorial.dart';
import 'tabs/map_tab.dart';
import 'tabs/hexes_tab.dart';
import 'tabs/warehouse_tab.dart';
import 'factory_screen.dart';
import 'market_screen.dart';
import 'achievements_screen.dart';
import 'leaderboard_screen.dart';
import '../widgets/picture_cache.dart';
import 'campus_screen.dart';
import 'luxury_screen.dart';
import 'profile_screen.dart';
import 'quests_screen.dart';
import 'placeholder_screen.dart';
import 'settings_screen.dart';
import 'log_screen.dart';
import 'login_screen.dart';

import '../app_colors.dart';
import '../services/screen_mode.dart';
import '../services/play_games.dart';
import '../v3/company.dart';
import '../v3/streak.dart';
class _TabMeta {
  final String label;
  final IconData icon;
  final Widget Function() build;
  // true for tabs that are raw content widgets (no Scaffold of their own)
  // — they need one when pushed standalone from the More menu.
  final bool needsScaffold;
  /// A drawn icon instead of [icon] (the Tantalum-180m mark).
  final Widget Function(Color? color, double size)? draw;
  const _TabMeta({required this.label, required this.icon, required this.build, this.needsScaffold = false,
      this.draw});

  Widget iconWidget({Color? color, double size = 24}) =>
      draw != null ? draw!(color, size) : Icon(icon, color: color, size: size);
}

final Map<GameTabId, _TabMeta> tabMeta = {
  GameTabId.map: _TabMeta(label: 'Map', icon: Icons.map_outlined,
      build: () => const MapTab(), needsScaffold: true),
  GameTabId.mines: _TabMeta(label: 'Hexes', icon: Icons.hexagon_outlined,
      build: () => const HexesTab(), needsScaffold: true),
  GameTabId.warehouse: _TabMeta(label: 'Storage', icon: Icons.inventory_2_outlined,
      build: () => const WarehouseTab(), needsScaffold: true),
  GameTabId.factories: _TabMeta(label: 'Production', icon: Icons.factory_outlined,
      build: () => const FactoryScreen()),
  GameTabId.market: _TabMeta(label: 'Market', icon: Icons.storefront_outlined,
      build: () => const MarketScreen(), needsScaffold: true),
  GameTabId.leaderboard: _TabMeta(label: 'Leaderboard', icon: Icons.leaderboard_outlined,
      build: () => const LeaderboardScreen(embedded: true)),
  GameTabId.specialBuildings: _TabMeta(label: 'Campus', icon: Icons.location_city_outlined,
      build: () => const CampusScreen()),
  GameTabId.luxury: _TabMeta(label: 'Tantalum', icon: Icons.science_outlined,
      draw: (c, s) => TaIcon(color: c, size: s),
      build: () => const LuxuryScreen()),
  GameTabId.quests: _TabMeta(label: 'Rewards', icon: Icons.redeem,
      build: () => const QuestsScreen(), needsScaffold: true),
  GameTabId.stats: _TabMeta(label: 'Company', icon: Icons.bar_chart_outlined,       // owner 2026-11-03: one name
      build: () => const ProfileScreen(embedded: true), needsScaffold: true),
};

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});
  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> with WidgetsBindingObserver {

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ScreenMode.apply();                       // Android shows the bars again after leaving the app
    }
  }

  TabConfig _config = const TabConfig(kDefaultBottomTabs);
  bool _configLoaded = false;
  /// The company in the redesigned game (state + catalog), shared by every tab.
  late final Company _company = Company(context.read<PlayerProvider>().sid,
      onCredits: context.read<PlayerProvider>().setCredits)..start();
  late PageController _pageCtrl;
  final _tabBar = ScrollController();     // the bottom tabs, when they don't all fit
  double _tabW = 68;                     // one tab's width in the bar (set when it is laid out)
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ScreenMode.apply();
    _pageCtrl = PageController(initialPage: 1);
    tutorialAsked.addListener(_onTutorialAsked);
    mapFocus.addListener(_toMap);
    campusMoveAsked.addListener(_toMap);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Company.active.value = _company;
      _company.addListener(_syncLock);
      _syncLock();
    });
    TabConfig.load().then((cfg) {
      if (mounted) setState(() { _config = cfg; _configLoaded = true; });
      if (mounted) _syncGps();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final prov = context.read<PlayerProvider>();
      // Android 13+ asks once; without it no notification can show
      NotificationService.requestPermission().whenComplete(() => ChatBridge.configure(prov.sid));
      Legal.report(prov.sid);                     // the server keeps who accepted which terms
      // the leaderboard flags and the game's pictures, decoded in the background: they never pop in
      Future.delayed(const Duration(seconds: 2), () async {
        if (mounted) await warmGamePictures(context);
        if (mounted) await warmFlags(context);
      });
      ChatBridge.reportDevice(prov.sid);          // multi-account detection (hashed device ID)
      IntegrityCheck.start(prov.sid);             // real app on a real device?
      PlayGames.start(prov.sid);                  // achievements recorded, and on to Play Games
      // offer a newer published build (once per build; Settings > Updates anytime)
      Future.delayed(const Duration(seconds: 3), () { if (mounted) PlayUpdate.checkOnStart(context); });
      Future.delayed(const Duration(seconds: 2), _offerStreak);
    });
  }

  /// A place to see on the map (the activity log): back to the game and the map tab.
  void _toMap() {
    if ((mapFocus.value == null && !campusMoveAsked.value) || !mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    final idx = _config.bottomTabs.indexOf(GameTabId.map);
    if (idx >= 0) _goToTab(idx);
  }

  @override
  void dispose() {
    final co = _company;
    co.removeListener(_syncLock);
    WidgetsBinding.instance.addPostFrameCallback((_) => tutorialLocked.value = true);    // the next login starts unknown
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (Company.active.value == co) Company.active.value = null;
    });
    PlayGames.stop();
    IntegrityCheck.stop();
    tutorialAsked.removeListener(_onTutorialAsked);
    WidgetsBinding.instance.addPostFrameCallback((_) => tutorialRun.value = null);
    mapFocus.removeListener(_toMap);
    campusMoveAsked.removeListener(_toMap);
    WidgetsBinding.instance.removeObserver(this);
    ScreenMode.apply();
    _pageCtrl.dispose();
    _tabBar.dispose();
    super.dispose();
  }


  int get _totalTabs => _config.bottomTabs.length + 1; // +1 for More

  List<GameTabId> get _overflowIds => GameTabId.values
      .where((t) => tabMeta.containsKey(t) && !_config.bottomTabs.contains(t))
      .toList();

  Widget _tabBody(int i) {
    final isMore = i == _totalTabs - 1;
    final id = isMore ? null : _config.bottomTabs[i];
    final body = isMore
        ? _MoreTab(overflowIds: _overflowIds, onOpenSettings: _openSettings)
        : tabMeta[id]?.build() ?? PlaceholderScreen(title: id!.name, icon: Icons.help_outline, subtitle: '');
    // room for the floating top bar: the map runs under it (its own panels move down), other pages
    // start below it. The same widgets in every style, so switching keeps the pages' state.
    // With the map behind the status bar (or under a see-through tab bar) the padding arrives here as
    // MediaQuery padding: the map keeps it (its panels move inside), the other pages turn it into space.
    return AnimatedBuilder(
      animation: UiLook.all,
      child: body,
      builder: (context, child) {
        final inset = UiLook.showHud.value ? UiLook.hudInset : 0.0;
        // the map and the one-list pages run under the bars (the lists add the room: tabPadding);
        // pages with a fixed header (Hexes, Market) start below them
        final under = isMore || id == GameTabId.map || _kScrollUnder.contains(id);
        final mq = MediaQuery.of(context);
        final top = mq.padding.top + inset;
        final page = Padding(
          padding: EdgeInsets.only(top: under ? 0 : top, bottom: under ? 0 : mq.padding.bottom),
          child: MediaQuery(
            data: mq.copyWith(padding: under
                ? mq.padding.copyWith(top: top)
                : mq.padding.copyWith(top: 0, bottom: 0)),
            child: child!,
          ),
        );
        return id == GameTabId.map ? page : ColoredBox(color: Theme.of(context).scaffoldBackgroundColor, child: page);
      },
    );
  }

  /// Tabs whose content is one list: it scrolls up behind the status bar and the top bar.
  static const _kScrollUnder = {
    GameTabId.mines, GameTabId.market, GameTabId.warehouse, GameTabId.factories, GameTabId.specialBuildings, GameTabId.luxury,
    GameTabId.quests, GameTabId.stats,
  };

  // Keep state alive so tab icons/data don't reload on every switch.
  // Warehouse and Mines are now included — their data is stable enough between switches.
  static const _kKeepAlive = {
    GameTabId.map,
    GameTabId.factories,
    GameTabId.warehouse,
    GameTabId.mines,
  };

  Widget _wrapPage(int i) {
    final w = _tabBody(i);
    final isMore = i == _totalTabs - 1;
    if (isMore) {
      return _KeepAliveTab(key: const ValueKey('__more__'), child: w);
    }
    final id = _config.bottomTabs[i];
    if (_kKeepAlive.contains(id)) {
      return _KeepAliveTab(key: ValueKey(id), child: w);
    }
    return w;
  }

  // Page layout: [lastDup(0), tab0(1)..tabN(N), firstDup(N+1)]
  // Real pages 1..N correspond to _currentIndex 0..N-1
  List<Widget> _buildPages() {
    final n = _totalTabs;
    return [
      _tabBody(n - 1), // sentinel: last tab duplicate
      for (int i = 0; i < n; i++) _wrapPage(i),
      _tabBody(0), // sentinel: first tab duplicate
    ];
  }

  /// GPS only while the Map tab is open (owner 2026-10-31); screens that need a position ask for it.
  void _syncGps() {
    final onMap = _currentIndex < _config.bottomTabs.length && _config.bottomTabs[_currentIndex] == GameTabId.map;
    LocationService.instance.setAway(!onMap);
  }

  void _onPageChanged(int page) {
    final n = _totalTabs;
    if (page == 0) {
      // Swiped right past first — jump to real last tab
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pageCtrl.hasClients) _pageCtrl.jumpToPage(n);
      });
      setState(() => _currentIndex = n - 1);
    } else if (page == n + 1) {
      // Swiped left past last — jump to real first tab
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pageCtrl.hasClients) _pageCtrl.jumpToPage(1);
      });
      setState(() => _currentIndex = 0);
    } else {
      setState(() => _currentIndex = page - 1);
    }
    _syncGps();
  }

  void _syncLock() => tutorialLocked.value = _company.error == null && !_company.hasCampus;

  /// The login streak: today's reward, once a day, never over the tutorial (it comes when that ends).
  void _offerStreak([int tries = 0]) {
    if (!mounted) return;
    if (_company.state.isEmpty && _company.error == null && tries < 20) {
      Future.delayed(const Duration(milliseconds: 500), () => _offerStreak(tries + 1));
      return;
    }
    if (!tutorialLocked.value && tutorialRun.value == null) offerLoginStreak(context, _company);
  }

  /// The tab a tutorial card talks about; one that isn't on the bar is under More.
  void _tutorialTab(TutorialStep step) {
    if (step.more) {
      _goToTab(_totalTabs - 1);
    } else {
      _toTab(step.tab ?? GameTabId.map);
    }
  }

  void _toTab(GameTabId id) {
    final i = _config.bottomTabs.indexOf(id);
    _goToTab(i >= 0 ? i : _totalTabs - 1);
  }

  /// Settings › Tutorial: back on the map, whatever was open, and it starts there.
  void _onTutorialAsked() {
    if (!tutorialAsked.value || !mounted) return;
    tutorialAsked.value = false;
    Navigator.of(context).popUntil((r) => r.isFirst);
    _toTab(GameTabId.map);
    tutorialStart.value++;
  }

  void _goToTab(int index) {
    if (index == _currentIndex) return;
    // straight to the tab (owner 2026-11-07: the slide from a neighbouring tab showed a page on the way,
    // Market to Map went past Hexes); swiping between tabs still slides
    if (_pageCtrl.hasClients) _pageCtrl.jumpToPage(index + 1);
    setState(() => _currentIndex = index);
    _syncGps();
    // the bar stays where the player left it (owner 2026-11-07: no centring); only a tab out of
    // sight (the tutorial, More after it) is scrolled just into view
    if (_tabBar.hasClients) {
      final pos = _tabBar.position;
      final left = index * _tabW, right = left + _tabW;
      double? to;
      if (left < pos.pixels) {
        to = left;
      } else if (right > pos.pixels + pos.viewportDimension) {
        to = right - pos.viewportDimension;
      }
      if (to != null) {
        _tabBar.animateTo(to.clamp(0.0, pos.maxScrollExtent),
            duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
      }
    }
  }

  void _onConfigSaved(TabConfig cfg) {
    setState(() { _config = cfg; _currentIndex = 0; });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pageCtrl.hasClients) _pageCtrl.jumpToPage(1);
    });
  }

  /// The top bar opens the Stats tab: switch to it if it's in the bottom bar, otherwise open it
  /// the same way the More tab does.
  void _openStats() {
    final idx = _config.bottomTabs.indexOf(GameTabId.stats);
    if (idx >= 0) {
      _goToTab(idx);
      return;
    }
    final meta = tabMeta[GameTabId.stats]!;
    Navigator.push(context, MaterialPageRoute(builder: (_) => Scaffold(
      appBar: AppBar(title: Text(meta.label), toolbarHeight: 44),
      body: meta.build(),
    )));
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsScreen(config: _config, onSave: _onConfigSaved),
      ),
    );
  }

  @override
  Widget build(BuildContext context) =>
      ChangeNotifierProvider<Company>.value(value: _company, child: _buildGame(context));

  Widget _buildGame(BuildContext context) {
    if (!_configLoaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final cs   = Theme.of(context).colorScheme;

    return AnimatedBuilder(
      animation: Listenable.merge([UiLook.all, ScreenMode.changed]),
      builder: (context, _) => Stack(children: [
        Positioned.fill(child: _scaffold(context, cs)),
        // over everything, tab bar too: while it runs only its cards change the tab
        ValueListenableBuilder<TutorialRun?>(valueListenable: tutorialRun, builder: (_, run, __) => run == null
            ? const SizedBox.shrink()
            : TutorialOverlay(key: ObjectKey(run), steps: run.steps, onStep: _tutorialTab, changes: run.changes,
                guided: run.guided, start: run.start, onShow: run.onShow, onDone: () {
                _toTab(GameTabId.map);
                run.onDone();
                _offerStreak();
              })),
      ]),
    );
  }

  Widget _scaffold(BuildContext context, ColorScheme cs) {
    final hud = UiLook.showHud.value;
    final under = UiLook.underStatusBar.value;
    // see-through on every tab: the other pages bring their own background under it, so the colour
    // slides in with the page instead of switching at once (owner 2026-10-31)
    final clear = UiLook.clearTabs.value;
    final statusTop = MediaQuery.of(context).padding.top;      // 0 when the status bar is hidden
    return Scaffold(
      // a see-through tab bar lets the map run under it (the pages make room themselves, _tabBody)
      extendBody: UiLook.clearTabs.value,
      body: SafeArea(
        bottom: false,
        top: !under,                    // the map behind the status bar; the pages keep below it (_tabBody)
        // the top bar floats over the pages (they make room for it, _tabBody)
        child: Column(children: [
          Expanded(
            key: const ValueKey('pages'),
            child: Stack(children: [
              PageView(
                controller: _pageCtrl,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: _onPageChanged,
                children: _buildPages(),
              ),
              if (hud)
                Positioned(top: under ? statusTop : 0, left: 0, right: 0, child: ValueListenableBuilder<bool>(
                  valueListenable: tutorialLocked,
                  builder: (_, locked, hud) => ValueListenableBuilder<GlobalKey?>(valueListenable: tutorialFocus,
                      builder: (_, focus, __) => IgnorePointer(ignoring: locked || focus != null, child: hud)),
                  child: ValueListenableBuilder<bool>(valueListenable: UiLook.hudOpensCompany,
                      builder: (_, opens, __) => PlayerHud(onTap: opens ? _openStats : null)))),
            ]),
          ),
        ]),
      ),
      bottomNavigationBar: Material(
        color: clear ? Colors.transparent : cs.surface,
        elevation: clear ? 0 : 3,
        child: SafeArea(
          child: Padding(
            // full screen: Android's swipe-up gesture starts at the very edge; keep the tabs off it
            // (owner 2026-10-31: switched apps by accident)
            padding: EdgeInsets.only(bottom: ScreenMode.hideNav ? 14 : 0),
            child: SizedBox(
            height: 60,
            child: LayoutBuilder(builder: (context, constraints) {
              const double minTabW = 68;
              final n = _totalTabs;
              final natural = constraints.maxWidth / n;
              final tabW = natural < minTabW ? minTabW : natural;
              final scrollable = tabW * n > constraints.maxWidth;
              _tabW = tabW;

              Widget buildTab(int i) {
                final isMore     = i == n - 1;
                final isSelected = i == _currentIndex;
                final id         = isMore ? null : _config.bottomTabs[i];
                final meta       = isMore ? null : tabMeta[id]!;
                final label      = isMore ? 'More' : tabMeta[id]!.label;

                final iconColor = isSelected ? cs.primary : cs.onSurfaceVariant;
                Widget iconWidget = meta == null ? Icon(Icons.menu, size: 22, color: iconColor)
                    : meta.iconWidget(color: iconColor, size: 22);

                return SizedBox(
                  width: tabW,
                  child: InkWell(
                    // a tutorial task (a card waiting for one tap) keeps the player on its tab (owner 2026-11-06)
                    onTap: () { if (!tutorialLocked.value && tutorialFocus.value == null) _goToTab(i); },
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        iconWidget,
                        const SizedBox(height: 2),
                        Text(label,
                            style: TextStyle(
                                fontSize: 10,
                                color: isSelected ? cs.primary : cs.onSurfaceVariant),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1),
                      ],
                    ),
                  ),
                );
              }

              final tabs = List.generate(n, buildTab);
              if (scrollable) {
                return SingleChildScrollView(
                  controller: _tabBar,
                  scrollDirection: Axis.horizontal,
                  child: Row(children: tabs),
                );
              }
              return Row(children: tabs);
            }),
          ),
          ),
        ),
      ),
    );
  }
}

class _KeepAliveTab extends StatefulWidget {
  final Widget child;
  const _KeepAliveTab({super.key, required this.child});
  @override
  State<_KeepAliveTab> createState() => _KeepAliveTabState();
}

class _KeepAliveTabState extends State<_KeepAliveTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class _MoreTab extends StatefulWidget {
  final List<GameTabId> overflowIds;
  final VoidCallback onOpenSettings;
  const _MoreTab({required this.overflowIds, required this.onOpenSettings});
  @override
  State<_MoreTab> createState() => _MoreTabState();
}

class _MoreTabState extends State<_MoreTab> {
  int? _rank;

  @override
  void initState() {
    super.initState();
    _loadRank();
  }

  Future<void> _loadRank() async {
    final sid = context.read<PlayerProvider>().sid;
    if (sid.isEmpty) return;
    // the overall leaderboard (company value x activity); the server says where you are
    final r = await GameApi.call('/api/v1/rank/players', sid);
    if (!mounted || !r.ok) return;
    setState(() => _rank = (r.data['myRank'] as num?)?.toInt());
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>().player;

    void open(Widget page) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    final campus = context.watch<Company>().campusLevel;

    return ListView(
      padding: tabPadding(context, 12),
      children: [
        if (player != null) ...[
          Panel(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              if (player.country.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.asset(
                    'assets/images_countryflags/${player.country}.png',
                    width: 60, height: 40, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _fallbackAvatar(player),
                  ),
                )
              else
                _fallbackAvatar(player),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(player.name, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text([if (_rank != null) 'Rank #$_rank', if (campus > 0) 'Campus $campus'].join(' · '),
                    style: TextStyle(color: AppColors.t60, fontSize: 12)),
              ])),
            ]),
            const SizedBox(height: 12),
            SizedBox(width: double.infinity, child: OutlinedButton.icon(
              icon: const Icon(Icons.star_outline, size: 16),
              label: const Text('Achievements'),
              onPressed: () => open(const AchievementsScreen()),
            )),
          ])),
          const SizedBox(height: 16),
        ],

        if (widget.overflowIds.isNotEmpty) ...[
          const SectionLabel('Game'),
          RowGroup([
            for (final id in widget.overflowIds)
              NavRow(
                icon: tabMeta[id]!.iconWidget(color: AppColors.accent),
                title: tabMeta[id]!.label,
                onTap: () {
                  final meta = tabMeta[id]!;
                  final content = meta.build();
                  open(meta.needsScaffold
                      ? Scaffold(appBar: AppBar(title: Text(meta.label), toolbarHeight: 44), body: content)
                      : content);
                },
              ),
          ]),
          const SizedBox(height: 16),
        ],

        const SectionLabel('System'),
        RowGroup([
          NavRow(icon: Icon(Icons.settings, color: AppColors.accent), title: 'Settings', onTap: widget.onOpenSettings),
        ]),
        const SizedBox(height: 16),
        const SectionLabel('Account'),
        RowGroup([
          NavRow(
            icon: const Icon(Icons.logout, color: Colors.redAccent),
            title: 'Log out',
            titleColor: Colors.redAccent,
            arrow: false,
            onTap: () async {
              await StorageService.clearHid();
              if (!context.mounted) return;
              context.read<PlayerProvider>().clear();
              Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreen()));
            },
          ),
          // owner 2026-10-25: credits and the legal texts right under Log out
          NavRow(icon: Icon(Icons.photo_library_outlined, color: AppColors.t54), title: 'Image credits',
              onTap: () => open(const CreditsScreen())),
          NavRow(icon: Icon(Icons.gavel_outlined, color: AppColors.t54), title: 'Terms of use',
              onTap: () => Legal.show(context, privacy: false)),
          NavRow(icon: Icon(Icons.privacy_tip_outlined, color: AppColors.t54), title: 'Privacy policy',
              onTap: () => Legal.show(context, privacy: true)),
          NavRow(icon: Icon(Icons.history, color: AppColors.t54), title: 'Activity log',
              onTap: () => open(const LogScreen())),
        ]),
      ],
    );
  }

  Widget _fallbackAvatar(dynamic player) => CircleAvatar(
    backgroundColor: AppColors.accent, radius: 24,
    child: Text(
      player.name.isNotEmpty ? player.name[0].toUpperCase() : '?',
      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
    ),
  );
}

