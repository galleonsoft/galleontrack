import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core.dart';
import '../db.dart';
import '../models.dart';
import '../services/call_log_service.dart';
import '../services/geo.dart';
import '../services/reports.dart';
import 'geo_map.dart';
import 'widgets.dart';

class LocationScreen extends ConsumerWidget {
  const LocationScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => DefaultTabController(
        length: 3,
        child: Scaffold(
          appBar: AppBar(title: const Text('Location & geofences'), bottom: const TabBar(tabs: [Tab(text: 'Live'), Tab(text: 'Geofences'), Tab(text: 'History')])),
          body: const TabBarView(children: [_LiveTab(), _FencesTab(), _HistoryTab()]),
        ),
      );
}

class _LiveTab extends ConsumerWidget {
  const _LiveTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(dbProvider);
    final svc = ref.watch(locationProvider);
    final s = db.settings;
    final l = svc.last;
    Future<void> toggle() async {
      if (svc.tracking) {
        await svc.stop();
        return;
      }
      final ok = await confirm(context, 'Start tracking?',
          'GPS positions are saved only on this device (Hive database) and never uploaded unless you export them.\n\n'
          '${s.locBackground ? 'Background tracking keeps running with a visible notification/indicator while the session is active. It stops if you stop it, the OS ends the app, or permission is revoked.' : 'Tracking will only run while the app is open.'}',
          ok: 'Start');
      if (!ok) return;
      await ref.read(notificationProvider).requestPermission();
      await svc.start();
    }
    return ListView(padding: const EdgeInsets.all(12), children: [
      Section('Current location', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, children: [
          StatusChip(svc.tracking ? 'Tracking active' : 'Tracking stopped', color: svc.tracking ? Colors.green.shade700 : Colors.grey),
          for (final id in svc.insideIds) StatusChip('Inside ${db.fences.get(id)?.name ?? ''}', color: Colors.teal),
        ]),
        const SizedBox(height: 8),
        if (l == null) const Text('No fix yet. Tap "Get location" or start tracking.') else Text(
            'Latitude: ${l.lat.toStringAsFixed(6)}\nLongitude: ${l.lng.toStringAsFixed(6)}\nAccuracy: ±${l.accuracy.round()} m'
            '${l.speed != null ? '\nSpeed: ${(l.speed! * 3.6).toStringAsFixed(1)} km/h' : ''}\nLast update: ${fmtDt(l.at)}'),
        if (svc.error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(svc.error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        if (svc.tracking) Text('This session: ${svc.sessionPoints} points • ${(svc.sessionDistance / 1000).toStringAsFixed(2)} km'),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          FilledButton.icon(icon: Icon(svc.tracking ? Icons.stop : Icons.play_arrow), label: Text(svc.tracking ? 'Stop tracking' : 'Start tracking'), onPressed: svc.busy ? null : () => guard(context, toggle)),
          OutlinedButton.icon(icon: svc.busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.my_location), label: const Text('Get location'), onPressed: svc.busy ? null : svc.refreshCurrent),
        ]),
      ])),
      GeoMap(fences: db.fences.values.toList(), current: l, insideIds: svc.insideIds, height: 280),
      const Padding(padding: EdgeInsets.only(top: 4), child: Text('Offline plot (no street tiles, so no network is used). Green = inside, blue = outside, grey = disabled.', style: TextStyle(fontSize: 11))),
      Section('Tracking settings', Column(children: [
        ListTile(contentPadding: EdgeInsets.zero, title: const Text('Update interval'), trailing: DropdownButton<int>(value: s.locIntervalSec, items: [for (final v in [5, 10, 30, 60, 300]) DropdownMenuItem(value: v, child: Text('${v >= 60 ? '${v ~/ 60} min' : '$v s'}'))], onChanged: (v) async { s.locIntervalSec = v!; await guard(context, db.saveSettings); })),
        ListTile(contentPadding: EdgeInsets.zero, title: const Text('Minimum movement'), trailing: DropdownButton<int>(value: s.locDistanceM, items: [for (final v in [0, 5, 10, 25, 50, 100]) DropdownMenuItem(value: v, child: Text('$v m'))], onChanged: (v) async { s.locDistanceM = v!; await guard(context, db.saveSettings); })),
        ListTile(contentPadding: EdgeInsets.zero, title: const Text('Ignore fixes worse than'), subtitle: const Text('Used for geofence decisions'), trailing: DropdownButton<int>(value: s.locMaxAccuracyM, items: [for (final v in [30, 50, 100, 200]) DropdownMenuItem(value: v, child: Text('±$v m'))], onChanged: (v) async { s.locMaxAccuracyM = v!; await guard(context, db.saveSettings); })),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Background tracking'), subtitle: const Text('Android: foreground service + notification. iOS: background location indicator.'), value: s.locBackground, onChanged: (v) async { s.locBackground = v; await guard(context, db.saveSettings); }),
        if (svc.tracking) const Text('Changes apply to the next tracking session.', style: TextStyle(fontSize: 11)),
      ])),
    ]);
  }
}

