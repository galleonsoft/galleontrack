import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import '../core.dart';
import '../db.dart';
import '../models.dart';

const packageFormat = 'galleontrack-package';
const appVersion = '1.0.0';

const categoryLabels = {
  'settings': 'Workspace settings',
  'employees': 'Employees',
  'teams': 'Teams',
  'leads': 'Leads (incl. status history)',
  'calls': 'Call records',
  'follow_ups': 'Follow-ups',
  'excluded_numbers': 'Excluded numbers',
};

class BuiltPackage {
  BuiltPackage(this.bytes, this.manifest);
  final Uint8List bytes;
  final Map<String, dynamic> manifest;
  Map<String, int> get counts => Map<String, int>.from(manifest['counts'] as Map);
}

Map<String, List<Map<String, dynamic>>> collect(Db db, Set<String> cats,
    {Range? range, Set<String>? employeeIds, bool forServer = false}) {
  bool empOk(String? id) => employeeIds == null || employeeIds.isEmpty || (id != null && employeeIds.contains(id));
  final out = <String, List<Map<String, dynamic>>>{};
  if (cats.contains('settings')) {
    final s = db.settings.toJson()
      ..remove('serverUrl'); // never exported
    if (forServer) s.remove('defaultEmployeeId');
    out['settings'] = [s];
  }
  if (cats.contains('employees')) {
    out['employees'] = [for (final e in db.employees.values.where((e) => empOk(e.id))) e.toJson()];
  }
  if (cats.contains('teams')) out['teams'] = [for (final t in db.teams.values) t.toJson()];
  if (cats.contains('leads')) {
    out['leads'] = [for (final l in db.leads.values.where((l) => empOk(l.assignedEmployeeId))) l.toJson()];
  }
  if (cats.contains('calls')) {
    out['calls'] = [
      for (final c in db.calls.values.where((c) => empOk(c.employeeId) && (range == null || range.contains(c.start)))) c.toJson()
    ];
  }
  if (cats.contains('follow_ups')) {
    out['follow_ups'] = [
      for (final f in db.followUps.values.where((f) => empOk(f.employeeId) && (range == null || range.contains(f.dueAt)))) f.toJson()
    ];
  }
  if (cats.contains('excluded_numbers')) out['excluded_numbers'] = [for (final e in db.excluded.values) e.toJson()];
  return out;
}

/// Builds a versioned ZIP: manifest.json + one JSON file per selected category.
BuiltPackage buildPackage(Db db, Set<String> cats,
    {Range? range, Set<String>? employeeIds, bool forServer = false, String? exportId, String purpose = 'backup'}) {
  final data = collect(db, cats, range: range, employeeIds: employeeIds, forServer: forServer);
  final archive = Archive();
  final files = <Map<String, dynamic>>[];
  data.forEach((k, v) {
    final b = utf8.encode(jsonEncode(v));
    archive.addFile(ArchiveFile('$k.json', b.length, b));
    files.add({'name': '$k.json', 'bytes': b.length});
  });
  final manifest = <String, dynamic>{
    'format': packageFormat,
    'exportId': exportId ?? newId(),
    'schemaVersion': Db.schemaVersion,
    'appVersion': appVersion,
    'purpose': purpose,
    'createdAt': sd(DateTime.now()),
    'categories': data.keys.toList(),
    'counts': {for (final e in data.entries) e.key: e.value.length},
    'files': files,
    'range': range == null ? null : {'from': sd(range.from), 'to': sd(range.to)},
  };
  final mb = utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest));
  archive.addFile(ArchiveFile('manifest.json', mb.length, mb));
  final zip = ZipEncoder().encode(archive)!;
  return BuiltPackage(Uint8List.fromList(zip), manifest);
}

class ParsedPackage {
  ParsedPackage(this.manifest, this.data);
  final Map<String, dynamic> manifest;
  final Map<String, List<dynamic>> data;
  Map<String, int> get counts => {for (final e in data.entries) e.key: e.value.length};
}

