import 'dart:io';
import 'package:intl/intl.dart';
import '../core.dart';
import '../db.dart';
import '../models.dart';
import 'analytics.dart';

class ReportFilter {
  ReportFilter({required this.range, this.employeeId, this.applyExclusions = true,
      this.maskPhones = false, this.neverDays = 0});
  Range range;
  String? employeeId;
  bool applyExclusions, maskPhones;
  int neverDays;
}

class ReportTable {
  ReportTable(this.title, this.headers, this.rows);
  final String title;
  final List<String> headers;
  final List<List<Object?>> rows;
}

const reportTypes = {
  'calls': 'Call history',
  'employees': 'Employee performance',
  'leads': 'Lead list',
  'followups': 'Follow-ups',
  'never': 'Leads not contacted',
  'notconnected': 'Leads not connected',
};

String _dt(DateTime? d) => d == null ? '' : DateFormat('yyyy-MM-dd HH:mm').format(d.toLocal());

ReportTable buildReport(Db db, String type, ReportFilter f) {
  String emp(String? id) => db.employees.get(id)?.name ?? '';
  String ph(String p) => f.maskPhones ? maskPhone(p) : p;
  final ex = f.applyExclusions ? db.excludedKeys : <String>{};
  final calls = db.calls.values
      .where((c) => f.range.contains(c.start) && (f.employeeId == null || c.employeeId == f.employeeId) && !ex.contains(c.key))
      .toList()
    ..sort((a, b) => b.start.compareTo(a.start));
  final leadsAll = db.leads.values.where((l) => f.employeeId == null || l.assignedEmployeeId == f.employeeId);

  switch (type) {
    case 'calls':
      return ReportTable('Call history', [
        'Date', 'Phone', 'Name', 'Direction', 'Outcome', 'Duration (s)', 'Employee', 'Lead', 'Follow-up needed', 'Notes'
      ], [
        for (final c in calls)
          [_dt(c.start), ph(c.phone), c.contactName, c.direction, c.outcome, c.durationSec,
           emp(c.employeeId), db.leads.get(c.leadId)?.name ?? '', c.needsFollowUp ? 'Yes' : 'No', c.notes]
      ]);
    case 'employees':
      final rows = employeePerformance(db.employees.values, calls, db.followUps.values, db.settings, f.range);
      return ReportTable('Employee performance', [
        'Employee', 'Total', 'Incoming', 'Outgoing', 'Missed', 'Connected', 'Connected duration (s)',
        'Avg connected (s)', 'Connection rate %', 'Calls in working hours', 'Calls outside working hours',
        'Leads contacted', 'Follow-ups done', 'Follow-ups total'
      ], [
        for (final r in rows)
          [r.employee.name, r.stats.total, r.stats.incoming, r.stats.outgoing, r.stats.missed, r.stats.connected,
           r.stats.connectedSeconds, r.stats.avgConnected.round(),
           r.stats.connectionRate?.toStringAsFixed(1) ?? 'n/a', r.stats.inHours, r.stats.outHours,
           r.leadsContacted, r.fuDone, r.fuTotal]
      ]);
    case 'leads':
      return ReportTable('Lead list', [
        'Name', 'Phone', 'Email', 'Company', 'City', 'Source', 'Status', 'Priority', 'Assigned to',
        'Created', 'Last contacted', 'Last connected', 'Next follow-up', 'Tags', 'Archived'
      ], [
        for (final l in leadsAll)
          [l.name, ph(l.phone), l.email, l.company, l.city, l.source, l.status, l.priority, emp(l.assignedEmployeeId),
           _dt(l.createdAt), _dt(l.lastContactedAt), _dt(l.lastConnectedAt), _dt(l.nextFollowUp), l.tags.join(';'),
           l.archived ? 'Yes' : 'No']
      ]);
    case 'followups':
      return ReportTable('Follow-ups', [
        'Due', 'Lead', 'Employee', 'Priority', 'Type', 'Status', 'Description', 'Completed', 'Outcome'
      ], [
        for (final x in db.followUps.values.where((x) => f.range.contains(x.dueAt) && (f.employeeId == null || x.employeeId == f.employeeId)))
          [_dt(x.dueAt), db.leads.get(x.leadId)?.name ?? '', emp(x.employeeId), x.priority, x.type, x.label,
           x.description, _dt(x.completedAt), x.outcome]
      ]);
    case 'never':
      var l = leadsNeverContacted(leadsAll, db.calls.values);
      if (f.neverDays > 0) {
        final cut = DateTime.now().toUtc().subtract(Duration(days: f.neverDays));
        l = [...l, ...leadsAll.where((x) => !x.archived && !x.closed && x.lastContactedAt != null && x.lastContactedAt!.isBefore(cut))];
      }
      return ReportTable('Leads not contacted', ['Name', 'Phone', 'Status', 'Assigned to', 'Created', 'Last contacted'],
          [for (final x in l) [x.name, ph(x.phone), x.status, emp(x.assignedEmployeeId), _dt(x.createdAt), _dt(x.lastContactedAt)]]);
    case 'notconnected':
      final l = leadsNotConnected(leadsAll, db.calls.values);
      return ReportTable('Leads not connected',
          ['Name', 'Phone', 'Status', 'Assigned to', 'Attempts (known outcome)', 'Last attempt', 'Next follow-up'], [
        for (final x in l)
          () {
            final s = leadCallSummary(x.id, db.calls.values);
            return <Object?>[x.name, ph(x.phone), x.status, emp(x.assignedEmployeeId), s.attempts, _dt(s.lastAttempt), _dt(x.nextFollowUp)];
          }()
      ]);
  }
  throw ArgumentError('Unknown report $type');
}

/// Writes a UTF-8 CSV (with BOM, Excel compatible). Never labelled XLSX.
Future<File> writeCsv(Db db, ReportTable t, List<int> columnIdx, String slug) async {
  final dir = Directory('${db.dir}/exports');
  await dir.create(recursive: true);
  final f = File('${dir.path}/${slug}_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.csv');
  final csv = toCsv([for (final i in columnIdx) t.headers[i]],
      [for (final r in t.rows) [for (final i in columnIdx) r[i]]]);
  await f.writeAsString(csv, flush: true);
  return f;
}
