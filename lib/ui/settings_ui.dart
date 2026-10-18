import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core.dart';
import '../models.dart';
import 'widgets.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(dbProvider);
    final ops = ref.read(opsProvider);
    final s = db.settings;
    Future<void> save() => guard(context, db.saveSettings);
    String hm(int m) => '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
    Future<void> pickTime(bool start) async {
      final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: (start ? s.workStartMin : s.workEndMin) ~/ 60, minute: (start ? s.workStartMin : s.workEndMin) % 60));
      if (t == null) return;
      start ? s.workStartMin = t.hour * 60 + t.minute : s.workEndMin = t.hour * 60 + t.minute;
      await save();
    }
    Future<void> askInt(String title, int cur, void Function(int) set) async {
      final c = TextEditingController(text: '$cur');
      final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(title: Text(title), content: TextField(controller: c, keyboardType: TextInputType.number), actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Save'))]));
      final v = int.tryParse(c.text);
      if (ok == true && v != null && v >= 0) { set(v); await save(); }
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Section('General', Column(children: [
          ListTile(contentPadding: EdgeInsets.zero, title: const Text('Workspace'), subtitle: Text('${s.workspace} • ${s.business}')),
          SegmentedButton<String>(
            segments: const [ButtonSegment(value: 'system', label: Text('System')), ButtonSegment(value: 'light', label: Text('Light')), ButtonSegment(value: 'dark', label: Text('Dark'))],
            selected: {s.themeMode}, onSelectionChanged: (v) { s.themeMode = v.first; save(); }),
          ListTile(contentPadding: EdgeInsets.zero, title: const Text('Week starts on'), trailing: DropdownButton<int>(value: s.weekStart, items: const [DropdownMenuItem(value: 1, child: Text('Monday')), DropdownMenuItem(value: 7, child: Text('Sunday'))], onChanged: (v) { s.weekStart = v!; save(); })),
          Text('Times are stored in UTC and shown in the device time zone (${DateTime.now().timeZoneName}).', style: Theme.of(context).textTheme.bodySmall),
        ])),
        Section('Working schedule', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            OutlinedButton(onPressed: () => pickTime(true), child: Text('Start ${hm(s.workStartMin)}')), const SizedBox(width: 8),
            OutlinedButton(onPressed: () => pickTime(false), child: Text('End ${hm(s.workEndMin)}')),
          ]),
          const Text('If End is earlier than Start the shift is treated as overnight.', style: TextStyle(fontSize: 11)),
          Wrap(spacing: 4, children: [for (var d = 1; d <= 7; d++) FilterChip(label: Text(const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d - 1]), selected: s.workDays.contains(d), onSelected: (v) { v ? s.workDays.add(d) : s.workDays.remove(d); save(); })]),
          const SizedBox(height: 6),
          Wrap(spacing: 4, children: [
            for (final h in s.holidays) InputChip(label: Text(h), onDeleted: () { s.holidays.remove(h); save(); }),
            ActionChip(avatar: const Icon(Icons.add, size: 16), label: const Text('Holiday'), onPressed: () async {
              final d = await showDatePicker(context: context, initialDate: DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime(2100));
              if (d != null) { s.holidays.add('${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}'); await save(); }
            }),
          ]),
        ])),
        Section('Leads', Column(children: [
          ListTile(contentPadding: EdgeInsets.zero, title: const Text('Max active leads per employee'), subtitle: Text(s.maxActiveLeads == 0 ? 'Unlimited (round-robin)' : '${s.maxActiveLeads}'), onTap: () => askInt('Max active leads (0 = unlimited)', s.maxActiveLeads, (v) => s.maxActiveLeads = v)),
          ListTile(contentPadding: EdgeInsets.zero, title: const Text('Initial-contact deadline (days)'), subtitle: Text('${s.contactDeadlineDays}'), onTap: () => askInt('Days', s.contactDeadlineDays, (v) => s.contactDeadlineDays = v)),
          ListTile(contentPadding: EdgeInsets.zero, title: const Text('Default follow-up hour'), subtitle: Text('${s.followUpHour}:00'), onTap: () => askInt('Hour (0-23)', s.followUpHour, (v) => s.followUpHour = v.clamp(0, 23))),
          ListTile(contentPadding: EdgeInsets.zero, title: const Text('Lead statuses'), subtitle: Text('${s.activeStatuses.length} active of ${s.statuses.length}'), trailing: const Icon(Icons.chevron_right), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StatusesScreen()))),
        ])),
        Section('Data retention', Column(children: [
          ListTile(contentPadding: EdgeInsets.zero, title: const Text('Auto-delete calls older than (days)'), subtitle: Text(s.retentionDays == 0 ? 'Keep forever' : '${s.retentionDays} days'), onTap: () => askInt('Days (0 = keep forever)', s.retentionDays, (v) => s.retentionDays = v)),
          if (s.retentionDays > 0) TextButton(onPressed: () => guard(context, () async {
            if (await confirm(context, 'Purge old calls?', 'Calls older than ${s.retentionDays} days will be permanently deleted.', ok: 'Delete')) {
              final n = await ops.purgeCallsOlderThan(s.retentionDays);
              if (context.mounted) toast(context, 'Deleted $n calls');
            }
          }), child: const Text('Apply retention now')),
        ])),
        Section('Local role (this installation only)', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Roles are enforced by the local data layer on this device. They are not centralised, server-enforced access control; anyone with the device can switch roles unless you add an app lock.', style: TextStyle(fontSize: 12)),
          DropdownButton<String>(value: s.role, items: [for (final r in Role.values) DropdownMenuItem(value: r.name, child: Text(r.label))], onChanged: (v) async { s.role = v!; await db.saveSettingsForce(); }),
        ])),
        Section('Demo data', OutlinedButton(onPressed: () => guard(context, () async { await ops.removeDemoData(); if (context.mounted) toast(context, 'Demo data removed'); }), child: const Text('Remove demo data'))),
        const Section('Privacy', Text('All business data is stored locally in Hive CE and is not encrypted by Hive. Use device encryption/screen lock. The only network feature is the manual "Export to server" action. Backups are unencrypted ZIP files.')),
      ]),
    );
  }
}

class StatusesScreen extends ConsumerWidget {
  const StatusesScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(dbProvider);
    final s = db.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Lead statuses'), actions: [
        IconButton(icon: const Icon(Icons.add), onPressed: () async {
          final c = TextEditingController();
          final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(title: const Text('New status'), content: TextField(controller: c, autofocus: true), actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Add'))]));
          final n = c.text.trim();
          if (ok == true && n.isNotEmpty && !s.statuses.contains(n) && context.mounted) { s.statuses.add(n); await guard(context, db.saveSettings); }
        }),
      ]),
      body: ReorderableListView(
        onReorder: (a, b) async { if (b > a) b--; final x = s.statuses.removeAt(a); s.statuses.insert(b, x); await guard(context, db.saveSettings); },
        children: [
          for (final st in s.statuses)
            SwitchListTile(
              key: ValueKey(st), title: Text(st), subtitle: closedStatuses.contains(st) ? const Text('Closes the lead') : null,
              value: !s.disabledStatuses.contains(st),
              onChanged: (v) => guard(context, () async { v ? s.disabledStatuses.remove(st) : s.disabledStatuses.add(st); await db.saveSettings(); }),
            ),
        ],
      ),
    );
  }
}