class _FencesTab extends ConsumerWidget {
  const _FencesTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(dbProvider);
    final svc = ref.watch(locationProvider);
    final list = db.fences.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final today = rangeFor(Period.today, DateTime.now());
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(icon: const Icon(Icons.add_location_alt), label: const Text('New geofence'), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GeofenceForm()))),
      body: list.isEmpty
          ? const EmptyState(Icons.fence, 'No geofences yet. Create a circular zone to detect entry and exit.')
          : ListView(children: [
              for (final f in list)
                ListTile(
                  leading: Icon(Icons.radio_button_checked, color: !f.enabled ? Colors.grey : svc.insideIds.contains(f.id) ? Colors.green : Colors.blue),
                  title: Text(f.name),
                  subtitle: Text('${f.lat.toStringAsFixed(5)}, ${f.lng.toStringAsFixed(5)} • ${f.radiusM.round()} m\n'
                      'Today inside: ${fmtDur(timeInside(db.geoEvents.values, f.id, today, svc.tracking ? DateTime.now() : (svc.last?.at ?? DateTime.now())))}'),
                  isThreeLine: true,
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => GeofenceForm(fenceId: f.id))),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    Switch(value: f.enabled, onChanged: (v) => guard(context, () async { f.enabled = v; f.updatedAt = DateTime.now().toUtc(); await db.fences.put(f); })),
                    IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => guard(context, () async {
                      if (await confirm(context, 'Delete geofence?', '"${f.name}" is removed. Past events are kept in history.', ok: 'Delete')) {
                        await svc.fenceRemoved(f);
                        await db.fences.delete(f.id);
                      }
                    })),
                  ]),
                ),
            ]),
    );
  }
}

class GeofenceForm extends ConsumerStatefulWidget {
  const GeofenceForm({super.key, this.fenceId});
  final String? fenceId;
  @override
  ConsumerState<GeofenceForm> createState() => _GeofenceFormState();
}

class _GeofenceFormState extends ConsumerState<GeofenceForm> {
  final name = TextEditingController(), lat = TextEditingController(), lng = TextEditingController(), radius = TextEditingController(text: '100');
  bool enabled = true, nEnter = true, nExit = true;
  GeoFence? fence;
  ({double lat, double lng})? center;

  @override
  void initState() {
    super.initState();
    final db = ref.read(dbProvider);
    fence = db.fences.get(widget.fenceId);
    if (fence != null) {
      name.text = fence!.name;
      lat.text = fence!.lat.toString();
      lng.text = fence!.lng.toString();
      radius.text = fence!.radiusM.round().toString();
      enabled = fence!.enabled;
      nEnter = fence!.notifyEnter;
      nExit = fence!.notifyExit;
      center = (lat: fence!.lat, lng: fence!.lng);
    } else {
      final cur = ref.read(locationProvider).last;
      if (cur != null) {
        lat.text = cur.lat.toStringAsFixed(6);
        lng.text = cur.lng.toStringAsFixed(6);
        center = (lat: cur.lat, lng: cur.lng);
      }
    }
  }

  ({double lat, double lng})? get _pin {
    final a = double.tryParse(lat.text), b = double.tryParse(lng.text);
    return a == null || b == null ? null : (lat: a, lng: b);
  }

