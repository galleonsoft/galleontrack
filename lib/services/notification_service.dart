import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Local notifications only. No push service, no network.
class NotificationService {
  final _p = FlutterLocalNotificationsPlugin();
  bool ready = false;
  int _id = 1000;

  Future<void> init() async {
    const ios = DarwinInitializationSettings(
        requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false);
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    ready = await _p.initialize(settings: const InitializationSettings(android: android, iOS: ios)) ?? false;
  }

  Future<bool> requestPermission() async {
    if (!ready) return false;
    final a = _p.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (a != null) return await a.requestNotificationsPermission() ?? false;
    final i = _p.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    return await i?.requestPermissions(alert: true, badge: true, sound: true) ?? false;
  }

  Future<void> show(String title, String body) async {
    if (!ready) return;
    const d = NotificationDetails(
      android: AndroidNotificationDetails('geofence_events', 'Geofence events',
          channelDescription: 'Entering or leaving a geofence', importance: Importance.high, priority: Priority.high),
      iOS: DarwinNotificationDetails(),
    );
    await _p.show(
      id: _id++,
      title: title,
      body: body,
      notificationDetails: d,
    );
  }
}
