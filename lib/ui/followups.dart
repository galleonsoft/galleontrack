import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core.dart';
import '../db.dart';
import '../models.dart';
import 'leads.dart';
import 'widgets.dart';

class FollowUpsScreen extends ConsumerStatefulWidget {
  const FollowUpsScreen({super.key});
  @override
  ConsumerState<FollowUpsScreen> createState() => _FuState();
}

class _FuState extends ConsumerState<FollowUpsScreen> {
  String view = 'open';
  String? employeeId, priority;

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(dbProvider);
    var list = db.followUps.values.where((f) =>
        (employeeId == null || f.employeeId == employeeId) && (priority == null || f.priority == priority)).toList();
    list = switch (view) {
      'overdue' => list.where((f) => f.overdue).toList(),
      'today' => list.where((f) => f.dueToday).toList(),
      'done' => list.where((f) => f.status == 'completed').toList(),
      'cancelled' => list.where((f) => f.status == 'cancelled').toList(),
      _ => list.where((f) => f.open).toList(),
    };
    list.sort((a, b) => view == 'done' ? b.dueAt.compareTo(a.dueAt) : a.dueAt.compareTo(b.dueAt));
    const views = {'open': 'Open', 'overdue': 'Overdue', 'today': 'Due today', 'done': 'Completed', 'cancelled': 'Cancelled'};
    return Scaffold(
      appBar: AppBar(title: const Text('Follow-ups'), actions: [
        PopupMenuButton<String?>(
          icon: const Icon(Icons.filter_list),
          onSelected: (v) => setState(() => employeeId = v == '' ? null : v),
          itemBuilder: (_) => [const PopupMenuItem(value: '', child: Text('All employees')), for (final e in db.employees.values) PopupMenuItem(value: e.id, child: Text(e.name))],
        ),
        PopupMenuButton<String?>(
          icon: const Icon(Icons.flag_outlined),
          onSelected: (v) => setState(() => priority = v == '' ? null : v),
          itemBuilder: (_) => [const PopupMenuItem(value: '', child: Text('Any priority')), for (final p in ['High', 'Medium', 'Low']) PopupMenuItem(value: p, child: Text(p))],
        ),
      ]),
      body: Column(children: [
        SizedBox(height: 48, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.all(6), children: [
          for (final e in views.entries) Padding(padding: const EdgeInsets.symmetric(horizontal: 3), child: ChoiceChip(label: Text(e.value), selected: view == e.key, onSelected: (_) => setState(() => view = e.key))),
        ])),
        Expanded(child: list.isEmpty
            ? const EmptyState(Icons.event_available, 'No follow-ups here. Schedule one from a lead or call.')
            : ListView.builder(itemCount: list.length, itemBuilder: (_, i) => FollowUpTile(list[i], db: db))),
      ]),
    );
  }
}

class FollowUpTile extends ConsumerWidget {
  const FollowUpTile(this.f, {super.key, required this.db, this.showLead = true});
  final FollowUp f;
  final Db db;
  final bool showLead;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ops = ref.read(opsProvider);
    final lead = db.leads.get(f.leadId);
    return ListTile(
      title: Text(showLead ? (lead?.name ?? 'Unknown lead') : '${f.type} • ${f.priority}'),
      subtitle: Text('${fmtDt(f.dueAt)}${f.description.isEmpty ? '' : '\n${f.description}'}${f.outcome.isEmpty ? '' : '\nOutcome: ${f.outcome}'}'),
      isThreeLine: f.description.isNotEmpty || f.outcome.isNotEmpty,
      leading: StatusChip(f.label, color: followUpColor(f.label)),
      onTap: lead == null || !showLead ? null : () => Navigator.push(context, MaterialPageRoute(builder: (_) => LeadDetail(lead.id))),
      trailing: !f.open
          ? null
          : PopupMenuButton<String>(
              onSelected: (v) => guard(context, () async {
                if (v == 'done') {
                  final t = TextEditingController();
                  final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(title: const Text('Complete follow-up'), content: TextField(controller: t, maxLines: 3, decoration: const InputDecoration(labelText: 'Outcome / notes')), actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Complete'))]));
                  if (ok == true) await ops.completeFollowUp(f, t.text.trim());
                } else if (v == 'resched') {
                  if (!context.mounted) return;
                  final d = await pickDateTime(context, initial: f.dueAt.toLocal());
                  if (d != null) await ops.reschedule(f, d);
                } else if (v == 'cancel') {
                  if (await confirm(context, 'Cancel follow-up?', 'It will stay in history as cancelled.')) await ops.cancelFollowUp(f);
                }
              }),
              itemBuilder: (_) => const [PopupMenuItem(value: 'done', child: Text('Complete')), PopupMenuItem(value: 'resched', child: Text('Reschedule')), PopupMenuItem(value: 'cancel', child: Text('Cancel'))],
            ),
    );
  }
}

Future<void> showFollowUpDialog(BuildContext context, WidgetRef ref, Lead lead, {CallRecord? call}) async {
  final db = ref.read(dbProvider);
  final ops = ref.read(opsProvider);
  final desc = TextEditingController();
  var due = DateTime.now().add(const Duration(days: 1));
  due = DateTime(due.year, due.month, due.day, db.settings.followUpHour);
  var prio = 'Medium', type = 'Call';
  String? emp = lead.assignedEmployeeId;
  await showDialog<void>(
    context: context,
    builder: (d) => StatefulBuilder(builder: (ctx, set) => AlertDialog(
      title: Text('Follow-up: ${lead.name}'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(contentPadding: EdgeInsets.zero, title: const Text('Due'), subtitle: Text(fmtDt(due)), trailing: const Icon(Icons.edit_calendar), onTap: () async {
          final x = await pickDateTime(ctx, initial: due);
          if (x != null) set(() => due = x);
        }),
        DropdownButtonFormField<String>(value: prio, decoration: const InputDecoration(labelText: 'Priority'), items: [for (final p in ['High', 'Medium', 'Low']) DropdownMenuItem(value: p, child: Text(p))], onChanged: (v) => set(() => prio = v!)),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(value: type, decoration: const InputDecoration(labelText: 'Type'), items: [for (final p in ['Call', 'Meeting', 'Email', 'Message', 'Other']) DropdownMenuItem(value: p, child: Text(p))], onChanged: (v) => set(() => type = v!)),
        const SizedBox(height: 8),
        DropdownButtonFormField<String?>(value: emp, isExpanded: true, decoration: const InputDecoration(labelText: 'Assigned to'), items: [const DropdownMenuItem(value: null, child: Text('Unassigned')), for (final e in db.employees.values.where((e) => e.active)) DropdownMenuItem(value: e.id, child: Text(e.name))], onChanged: (v) => set(() => emp = v)),
        const SizedBox(height: 8),
        TextField(controller: desc, decoration: const InputDecoration(labelText: 'Description')),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
        FilledButton(onPressed: () async {
          final f = FollowUp(leadId: lead.id, employeeId: emp, dueAt: due.toUtc(), priority: prio, type: type, description: desc.text.trim(), callId: call?.id);
          if (due.isBefore(DateTime.now())) { toast(ctx, 'Pick a time in the future.'); return; }
          final err = ops.validateFollowUp(f);
          if (err != null) { toast(ctx, err); return; }
          await guard(ctx, () async {
            await ops.saveFollowUp(f);
            if (call != null) { call.needsFollowUp = true; call.followUpDue = f.dueAt; await ops.updateCall(call); }
          });
          if (d.mounted) Navigator.pop(d);
        }, child: const Text('Schedule')),
      ],
    )),
  );
}
