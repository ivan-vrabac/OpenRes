import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../constants.dart';
import '../models/player_provider.dart';
import '../services/game_api.dart';
import '../widgets/async_view.dart';
import '../widgets/glass.dart' show tabPadding;
import '../widgets/top_banner.dart';

import '../app_colors.dart';
import '../widgets/popups.dart';
import '../widgets/price_chart.dart';
import '../v3/company.dart';
import '../v3/sell_sheet.dart';
/// Market (0.2.3 redo, owner 2026-10-31): one page, no tabs. A short tax note, your open buy orders
/// as a strip of cards, then every tradable item as a card with what you'd get selling it now (the
/// best buy order or the system) and its sales tax, which is lowest on items few companies make.
/// Sort by name, tax, price or what you own. Tap an item for its page.
class MarketScreen extends StatefulWidget {
  const MarketScreen({super.key});
  @override
  State<MarketScreen> createState() => _MarketScreenState();
}

enum _Sort { name, tax, price, owned }

class _MarketScreenState extends State<MarketScreen> {
  // the last data is kept for the session: the list and its pictures show at once
  static List<Map<String, dynamic>> _cItems = [], _cOrders = [];
  List<Map<String, dynamic>> _items = _cItems;
  List<Map<String, dynamic>> _orders = _cOrders;
  bool _loading = _cItems.isEmpty;
  String? _error;
  String _filter = '';
  _Sort _sort = _Sort.name;
  double _taxMin = 0.05, _taxMax = 0.25;