  @override
  Widget build(BuildContext context) {
    final r = double.tryParse(radius.text) ?? 100;
    return Scaffold(
      appBar: AppBar(title: Text(fence == null ? 'New geofence' : 'Edit geofence')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: TextField(controller: lat, onChanged: (_) => setState(() {}), keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: const InputDecoration(labelText: 'Latitude'))),
          const SizedBox(width: 8),
          Expanded(child: TextField(controller: lng, onChanged: (_) => setState(() {}), keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: const InputDecoration(labelText: 'Longitude'))),
        ]),
        const SizedBox(height: 10),
        TextField(controller: radius, onChanged: (_) => setState(() {}), keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Radius (metres)', helperText: '20 m minimum; GPS accuracy limits very small zones')),
        Wrap(spacing: 8, children: [
          OutlinedButton.icon(icon: const Icon(Icons.my_location), label: const Text('Use current location'), onPressed: () async {
            final svc = ref.read(locationProvider);
            await svc.refreshCurrent();
            final c = svc.last;
            if (c == null) { if (mounted) toast(context, svc.error ?? 'No location available'); return; }
            setState(() { lat.text = c.lat.toStringAsFixed(6); lng.text = c.lng.toStringAsFixed(6); center = (lat: c.lat, lng: c.lng); });
          }),
          OutlinedButton.icon(icon: const Icon(Icons.center_focus_strong), label: const Text('Recenter map'), onPressed: () => setState(() => center = _pin)),
        ]),
        const SizedBox(height: 8),
        if (center != null || _pin != null) GeoMap(
          fences: ref.read(dbProvider).fences.values.where((f) => f.id != fence?.id).toList(),
          fixedCenter: center ?? _pin, fixedHalfSpanM: (r * 3).clamp(300, 200000).toDouble(),
          pin: _pin, pinRadius: r, height: 260,
          onTap: (a, b) => setState(() { lat.text = a.toStringAsFixed(6); lng.text = b.toStringAsFixed(6); }),
        ) else const Text('Enter coordinates or use your current location, then tap the plot to fine-tune the centre.'),
        const Text('Tap the plot to move the centre. The plot is offline (no street tiles).', style: TextStyle(fontSize: 11)),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Enabled'), value: enabled, onChanged: (v) => setState(() => enabled = v)),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Notify on entry'), value: nEnter, onChanged: (v) => setState(() => nEnter = v)),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Notify on exit'), value: nExit, onChanged: (v) => setState(() => nExit = v)),
        FilledButton(onPressed: () => guard(context, () async {
          final a = double.tryParse(lat.text.trim()), b = double.tryParse(lng.text.trim()), rr = double.tryParse(radius.text.trim());
          final err = GeoFence.validate(name.text, a, b, rr);
          if (err != null) { toast(context, err); return; }
          final f = fence ?? GeoFence(name: '', lat: 0, lng: 0, radiusM: 100);
          f..name = name.text.trim()..lat = a!..lng = b!..radiusM = rr!..enabled = enabled..notifyEnter = nEnter..notifyExit = nExit..updatedAt = DateTime.now().toUtc();
          await ref.read(dbProvider).fences.put(f);
          if (context.mounted) Navigator.pop(context);
        }), child: const Text('Save geofence')),
      ]),
    );
  }
}

class _HistoryTab extends ConsumerStatefulWidget {
  const _HistoryTab();
  @override
  ConsumerState<_HistoryTab> createState() => _HistoryState();
}

