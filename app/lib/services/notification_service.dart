import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import '../branding.dart';

/// The phone's notification channel (game alerts come from the server: systems/notify.py, fetched by
/// the background worker; the 1.2.3 mine and warehouse alerts the phone scheduled itself are gone).
class NotificationService {
  static const _androidChannel = AndroidNotificationChannel(
    'openres_game',
    Branding.appName,
    description: 'Game alerts',
    importance: Importance.defaultImportance,
  );

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    tz.initializeTimeZones();
    const android = AndroidInitializationSettings('@drawable/ic_notification');
    await _plugin.initialize(const InitializationSettings(android: android));
    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.createNotificationChannel(_androidChannel);
  }

  static Future<bool> requestPermission() async {
    final impl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    return await impl?.requestNotificationsPermission() ?? false;
  }
}
