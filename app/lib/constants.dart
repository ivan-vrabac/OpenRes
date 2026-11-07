import 'package:flutter/widgets.dart';
import 'branding.dart';

const String kBaseUrl = Branding.apiBaseUrl;

/// Decimal places of short numbers (owner 2026-11-03: always two, no setting any more).
const int kNumDecimals = 2;

/// Market colours: ASK red / BID green like a stock ticker.
const kAskColor = Color(0xFFEF5350);
const kBidColor = Color(0xFF4CAF50);

/// Short-scale suffixes, biggest first: far past anything played, so no score ever prints in full or
/// in exponent form (owner 2026-11-03).
const kBigSuffixes = <(double, String)>[
  (1e33, 'Dc'), (1e30, 'No'), (1e27, 'Oc'), (1e24, 'Sp'), (1e21, 'Sx'), (1e18, 'Qi'), (1e15, 'Q'),
  (1e12, 'T'), (1e9, 'B'), (1e6, 'M'), (1e3, 'K'),
];

/// [v] with the biggest suffix it reaches at or above [from], with [d] decimals; null below [from].
/// Without a decimal that says nothing (owner 2026-11-07): 1.50 is 1.5, 1.00 is 1, 1.25 stays.
String trimDec(String s) => s.contains('.') && !s.contains('e') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;

String? suffixed(num v, int d, {double from = 1e3, bool lowerK = false}) {
  if (!v.isFinite) return v.isNaN ? '-' : (v < 0 ? '-∞' : '∞');
  final a = v.abs();
  for (final (base, suf) in kBigSuffixes) {
    if (base < from) break;
    if (a >= base) {
      final x = a / base;
      final body = x >= 1e15 ? x.toStringAsExponential(2) : trimDec(x.toStringAsFixed(d));
      return '${v < 0 ? '-' : ''}$body${lowerK && suf == 'K' ? 'k' : suf}';
    }
  }
  return null;
}

/// The whole number with thousands commas (and cents when it has them): the activity log shows exact
/// amounts (owner 2026-11-03). Past 1e21 it falls back to the short form.
String fmtFull(num v) {
  if (!v.isFinite || v.abs() >= 1e21) return fmtNum(v);
  final a = v.abs();
  final s = a.toStringAsFixed(a == a.roundToDouble() ? 0 : 2);         // exact amounts keep their cents
  final parts = s.split('.');
  final w = parts[0];
  final buf = StringBuffer(v < 0 ? '-' : '');
  for (var i = 0; i < w.length; i++) {
    if (i > 0 && (w.length - i) % 3 == 0) buf.write(',');
    buf.write(w[i]);
  }
  if (parts.length > 1) buf.write('.${parts[1]}');
  return buf.toString();
}

/// Large numbers with a suffix and [kNumDecimals] decimals (1.23K, 4.56M ... up to Dc); below 1,000 whole.
String fmtNum(num n, {int? decimals}) {
  if (!n.isFinite) return suffixed(n, 0)!;
  final d = decimals ?? kNumDecimals;
  return suffixed(n, d) ?? n.toStringAsFixed(0);
}
