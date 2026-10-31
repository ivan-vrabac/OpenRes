part of 'map_tab.dart';

/// The round buttons on the map.
extension _MapButtons on _MapTabState {
  Widget _mapBtn(IconData icon, VoidCallback onTap, {bool active = false, String? tip}) {
    final w = Material(
      color: active ? AppColors.accentDark : Colors.white.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(_MapTabState._btnR),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(_MapTabState._btnR),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: 20,
              color: active ? Colors.white : AppColors.accent),
        ),
      ),
    );
    return tip != null ? Tooltip(message: tip, child: w) : w;
  }

  Widget _mapBtnW(Widget iconWidget, VoidCallback onTap, {bool active = false, String? tip}) {
    final w = Material(
      color: active ? AppColors.accentDark : Colors.white.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(_MapTabState._btnR),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(_MapTabState._btnR),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: SizedBox(width: 20, height: 20, child: iconWidget),
        ),
      ),
    );
    return tip != null ? Tooltip(message: tip, child: w) : w;
  }
}
