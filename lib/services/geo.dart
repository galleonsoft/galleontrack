import 'dart:math';
import '../core.dart';
import '../models.dart';

const _earthR = 6371008.8;

/// Great-circle (haversine) distance in metres.
double distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  final p1 = lat1 * pi / 180, p2 = lat2 * pi / 180;
  final dp = (lat2 - lat1) * pi / 180, dl = (lng2 - lng1) * pi / 180;
  final a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2);
  return 2 * _earthR * asin(min(1.0, sqrt(a)));
}

double routeDistance(List<LocationPoint> pts) {
  var d = 0.0;
  for (var i = 1; i < pts.length; i++) {
    d += distanceMeters(pts[i - 1].lat, pts[i - 1].lng, pts[i].lat, pts[i].lng);
  }
  return d;
}

typedef FenceHit = ({GeoFence fence, String type});

/// Entry/exit detection with noise protection:
///  - fixes with accuracy worse than [maxAccuracyM] are ignored;
///  - a transition needs [confirmCount] consecutive agreeing fixes;
///  - exit uses hysteresis: distance must exceed radius + [exitBufferM].
class GeoEngine {
  GeoEngine({this.confirmCount = 2, this.exitBufferM = 10, this.maxAccuracyM = 100});
  int confirmCount;
  double exitBufferM, maxAccuracyM;
  final Set<String> inside = {};
  final Map<String, int> _pending = {};

  List<FenceHit> evaluate(Iterable<GeoFence> fences, double lat, double lng, double accuracy) {
    final out = <FenceHit>[];
    if (accuracy > maxAccuracyM) return out;
    for (final f in fences) {
      final isIn = inside.contains(f.id);
      if (!f.enabled) {
        if (isIn) {
          inside.remove(f.id);
          out.add((fence: f, type: 'suspend'));
        }
        _pending.remove(f.id);
        continue;
      }
      final d = distanceMeters(lat, lng, f.lat, f.lng);
      final want = isIn ? !(d > f.radiusM + exitBufferM) : d <= f.radiusM;
      if (want == isIn) {
        _pending.remove(f.id);
        continue;
      }
      final n = (_pending[f.id] ?? 0) + 1;
      if (n >= confirmCount) {
        _pending.remove(f.id);
        if (want) {
          inside.add(f.id);
          out.add((fence: f, type: 'enter'));
        } else {
          inside.remove(f.id);
          out.add((fence: f, type: 'exit'));
        }
      } else {
        _pending[f.id] = n;
      }
    }
    return out;
  }

  void reset() {
    inside.clear();
    _pending.clear();
  }
}

/// Time spent inside [fenceId] within [r]. An interval opens at `enter` and closes at
/// `exit` or `suspend`. An interval still open at the end is closed at [cap]
/// (now while tracking, otherwise the last recorded fix) so it is never over-counted.
Duration timeInside(Iterable<GeoEvent> events, String fenceId, Range r, DateTime cap) {
  final ev = events.where((e) => e.fenceId == fenceId).toList()..sort((a, b) => a.at.compareTo(b.at));
  final lo = r.from.toUtc(), hi = r.to.toUtc().isBefore(cap.toUtc()) ? r.to.toUtc() : cap.toUtc();
  var total = Duration.zero;
  DateTime? open;
  void close(DateTime end) {
    if (open == null) return;
    final a = open!.isBefore(lo) ? lo : open!;
    final b = end.isAfter(hi) ? hi : end;
    if (b.isAfter(a)) total += b.difference(a);
    open = null;
  }
  for (final e in ev) {
    if (e.type == 'enter') {
      open ??= e.at;
    } else {
      close(e.at);
    }
  }
  close(cap.toUtc());
  return total;
}

String fmtDur(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  return h > 0 ? '${h}h ${m}m' : m > 0 ? '${m}m ${s}s' : '${s}s';
}

/// Local equirectangular projection used by the offline map canvas.
class GeoProjector {
  GeoProjector(this.lat0, this.lng0, this.mpp, this.w, this.h)
      : _mLng = 111320 * cos(lat0 * pi / 180);
  final double lat0, lng0, mpp, w, h;
  final double _mLng;
  static const _mLat = 110574.0;

  ({double x, double y}) toXY(double lat, double lng) =>
      (x: w / 2 + (lng - lng0) * _mLng / mpp, y: h / 2 - (lat - lat0) * _mLat / mpp);
  ({double lat, double lng}) fromXY(double x, double y) =>
      (lat: lat0 - (y - h / 2) * mpp / _mLat, lng: lng0 + (x - w / 2) * mpp / _mLng);
}
