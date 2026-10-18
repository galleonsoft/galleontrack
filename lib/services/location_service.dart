import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import '../core.dart';
import '../db.dart';
import '../models.dart';
import 'geo.dart';
import 'notification_service.dart';

/// Owns the GPS stream while a tracking session is active. All data stays in Hive CE.
/// Tracking never starts automatically; it is not resumed after the app process is killed.
class LocationService extends ChangeNotifier {
  LocationService(this.db, this.notifier) : engine = GeoEngine();
  final Db db;
  final NotificationService notifier;
  final GeoEngine engine;

  bool tracking = false, busy = false;
  LocationPoint? last;
  String? error;
  TrackingSession? session;
  int sessionPoints = 0;
  double sessionDistance = 0;
  StreamSubscription<Position>? _sub;

  Set<String> get insideIds => engine.inside;

  /// Returns an error message, or null when location can be used.
  Future<String?> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return 'Location services are turned off on this device.';
    }
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    if (p == LocationPermission.denied) return 'Location permission was denied.';
    if (p == LocationPermission.deniedForever) {
      return 'Location permission is permanently denied. Enable it in system settings.';
    }
    return null;
  }

  LocationPoint _toPoint(Position p, String? sid) => LocationPoint(
        sessionId: sid, at: p.timestamp.toUtc(), lat: p.latitude, lng: p.longitude,
        accuracy: p.accuracy, speed: p.speed >= 0 ? p.speed : null, altitude: p.altitude);

  Future<void> refreshCurrent() async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      error = await ensurePermission();
      if (error == null) {
        final pos = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)));
        last = _toPoint(pos, null);
      }
    } on TimeoutException {
      error = 'Could not get a GPS fix in time. Try outdoors or with a clearer sky view.';
    } catch (e) {
      error = 'Could not read location: $e';
    }
    busy = false;
    notifyListeners();
  }

  LocationSettings _settings() {
    final s = db.settings;
    final acc = LocationAccuracy.high;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidSettings(
          accuracy: acc, distanceFilter: s.locDistanceM, intervalDuration: Duration(seconds: s.locIntervalSec),
          foregroundNotificationConfig: s.locBackground
              ? const ForegroundNotificationConfig(
                  notificationTitle: 'GalleonTrack', notificationText: 'Location tracking is active', enableWakeLock: true)
              : null,
        );
      case TargetPlatform.iOS:
        return AppleSettings(
          accuracy: acc, activityType: ActivityType.otherNavigation, distanceFilter: s.locDistanceM,
          pauseLocationUpdatesAutomatically: false, showBackgroundLocationIndicator: s.locBackground,
          allowBackgroundLocationUpdates: s.locBackground,
        );
      default:
        return LocationSettings(accuracy: acc, distanceFilter: s.locDistanceM);
    }
  }

  Future<bool> start() async {
    if (tracking) return true;
    error = await ensurePermission();
    if (error != null) {
      notifyListeners();
      return false;
    }
    final s = db.settings;
    engine
      ..reset()
      ..maxAccuracyM = s.locMaxAccuracyM.toDouble();
    try {
      session = TrackingSession(
          employeeId: s.defaultEmployeeId.isEmpty ? null : s.defaultEmployeeId,
          intervalSec: s.locIntervalSec, distanceM: s.locDistanceM, background: s.locBackground);
      await db.sessions.put(session!);
    } on PermissionDenied {
      error = 'Your local role does not allow tracking.';
      notifyListeners();
      return false;
    }
    sessionPoints = 0;
    sessionDistance = 0;
    _sub = Geolocator.getPositionStream(locationSettings: _settings()).listen(
      _onPosition,
      onError: (Object e) {
        error = 'Location stream stopped: $e';
        stop();
      },
    );
    tracking = true;
    notifyListeners();
    return true;
  }

  Future<void> _onPosition(Position pos) async {
    final sid = session?.id;
    final pt = _toPoint(pos, sid);
    try {
      if (last != null && last!.sessionId == sid) {
        sessionDistance += distanceMeters(last!.lat, last!.lng, pt.lat, pt.lng);
      }
      last = pt;
      await db.points.put(pt);
      sessionPoints++;
      final hits = engine.evaluate(db.fences.values, pt.lat, pt.lng, pt.accuracy);
      for (final h in hits) {
        await db.geoEvents.put(GeoEvent(
            fenceId: h.fence.id, fenceName: h.fence.name, type: h.type, at: pt.at,
            lat: pt.lat, lng: pt.lng, accuracy: pt.accuracy, sessionId: sid));
        final enter = h.type == 'enter';
        if ((enter && h.fence.notifyEnter) || (h.type == 'exit' && h.fence.notifyExit)) {
          await notifier.show(enter ? 'Entered ${h.fence.name}' : 'Left ${h.fence.name}',
              '${enter ? 'Entered' : 'Left'} at ${pt.at.toLocal().toString().substring(11, 16)} (accuracy ±${pt.accuracy.round()} m)');
        }
      }
    } on PermissionDenied {
      error = 'Your local role does not allow saving location data.';
      await stop();
      return;
    } catch (e) {
      error = 'Could not save location: $e';
    }
    notifyListeners();
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    final now = DateTime.now().toUtc();
    try {
      for (final id in engine.inside.toList()) {
        final f = db.fences.get(id);
        await db.geoEvents.put(GeoEvent(
            fenceId: id, fenceName: f?.name ?? '', type: 'suspend', at: last?.at ?? now, sessionId: session?.id));
      }
      if (session != null) {
        session!.end = now;
        await db.sessions.put(session!);
      }
    } catch (_) {}
    engine.reset();
    tracking = false;
    notifyListeners();
  }

  /// Call before deleting a fence the device is currently inside.
  Future<void> fenceRemoved(GeoFence f) async {
    if (engine.inside.remove(f.id)) {
      await db.geoEvents.put(GeoEvent(fenceId: f.id, fenceName: f.name, type: 'suspend', at: DateTime.now().toUtc(), sessionId: session?.id));
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
