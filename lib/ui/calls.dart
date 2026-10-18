import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core.dart';
import '../db.dart';
import '../models.dart';
import '../services/analytics.dart';
import '../services/ops.dart';
import '../services/call_log_service.dart';
import '../services/reports.dart';
import 'call_import.dart';
import 'followups.dart';
import 'leads.dart';
import 'widgets.dart';

class CallsScreen extends ConsumerStatefulWidget {
  const CallsScreen({super.key});
  @override
  ConsumerState<CallsScreen> createState() => _CallsState();
}

class _CallsState extends ConsumerState<CallsScreen> {
  String q = '', filter = 'all', sort = 'newest';
  String? employeeId;
  Range? range;
  bool showExcluded = false;
  int page = 100;
  final _sc = ScrollController();

  @override
  void initState() {
    super.initState();
    _sc.addListener(() {
      if (_sc.position.pixels > _sc.position.maxScrollExtent - 400) setState(() => page += 100);
    });
  }

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  bool _match(CallRecord c, Set<String> ex, Db0 db) {
    if (!showExcluded && ex.contains(c.key)) return false;
    if (employeeId != null && c.employeeId != employeeId) return false;
    if (range != null && !range!.contains(c.start)) return false;
    switch (filter) {
      case 'in': if (c.direction != Dir.incoming) return false;
      case 'out': if (c.direction != Dir.outgoing) return false;
      case 'missed': if (c.direction != Dir.missed) return false;
      case 'rejected': if (c.direction != Dir.rejected) return false;
      case 'connected': if (!c.connected) return false;
      case 'notconnected': if (c.outcome == Outcome.connected || c.outcome == Outcome.unknown) return false;
      case 'followup': if (!c.needsFollowUp) return false;
    }
    if (q.isNotEmpty) {
      final lead = db.leads.get(c.leadId)?.name ?? '';
      if (!('${c.phone} ${c.contactName} $lead ${c.notes}'.toLowerCase().contains(q) ||
          c.normalized.contains(q.replaceAll(' ', '')))) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(dbProvider);
    final ex = db.excludedKeys;
    final list = db.calls.values.where((c) => _match(c, ex, db)).toList();
    switch (sort) {
      case 'oldest': list.sort((a, b) => a.start.compareTo(b.start));
      case 'longest': list.sort((a, b) => b.durationSec.compareTo(a.durationSec));
      case 'shortest': list.sort((a, b) => a.durationSec.compareTo(b.durationSec));
      case 'employee': list.sort((a, b) => (db.employees.get(a.employeeId)?.name ?? '').compareTo(db.employees.get(b.employeeId)?.name ?? ''));
      default: list.sort((a, b) => b.start.compareTo(a.start));
    }
    final shown = list.take(page).toList();
    const chips = {
      'all': 'All', 'in': 'Incoming', 'out': 'Outgoing', 'missed': 'Missed', 'rejected': 'Rejected',
      'connected': 'Connected', 'notconnected': 'Not connected', 'followup': 'Follow-up',
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Calls'), actions: [
        IconButton(icon: const Icon(Icons.sync), tooltip: 'Import device calls', onPressed: () => importDeviceCalls(context, ref)),
        IconButton(icon: const Icon(Icons.tune), tooltip: 'Filters', onPressed: () => _sheet(db)),
      ]),
      floatingActionButton: FloatingActionButton.extended(
          icon: const Icon(Icons.add_call), label: const Text('Add call'),
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CallForm()))),
      body: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 4), child: SearchBox(hint: 'Search number, name, lead, notes', onChanged: (v) => setState(() { q = v; page = 100; }))),
        SizedBox(
          height: 44,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
            for (final e in chips.entries)
              Padding(padding: const EdgeInsets.symmetric(horizontal: 3), child: FilterChip(label: Text(e.value), selected: filter == e.key, onSelected: (_) => setState(() { filter = e.key; page = 100; }))),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Text('${list.length} calls', style: Theme.of(context).textTheme.labelMedium),
            const Spacer(),
            Text(db.settings.lastImport == null ? 'Never imported from device' : 'Last import: ${fmtDt(db.settings.lastImport)}', style: Theme.of(context).textTheme.labelSmall),
          ]),
        ),
        Expanded(
          child: shown.isEmpty
              ? const EmptyState(Icons.call_outlined, 'No calls match. Import device calls or add one manually.')
              : ListView.builder(
                  controller: _sc, itemCount: shown.length,
                  itemBuilder: (_, i) => CallTile(shown[i], db: db),
                ),
        ),
      ]),
    );
  }

  void _sheet(Db0 db) {
    showModalBottomSheet(
      context: context, isScrollControlled: true,
      builder: (_) => StatefulBuilder(builder: (ctx, set) {
        void both(VoidCallback f) { set(f); setState(f); }
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            DropdownButtonFormField<String?>(
              value: employeeId, decoration: const InputDecoration(labelText: 'Employee'), isExpanded: true,
              items: [const DropdownMenuItem(value: null, child: Text('All')), for (final e in db.employees.values) DropdownMenuItem(value: e.id, child: Text(e.name))],
              onChanged: (v) => both(() => employeeId = v),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              value: sort, decoration: const InputDecoration(labelText: 'Sort'),
              items: const [
                DropdownMenuItem(value: 'newest', child: Text('Newest')), DropdownMenuItem(value: 'oldest', child: Text('Oldest')),
                DropdownMenuItem(value: 'longest', child: Text('Longest')), DropdownMenuItem(value: 'shortest', child: Text('Shortest')),
                DropdownMenuItem(value: 'employee', child: Text('Employee')),
              ],
              onChanged: (v) => both(() => sort = v!),
            ),
            const SizedBox(height: 10),
            Row(children: [
              OutlinedButton.icon(icon: const Icon(Icons.date_range), label: Text(range == null ? 'Date range' : '${fmtDate(range!.from)} – ${fmtDate(range!.to.subtract(const Duration(days: 1)))}'), onPressed: () async {
                final r = await pickRange(ctx, range);
                if (r != null) both(() => range = rangeFromPicker(r));
              }),
              if (range != null) IconButton(icon: const Icon(Icons.clear), onPressed: () => both(() => range = null)),
            ]),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Show excluded numbers'), value: showExcluded, onChanged: (v) => both(() => showExcluded = v)),
            Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))),
          ]),
        );
      }),
    );
  }
}

