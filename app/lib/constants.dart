import 'package:flutter/widgets.dart';
import 'branding.dart';

const String kBaseUrl = Branding.apiBaseUrl;

/// Decimal places of short numbers (owner 2026-11-03: always two, no setting any more).
const int kNumDecimals = 2;

/// Market colours: ASK red / BID green like a stock ticker; Settings > Numbers & Display can invert.
bool kInvertAskBid = false;
Color get kAskColor => kInvertAskBid ? const Color(0xFF4CAF50) : const Color(0xFFEF5350);
Color get kBidColor => kInvertAskBid ? const Color(0xFFEF5350) : const Color(0xFF4CAF50);

/// Short-scale suffixes, biggest first: far past anything played, so no score ever prints in full or
/// in exponent form (owner 2026-11-03).
const kBigSuffixes = <(double, String)>[
  (1e33, 'Dc'), (1e30, 'No'), (1e27, 'Oc'), (1e24, 'Sp'), (1e21, 'Sx'), (1e18, 'Qi'), (1e15, 'Q'),
  (1e12, 'T'), (1e9, 'B'), (1e6, 'M'), (1e3, 'K'),
];

/// [v] with the biggest suffix it reaches at or above [from], with [d] decimals; null below [from].
String? suffixed(num v, int d, {double from = 1e3, bool lowerK = false}) {
  if (!v.isFinite) return v.isNaN ? '-' : (v < 0 ? '-∞' : '∞');
  final a = v.abs();
  for (final (base, suf) in kBigSuffixes) {
    if (base < from) break;
    if (a >= base) {
      final x = a / base;
      final body = x >= 1e15 ? x.toStringAsExponential(2) : x.toStringAsFixed(d);
      return '${v < 0 ? '-' : ''}$body${lowerK && suf == 'K' ? 'k' : suf}';
    }
  }
  return null;
}

/// Large numbers with a suffix and [kNumDecimals] decimals (1.23K, 4.56M ... up to Dc); below 1,000 whole.
String fmtNum(num n, {int? decimals}) {
  if (!n.isFinite) return suffixed(n, 0)!;
  final d = decimals ?? kNumDecimals;
  return suffixed(n, d) ?? n.toStringAsFixed(0);
}
