import 'dart:math';
import 'package:flutter/material.dart';
import '../models.dart';
import '../services/geo.dart';

/// Offline map: a scaled plot of geofences, route and position on a metric grid.
/// It deliberately has NO street tiles, because tiles require network access.
class GeoMap extends StatelessWidget {
  const GeoMap({
    super.key, required this.fences, this.route = const [], this.current, this.insideIds = const {},
    this.height = 260, this.onTap, this.pin, this.pinRadius, this.fixedCenter, this.fixedHalfSpanM,
  });
  final List<GeoFence> fences;
  final List<LocationPoint> route;
  final LocationPoint? current;
  final Set<String> insideIds;
  final double height;
  final void Function(double lat, double lng)? onTap;
  final ({double lat, double lng})? pin, fixedCenter;
  final double? pinRadius, fixedHalfSpanM;

  GeoProjector? _projector(double w, double h) {
    double? minLa, maxLa, minLo, maxLo;
    void add(double la, double lo) {
      minLa = minLa == null ? la : min(minLa!, la);
      maxLa = maxLa == null ? la : max(maxLa!, la);
      minLo = minLo == null ? lo : min(minLo!, lo);
      maxLo = maxLo == null ? lo : max(maxLo!, lo);
    }
    if (fixedCenter != null) {
      final mpp = (fixedHalfSpanM ?? 500) * 2 / min(w, h);
      return GeoProjector(fixedCenter!.lat, fixedCenter!.lng, mpp, w, h);
    }
    for (final p in route) {
      add(p.lat, p.lng);
    }
    if (current != null) add(current!.lat, current!.lng);
    for (final f in fences) {
      final dLa = f.radiusM / 110574, dLo = f.radiusM / (111320 * cos(f.lat * pi / 180)).abs().clamp(1, 1e9);
      add(f.lat - dLa, f.lng - dLo);
      add(f.lat + dLa, f.lng + dLo);
    }
    if (pin != null) add(pin!.lat, pin!.lng);
    if (minLa == null) return null;
    final la0 = (minLa! + maxLa!) / 2, lo0 = (minLo! + maxLo!) / 2;
    final spanY = (maxLa! - minLa!) * 110574, spanX = (maxLo! - minLo!) * 111320 * cos(la0 * pi / 180);
    final mpp = max(max(spanX / max(w - 48, 1), spanY / max(h - 48, 1)), 0.5);
    return GeoProjector(la0, lo0, mpp, w, h);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth, h = height;
      final proj = _projector(w, h);
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: w, height: h,
          child: proj == null
              ? Container(color: cs.surfaceContainerHighest, alignment: Alignment.center, child: const Text('Nothing to show yet — add a geofence or get your location.'))
              : GestureDetector(
                  onTapUp: onTap == null ? null : (d) {
                    final q = proj.fromXY(d.localPosition.dx, d.localPosition.dy);
                    onTap!(q.lat, q.lng);
                  },
                  child: CustomPaint(painter: _Painter(this, proj, cs), size: Size(w, h)),
                ),
        ),
      );
    });
  }
}

class _Painter extends CustomPainter {
  _Painter(this.m, this.p, this.cs);
  final GeoMap m;
  final GeoProjector p;
  final ColorScheme cs;

  void _text(Canvas c, String t, Offset o, {Color? color, double size = 11, bool center = false}) {
    final tp = TextPainter(text: TextSpan(text: t, style: TextStyle(color: color ?? cs.onSurface, fontSize: size)), textDirection: TextDirection.ltr)..layout();
    tp.paint(c, center ? o - Offset(tp.width / 2, tp.height / 2) : o);
  }