class PackageException implements Exception {
  PackageException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Validates manifest, schema version, file presence and record counts.
ParsedPackage parsePackage(List<int> bytes) {
  final Archive a;
  try {
    a = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw PackageException('Not a valid ZIP archive.');
  }
  final mf = a.findFile('manifest.json');
  if (mf == null) throw PackageException('manifest.json is missing.');
  final Map<String, dynamic> manifest;
  try {
    manifest = jsonDecode(utf8.decode(mf.content as List<int>)) as Map<String, dynamic>;
  } catch (_) {
    throw PackageException('manifest.json is not valid JSON.');
  }
  if (manifest['format'] != packageFormat) throw PackageException('Unknown package format.');
  final sv = manifest['schemaVersion'];
  if (sv is! int || sv > Db.schemaVersion || sv < 1) {
    throw PackageException('Unsupported schema version: $sv.');
  }
  final data = <String, List<dynamic>>{};
  final counts = Map<String, dynamic>.from(manifest['counts'] as Map? ?? {});
  for (final cat in List<String>.from(manifest['categories'] as List? ?? [])) {
    if (!categoryLabels.containsKey(cat)) throw PackageException('Unknown category: $cat');
    final f = a.findFile('$cat.json');
    if (f == null) throw PackageException('$cat.json is missing.');
    final list = jsonDecode(utf8.decode(f.content as List<int>));
    if (list is! List) throw PackageException('$cat.json is malformed.');
    if (counts[cat] != list.length) throw PackageException('Record count mismatch in $cat.json.');
    data[cat] = list;
  }
  return ParsedPackage(manifest, data);
}

typedef Staged = ({
  List<Employee> employees, List<Team> teams, List<Lead> leads, List<CallRecord> calls,
  List<FollowUp> followUps, List<ExcludedNumber> excluded, Map<String, dynamic>? settings
});

/// Stage 1: decode everything into model objects. Throws before touching the DB.
Staged stage(ParsedPackage p) {
  List<T> conv<T>(String k, T Function(Map<String, dynamic>) f) {
    try {
      return [for (final e in p.data[k] ?? const []) f(Map<String, dynamic>.from(e as Map))];
    } catch (e) {
      throw PackageException('Invalid record in $k.json.');
    }
  }
  return (
    employees: conv('employees', Employee.fromJson), teams: conv('teams', Team.fromJson),
    leads: conv('leads', Lead.fromJson), calls: conv('calls', CallRecord.fromJson),
    followUps: conv('follow_ups', FollowUp.fromJson),
    excluded: conv('excluded_numbers', ExcludedNumber.fromJson),
    settings: (p.data['settings']?.isNotEmpty ?? false) ? Map<String, dynamic>.from(p.data['settings']!.first as Map) : null,
  );
}

/// Stage 2: apply. replace=true clears only the categories contained in the package.
/// A safety backup of the current data should be written by the caller first.
Future<void> applyStaged(Db db, ParsedPackage p, Staged s, {required bool replace}) async {
  if (replace) {
    if (p.data.containsKey('calls')) await db.calls.clear();
    if (p.data.containsKey('leads')) await db.leads.clear();
    if (p.data.containsKey('follow_ups')) await db.followUps.clear();
    if (p.data.containsKey('employees')) await db.employees.clear();
    if (p.data.containsKey('teams')) await db.teams.clear();
    if (p.data.containsKey('excluded_numbers')) await db.excluded.clear();
  }
  await db.teams.putAll(s.teams);
  await db.employees.putAll(s.employees);
  await db.leads.putAll(s.leads);
  await db.calls.putAll(s.calls);
  await db.followUps.putAll(s.followUps);
  await db.excluded.putAll(s.excluded);
  if (s.settings != null) {
    final keep = db.settings;
    final n = Settings.fromJson(s.settings!);
    n.serverUrl = keep.serverUrl;
    n.role = keep.role;
    n.onboarded = true;
    n.defaultEmployeeId = keep.defaultEmployeeId.isNotEmpty ? keep.defaultEmployeeId : n.defaultEmployeeId;
    db.settings = n;
    await db.saveSettingsForce();
  }
}

Future<File> writeBackup(Db db, Set<String> cats, {String prefix = 'backup'}) async {
  final pkg = buildPackage(db, cats, purpose: 'backup');
  final dir = Directory('${db.dir}/backups');
  await dir.create(recursive: true);
  final ts = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
  final f = File('${dir.path}/galleontrack_${prefix}_$ts.zip');
  await f.writeAsBytes(pkg.bytes, flush: true);
  db.settings.lastBackup = DateTime.now().toUtc();
  await db.saveSettingsForce();
  return f;
}

List<File> listBackups(Db db) {
  final d = Directory('${db.dir}/backups');
  if (!d.existsSync()) return [];
  return d.listSync().whereType<File>().where((f) => f.path.endsWith('.zip')).toList()
    ..sort((a, b) => b.path.compareTo(a.path));
}