  String get _sid => context.read<PlayerProvider>().sid;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Refreshes values in place: the spinner only shows on the very first load.
  Future<void> _load() async {
    setState(() { _loading = _items.isEmpty; _error = null; });
    final res = await Future.wait([
      GameApi.call('/api/v1/market/overview', _sid),
      GameApi.call('/api/v1/market/mine', _sid),
    ]);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (!res[0].ok) { _error = res[0].message; return; }
      _items = res[0].list('items');
      _taxMin = (res[0].data['taxMin'] as num? ?? 0.05).toDouble();
      _taxMax = (res[0].data['taxMax'] as num? ?? 0.25).toDouble();
      _orders = res[1].list('orders');
      _cItems = _items; _cOrders = _orders;
    });
  }

  Future<void> _open(String item) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => MarketItemScreen(item: item)));
    if (mounted) _load();
  }

  /// What selling one unit brings now: the best buy order, or the system's price.
  static double _sellPrice(Map<String, dynamic> e) {
    final bid = (e['bestBid'] as num?)?.toDouble() ?? 0;
    final sys = (e['systemSell'] as num?)?.toDouble() ?? 0;
    return bid > sys ? bid : sys;
  }

  /// Green for the lowest tax, red for the highest.
  Color _taxColor(double r) {
    final t = _taxMax <= _taxMin ? 0.5 : ((r - _taxMin) / (_taxMax - _taxMin)).clamp(0.0, 1.0);
    return Color.lerp(Colors.greenAccent, Colors.redAccent, t)!;
  }

  @override
  Widget build(BuildContext context) {
    final co = context.watch<Company>();
    final raw = (co.catalog['raw'] as Map?) ?? const {};
    final shown = _items.where((e) =>
        _filter.isEmpty || (e['name'] as String? ?? '').toLowerCase().contains(_filter)).toList();
    switch (_sort) {
      case _Sort.name:
        shown.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
      case _Sort.tax:
        shown.sort((a, b) => (a['taxRate'] as num).compareTo(b['taxRate'] as num));
      case _Sort.price:
        shown.sort((a, b) => _sellPrice(b).compareTo(_sellPrice(a)));
      case _Sort.owned:
        shown.sort((a, b) => ((b['owned'] as num?) ?? 0).compareTo((a['owned'] as num?) ?? 0));
    }
    return AsyncView(
      loading: _loading,
      error: _error,
      onRetry: _load,
      builder: () => RefreshIndicator(
        onRefresh: _load,
        child: ListView(key: const PageStorageKey('market_items'), padding: tabPadding(context, 12), children: [
          Row(children: [
            Icon(Icons.receipt_long_outlined, size: 14, color: AppColors.t54),
            const SizedBox(width: 6),
            Expanded(child: Text('Sellers pay a sales tax of ${(_taxMin * 100).round()} to ${(_taxMax * 100).round()} %, '
                'lowest on items few companies make. Buying is tax-free.',
                style: TextStyle(fontSize: 11, color: AppColors.t54))),
          ]),
          if (_orders.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Your buy orders', style: TextStyle(fontSize: 12, color: AppColors.t54)),
            const SizedBox(height: 6),
            SizedBox(
              height: 64,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final o in _orders)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Material(
                      color: AppColors.accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => _open(o['item'] as String),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          child: Row(children: [
                            GameItemIcon(o['item'] as String, size: 36, hex: raw.containsKey(o['item'])),
                            const SizedBox(width: 8),
                            Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              Text('${fmtQty(o['qtyOpen'] as num)} left', style: const TextStyle(fontWeight: FontWeight.bold)),
                              Text('at ${fmtCredits(o['price'] as num)}', style: TextStyle(fontSize: 11, color: AppColors.t54)),
                            ]),
                          ]),
                        ),
                      ),
                    ),
                  ),
              ]),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            decoration: InputDecoration(isDense: true, prefixIcon: const Icon(Icons.search), hintText: 'Find an item',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14))),
            onChanged: (v) => setState(() => _filter = v.trim().toLowerCase()),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final (s, label) in const [(_Sort.name, 'A to Z'), (_Sort.tax, 'Lowest tax'),
                  (_Sort.price, 'Best price'), (_Sort.owned, 'You own')])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(label: Text(label), selected: _sort == s, visualDensity: VisualDensity.compact,
                      onSelected: (_) => setState(() => _sort = s)),
                ),
            ]),
          ),
          const SizedBox(height: 8),
          for (final e in shown) _itemCard(e, raw.containsKey(e['item'])),
        ]),
      ),
    );
  }

  Widget _itemCard(Map<String, dynamic> e, bool hex) {
    final id = e['item'] as String;
    final owned = (e['owned'] as num? ?? 0);
    final tax = (e['taxRate'] as num? ?? 0).toDouble();
    final orders = (e['bestBid'] as num? ?? 0) > (e['systemSell'] as num? ?? 0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _open(id),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(children: [
              GameItemIcon(id, size: 44, hex: hex),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(e['name'] as String? ?? id, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                Text(owned >= 1 ? 'You have ${fmtNum(owned.floor())}' : 'None in storage',
                    style: TextStyle(fontSize: 11, color: AppColors.t54)),
              ])),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(fmtCredits(_sellPrice(e)),
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.greenAccent)),
                Text(orders ? 'a buy order pays' : 'the system pays', style: TextStyle(fontSize: 10, color: AppColors.t54)),
              ]),
              const SizedBox(width: 10),
              Container(
                width: 46,
                padding: const EdgeInsets.symmetric(vertical: 4),
                decoration: BoxDecoration(color: _taxColor(tax).withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                child: Column(children: [
                  Text('${(tax * 100).round()}%', style: TextStyle(fontWeight: FontWeight.bold, color: _taxColor(tax))),
                  Text('tax', style: TextStyle(fontSize: 9, color: _taxColor(tax))),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// One item: an order book of BUY orders only. Top: buy from the system; middle: players' buy
/// orders (highest price first, oldest first at equal price) that you can sell into; bottom: sell
/// to the system. You can have one buy order per item (edit or cancel it).
class MarketItemScreen extends StatefulWidget {
  final String item;
  const MarketItemScreen({super.key, required this.item});
  @override
  State<MarketItemScreen> createState() => _MarketItemScreenState();
}

class _MarketItemScreenState extends State<MarketItemScreen> {
  Timer? _live;
  Map<String, dynamic>? _b;
  bool _loading = true;
  String? _error;

  String get _sid => context.read<PlayerProvider>().sid;
  String get _name => context.read<Company>().itemName(widget.item);
  String _rid() => '${DateTime.now().microsecondsSinceEpoch}${Random().nextInt(1 << 30)}';

  @override
  void initState() {
    super.initState();
    _live = Timer.periodic(const Duration(seconds: 10), (_) => _load());   // room, credits, orders
    _load();
  }

  @override
  void dispose() {
    _live?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    // values refresh in place (no spinner after the first load)
    final r = await GameApi.call('/api/v1/market/book', _sid, {'item': widget.item});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = r.ok ? null : r.message;
      if (r.ok) _b = r.data;
    });
  }

  Future<void> _done(ApiResult r, String ok) async {
    if (!mounted) return;
    AppNotify.show(context, r.ok ? ok : (r.message ?? 'Failed'), isError: !r.ok);
    if (r.ok) context.read<PlayerProvider>().refresh();
    _load();
  }

  /// Quantity-only trades: buy from / sell to the system, sell into a player's buy order.
  Future<void> _qtyTrade({required String title, required num price, required int maxQty,
      required bool selling, required Future<ApiResult> Function(int qty) run, double taxRate = 0,
      Future<int?> Function()? liveMax}) async {
    final q = await showAppDialog<int>(
      context: context,
      builder: (_) => _QtyDialog(title: title, item: widget.item, price: price, maxQty: maxQty,
          selling: selling, taxRate: taxRate, liveMax: liveMax),
    );
    if (q == null || q <= 0) return;
    final r = await run(q);
    await _done(r, selling ? 'Sold $q × $_name' : 'Bought ${fmtNum((r.data['qty'] as num?) ?? q)} × $_name');
  }

  Future<void> _orderDialog({Map<String, dynamic>? mine}) async {
    final b = _b!;
    final bids = (b['bids'] as List).cast<Map<String, dynamic>>();
    final topOther = bids.where((o) => o['isMe'] != true).map((o) => o['price'] as num).fold<num?>(null,
        (a, p) => a == null || p > a ? p : a);
    final res = await showAppDialog<(int, double)>(
      context: context,
      builder: (_) => _OrderDialog(
        item: widget.item,
        name: _name,
        taxRate: 0,                     // buying is tax-free (owner 2026-10-31)
        credits: (b['credits'] as num).toDouble() + ((mine?['escrow'] as num?) ?? 0),
        freeSpace: ((b['freeSpace'] as num) + (mine != null ? (mine['qty'] as num) : 0)).toInt(),
        initialPrice: (mine?['price'] as num?)?.toDouble() ?? _suggest(topOther, b),
        initialQty: (mine?['qty'] as num?)?.toInt(),
        maxPrice: (b['systemBuy'] as num?)?.toDouble(),
        minPrice: (b['systemSell'] as num?)?.toDouble(),
        editing: mine != null,
      ),
    );
    if (res == null) return;
    final r = mine == null
        ? await GameApi.call('/api/v1/market/order', _sid,
            {'side': 'buy', 'item': widget.item, 'qty': res.$1, 'price': res.$2, 'rid': _rid()})
        : await GameApi.call('/api/v1/market/edit', _sid,
            {'orderID': mine['id'], 'qty': res.$1, 'price': res.$2, 'rid': _rid()});
    await _done(r, mine == null ? 'Buy order placed' : 'Buy order updated');
  }

  /// Suggested bid: 1 credit above the highest offer (or the system BID price), but never above
  /// the system ASK price (150 %) — the server refuses anything higher.
  double _suggest(num? topOther, Map<String, dynamic> b) {
    final base = (topOther ?? b['systemSell'] as num? ?? 0).toDouble();
    final ask = (b['systemBuy'] as num?)?.toDouble();
    final s = base + 1;
    return ask != null && s > ask ? ask : s;
  }

  Future<void> _cancelMine(Map<String, dynamic> mine) async {
    final r = await GameApi.call('/api/v1/market/cancel', _sid, {'orderID': mine['id']});
    await _done(r, 'Order cancelled, credits returned');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(toolbarHeight: 40, title: Text(_name)),
      body: AsyncView(
        loading: _loading,
        error: _error,
        onRetry: _load,
        builder: () {
          final b = _b!;
          final co = context.read<Company>();
          final raw = (co.catalog['raw'] as Map?)?.containsKey(widget.item) ?? false;
          final owned = (b['owned'] as num? ?? 0).toInt();
          final credits = (b['credits'] as num).toDouble();
          final space = (b['freeSpace'] as num? ?? 0).toInt();
          final tax = (b['taxRate'] as num).toDouble();
          final sysSell = b['systemSell'] as num?;
          final sysBuy = b['systemBuy'] as num?;
          final bids = (b['bids'] as List).cast<Map<String, dynamic>>();
          final mine = (b['myOrder'] as Map?)?.cast<String, dynamic>();
          final others = bids.where((o) => o['isMe'] != true).toList();
          final best = [if (others.isNotEmpty) others.first['price'] as num, if (sysSell != null) sysSell]
              .fold<num>(0, (a, v) => v > a ? v : a);
          // one page (owner 2026-10-31): the item, its price chart, Sell (the Storage sell sheet) and your
          // buy order, then the buy orders of other companies
          return RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.all(14), children: [
              Row(children: [
                GameItemIcon(widget.item, size: 64, hex: raw),
                const SizedBox(width: 14),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  Text('You have ${fmtNum(owned)} · room for ${fmtNum(space)}',
                      style: TextStyle(color: AppColors.t54, fontSize: 12)),
                ])),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(10)),
                  child: Column(children: [
                    Text('${(tax * 100).round()}%', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    Text('sales tax', style: TextStyle(fontSize: 9, color: AppColors.t54)),
                  ]),
                ),
              ]),
              const SizedBox(height: 12),
              PriceHistoryChart(item: widget.item),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: _wideButton(Icons.sell_outlined,
                    owned > 0 ? 'Sell · up to ${fmtCredits(best)}' : 'Nothing to sell',
                    owned <= 0 ? null : () async {
                      if (await showSellSheet(context, co, widget.item, owned.toDouble()) && mounted) _load();
                    }, filled: true)),
                const SizedBox(width: 10),
                Expanded(child: mine == null
                    ? _wideButton(Icons.add_shopping_cart, 'Buy order', () => _orderDialog())
                    : _wideButton(Icons.edit, 'Edit my order', () => _orderDialog(mine: mine))),
              ]),
              if (mine != null)
                Container(
                  margin: const EdgeInsets.only(top: 10),
                  padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                  decoration: BoxDecoration(color: AppColors.accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
                  child: Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Your buy order: ${fmtNum((mine['qty'] as num).toInt())} at ${fmtCredits(mine['price'] as num)}',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text('Holds ${fmtCredits(mine['escrow'] as num)} until it fills',
                          style: TextStyle(color: AppColors.t54, fontSize: 12)),
                    ])),
                    TextButton(onPressed: () => _cancelMine(mine), child: const Text('Cancel')),
                  ]),
                ),
              if (sysBuy != null) ...[
                const SizedBox(height: 10),
                _wideButton(Icons.storefront_outlined, 'Buy from the system at ${fmtCredits(sysBuy)}', () => _qtyTrade(
                  title: 'Buy from the system', price: sysBuy, selling: false,
                  maxQty: max(0, min(space, (credits / sysBuy).floor())),
                  liveMax: () async {                    // hexes and plants keep filling Central Storage
                    final r = await GameApi.call('/api/v1/market/book', _sid, {'item': widget.item});
                    if (!r.ok) return null;
                    return max(0, min((r.data['freeSpace'] as num).toInt(), ((r.data['credits'] as num) / sysBuy).floor()));
                  },
                  run: (q) => GameApi.call('/api/v1/market/system', _sid,
                      {'side': 'buy', 'item': widget.item, 'qty': q, 'fit': 1, 'rid': _rid()}))),
              ],
              const SizedBox(height: 18),
              Text('Buy orders', style: TextStyle(color: AppColors.t54, fontSize: 12)),
              const SizedBox(height: 4),
              for (final o in bids)
                _bookRow(
                  label: o['isMe'] == true ? 'You' : (o['name'] as String? ?? 'Player'),
                  price: o['price'] as num, qtyText: fmtNum((o['qty'] as num).toInt()),
                  color: o['isMe'] == true ? AppColors.accent : AppColors.fg,
                ),
              if (sysSell != null)
                _bookRow(label: 'The system', price: sysSell, qtyText: '', color: AppColors.t54),
              if (bids.isEmpty)
                Padding(padding: const EdgeInsets.all(8),
                    child: Text('No buy orders from players yet.', style: TextStyle(color: AppColors.t38, fontSize: 12))),
              const SizedBox(height: 10),
              Text('Selling fills the best orders first, then the system. The seller pays the sales tax; '
                  'buying is tax-free. At equal prices the older order is served first.',
                  style: TextStyle(color: AppColors.t38, fontSize: 11)),
            ]),
          );
        },
      ),
    );
  }

  Widget _wideButton(IconData icon, String text, VoidCallback? onTap, {bool filled = false}) {
    final child = FittedBox(fit: BoxFit.scaleDown, child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 18), const SizedBox(width: 6), Text(text, maxLines: 1),
    ]));
    return SizedBox(
      width: double.infinity,
      height: 44,
      child: filled ? FilledButton(onPressed: onTap, child: child) : OutlinedButton(onPressed: onTap, child: child),
    );
  }

  Widget _bookRow({required String label, required num price, required String qtyText, required Color color,
      String? action, VoidCallback? onTap}) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.04), borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        Expanded(flex: 4, child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: color))),
        Expanded(flex: 4, child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight,
            child: Text(fmtCredits(price), style: const TextStyle(fontWeight: FontWeight.bold)))),
        const SizedBox(width: 8),
        Expanded(flex: 3, child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight,
            child: Text(qtyText, style: TextStyle(color: AppColors.t70)))),
        const SizedBox(width: 8),
        SizedBox(
          width: 64,
          child: action == null
              ? const SizedBox.shrink()
              : FilledButton.tonal(
                  style: FilledButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                  onPressed: onTap, child: Text(action)),
        ),
      ]),
    );
  }
}

