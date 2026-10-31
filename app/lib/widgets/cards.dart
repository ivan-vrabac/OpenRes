import 'package:flutter/material.dart';

import '../app_colors.dart';

/// The small uppercase title above a group of cards.
class SectionLabel extends StatelessWidget {
  final String text;
  final EdgeInsets padding;
  const SectionLabel(this.text, {super.key, this.padding = const EdgeInsets.only(left: 4, bottom: 8)});
  @override
  Widget build(BuildContext context) => Padding(
        padding: padding,
        child: Text(text.toUpperCase(), style: TextStyle(fontSize: 11, color: AppColors.t38, letterSpacing: 1.2)),
      );
}

/// The soft card every page is made of.
class Panel extends StatelessWidget {
  final Widget child;
  final Color? color;
  final EdgeInsets padding;
  const Panel({super.key, required this.child, this.color, this.padding = const EdgeInsets.all(14)});
  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(color: color ?? Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(16)),
        child: child,
      );
}

/// A number with its name under it; put a few in a Row.
class StatTile extends StatelessWidget {
  final String value, label;
  final Color? color;
  const StatTile(this.value, this.label, {super.key, this.color});
  @override
  Widget build(BuildContext context) => Expanded(child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(12)),
        child: Column(children: [
          FittedBox(fit: BoxFit.scaleDown,
              child: Text(value, maxLines: 1, style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: color))),
          const SizedBox(height: 2),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: AppColors.t54)),
        ]),
      ));
}

/// Rows in one card, thin lines between them.
class RowGroup extends StatelessWidget {
  final List<Widget> rows;
  const RowGroup(this.rows, {super.key});
  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Material(
          color: Colors.white.withValues(alpha: 0.05),
          child: Column(children: [
            for (final (i, r) in rows.indexed) ...[
              if (i > 0) const Divider(height: 1, indent: 52, color: Colors.white10),
              r,
            ],
          ]),
        ),
      );
}

/// One row of a [RowGroup]: icon, title, optional line under it, an arrow when it opens a page.
class NavRow extends StatelessWidget {
  final Widget icon;
  final String title;
  final String? subtitle;
  final Color? titleColor;
  final bool arrow;
  final VoidCallback onTap;
  const NavRow({super.key, required this.icon, required this.title, this.subtitle, this.titleColor,
      this.arrow = true, required this.onTap});
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(children: [
            SizedBox(width: 24, child: Center(child: icon)),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontSize: 15, color: titleColor)),
              if (subtitle != null) Text(subtitle!, style: TextStyle(fontSize: 12, color: AppColors.t38)),
            ])),
            if (arrow) Icon(Icons.chevron_right, color: AppColors.t38),
          ]),
        ),
      );
}
