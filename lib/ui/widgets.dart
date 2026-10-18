import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../core.dart';
import '../db.dart';
import '../services/ops.dart';

final dbProvider = ChangeNotifierProvider<Db>((ref) => throw UnimplementedError('db not opened'));
final opsProvider = Provider<Ops>((ref) => Ops(ref.watch(dbProvider)));

String fmtDt(DateTime? d) => d == null ? '—' : DateFormat('d MMM yyyy, HH:mm').format(d.toLocal());
String fmtDate(DateTime? d) => d == null ? '—' : DateFormat('d MMM yyyy').format(d.toLocal());

Future<bool> confirm(BuildContext c, String title, String body, {String ok = 'Confirm'}) async =>
    await showDialog<bool>(
      context: c,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(ok)),
        ],
      ),
    ) ?? false;

void toast(BuildContext c, String m) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

/// Runs [f]; converts role and storage errors into friendly messages.
Future<void> guard(BuildContext c, Future<void> Function() f) async {
  try {
    await f();
  } on PermissionDenied {
    if (c.mounted) toast(c, 'Your local role does not allow this action.');
  } catch (e) {
    if (c.mounted) toast(c, 'Something went wrong: $e');
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState(this.icon, this.text, {super.key});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.outline)),
          ]),
        ),
      );
}

class StatCard extends StatelessWidget {
  const StatCard(this.title, this.value, this.icon, {super.key, this.color});
  final String title, value;
  final IconData icon;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
          Row(children: [Icon(icon, size: 18, color: c), const SizedBox(width: 6), Expanded(child: Text(title, style: Theme.of(context).textTheme.labelMedium, overflow: TextOverflow.ellipsis))]),
          const SizedBox(height: 6),
          Text(value, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.label, {super.key, this.color});
  final String label;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w600)),
    );
  }
}

Color followUpColor(String label) => switch (label) {
      'Overdue' => Colors.red.shade700,
      'Due Today' => Colors.orange.shade800,
      'Completed' => Colors.green.shade700,
      'Cancelled' => Colors.grey,
      _ => Colors.blue.shade700,
    };

IconData dirIcon(String d) => switch (d) {
      Dir.incoming => Icons.call_received,
      Dir.outgoing => Icons.call_made,
      Dir.missed => Icons.call_missed,
      Dir.rejected => Icons.call_end,
      _ => Icons.help_outline,
    };
Color dirColor(String d) => switch (d) {
      Dir.incoming => Colors.green.shade700,
      Dir.outgoing => Colors.blue.shade700,
      Dir.missed => Colors.red.shade700,
      Dir.rejected => Colors.orange.shade800,
      _ => Colors.grey,
    };

/// Debounced search field.
class SearchBox extends StatefulWidget {
  const SearchBox({super.key, required this.onChanged, this.hint = 'Search'});
  final ValueChanged<String> onChanged;
  final String hint;
  @override
  State<SearchBox> createState() => _SearchBoxState();
}

class _SearchBoxState extends State<SearchBox> {
  Timer? _t;
  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search), hintText: widget.hint, isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(24))),
        onChanged: (v) {
          _t?.cancel();
          _t = Timer(const Duration(milliseconds: 300), () => widget.onChanged(v.trim().toLowerCase()));
        },
      );
}

class HBars extends StatelessWidget {
  const HBars(this.data, {super.key, this.color});
  final Map<String, int> data;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final mx = data.values.fold<int>(0, (a, b) => a > b ? a : b);
    if (mx == 0) return const Padding(padding: EdgeInsets.all(8), child: Text('No data for this period'));
    return Column(
      children: [
        for (final e in data.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              SizedBox(width: 110, child: Text(e.key, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
              Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: e.value / mx, minHeight: 10, color: color))),
              SizedBox(width: 36, child: Text('${e.value}', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
            ]),
          ),
      ],
    );
  }
}

class VBars extends StatelessWidget {
  const VBars(this.values, this.labels, {super.key, this.color});
  final List<int> values;
  final List<String> labels;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final mx = values.fold<int>(0, (a, b) => a > b ? a : b);
    if (mx == 0) return const SizedBox(height: 60, child: Center(child: Text('No data for this period')));
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Column(children: [
      SizedBox(
        height: 110,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (final v in values)
            Expanded(child: Tooltip(message: '$v', child: Container(margin: const EdgeInsets.symmetric(horizontal: 1), height: 4 + 104 * v / mx, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))))),
        ]),
      ),
      const SizedBox(height: 4),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(labels.first, style: const TextStyle(fontSize: 10)),
        Text(labels[labels.length ~/ 2], style: const TextStyle(fontSize: 10)),
        Text(labels.last, style: const TextStyle(fontSize: 10)),
      ]),
    ]);
  }
}

class Section extends StatelessWidget {
  const Section(this.title, this.child, {super.key, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Card(
        elevation: 0,
        margin: const EdgeInsets.symmetric(vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Expanded(child: Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700))), if (trailing != null) trailing!]),
            const SizedBox(height: 8),
            child,
          ]),
        ),
      );
}

Future<DateTimeRange?> pickRange(BuildContext c, [Range? initial]) => showDateRangePicker(
      context: c,
      firstDate: DateTime(2015),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDateRange: initial == null ? null : DateTimeRange(start: initial.from, end: initial.to.subtract(const Duration(days: 1))),
    );

Range rangeFromPicker(DateTimeRange r) =>
    Range(DateTime(r.start.year, r.start.month, r.start.day), DateTime(r.end.year, r.end.month, r.end.day + 1));

Future<DateTime?> pickDateTime(BuildContext c, {DateTime? initial}) async {
  final base = initial ?? DateTime.now().add(const Duration(days: 1));
  final d = await showDatePicker(context: c, initialDate: base, firstDate: DateTime(2015), lastDate: DateTime(2100));
  if (d == null || !c.mounted) return null;
  final t = await showTimePicker(context: c, initialTime: TimeOfDay.fromDateTime(base));
  if (t == null) return null;
  return DateTime(d.year, d.month, d.day, t.hour, t.minute);
}
