import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';
import 'core.dart';
import 'models.dart';

/// In-memory index over a Hive CE box. Records are persisted as JSON strings
/// (no generated adapters), keyed by stable UUID. Writes are role-checked here,
/// i.e. in the data layer, not only in the UI.
class Collection<T> {
  Collection(this._db, this.name, this._box, this._from, this._to, this._id, this.minWriteRank);
  final Db _db;
  final String name;
  final Box<String> _box;
  final T Function(Map<String, dynamic>) _from;
  final Map<String, dynamic> Function(T) _to;
  final String Function(T) _id;
  final int minWriteRank;
  final Map<String, T> _m = {};

  void load() {
    for (final k in _box.keys) {
      try {
        _m[k as String] = _from(jsonDecode(_box.get(k)!) as Map<String, dynamic>);
      } catch (_) {
        _db.corruptRecords++;
      }
    }
  }

  List<T> get all => _m.values.toList();
  Iterable<T> get values => _m.values;
  int get length => _m.length;
  T? get(String? id) => id == null ? null : _m[id];

  void _check() {
    if (_db.role.rank < minWriteRank) throw PermissionDenied(name);
  }

  Future<void> put(T v) async {
    _check();
    await _box.put(_id(v), jsonEncode(_to(v)));
    _m[_id(v)] = v;
    _db.touch();
  }

  Future<void> putAll(Iterable<T> vs) async {
    _check();
    final list = vs.toList();
    await _box.putAll({for (final v in list) _id(v): jsonEncode(_to(v))});
    for (final v in list) {
      _m[_id(v)] = v;
    }
    _db.touch();
  }

  Future<void> delete(String id) async {
    _check();
    await _box.delete(id);
    _m.remove(id);
    _db.touch();
  }

  Future<void> deleteAll(Iterable<String> ids) async {
    _check();
    final l = ids.toList();
    await _box.deleteAll(l);
    for (final i in l) {
      _m.remove(i);
    }
    _db.touch();
  }

  Future<void> clear() async {
    _check();
    await _box.clear();
    _m.clear();
    _db.touch();
  }
}

class Db extends ChangeNotifier {
  Db._();
  static const schemaVersion = 2;
  late final String dir;
  late final Box<String> _settingsBox, _auditBox;
  late final Collection<Employee> employees;
  late final Collection<Team> teams;
  late final Collection<Lead> leads;
  late final Collection<CallRecord> calls;
  late final Collection<FollowUp> followUps;
  late final Collection<ExcludedNumber> excluded;
  late final Collection<ExportHistory> exports;
  late final Collection<GeoFence> fences;
  late final Collection<LocationPoint> points;
  late final Collection<GeoEvent> geoEvents;
  late final Collection<TrackingSession> sessions;
  Settings settings = Settings();
  int corruptRecords = 0;
  int version = 0;

  Role get role => roleFrom(settings.role);