typedef Db0 = Db;

class CallTile extends StatelessWidget {
  const CallTile(this.c, {super.key, required this.db});
  final CallRecord c;
  final Db0 db;
  @override
  Widget build(BuildContext context) {
    final lead = db.leads.get(c.leadId);
    return ListTile(
      leading: CircleAvatar(backgroundColor: dirColor(c.direction).withValues(alpha: 0.12), child: Icon(dirIcon(c.direction), color: dirColor(c.direction))),
      title: Text(c.contactName.isNotEmpty ? c.contactName : (lead?.name ?? c.phone), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${fmtDt(c.start)} • ${c.connected ? fmtDuration(c.durationSec) : c.outcome}'
          '${db.employees.get(c.employeeId) != null ? ' • ${db.employees.get(c.employeeId)!.name}' : ''}'),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (lead != null) const Icon(Icons.person, size: 16),
        if (c.needsFollowUp) const Icon(Icons.flag, size: 16, color: Colors.orange),
      ]),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CallDetail(c.id))),
    );
  }
}

class CallDetail extends ConsumerWidget {
  const CallDetail(this.id, {super.key});
  final String id;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(dbProvider);
    final ops = ref.read(opsProvider);
    final c = db.calls.get(id);
    if (c == null) return Scaffold(appBar: AppBar(), body: const EmptyState(Icons.error_outline, 'Call not found'));
    final lead = db.leads.get(c.leadId);
    final excluded = db.excludedKeys.contains(c.key);
    return Scaffold(
      appBar: AppBar(title: Text(c.contactName.isEmpty ? c.phone : c.contactName), actions: [
        PopupMenuButton<String>(
          onSelected: (v) => guard(context, () async {
            if (v == 'export') {
              final t = ReportTable('Call', ['Date', 'Phone', 'Name', 'Direction', 'Outcome', 'Duration (s)', 'Notes'],
                  [[fmtDt(c.start), c.phone, c.contactName, c.direction, c.outcome, c.durationSec, c.notes]]);
              final f = await writeCsv(db, t, List.generate(t.headers.length, (i) => i), 'call');
              await Native.shareFile(f.path, 'text/csv').catchError((_) => toast(context, 'Saved to ${f.path}'));
            } else if (v == 'delete') {
              if (await confirm(context, 'Delete call record?', 'This permanently removes the record from this device.', ok: 'Delete')) {
                await db.calls.delete(c.id);
                if (context.mounted) Navigator.pop(context);
              }
            }
          }),
          itemBuilder: (_) => const [PopupMenuItem(value: 'export', child: Text('Export record (CSV)')), PopupMenuItem(value: 'delete', child: Text('Delete'))],
        ),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Wrap(spacing: 8, children: [StatusChip(c.direction, color: dirColor(c.direction)), StatusChip(c.outcome), if (c.source == 'demo') const StatusChip('Demo', color: Colors.purple)]),
        const SizedBox(height: 8),
        _row('Phone', c.phone), _row('Started', fmtDt(c.start)), _row('Ended', fmtDt(c.end)),
        _row('Duration', fmtDuration(c.durationSec)), _row('Employee', db.employees.get(c.employeeId)?.name ?? '—'),
        _row('Source', c.source), _row('Native ID', c.nativeId ?? '—'), _row('Lead status at call', c.leadStatusAtCall ?? '—'),
        _row('Recording', 'Not available (recording management is not included in this build)'),
        const Divider(),
        Wrap(spacing: 8, children: [
          FilledButton.icon(icon: const Icon(Icons.dialpad), label: const Text('Open dialer'), onPressed: () => Native.dial(c.phone).catchError((_) => toast(context, 'Dialer unavailable'))),
          OutlinedButton.icon(icon: const Icon(Icons.notes), label: const Text('Notes'), onPressed: () => _notes(context, ops, c)),
          if (lead == null) OutlinedButton.icon(icon: const Icon(Icons.person_add), label: const Text('Create lead'), onPressed: () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => LeadForm(prefillPhone: c.phone, prefillName: c.contactName, linkCallId: c.id)));
          }),
          if (lead != null) OutlinedButton.icon(icon: const Icon(Icons.person), label: Text(lead.name), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => LeadDetail(lead.id)))),
          OutlinedButton.icon(icon: const Icon(Icons.event), label: const Text('Schedule follow-up'), onPressed: () async {
            if (lead == null) { toast(context, 'Create or link a lead first.'); return; }
            await showFollowUpDialog(context, ref, lead, call: c);
          }),
          OutlinedButton.icon(
            icon: Icon(c.needsFollowUp ? Icons.check_circle : Icons.flag), label: Text(c.needsFollowUp ? 'Mark follow-up done' : 'Flag for follow-up'),
            onPressed: () => guard(context, () async { c.needsFollowUp = !c.needsFollowUp; await ops.updateCall(c); })),
          OutlinedButton.icon(
            icon: Icon(excluded ? Icons.visibility : Icons.visibility_off), label: Text(excluded ? 'Already excluded' : 'Exclude number'),
            onPressed: excluded ? null : () => guard(context, () async {
              if (await confirm(context, 'Exclude number?', 'Calls to/from this number are left out of analytics. Records are kept.')) {
                await ops.exclude(c.phone, 'Excluded from call detail');
              }
            })),
        ]),
        if (c.notes.isNotEmpty) ...[const SizedBox(height: 12), Text('Notes', style: Theme.of(context).textTheme.titleSmall), Text(c.notes)],
      ]),
    );
  }

  Widget _row(String k, String v) => Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [SizedBox(width: 130, child: Text(k, style: const TextStyle(color: Colors.grey))), Expanded(child: Text(v))]));

  Future<void> _notes(BuildContext context, Ops ops, CallRecord c) async {
    final t = TextEditingController(text: c.notes);
    final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
      title: const Text('Call notes'), content: TextField(controller: t, maxLines: 5, autofocus: true),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Save'))]));
    if (ok == true && context.mounted) {
      await guard(context, () async { c.notes = t.text.trim(); await ops.updateCall(c); });
    }
  }
}

