import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../branding.dart';
import '../services/storage_service.dart';
import '../services/api_service.dart';
import '../services/fcm_service.dart';
import '../services/update_service.dart';
import '../models/player_provider.dart';
import 'login_screen.dart';
import 'legal_screen.dart';
import 'game_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    UpdateService.cleanupOldDownloads();       // the update worked: remove its downloaded APK
    // terms of use + privacy policy: accepted for this version, or the app closes (owner 2026-10-25)
    if (!await Legal.ensure(context)) return;
    // Older installs stored only the player ID; they have no session and must sign in.
    final sid = await StorageService.getSid();
    if (sid == null || sid.isEmpty) {
      _go(const LoginScreen());
      return;
    }
    final player = await ApiService.getPlayerData(sid);
    if (player == null || !mounted) {
      _go(const LoginScreen());
      return;
    }
    context.read<PlayerProvider>().setPlayer(player, sid: sid);
    FcmService.init(context.read<PlayerProvider>().sid);
    _go(const GameScreen());
  }

  void _go(Widget screen) {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (Branding.logoAsset.isNotEmpty) ...[
          Image.asset(Branding.logoAsset, height: 96),
          const SizedBox(height: 16),
        ],
        Text(Branding.appTitle, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
        const SizedBox(height: 24),
        const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
      ])),
    );
  }
}