  @override
  void paint(Canvas c, Size s) {
    c.drawRect(Offset.zero & s, Paint()..color = cs.surfaceContainerHighest);
    // grid with a "nice" step >= ~60px
    const steps = [5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000, 100000];
    final step = steps.firstWhere((x) => x / p.mpp >= 60, orElse: () => steps.last).toDouble();
    final gp = Paint()..color = cs.outlineVariant.withValues(alpha: 0.5)..strokeWidth = 1;
    final px = step / p.mpp;
    final ox = (s.width / 2) % px, oy = (s.height / 2) % px;
    for (double x = ox; x < s.width; x += px) {
      c.drawLine(Offset(x, 0), Offset(x, s.height), gp);
    }
    for (double y = oy; y < s.height; y += px) {
      c.drawLine(Offset(0, y), Offset(s.width, y), gp);
    }
    // fences
    for (final f in m.fences) {
      final o = p.toXY(f.lat, f.lng);
      final inside = m.insideIds.contains(f.id);
      final col = !f.enabled ? Colors.grey : inside ? Colors.green : Colors.blue;
      final r = f.radiusM / p.mpp;
      c.drawCircle(Offset(o.x, o.y), r, Paint()..color = col.withValues(alpha: 0.15));
      c.drawCircle(Offset(o.x, o.y), r, Paint()..color = col..style = PaintingStyle.stroke..strokeWidth = 2);
      _text(c, f.name, Offset(o.x, o.y), center: true, color: col);
    }
    // route
    if (m.route.length > 1) {
      final path = Path();
      final pts = m.route.length > 4000 ? [for (var i = 0; i < m.route.length; i += (m.route.length / 4000).ceil()) m.route[i], m.route.last] : m.route;
      for (var i = 0; i < pts.length; i++) {
        final o = p.toXY(pts[i].lat, pts[i].lng);
        i == 0 ? path.moveTo(o.x, o.y) : path.lineTo(o.x, o.y);
      }
      c.drawPath(path, Paint()..color = Colors.deepPurple..style = PaintingStyle.stroke..strokeWidth = 3..strokeJoin = StrokeJoin.round);
    }
    if (m.route.isNotEmpty) {
      final a = p.toXY(m.route.first.lat, m.route.first.lng), b = p.toXY(m.route.last.lat, m.route.last.lng);
      c.drawCircle(Offset(a.x, a.y), 6, Paint()..color = Colors.green);
      c.drawCircle(Offset(b.x, b.y), 6, Paint()..color = Colors.red);
    }
    // pin (geofence being edited)
    if (m.pin != null) {
      final o = p.toXY(m.pin!.lat, m.pin!.lng);
      final r = (m.pinRadius ?? 0) / p.mpp;
      if (r > 0) {
        c.drawCircle(Offset(o.x, o.y), r, Paint()..color = Colors.orange.withValues(alpha: 0.2));
        c.drawCircle(Offset(o.x, o.y), r, Paint()..color = Colors.orange..style = PaintingStyle.stroke..strokeWidth = 2);
      }
      final lp = Paint()..color = Colors.orange..strokeWidth = 2;
      c.drawLine(Offset(o.x - 10, o.y), Offset(o.x + 10, o.y), lp);
      c.drawLine(Offset(o.x, o.y - 10), Offset(o.x, o.y + 10), lp);
    }
    // current position + accuracy
    if (m.current != null) {
      final o = p.toXY(m.current!.lat, m.current!.lng);
      c.drawCircle(Offset(o.x, o.y), max(m.current!.accuracy / p.mpp, 6), Paint()..color = Colors.blue.withValues(alpha: 0.15));
      c.drawCircle(Offset(o.x, o.y), 7, Paint()..color = Colors.white);
      c.drawCircle(Offset(o.x, o.y), 5, Paint()..color = Colors.blue.shade700);
    }
    // north + scale bar
    _text(c, 'N ↑', Offset(s.width - 30, 6), size: 12);
    final bar = step / p.mpp;
    final y = s.height - 16;
    final sp = Paint()..color = cs.onSurface..strokeWidth = 2;
    c.drawLine(Offset(10, y), Offset(10 + bar, y), sp);
    c.drawLine(Offset(10, y - 4), Offset(10, y + 4), sp);
    c.drawLine(Offset(10 + bar, y - 4), Offset(10 + bar, y + 4), sp);
    _text(c, step >= 1000 ? '${(step / 1000).toStringAsFixed(step % 1000 == 0 ? 0 : 1)} km' : '${step.round()} m', Offset(14, y - 16));
  }

  @override
  bool shouldRepaint(covariant _Painter o) => true;
}