/// Whole-unit quantity with a slider (up to what you can afford / store / own) and a number field.
class _QtyDialog extends StatefulWidget {
  final String title, item;
  final int maxQty;
  final num price;
  final bool selling;
  final double taxRate;      // the sales tax, taken off what a seller receives
  final Future<int?> Function()? liveMax;   // asked every few seconds: the maximum can change while open
  const _QtyDialog({required this.title, required this.item, required this.price, required this.maxQty,
      required this.selling, this.taxRate = 0, this.liveMax});
  @override
  State<_QtyDialog> createState() => _QtyDialogState();
}

class _QtyDialogState extends State<_QtyDialog> {
  late int _max = widget.maxQty;
  late int _q = widget.maxQty;
  late final _ctl = TextEditingController(text: '${widget.maxQty}');
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.liveMax != null) {
      _timer = Timer.periodic(const Duration(seconds: 4), (_) async {
        final m = await widget.liveMax!();
        if (!mounted || m == null || m == _max) return;
        final atMax = _q >= _max;                // the slider at the end stays at the end
        setState(() => _max = m);
        _set(atMax ? m : _q);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _set(int v) {
    setState(() => _q = v.clamp(0, _max));
    final t = '$_q';
    if (_ctl.text != t) _ctl.value = TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
  }

  @override
  Widget build(BuildContext context) {
    final value = (_q * widget.price).round();
    final tax = widget.selling ? (value * widget.taxRate).round() : 0;
    final total = value - tax;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          GameItemIcon(widget.item, size: 32),
          const SizedBox(width: 8),
          Expanded(child: Text('${fmtCredits(widget.price)} per unit'
              '${widget.selling && widget.taxRate > 0 ? ' less ${(widget.taxRate * 100).round()}% sales tax' : ''}')),
        ]),
        if (_max <= 0)
          Padding(padding: const EdgeInsets.only(top: 12), child: Text(widget.selling
              ? "You don't have any to sell." : 'Not enough credits or room in Central Storage.',
              style: const TextStyle(color: Colors.orangeAccent)))
        else ...[
          Slider(value: _q.toDouble(), min: 0, max: _max.toDouble(),
              onChanged: (v) => _set(v.round())),
          TextField(
            controller: _ctl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(labelText: 'Quantity', helperText: 'max ${fmtNum(_max)}'),
            onChanged: (t) => _set(int.tryParse(t) ?? 0),
          ),
          const SizedBox(height: 10),
          if (tax > 0)
            Row(children: [
              Expanded(child: Text('Sales tax', style: TextStyle(color: AppColors.t70))),
              Text('- ${fmtCredits(tax)}'),
            ]),
          Row(children: [
            Expanded(child: Text(widget.selling ? 'You receive' : 'You pay', style: TextStyle(color: AppColors.t70))),
            Text(fmtCredits(total), style: const TextStyle(fontWeight: FontWeight.bold)),
          ]),
        ],
      ]),
      actions: [
        TextButton(onPressed: () => popIfCurrent(context), child: const Text('Cancel')),
        FilledButton(onPressed: _q <= 0 ? null : () => popIfCurrent(context, _q), child: const Text('Confirm')),
      ],
    );
  }
}

