import 'package:flutter/material.dart';

import '../app_colors.dart';
import 'hex_tiles.dart';

/// Clips to the flat-top hex of the map's hexes (centred; a square box shows it full width).
class HexClipper extends CustomClipper<Path> {
  const HexClipper();
  @override
  Path getClip(Size size) => HexTiles.hexPath(size.width / 2, size.height / 2, size.width / 2);
  @override
  bool shouldReclip(covariant CustomClipper<Path> _) => false;
}

/// A picture cut to the hex shape, like the hexes on the map (owner 2026-10-31: hex pictures
/// everywhere a hex is meant: picker, leaderboard, company sheet).
class HexPicture extends StatelessWidget {
  final String asset;
  final double size;
  const HexPicture(this.asset, {super.key, this.size = 28});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size, height: size * 0.866,
        child: ClipPath(
          clipper: const HexClipper(),
          child: Transform.scale(scale: 1.1, child: Image.asset(asset, fit: BoxFit.cover, gaplessPlayback: true,
              errorBuilder: (_, __, ___) => Icon(Icons.hexagon_outlined, size: size * 0.8, color: AppColors.t38))),
        ),
      );
}
/// Consistent loading / error / empty states for screens backed by a server call.
class AsyncView extends StatelessWidget {
  final bool loading;
  final String? error;
  final bool empty;
  final String emptyText;
  final IconData emptyIcon;
  final VoidCallback? onRetry;
  final Widget Function() builder;

  const AsyncView({
    super.key,
    required this.loading,
    required this.builder,
    this.error,
    this.empty = false,
    this.emptyText = 'Nothing here yet',
    this.emptyIcon = Icons.inbox_outlined,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 40),
            const SizedBox(height: 12),
            Text(error!, textAlign: TextAlign.center, style: TextStyle(color: AppColors.t70)),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Retry')),
            ],
          ]),
        ),
      );
    }
    if (empty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(emptyIcon, color: Colors.white24, size: 48),
          const SizedBox(height: 12),
          Text(emptyText, textAlign: TextAlign.center, style: TextStyle(color: AppColors.t54)),
        ]),
      );
    }
    return builder();
  }
}

/// Item image by item id (same asset convention as the rest of the app), with a fallback icon.
/// The picture of a 0.2.3 item (text key, app/assets/game/items).
/// The Tantalum-180m mark, written like the isotope: a small raised "180m" before "Ta" (owner
/// 2026-10-31: instead of the diamond icon). Sized like an Icon of [size].
class TaIcon extends StatelessWidget {
  final double size;
  final Color? color;
  const TaIcon({super.key, this.size = 24, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? IconTheme.of(context).color ?? AppColors.fg;
    return SizedBox(
      width: size * 1.3, height: size,
      child: FittedBox(
        child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text('180m', style: TextStyle(fontSize: 8, height: 1, fontWeight: FontWeight.w700, color: c)),
          ),
          Text('Ta', style: TextStyle(fontSize: 18, height: 1.1, fontWeight: FontWeight.w800, color: c)),
        ]),
      ),
    );
  }
}

class GameItemIcon extends StatelessWidget {
  final String item;
  final double size;
  final bool hex;           // cut to the hex shape (things made on hexes)
  const GameItemIcon(this.item, {super.key, this.size = 28, this.hex = false});

  @override
  Widget build(BuildContext context) => item == 'electricity'
      // electricity is a lightning bolt everywhere (owner 2026-10-31), not a picture
      ? SizedBox(width: size, height: size, child: Icon(Icons.bolt, size: size, color: Colors.amberAccent))
      : hex ? HexPicture('assets/game/items/$item.png', size: size) : Image.asset(
        'assets/game/items/$item.png',
        width: size, height: size, fit: BoxFit.contain, gaplessPlayback: true,
        errorBuilder: (_, __, ___) => Icon(Icons.inventory_2_outlined, size: size * 0.8, color: AppColors.t38),
      );
}

/// The credits mark wherever credits are shown: a plain icon like the Campus one (owner 2026-10-31;
/// it was a drawn coin picture). Red when the player can't afford it.
class CreditsIcon extends StatelessWidget {
  final double size;
  final bool ok;
  final Color? color;
  const CreditsIcon({super.key, this.size = 16, this.ok = true, this.color});
  @override
  Widget build(BuildContext context) => Icon(Icons.toll, size: size,
      color: ok ? (color ?? AppColors.t54) : Colors.redAccent.withValues(alpha: 0.85));
}

String fmtCredits(num v) {
  final a = v.abs();
  String s;
  if (a >= 1e12) {
    s = '${(v / 1e12).toStringAsFixed(2)}T';
  } else if (a >= 1e9) {
    s = '${(v / 1e9).toStringAsFixed(2)}B';
  } else if (a >= 1e6) {
    s = '${(v / 1e6).toStringAsFixed(2)}M';
  } else if (a >= 1e4) {
    s = '${(v / 1e3).toStringAsFixed(1)}k';
  } else {
    s = v.round().toString();
  }
  return 'ꞓ$s';
}

String fmtQty(num v) {
  final a = v.abs();
  if (a >= 1e9) return '${(v / 1e9).toStringAsFixed(2)}B';
  if (a >= 1e6) return '${(v / 1e6).toStringAsFixed(2)}M';
  if (a >= 1e4) return '${(v / 1e3).toStringAsFixed(1)}k';
  return v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2);
}