class _HistoryState extends ConsumerState<_HistoryTab> {
  Period period = Period.today;
  Range? custom;
  String? sessionId;

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(dbProvider);
    final svc = ref.watch(locationProvider);
    final r = rangeFor(period, DateTime.now(), weekStart: db.settings.weekStart, custom: custom);
    final sessions = db.sessions.values.where((s) => r.contains(s.start)).toList()..sort((a, b) => b.start.compareTo(a.start));
    if (sessionId != null && !sessions.any((s) => s.id == sessionId)) sessionId = null;
    final pts = db.points.values.where((p) => r.contains(p.at) && (sessionId == null || p.sessionId == sessionId)).toList()..sort((a, b) => a.at.compareTo(b.at));
    final events = db.geoEvents.values.where((e) => r.contains(e.at) && (sessionId == null || e.sessionId == sessionId)).toList()..sort((a, b) => b.at.compareTo(a.at));
    final cap = svc.tracking ? DateTime.now() : (pts.isEmpty ? DateTime.now() : pts.last.at);
    final rows = [for (final f in db.fences.values) (f, timeInside(events, f.id, r, cap))];
    final dist = routeDistance(pts);
    return ListView(padding: const EdgeInsets.all(12), children: [
      Wrap(spacing: 6, children: [
        for (final p in Period.values) ChoiceChip(label: Text(periodLabels[p]!), selected: period == p, onSelected: (_) async {
          if (p == Period.custom) { final x = await pickRange(context, custom); if (x == null) return; custom = rangeFromPicker(x); }
          setState(() => period = p);
        }),
      ]),
      const SizedBox(height: 8),
      DropdownButtonFormField<String?>(value: sessionId, isExpanded: true, decoration: const InputDecoration(labelText: 'Session'), items: [
        const DropdownMenuItem(value: null, child: Text('All sessions in period')),
        for (final s in sessions) DropdownMenuItem(value: s.id, child: Text('${fmtDt(s.start)} → ${s.end == null ? (svc.session?.id == s.id && svc.tracking ? 'running' : 'interrupted') : fmtDt(s.end)}')),
      ], onChanged: (v) => setState(() => sessionId = v)),
      const SizedBox(height: 8),
      GeoMap(fences: db.fences.values.toList(), route: pts, current: svc.last, insideIds: svc.insideIds, height: 300),
      const Text('Route: green = start, red = end. Offline plot without street tiles.', style: TextStyle(fontSize: 11)),
      Section('Summary', Text('${pts.length} GPS points • ${(dist / 1000).toStringAsFixed(2)} km'
          '${pts.length > 1 ? ' • ${fmtDur(pts.last.at.difference(pts.first.at))} from first to last fix' : ''}\n'
          'Distance is the sum of straight lines between stored fixes; GPS noise can inflate it slightly.')),
      Section('Time inside geofences', db.fences.length == 0 ? const Text('No geofences') : Column(children: [
        for (final e in rows) ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text(e.$1.name), trailing: Text(fmtDur(e.$2))),
      ])),
      Section('Geofence events (${events.length})', events.isEmpty ? const Text('No events in this period') : Column(children: [
        for (final e in events.take(100)) ListTile(dense: true, contentPadding: EdgeInsets.zero,
          leading: Icon(e.type == 'enter' ? Icons.login : e.type == 'exit' ? Icons.logout : Icons.pause_circle_outline, color: e.type == 'enter' ? Colors.green : e.type == 'exit' ? Colors.orange : Colors.grey),
          title: Text('${e.type == 'suspend' ? 'Tracking paused inside' : e.type == 'enter' ? 'Entered' : 'Left'} ${e.fenceName}'), subtitle: Text(fmtDt(e.at))),
        if (events.length > 100) Text('Showing newest 100 of ${events.length}. Export for the full list.'),
      ])),
      Section('Export & data', Wrap(spacing: 8, children: [
        OutlinedButton.icon(icon: const Icon(Icons.route), label: const Text('Points CSV'), onPressed: pts.isEmpty ? null : () => _export(context, db, ReportTable('Location points', ['Time (UTC)', 'Latitude', 'Longitude', 'Accuracy (m)', 'Speed (m/s)', 'Session'], [for (final p in pts) [sd(p.at), p.lat, p.lng, p.accuracy.round(), p.speed?.toStringAsFixed(2) ?? '', p.sessionId ?? '']]), 'location_points')),
        OutlinedButton.icon(icon: const Icon(Icons.fence), label: const Text('Events CSV'), onPressed: events.isEmpty ? null : () => _export(context, db, ReportTable('Geofence events', ['Time (UTC)', 'Geofence', 'Event', 'Latitude', 'Longitude', 'Accuracy (m)'], [for (final e in events.reversed) [sd(e.at), e.fenceName, e.type, e.lat ?? '', e.lng ?? '', e.accuracy?.round() ?? '']]), 'geofence_events')),
        OutlinedButton.icon(icon: const Icon(Icons.timer), label: const Text('Time inside CSV'), onPressed: rows.isEmpty ? null : () => _export(context, db, ReportTable('Time inside', ['Geofence', 'Seconds inside', 'Formatted', 'From', 'To'], [for (final e in rows) [e.$1.name, e.$2.inSeconds, fmtDur(e.$2), fmtDate(r.from), fmtDate(r.to.subtract(const Duration(days: 1)))]]), 'time_inside_geofences')),
        OutlinedButton.icon(icon: const Icon(Icons.delete_sweep), label: const Text('Delete history…'), onPressed: () => _purge(context, db)),
      ])),
    ]);
  }

  Future<void> _export(BuildContext context, Db db, ReportTable t, String slug) => guard(context, () async {
        final f = await writeCsv(db, t, List.generate(t.headers.length, (i) => i), slug);
        if (!context.mounted) return;
        try {
          await Native.shareFile(f.path, 'text/csv');
        } catch (_) {
          if (context.mounted) toast(context, 'Saved to ${f.path}');
        }
      });

  Future<void> _purge(BuildContext context, Db db) => guard(context, () async {
        final days = db.settings.locRetentionDays;
        final choice = await showDialog<String>(context: context, builder: (d) => SimpleDialog(title: const Text('Delete location history'), children: [
          if (days > 0) SimpleDialogOption(onPressed: () => Navigator.pop(d, 'old'), child: Text('Older than $days days (retention setting)')),
          SimpleDialogOption(onPressed: () => Navigator.pop(d, '30'), child: const Text('Older than 30 days')),
          SimpleDialogOption(onPressed: () => Navigator.pop(d, 'all'), child: const Text('Everything (points, events, sessions)')),
        ]));
        if (choice == null || !context.mounted) return;
        if (!await confirm(context, 'Delete location history?', 'This cannot be undone. Geofences are kept.', ok: 'Delete')) return;
        if (choice == 'all') {
          await db.points.clear();
          await db.geoEvents.clear();
          await db.sessions.clear();
        } else {
          final cut = DateTime.now().toUtc().subtract(Duration(days: choice == 'old' ? days : 30));
          await db.points.deleteAll(db.points.values.where((p) => p.at.isBefore(cut)).map((p) => p.id));
          await db.geoEvents.deleteAll(db.geoEvents.values.where((p) => p.at.isBefore(cut)).map((p) => p.id));
          await db.sessions.deleteAll(db.sessions.values.where((s) => s.start.isBefore(cut)).map((s) => s.id));
        }
      });
}
