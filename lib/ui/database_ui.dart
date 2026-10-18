import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core.dart';
import '../db.dart';
import '../models.dart';
import '../services/call_log_service.dart';
import '../services/database_export_api_service.dart';
import '../services/packages.dart';
import 'widgets.dart';

String _size(int b) => b < 1024 ? '$b B' : b < 1048576 ? '${(b / 1024).toStringAsFixed(1)} KB' : '${(b / 1048576).toStringAsFixed(1)} MB';

class DatabaseScreen extends ConsumerWidget {
  const DatabaseScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(dbProvider);
    final h = db.health();
    final backups = listBackups(db);
    return Scaffold(
      appBar: AppBar(title: const Text('Database')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Section('Status (Hive CE, schema v${Db.schemaVersion})', Column(children: [
          for (final e in h.entries) ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text(e.key), trailing: Text('${e.value}', style: TextStyle(color: e.key != 'employees' && e.key != 'teams' && e.key != 'leads' && e.key != 'calls' && e.key != 'followUps' && e.key != 'excludedNumbers' && e.value > 0 ? Colors.red : null))),
          Text('Last backup: ${fmtDt(db.settings.lastBackup)}'),
        ])),
        Section('Local backup (never uses the network)', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Backups are plain ZIP files in app storage. They are NOT encrypted — treat them as sensitive.'),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            FilledButton.icon(icon: const Icon(Icons.backup), label: const Text('Create full backup'), onPressed: () => guard(context, () async {
              final f = await writeBackup(db, categoryLabels.keys.toSet());
              if (context.mounted) toast(context, 'Backup saved: ${f.path}');
            })),
          ]),
          for (final f in backups.take(10)) ListTile(
            dense: true, contentPadding: EdgeInsets.zero, title: Text(f.path.split('/').last, style: const TextStyle(fontSize: 12)), subtitle: Text(_size(f.lengthSync())),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(icon: const Icon(Icons.share), onPressed: () => guard(context, () => Native.shareFile(f.path, 'application/zip'))),
              IconButton(icon: const Icon(Icons.restore), onPressed: () => _restore(context, ref, f)),
              IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => guard(context, () async {
                if (await confirm(context, 'Delete backup file?', f.path, ok: 'Delete')) { await f.delete(); db.touch(); }
              })),
            ]),
          ),
        ])),
        Section('Server export (optional)', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Send selected data to a server you configure. Only happens when you confirm an export.'),
          const SizedBox(height: 8),
          FilledButton.icon(icon: const Icon(Icons.cloud_upload), label: const Text('Export to server…'), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ExportScreen()))),
        ])),
        Section('Export history', db.exports.length == 0 ? const Text('No server exports yet') : Column(children: [
          for (final e in (db.exports.values.toList()..sort((a, b) => b.at.compareTo(a.at))).take(20))
            ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text('${fmtDt(e.at)} • ${e.status}'), subtitle: Text('${e.url}\n${e.counts.entries.map((x) => '${x.key}:${x.value}').join(', ')} • ${_size(e.sizeBytes)}${e.error.isEmpty ? '' : '\n${e.error}'}'), isThreeLine: true),
        ])),
        Section('Danger zone', Wrap(spacing: 8, children: [
          OutlinedButton.icon(icon: const Icon(Icons.delete_forever, color: Colors.red), label: const Text('Delete all leads, calls & follow-ups'), onPressed: () => guard(context, () async {
            if (await confirm(context, 'Delete all business data?', 'Leads, calls, follow-ups and exclusions will be erased from this device. Employees, teams and settings are kept. Create a backup first.', ok: 'Delete everything')) {
              await db.wipeBusinessData();
              if (context.mounted) toast(context, 'Data deleted.');
            }
          })),
        ])),
      ]),
    );
  }

  Future<void> _restore(BuildContext context, WidgetRef ref, File f) async {
    final db = ref.read(dbProvider);
    await guard(context, () async {
      final p = parsePackage(await f.readAsBytes());
      final staged = stage(p);
      if (!context.mounted) return;
      final mode = await showDialog<String>(context: context, builder: (d) => AlertDialog(
        title: const Text('Restore backup'),
        content: Text('Created ${p.manifest['createdAt']}\nSchema v${p.manifest['schemaVersion']}\n\n${p.counts.entries.map((e) => '${categoryLabels[e.key]}: ${e.value}').join('\n')}\n\n'
            'Merge: adds/updates records by ID, keeps everything else.\nReplace: clears the included categories first.\n'
            'A safety backup of current data is written before anything changes.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          OutlinedButton(onPressed: () => Navigator.pop(d, 'merge'), child: const Text('Merge')),
          FilledButton(onPressed: () => Navigator.pop(d, 'replace'), child: const Text('Replace')),
        ],
      ));
      if (mode == null) return;
      await writeBackup(db, categoryLabels.keys.toSet(), prefix: 'pre-restore');
      await applyStaged(db, p, staged, replace: mode == 'replace');
      final h = db.health();
      if (context.mounted) toast(context, 'Restored. Orphan references — calls→lead: ${h['callsWithMissingLead']}, calls→employee: ${h['callsWithMissingEmployee']}.');
    });
  }
}

