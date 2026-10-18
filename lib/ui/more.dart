import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core.dart';
import '../models.dart';
import '../services/analytics.dart';
import 'database_ui.dart';
import 'reports_ui.dart';
import 'settings_ui.dart';
import 'widgets.dart';

class MoreScreen extends ConsumerWidget {
  const MoreScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void go(Widget w) => Navigator.push(context, MaterialPageRoute(builder: (_) => w));
    final items = [
      (Icons.badge, 'Employees', () => go(const EmployeesScreen())),
      (Icons.groups, 'Teams', () => go(const TeamsScreen())),
      (Icons.visibility_off, 'Excluded numbers', () => go(const ExcludedScreen())),
      (Icons.assessment, 'Reports (CSV)', () => go(const ReportsScreen())),
      (Icons.storage, 'Database', () => go(const DatabaseScreen())),
      (Icons.settings, 'Settings', () => go(const SettingsScreen())),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(children: [
        for (final i in items) ListTile(leading: Icon(i.$1), title: Text(i.$2), trailing: const Icon(Icons.chevron_right), onTap: i.$3),
      ]),
    );
  }
}

class EmployeesScreen extends ConsumerWidget {
  const EmployeesScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(dbProvider);
    final list = db.employees.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return Scaffold(
      appBar: AppBar(title: const Text('Employees')),
      floatingActionButton: FloatingActionButton(child: const Icon(Icons.add), onPressed: () => _edit(context, ref, null)),
      body: list.isEmpty
          ? const EmptyState(Icons.badge, 'No employees yet.')
          : ListView(children: [
              for (final e in list)
                ListTile(
                  leading: CircleAvatar(child: Text(e.name.isEmpty ? '?' : e.name[0].toUpperCase())),
                  title: Text(e.name),
                  subtitle: Text('${db.teams.get(e.teamId)?.name ?? 'No team'} • ${e.phone.isEmpty ? 'no phone' : e.phone}'),
                  trailing: e.active ? null : const StatusChip('Inactive', color: Colors.grey),
                  onTap: () => _stats(context, ref, e),
                  onLongPress: () => _edit(context, ref, e),
                ),
            ]),
    );
  }

  void _stats(BuildContext context, WidgetRef ref, Employee e) {
    final db = ref.read(dbProvider);
    final calls = db.calls.values.where((c) => c.employeeId == e.id && !db.excludedKeys.contains(c.key)).toList();
    final st = computeStats(calls, db.settings);
    final fus = db.followUps.values.where((f) => f.employeeId == e.id).toList();
    showModalBottomSheet(context: context, builder: (_) => Padding(
      padding: const EdgeInsets.all(16),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(e.name, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text('All-time: ${st.total} calls (${st.incoming} in, ${st.outgoing} out, ${st.missed} missed)\n'
            'Connected: ${st.connected} • talk time ${fmtDuration(st.connectedSeconds)} • avg ${fmtDuration(st.avgConnected)}\n'
            'Connection rate: ${st.connectionRate == null ? 'n/a' : '${st.connectionRate!.toStringAsFixed(0)}%'}\n'
            'Assigned leads: ${db.leads.values.where((l) => l.assignedEmployeeId == e.id && !l.archived).length}\n'
            'Follow-ups: ${fus.where((f) => f.status == 'completed').length} done / ${fus.where((f) => f.status != 'cancelled').length}'),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          OutlinedButton(onPressed: () { Navigator.pop(context); _edit(context, ref, e); }, child: const Text('Edit')),
          OutlinedButton(onPressed: () async {
            Navigator.pop(context);
            await guard(context, () async { e.active = !e.active; e.updatedAt = DateTime.now().toUtc(); await db.employees.put(e); });
          }, child: Text(e.active ? 'Deactivate' : 'Reactivate')),
          if (e.phone.isNotEmpty) OutlinedButton(onPressed: () async {
            Navigator.pop(context);
            await guard(context, () => ref.read(opsProvider).exclude(e.phone, 'Employee number'));
          }, child: const Text('Exclude their number')),
        ]),
      ]),
    ));
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, Employee? e) async {
    final db = ref.read(dbProvider);
    final f = GlobalKey<FormState>();
    final name = TextEditingController(text: e?.name), code = TextEditingController(text: e?.code),
        phone = TextEditingController(text: e?.phone), email = TextEditingController(text: e?.email);
    String? team = e?.teamId;
    await showDialog<void>(context: context, builder: (d) => StatefulBuilder(builder: (ctx, set) => AlertDialog(
      title: Text(e == null ? 'New employee' : 'Edit employee'),
      content: Form(key: f, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextFormField(controller: name, decoration: const InputDecoration(labelText: 'Full name'), validator: (v) => v!.trim().isEmpty ? 'Required' : null),
        const SizedBox(height: 8),
        TextFormField(controller: code, decoration: const InputDecoration(labelText: 'Employee code')),
        const SizedBox(height: 8),
        TextFormField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone'), validator: (v) => v!.isEmpty || isValidPhone(v) ? null : 'Invalid phone'),
        const SizedBox(height: 8),
        TextFormField(controller: email, decoration: const InputDecoration(labelText: 'Email'), validator: (v) => isValidEmail(v ?? '') ? null : 'Invalid email'),
        const SizedBox(height: 8),
        DropdownButtonFormField<String?>(value: team, decoration: const InputDecoration(labelText: 'Team'), items: [const DropdownMenuItem(value: null, child: Text('No team')), for (final t in db.teams.values) DropdownMenuItem(value: t.id, child: Text(t.name))], onChanged: (v) => set(() => team = v)),
      ]))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
        FilledButton(onPressed: () async {
          if (!f.currentState!.validate()) return;
          await guard(ctx, () async {
            final x = e ?? Employee(name: '');
            x..name = name.text.trim()..code = code.text.trim()..phone = phone.text.trim()..email = email.text.trim()..teamId = team..updatedAt = DateTime.now().toUtc();
            await db.employees.put(x);
          });
          if (d.mounted) Navigator.pop(d);
        }, child: const Text('Save')),
      ],
    )));
  }
}

