import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:galleontrack/core.dart';
import 'package:galleontrack/db.dart';
import 'package:galleontrack/models.dart';
import 'package:galleontrack/services/ops.dart';
import 'package:galleontrack/services/packages.dart';

Future<Db> open(Directory d) => Db.open(d.path);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('gt_test'));
  tearDown(() async {
    await Hive0.close();
    dir.deleteSync(recursive: true);
  });

  test('CRUD and restart persistence', () async {
    var db = await open(dir);
    await db.leads.put(Lead(name: 'Asha', phone: '9876543210'));
    await db.close();
    db = await open(dir);
    expect(db.leads.length, 1);
    expect(db.leads.values.first.name, 'Asha');
    expect(db.health()['corruptRecords'], 0);
  });

  test('role checks are enforced in the data layer', () async {
    final db = await open(dir);
    db.settings.role = 'readOnly';
    expect(() => db.leads.put(Lead(name: 'x', phone: '9876543210')), throwsA(isA<PermissionDenied>()));
    db.settings.role = 'employee';
    await db.leads.put(Lead(name: 'x', phone: '9876543210'));
    expect(() => db.employees.put(Employee(name: 'e')), throwsA(isA<PermissionDenied>()));
  });

  test('repeated import does not duplicate and links leads', () async {
    final db = await open(dir);
    final ops = Ops(db);
    await db.leads.put(Lead(name: 'Asha', phone: '+91 98765 43210'));
    final raw = [
      {'id': '1', 'number': '09876543210', 'name': '', 'type': 2, 'date': 1760000000000, 'duration': 45},
      {'id': '2', 'number': '09876543210', 'name': '', 'type': 3, 'date': 1760000100000, 'duration': 0},
    ];
    final r1 = await ops.importNative(raw);
    final r2 = await ops.importNative(raw);
    expect(r1.added, 2);
    expect(r1.linked, 2);
    expect(r2.added, 0);
    expect(r2.duplicates, 2);
    expect(db.calls.length, 2);
    final lead = db.leads.values.first;
    expect(lead.lastConnectedAt, isNotNull);
  });

  test('round-robin is deterministic and respects limits', () async {
    final db = await open(dir);
    final ops = Ops(db);
    for (final n in ['Cara', 'Asha', 'Bilal']) {
      await db.employees.put(Employee(name: n));
    }
    final leads = [for (var i = 0; i < 6; i++) Lead(name: 'L$i', phone: '98765432${10 + i}')];
    await db.leads.putAll(leads);
    await ops.roundRobin(leads);
    final names = leads.map((l) => db.employees.get(l.assignedEmployeeId)!.name).toList();
    expect(names, ['Asha', 'Bilal', 'Cara', 'Asha', 'Bilal', 'Cara']);

    db.settings.maxActiveLeads = 2;
    final more = [Lead(name: 'M', phone: '9000000001')];
    await db.leads.putAll(more);
    final given = await ops.roundRobin(more);
    expect(given, isEmpty); // everyone at capacity
    expect(more.first.assignedEmployeeId, isNull);
  });

  test('closing a lead cancels open follow-ups', () async {
    final db = await open(dir);
    final ops = Ops(db);
    final l = Lead(name: 'A', phone: '9876543210');
    await db.leads.put(l);
    await ops.saveFollowUp(FollowUp(leadId: l.id, dueAt: DateTime.now().add(const Duration(days: 1)).toUtc()));
    expect(db.leads.get(l.id)!.nextFollowUp, isNotNull);
    await ops.setStatus(l, 'Won');
    expect(db.followUps.values.single.status, 'cancelled');
    expect(db.leads.get(l.id)!.nextFollowUp, isNull);
    expect(l.statusHistory.length, 2);
  });

  test('backup, validation and restore', () async {
    final db = await open(dir);
    final ops = Ops(db);
    await ops.createDemoData();
    final pkg = buildPackage(db, categoryLabels.keys.toSet());
    final parsed = parsePackage(pkg.bytes);
    expect(parsed.counts['leads'], 12);
    expect(parsed.data.containsKey('settings'), true);
    expect((parsed.data['settings']!.first as Map).containsKey('serverUrl'), false);

    await db.wipeBusinessData();
    expect(db.leads.length, 0);
    await applyStaged(db, parsed, stage(parsed), replace: true);
    expect(db.leads.length, 12);
    expect(db.calls.length, 60);
    expect(db.health()['callsWithMissingLead'], 0);

    expect(() => parsePackage([1, 2, 3]), throwsA(isA<PackageException>()));
  });

  test('server package contains only selected categories', () async {
    final db = await open(dir);
    await Ops(db).createDemoData();
    final pkg = buildPackage(db, {'leads'}, forServer: true, purpose: 'server-export');
    expect(pkg.manifest['categories'], ['leads']);
    final parsed = parsePackage(pkg.bytes);
    expect(parsed.data.keys, ['leads']);
  });
}

// ignore: camel_case_types
class Hive0 {
  static Future<void> close() async {
    try {
      await Hive.close();
    } catch (_) {}
  }
}