class ExportScreen extends ConsumerStatefulWidget {
  const ExportScreen({super.key, this.service});
  final DatabaseExportApiService? service;
  @override
  ConsumerState<ExportScreen> createState() => _ExportState();
}

class _ExportState extends ConsumerState<ExportScreen> {
  final _url = TextEditingController(), _token = TextEditingController();
  final Set<String> _cats = {};
  Range? _range;
  String? _emp;
  BuiltPackage? _pkg;
  double _progress = 0;
  bool _sending = false;
  ExportResult? _result;
  ExportCancelToken? _cancel;

  @override
  void initState() {
    super.initState();
    _url.text = ref.read(dbProvider).settings.serverUrl;
  }

  void _prepare() {
    final db = ref.read(dbProvider);
    setState(() {
      _result = null;
      _pkg = _cats.isEmpty ? null : buildPackage(db, _cats, range: _range, employeeIds: _emp == null ? null : {_emp!}, forServer: true, purpose: 'server-export');
    });
  }

  Future<void> _send() async {
    final db = ref.read(dbProvider);
    final pkg = _pkg!;
    final uri = DatabaseExportApiService.endpoint(_url.text);
    if (uri == null) { toast(context, 'Enter a valid server URL (https recommended).'); return; }
    final warn = uri.scheme == 'http' ? '\n\nWARNING: this URL is not HTTPS; data would be sent unencrypted.' : '';
    final ok = await confirm(context, 'Send data to server?',
        'You are about to send ${pkg.counts.entries.map((e) => '${e.value} ${categoryLabels[e.key]}').join(', ')} (${_size(pkg.bytes.length)}) to:\n${uri.toString()}\n\n'
        'This contains personal data of leads, employees and callers. Only send to a server you trust and are authorised to use.$warn',
        ok: 'Send');
    if (!ok) return;
    db.settings.serverUrl = _url.text.trim();
    await guard(context, db.saveSettings);
    setState(() { _sending = true; _progress = 0; _result = null; _cancel = ExportCancelToken(); });
    final res = await (widget.service ?? DatabaseExportApiService()).send(
      baseUrl: _url.text, archive: pkg.bytes, manifest: pkg.manifest, authToken: _token.text, cancel: _cancel,
      onProgress: (s, t) { if (mounted) setState(() => _progress = s / t); });
    try {
      await db.exports.put(ExportHistory(id: pkg.manifest['exportId'] as String, url: uri.toString(), categories: List<String>.from(pkg.manifest['categories'] as List), counts: pkg.counts, sizeBytes: pkg.bytes.length, status: res.state, error: res.ok ? '' : res.message));
    } catch (_) {}
    if (mounted) setState(() { _sending = false; _result = res; });
  }

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(dbProvider);
    final counts = {
      'settings': 1, 'employees': db.employees.length, 'teams': db.teams.length, 'leads': db.leads.length,
      'calls': db.calls.length, 'follow_ups': db.followUps.length, 'excluded_numbers': db.excluded.length,
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Export to server')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Card(color: Colors.orange.withValues(alpha: 0.15), child: const Padding(padding: EdgeInsets.all(12), child: Text(
            'Privacy: this is the only feature that uses the network, and it runs only when you press Send and confirm. '
            'Nothing is uploaded automatically and failed exports are never retried automatically. Call recordings are not included in this build.'))),
        const SizedBox(height: 8),
        TextField(controller: _url, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'Server base URL', hintText: 'https://example.com', helperText: 'POST /api/v1/database-export is appended')),
        const SizedBox(height: 8),
        TextField(controller: _token, obscureText: true, decoration: const InputDecoration(labelText: 'Bearer token (optional, not stored)')),
        Section('Data to export', Column(children: [
          for (final e in categoryLabels.entries)
            CheckboxListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text(e.value), subtitle: Text('${counts[e.key]} records'), value: _cats.contains(e.key), onChanged: (v) => setState(() { v! ? _cats.add(e.key) : _cats.remove(e.key); _pkg = null; })),
          Row(children: [
            Expanded(child: DropdownButtonFormField<String?>(value: _emp, isExpanded: true, decoration: const InputDecoration(labelText: 'Employee filter'), items: [const DropdownMenuItem(value: null, child: Text('All')), for (final e in db.employees.values) DropdownMenuItem(value: e.id, child: Text(e.name))], onChanged: (v) => setState(() { _emp = v; _pkg = null; }))),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: () async { final r = await pickRange(context, _range); if (r != null) setState(() { _range = rangeFromPicker(r); _pkg = null; }); }, child: Text(_range == null ? 'All dates' : '${fmtDate(_range!.from)}–${fmtDate(_range!.to.subtract(const Duration(days: 1)))}')),
            if (_range != null) IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(() { _range = null; _pkg = null; })),
          ]),
          const Text('Date range applies to calls and follow-ups; the employee filter applies to employees, leads, calls and follow-ups.', style: TextStyle(fontSize: 11)),
        ])),
        FilledButton.tonal(onPressed: _cats.isEmpty || _sending ? null : _prepare, child: const Text('Prepare & preview package')),
        if (_pkg != null) Section('Preview', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final e in _pkg!.counts.entries) Text('${categoryLabels[e.key]}: ${e.value}'),
          Text('Archive size: ${_size(_pkg!.bytes.length)}'),
          Text('Export ID: ${_pkg!.manifest['exportId']}', style: const TextStyle(fontSize: 11)),
          const Text('The server URL is never included in the package.', style: TextStyle(fontSize: 11)),
        ])),
        if (_sending) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(value: _progress),
          Row(children: [Text('${(_progress * 100).round()}%'), const Spacer(), TextButton(onPressed: () => _cancel?.cancel(), child: const Text('Cancel upload'))]),
        ],
        if (_pkg != null && !_sending) Padding(padding: const EdgeInsets.only(top: 8), child: FilledButton.icon(icon: const Icon(Icons.cloud_upload), label: const Text('Review & send…'), onPressed: _send)),
        if (_result != null) Card(
          color: (_result!.ok ? Colors.green : Colors.red).withValues(alpha: 0.12),
          child: Padding(padding: const EdgeInsets.all(12), child: Text('${_result!.ok ? 'Sent' : 'Not sent / unconfirmed'}: ${_result!.message}\nYour local data is unchanged. To retry, press Send again.')),
        ),
      ]),
    );
  }
}
