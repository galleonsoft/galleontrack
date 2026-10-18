import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core.dart';
import '../models.dart';
import '../services/analytics.dart';
import 'widgets.dart';
import 'call_import.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});
  @override
  ConsumerState<DashboardScreen> createState() => _DashState();
}

class _DashState extends ConsumerState<DashboardScreen> {
  Period period = Period.today;
  Range? custom;
  String? employeeId, teamId;

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(dbProvider);
    final s = db.settings;
    final r = rangeFor(period, DateTime.now(), weekStart: s.weekStart, custom: custom);
    final ex = db.excludedKeys;
    final teamEmps = teamId == null ? null : db.employees.values.where((e) => e.teamId == teamId).map((e) => e.id).toSet();
    final calls = db.calls.values.where((c) =>
        r.contains(c.start) && !ex.contains(c.key) &&
        (employeeId == null || c.employeeId == employeeId) &&
        (teamEmps == null || teamEmps.contains(c.employeeId))).toList();
    final st = computeStats(calls, s);
    final fus = db.followUps.values.toList();
    final fuDue = fus.where((f) => f.open && f.dueAt.isBefore(DateTime.now().toUtc())).length;
    final fuIn = fus.where((f) => r.contains(f.dueAt) && f.status != 'cancelled').toList();
    final fuDone = fuIn.where((f) => f.status == 'completed').length;
    final never = leadsNeverContacted(db.leads.values, db.calls.values).length;
    final notConn = leadsNotConnected(db.leads.values, db.calls.values).length;
    final needFu = calls.where((c) => c.needsFollowUp).length;
    final perf = employeePerformance(db.employees.values.where((e) => e.active), calls, db.followUps.values, s, r)
      ..sort((a, b) => b.stats.total.compareTo(a.stats.total));
    final freq = <String, int>{};
    for (final c in calls) {
      final k = c.contactName.isNotEmpty ? '${c.contactName}' : c.phone;
      freq[k] = (freq[k] ?? 0) + 1;
    }
    final top = (freq.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(5);
    final leadDist = <String, int>{};
    for (final l in db.leads.values.where((l) => !l.archived)) {
      leadDist[l.status] = (leadDist[l.status] ?? 0) + 1;
    }
    final daily = bucketCounts(calls, r, (_) => true);
    final missed = bucketCounts(calls, r, (c) => c.direction == Dir.missed);
    String pct(double? v) => v == null ? 'n/a' : '${v.toStringAsFixed(0)}%';

    return Scaffold(
      appBar: AppBar(
        title: Text(s.workspace.isEmpty ? 'Dashboard' : s.workspace),
        actions: [
          IconButton(tooltip: 'Import device calls', icon: const Icon(Icons.sync), onPressed: () => importDeviceCalls(context, ref)),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final p in Period.values)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(periodLabels[p]!),
                  selected: period == p,
                  onSelected: (_) async {
                    if (p == Period.custom) {
                      final x = await pickRange(context, custom);
                      if (x == null) return;
                      custom = rangeFromPicker(x);
                    }
                    setState(() => period = p);
                  },
                ),
              ),
          ]),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String?>(
              value: employeeId, isExpanded: true,
              decoration: const InputDecoration(labelText: 'Employee'),
              items: [const DropdownMenuItem(value: null, child: Text('All employees')), for (final e in db.employees.values) DropdownMenuItem(value: e.id, child: Text(e.name))],
              onChanged: (v) => setState(() => employeeId = v),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonFormField<String?>(
              value: teamId, isExpanded: true,
              decoration: const InputDecoration(labelText: 'Team'),
              items: [const DropdownMenuItem(value: null, child: Text('All teams')), for (final t in db.teams.values) DropdownMenuItem(value: t.id, child: Text(t.name))],
              onChanged: (v) => setState(() => teamId = v),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        if (db.calls.length == 0 && db.leads.length == 0)
          const SizedBox(height: 240, child: EmptyState(Icons.insights, 'No data yet. Import device calls, add a call manually or create your first lead.')),
        GridView.count(
          crossAxisCount: MediaQuery.of(context).size.width > 700 ? 4 : 2,
          shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 2.2, mainAxisSpacing: 8, crossAxisSpacing: 8,
          children: [
            StatCard('Total calls', '${st.total}', Icons.call),
            StatCard('Incoming', '${st.incoming}', Icons.call_received, color: Colors.green.shade700),
            StatCard('Outgoing', '${st.outgoing}', Icons.call_made, color: Colors.blue.shade700),
            StatCard('Connected', '${st.connected}', Icons.phone_in_talk, color: Colors.teal),
            StatCard('Missed', '${st.missed}', Icons.call_missed, color: Colors.red.shade700),
            StatCard('Rejected', '${st.rejected}', Icons.call_end, color: Colors.orange.shade800),
            StatCard('Unanswered outgoing', '${st.unansweredOutgoing}', Icons.phone_missed),
            StatCard('Connected time', fmtDuration(st.connectedSeconds), Icons.timer),
            StatCard('Avg connected', fmtDuration(st.avgConnected), Icons.av_timer),
            StatCard('Connection rate', pct(st.connectionRate), Icons.percent),
            StatCard('Calls needing follow-up', '$needFu', Icons.flag),
            StatCard('Overdue follow-ups', '$fuDue', Icons.alarm, color: Colors.red.shade700),
            StatCard('Leads never contacted', '$never', Icons.person_off),
            StatCard('Leads not connected', '$notConn', Icons.link_off),
            StatCard('Active employees', '${db.employees.values.where((e) => e.active).length}', Icons.badge),
            StatCard('Follow-up completion', fuIn.isEmpty ? 'n/a' : '${(fuDone * 100 / fuIn.length).round()}%', Icons.task_alt),
          ],
        ),
        Section('Calling activity', VBars(daily.values, daily.labels)),
        Section('Missed-call trend', VBars(missed.values, missed.labels, color: Colors.red.shade700)),
        Section('Incoming vs outgoing', HBars({'Incoming': st.incoming, 'Outgoing': st.outgoing, 'Missed': st.missed, 'Rejected': st.rejected})),
        Section('Call duration distribution (connected)', HBars(durationBuckets(calls))),
        Section('Working hours', Text(
            'Schedule: ${_hm(s.workStartMin)}–${_hm(s.workEndMin)}, ${s.workDays.length} days/week\n'
            'Calls in working hours: ${st.inHours} • outside: ${st.outHours}\n'
            'Connected time in working hours: ${fmtDuration(st.connectedSecondsInHours)}\n'
            'First / last observed call in working hours: ${st.firstInHours == null ? '—' : fmtDt(st.firstInHours)} / ${st.lastInHours == null ? '—' : fmtDt(st.lastInHours)}\n'
            'Call duration is not employee working time.')),
        Section('Employee comparison (calls)', HBars({for (final p in perf.take(8)) p.employee.name: p.stats.total})),
        Section('Lead status distribution', HBars(leadDist)),
        Section('Most frequently contacted', top.isEmpty ? const Text('No calls in this period') : Column(children: [for (final e in top) ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text(e.key), trailing: Text('${e.value}'))])),
      ]),
    );
  }

  String _hm(int m) => '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
}
