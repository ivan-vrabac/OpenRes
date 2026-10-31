/// One of the company's hexes and its lease (/api/v3/hex/list).
class Hex {
  final String id;
  final double lat, lng;
  final String item;          // product key ("wood", "iron_ore", ...)
  final String op;            // operation ("mine", "logging_camp", ...)
  final int quality;
  final double rateHr;        // made per hour, the supervisor included (electricity in Wh)
  final double leaseDays;     // days left on the lease
  final int renewPrice;       // what renewing costs now (grows with the days used)
  final double renewInHours;  // > 0: can't be renewed yet (a day after the last renewal)
  final int cancelRefund;     // 30 % of the remaining lease
  final int? edu;             // the supervisor's education step, null: no supervisor

  const Hex({
    required this.id, required this.lat, required this.lng, required this.item, required this.op,
    this.quality = 0, this.rateHr = 0, this.leaseDays = 90, this.renewPrice = 0, this.renewInHours = 0,
    this.cancelRefund = 0, this.edu,
  });

  factory Hex.fromJson(Map<String, dynamic> j) => Hex(
    id: '${j['id']}',
    lat: (j['lat'] as num).toDouble(),
    lng: (j['lng'] as num).toDouble(),
    item: j['item'] as String? ?? '',
    op: j['op'] as String? ?? '',
    quality: (j['quality'] as num? ?? 0).toInt(),
    rateHr: (j['ratePerHour'] as num? ?? 0).toDouble(),
    leaseDays: (j['leaseDays'] as num? ?? 0).toDouble(),
    renewPrice: (j['renewPrice'] as num? ?? 0).toInt(),
    renewInHours: (j['renewInHours'] as num? ?? 0).toDouble(),
    cancelRefund: (j['cancelRefund'] as num? ?? 0).toInt(),
    edu: (j['edu'] as num?)?.toInt(),
  );
}

/// The signed-in company (/api/v3/me). Everything else about it comes from the Company
/// (/api/v3/state); the 1.2.3 player data (mines, HQ, warehouse, XP) is gone.
class Player {
  final String hid;
  final String name;
  final int credits;
  final String country;
  final int campusLevel;

  const Player({required this.hid, required this.name, required this.credits, this.country = '',
      this.campusLevel = 0});

  factory Player.fromJson(Map<String, dynamic> j) => Player(
    hid: j['hID'] as String? ?? '',
    name: j['name'] as String? ?? '',
    credits: (j['credits'] as num? ?? 0).toInt(),
    country: j['country'] as String? ?? '',
    campusLevel: (j['campusLevel'] as num? ?? 0).toInt(),
  );
}