/// New or edited buy order: price (prefilled with the top bid) and a quantity slider limited by
/// your credits (price + tax) and room in Central Storage. Shows the price per unit including tax.
class _OrderDialog extends StatefulWidget {
  final String item, name;
  final int freeSpace;
  final double taxRate, credits, initialPrice;
  final double? maxPrice, minPrice;
  final int? initialQty;
  final bool editing;
  const _OrderDialog({required this.item, required this.name, required this.taxRate, required this.credits, required this.freeSpace,
      required this.initialPrice, this.initialQty, this.maxPrice, this.minPrice, this.editing = false});
  @override
  State<_OrderDialog> createState() => _OrderDialogState();
}

class _OrderDialogState extends State<_OrderDialog> {
  late double _price = widget.initialPrice;
  late final _priceCtl = TextEditingController(text: _fmt(widget.initialPrice));
  late final _qtyCtl = TextEditingController();
  int _q = 0;

  static String _fmt(double v) => v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2);

  int get _maxQty {
    if (_price <= 0) return 0;
    final afford = (widget.credits / (_price * (1 + widget.taxRate))).floor();
    return max(0, min(afford, widget.freeSpace));
  }

  @override
  void initState() {
    super.initState();
    _q = min(widget.initialQty ?? _maxQty, _maxQty);
    _qtyCtl.text = '$_q';
  }

  void _setQ(int v) {
    setState(() => _q = v.clamp(0, _maxQty));
    final t = '$_q';
    if (_qtyCtl.text != t) _qtyCtl.value = TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
  }

  @override
  Widget build(BuildContext context) {
    final unitWithTax = _price * (1 + widget.taxRate);
    final value = (_q * _price).round();
    final tax = (value * widget.taxRate).round();
    final m = _maxQty;
    final tooHigh = widget.maxPrice != null && _price > widget.maxPrice! + 1e-9;
    final tooLow = widget.minPrice != null && _price < widget.minPrice! - 1e-9;
    return AlertDialog(
      title: Text(widget.editing ? 'Edit buy order' : 'Place buy order'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            GameItemIcon(widget.item, size: 32),
            const SizedBox(width: 8),
            Expanded(child: Text(widget.name)),
          ]),
          TextField(
            controller: _priceCtl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: InputDecoration(
              labelText: 'Price per unit',
              helperText: widget.taxRate > 0
                  ? '${fmtCredits(unitWithTax)} per unit incl. ${(widget.taxRate * 100).round()}% tax' : null,
              errorText: tooHigh ? 'Above the system ASK price.' : tooLow ? 'Below the system BID price.' : null,
            ),
            onChanged: (t) => setState(() {
              _price = double.tryParse(t) ?? 0;
              _q = min(_q, _maxQty);
              _qtyCtl.text = '$_q';
            }),
          ),
          const SizedBox(height: 8),
          if (m > 0)
            Slider(value: _q.toDouble().clamp(0, m.toDouble()), min: 0, max: m.toDouble(), onChanged: (v) => _setQ(v.round())),
          TextField(
            controller: _qtyCtl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(labelText: 'Quantity', helperText: 'max ${fmtNum(m)} (credits / room in storage)'),
            onChanged: (t) => _setQ(int.tryParse(t) ?? 0),
          ),
          const SizedBox(height: 10),
          _line('Value', fmtCredits(value)),
          if (tax > 0) _line('Tax', fmtCredits(tax)),
          _line('Held now', fmtCredits(value + tax), bold: true),
          const SizedBox(height: 6),
          Text('Credits are held until players sell to you. Unfilled quantity is refunded on cancel '
              'or after 2 days. Editing the price puts the order behind older ones at the same price.',
              style: TextStyle(fontSize: 11, color: AppColors.t54)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => popIfCurrent(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _q <= 0 || _price <= 0 || tooHigh || tooLow ? null : () => popIfCurrent(context, (_q, _price)),
          child: Text(widget.editing ? 'Update' : 'Place order'),
        ),
      ],
    );
  }

  Widget _line(String k, String v, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(children: [
          Expanded(child: Text(k, style: TextStyle(color: AppColors.t70))),
          Text(v, style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        ]),
      );
}