class TeamsScreen extends ConsumerWidget {
  const TeamsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(dbProvider);
    final teams = db.teams.values.toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Teams')),
      floatingActionButton: FloatingActionButton(child: const Icon(Icons.add), onPressed: () => _edit(context, ref, null)),
      body: teams.isEmpty
          ? const EmptyState(Icons.groups, 'No teams yet.')
          : ListView(children: [
              for (final t in teams)
                ListTile(
                  leading: const Icon(Icons.groups),
                  title: Text(t.name),
                  subtitle: Text('${db.employees.values.where((e) => e.teamId == t.id).length} members • leader: ${db.employees.get(t.leaderId)?.name ?? '—'} • ${db.leads.values.where((l) => l.teamId == t.id && !l.archived).length} leads'),
                  onTap: () => _edit(context, ref, t),
                  trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => guard(context, () async {
                    if (await confirm(context, 'Delete team?', 'Members keep their records but lose this team.', ok: 'Delete')) {
                      final ms = db.employees.values.where((e) => e.teamId == t.id).toList();
                      for (final m in ms) { m.teamId = null; }
                      await db.employees.putAll(ms);
                      await db.teams.delete(t.id);
                    }
                  })),
                ),
            ]),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, Team? t) async {
    final db = ref.read(dbProvider);
    final name = TextEditingController(text: t?.name);
    String? leader = t?.leaderId;
    await showDialog<void>(context: context, builder: (d) => StatefulBuilder(builder: (ctx, set) => AlertDialog(
      title: Text(t == null ? 'New team' : 'Edit team'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: name, decoration: const InputDecoration(labelText: 'Team name')),
        const SizedBox(height: 8),
        DropdownButtonFormField<String?>(value: leader, decoration: const InputDecoration(labelText: 'Leader'), items: [const DropdownMenuItem(value: null, child: Text('None')), for (final e in db.employees.values) DropdownMenuItem(value: e.id, child: Text(e.name))], onChanged: (v) => set(() => leader = v)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
        FilledButton(onPressed: () async {
          if (name.text.trim().isEmpty) { toast(ctx, 'Name is required'); return; }
          await guard(ctx, () async {
            final x = t ?? Team(name: '');
            x..name = name.text.trim()..leaderId = leader;
            await db.teams.put(x);
          });
          if (d.mounted) Navigator.pop(d);
        }, child: const Text('Save')),
      ],
    )));
  }
}

class ExcludedScreen extends ConsumerWidget {
  const ExcludedScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(dbProvider);
    final list = db.excluded.values.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return Scaffold(
      appBar: AppBar(title: const Text('Excluded numbers')),
      floatingActionButton: FloatingActionButton(child: const Icon(Icons.add), onPressed: () async {
        final p = TextEditingController(), r = TextEditingController();
        final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
          title: const Text('Exclude a number'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: p, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone number')),
            const SizedBox(height: 8),
            TextField(controller: r, decoration: const InputDecoration(labelText: 'Reason (e.g. internal, test)')),
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Add'))]));
        if (ok != true || !context.mounted) return;
        if (!isValidPhone(p.text)) { toast(context, 'Enter a valid phone number'); return; }
        await guard(context, () => ref.read(opsProvider).exclude(p.text.trim(), r.text.trim()));
      }),
      body: list.isEmpty
          ? const EmptyState(Icons.visibility_off, 'No excluded numbers. Excluding a number hides it from analytics and reports but keeps the call records.')
          : ListView(children: [
              for (final e in list)
                SwitchListTile(
                  title: Text(e.phone), subtitle: Text(e.reason.isEmpty ? 'No reason' : e.reason),
                  value: e.active,
                  onChanged: (v) => guard(context, () async { e.active = v; await db.excluded.put(e); }),
                  secondary: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => guard(context, () => db.excluded.delete(e.id))),
                ),
            ]),
    );
  }
}