class CallForm extends ConsumerStatefulWidget {
  const CallForm({super.key});
  @override
  ConsumerState<CallForm> createState() => _CallFormState();
}

class _CallFormState extends ConsumerState<CallForm> {
  final _f = GlobalKey<FormState>();
  final phone = TextEditingController(), name = TextEditingController(), dur = TextEditingController(text: '0'), notes = TextEditingController();
  String dir = Dir.outgoing, outcome = Outcome.connected;
  String? emp;
  DateTime when = DateTime.now();

  @override
  void initState() {
    super.initState();
    final id = ref.read(dbProvider).settings.defaultEmployeeId;
    emp = id.isEmpty ? null : id;
  }

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(dbProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Add call manually')),
      body: Form(key: _f, child: ListView(padding: const EdgeInsets.all(16), children: [
        TextFormField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone number'), validator: (v) => isValidPhone(v ?? '') ? null : 'Enter a valid phone number'),
        const SizedBox(height: 10),
        TextFormField(controller: name, decoration: const InputDecoration(labelText: 'Contact name (optional)')),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(value: dir, decoration: const InputDecoration(labelText: 'Direction'), items: [for (final d in Dir.all) DropdownMenuItem(value: d, child: Text(d))], onChanged: (v) => setState(() => dir = v!)),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(value: outcome, decoration: const InputDecoration(labelText: 'Outcome'), items: [for (final d in Outcome.all) DropdownMenuItem(value: d, child: Text(d))], onChanged: (v) => setState(() => outcome = v!)),
        const SizedBox(height: 10),
        TextFormField(controller: dur, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Duration (seconds)'), validator: (v) => (int.tryParse(v ?? '') ?? -1) < 0 ? 'Enter 0 or more' : null),
        const SizedBox(height: 10),
        DropdownButtonFormField<String?>(value: emp, decoration: const InputDecoration(labelText: 'Employee'), items: [const DropdownMenuItem(value: null, child: Text('Unassigned')), for (final e in db.employees.values.where((e) => e.active)) DropdownMenuItem(value: e.id, child: Text(e.name))], onChanged: (v) => setState(() => emp = v)),
        ListTile(contentPadding: EdgeInsets.zero, title: const Text('Date & time'), subtitle: Text(fmtDt(when)), trailing: const Icon(Icons.edit_calendar), onTap: () async { final d = await pickDateTime(context, initial: when); if (d != null) setState(() => when = d); }),
        TextFormField(controller: notes, maxLines: 3, decoration: const InputDecoration(labelText: 'Notes')),
        const SizedBox(height: 16),
        FilledButton(onPressed: () => guard(context, () async {
          if (!_f.currentState!.validate()) return;
          if (when.isAfter(DateTime.now().add(const Duration(minutes: 1)))) { toast(context, 'Call time cannot be in the future.'); return; }
          await ref.read(opsProvider).addManualCall(CallRecord(
            phone: phone.text.trim(), contactName: name.text.trim(), direction: dir, outcome: outcome,
            start: when.toUtc(), durationSec: int.parse(dur.text), employeeId: emp, notes: notes.text.trim(),
            teamId: db.employees.get(emp)?.teamId));
          if (context.mounted) Navigator.pop(context);
        }), child: const Text('Save call')),
      ])),
    );
  }
}
