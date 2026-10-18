import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core.dart';
import '../services/call_log_service.dart';
import '../services/reports.dart';
import 'widgets.dart';

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});
  @override
  ConsumerState<ReportsScreen> createState() => _ReportsState();
}

class _ReportsState extends ConsumerState<ReportsScreen> {
  String type = 'calls';
  Period period = Period.thisMonth;
  Range? custom;
  String? employeeId;
  bool excl = true, mask = false;
  Set<int>? cols;

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(dbProvider);
    final f = ReportFilter(range: rangeFor(period, DateTime.now(), weekStart: db.settings.weekStart, custom: custom), employeeId: employeeId, applyExclusions: excl, maskPhones: mask, neverDays: db.settings.contactDeadlineDays);
    final t = buildReport(db, type, f);
    final sel = (cols == null || cols!.any((i) => i >= t.headers.length)) ? Set<int>.from(List.generate(t.headers.length, (i) => i)) : cols!;
    return Scaffold(
      appBar: AppBar(title: const Text('Reports')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        DropdownButtonFormField<String>(value: type, decoration: const InputDecoration(labelText: 'Report'), items: [for (final e in reportTypes.entries) DropdownMenuItem(value: e.key, child: Text(e.value))], onChanged: (v) => setState(() { type = v!; cols = null; })),
        const SizedBox(height: 8),
        Wrap(spacing: 6, children: [
          for (final p in Period.values) ChoiceChip(label: Text(periodLabels[p]!), selected: period == p, onSelected: (_) async {
            if (p == Period.custom) { final r = await pickRange(context, custom); if (r == null) return; custom = rangeFromPicker(r); }
            setState(() => period = p);
          }),
        ]),
        const SizedBox(height: 8),
        DropdownButtonFormField<String?>(value: employeeId, decoration: const InputDecoration(labelText: 'Employee'), items: [const DropdownMenuItem(value: null, child: Text('All')), for (final e in db.employees.values) DropdownMenuItem(value: e.id, child: Text(e.name))], onChanged: (v) => setState(() => employeeId = v)),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Apply excluded numbers'), value: excl, onChanged: (v) => setState(() => excl = v)),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Mask phone numbers in output'), value: mask, onChanged: (v) => setState(() => mask = v)),
        Section('Columns', Wrap(spacing: 6, children: [for (var i = 0; i < t.headers.length; i++) FilterChip(label: Text(t.headers[i]), selected: sel.contains(i), onSelected: (v) => setState(() { final n = Set<int>.from(sel); v ? n.add(i) : n.remove(i); cols = n; }))])),
        Section('Preview — ${t.rows.length} rows', t.rows.isEmpty
            ? const Text('No rows for these filters')
            : SingleChildScrollView(scrollDirection: Axis.horizontal, child: DataTable(
                columns: [for (final i in (sel.toList()..sort())) DataColumn(label: Text(t.headers[i]))],
                rows: [for (final r in t.rows.take(8)) DataRow(cells: [for (final i in (sel.toList()..sort())) DataCell(Text('${r[i] ?? ''}'))])]))),
        FilledButton.icon(
          icon: const Icon(Icons.download), label: const Text('Generate CSV'),
          onPressed: sel.isEmpty || t.rows.isEmpty ? null : () => guard(context, () async {
            final file = await writeCsv(db, t, sel.toList()..sort(), type);
            if (!context.mounted) return;
            final share = await confirm(context, 'CSV saved', '${file.path}\n\nUTF-8 CSV, opens in Excel. Share it now?', ok: 'Share');
            if (share) await Native.shareFile(file.path, 'text/csv');
          }),
        ),
        const SizedBox(height: 6),
        const Text('Spreadsheet formula characters are neutralised. PDF and XLSX generation are not included in this build.', style: TextStyle(fontSize: 12)),
      ]),
    );
  }
}