  /// [dir] is the application's private storage directory.
  static Future<Db> open(String dir) async {
    final db = Db._();
    db.dir = dir;
    Hive.init('$dir/hive');
    Future<Box<String>> b(String n) => Hive.openBox<String>(n);
    db._settingsBox = await b('app_settings');
    db._auditBox = await b('audit_events');
    await db._migrate();
    final raw = db._settingsBox.get('settings');
    if (raw != null) db.settings = Settings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    db.employees = Collection(db, 'employees', await b('employees'), Employee.fromJson,
        (e) => e.toJson(), (e) => e.id, Role.admin.rank);
    db.teams = Collection(db, 'teams', await b('teams'), Team.fromJson, (e) => e.toJson(),
        (e) => e.id, Role.admin.rank);
    db.leads = Collection(db, 'leads', await b('leads'), Lead.fromJson, (e) => e.toJson(),
        (e) => e.id, Role.employee.rank);
    db.calls = Collection(db, 'call_records', await b('call_records'), CallRecord.fromJson,
        (e) => e.toJson(), (e) => e.id, Role.employee.rank);
    db.followUps = Collection(db, 'follow_ups', await b('follow_ups'), FollowUp.fromJson,
        (e) => e.toJson(), (e) => e.id, Role.employee.rank);
    db.excluded = Collection(db, 'excluded_numbers', await b('excluded_numbers'),
        ExcludedNumber.fromJson, (e) => e.toJson(), (e) => e.id, Role.manager.rank);
    db.exports = Collection(db, 'export_history', await b('export_history'),
        ExportHistory.fromJson, (e) => e.toJson(), (e) => e.id, Role.readOnly.rank + 1);
    db.fences = Collection(db, 'geofences', await b('geofences'), GeoFence.fromJson, (e) => e.toJson(),
        (e) => e.id, Role.manager.rank);
    db.points = Collection(db, 'location_points', await b('location_points'), LocationPoint.fromJson,
        (e) => e.toJson(), (e) => e.id, Role.employee.rank);
    db.geoEvents = Collection(db, 'geo_events', await b('geo_events'), GeoEvent.fromJson,
        (e) => e.toJson(), (e) => e.id, Role.employee.rank);
    db.sessions = Collection(db, 'tracking_sessions', await b('tracking_sessions'),
        TrackingSession.fromJson, (e) => e.toJson(), (e) => e.id, Role.employee.rank);
    for (final c in [db.employees, db.teams, db.leads, db.calls, db.followUps, db.excluded, db.exports,
      db.fences, db.points, db.geoEvents, db.sessions]) {
      c.load();
    }
    return db;
  }

  Future<void> _migrate() async {
    var v = int.tryParse(_settingsBox.get('schema') ?? '') ?? 0;
    if (v > schemaVersion) {
      throw StateError('Database schema v$v is newer than this app (v$schemaVersion).');
    }
    while (v < schemaVersion) {
      switch (v) {
        case 0: // v1: initial layout, nothing to transform.
          break;
        case 1: // v2: adds location boxes (created empty on open); no data transform.
          break;
      }
      v++;
    }
    await _settingsBox.put('schema', '$schemaVersion');
  }

  void touch() {
    version++;
    notifyListeners();
  }

  Future<void> saveSettings() async {
    if (role.rank < Role.manager.rank && settings.onboarded) throw PermissionDenied('settings');
    await _settingsBox.put('settings', jsonEncode(settings.toJson()));
    touch();
  }

  /// Writes settings without a role check (used by onboarding / role switch by an admin).
  Future<void> saveSettingsForce() async {
    await _settingsBox.put('settings', jsonEncode(settings.toJson()));
    touch();
  }

  Future<void> audit(String entity, String id, String action, [String detail = '']) async {
    final key = '${DateTime.now().toUtc().microsecondsSinceEpoch}-$id';
    await _auditBox.put(key, jsonEncode({
      'at': sd(DateTime.now()), 'entity': entity, 'id': id, 'action': action, 'detail': detail,
    }));
  }

  List<Map<String, dynamic>> auditFor(String id) => _auditBox.values
      .map((s) => jsonDecode(s) as Map<String, dynamic>)
      .where((m) => m['id'] == id)
      .toList();

  Set<String> get excludedKeys =>
      excluded.values.where((e) => e.active).map((e) => phoneKey(e.phone)).toSet();

  /// Relationship / integrity check.
  Map<String, int> health() {
    final empIds = employees.values.map((e) => e.id).toSet();
    final leadIds = leads.values.map((e) => e.id).toSet();
    return {
      'employees': employees.length, 'teams': teams.length, 'leads': leads.length,
      'calls': calls.length, 'followUps': followUps.length, 'excludedNumbers': excluded.length, 'geofences': fences.length, 'locationPoints': points.length,
      'corruptRecords': corruptRecords,
      'callsWithMissingLead': calls.values.where((c) => c.leadId != null && !leadIds.contains(c.leadId)).length,
      'callsWithMissingEmployee': calls.values.where((c) => c.employeeId != null && !empIds.contains(c.employeeId)).length,
      'followUpsWithMissingLead': followUps.values.where((f) => !leadIds.contains(f.leadId)).length,
    };
  }

  Future<void> wipeBusinessData() async {
    for (final c in [leads, calls, followUps, excluded]) {
      await c.clear();
    }
    settings.lastNativeMs = 0;
    await saveSettingsForce();
  }

  Future<void> close() => Hive.close();
}
