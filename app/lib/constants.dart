import 'package:flutter/widgets.dart';
import 'branding.dart';

const String kBaseUrl = Branding.apiBaseUrl;

/// Number of decimal places used by [fmtNum]. Changed at runtime from settings.
int kNumDecimals = 1;

/// Market colours: ASK red / BID green like a stock ticker; Settings > Numbers & Display can invert.
bool kInvertAskBid = false;
Color get kAskColor => kInvertAskBid ? const Color(0xFF4CAF50) : const Color(0xFFEF5350);
Color get kBidColor => kInvertAskBid ? const Color(0xFFEF5350) : const Color(0xFF4CAF50);

/// Format large numbers with suffix. Uses [kNumDecimals] decimal places.
/// kNumDecimals == -1 → full digits with comma separators (no suffix).
String fmtNum(num n, {int? decimals}) {
  final d = decimals ?? kNumDecimals;
  if (d < 0) {
    final v = n.round().abs();
    final s = v.toString();
    final buf = StringBuffer(n < 0 ? '-' : '');
    final start = s.length % 3;
    if (start > 0) buf.write(s.substring(0, start));
    for (int i = start; i < s.length; i += 3) {
      if (buf.isNotEmpty && buf.toString() != '-') buf.write(',');
      buf.write(s.substring(i, i + 3));
    }
    return buf.toString();
  }
  if (n >= 1e15) return '${(n / 1e15).toStringAsFixed(d)}Q';
  if (n >= 1e12) return '${(n / 1e12).toStringAsFixed(d)}T';
  if (n >= 1e9)  return '${(n / 1e9).toStringAsFixed(d)}B';
  if (n >= 1e6)  return '${(n / 1e6).toStringAsFixed(d)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(d)}K';
  return n.toStringAsFixed(0);
}
