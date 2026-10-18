import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core.dart';
import '../db.dart';
import '../models.dart';
import '../services/analytics.dart';
import '../services/ops.dart';
import '../services/call_log_service.dart';
import '../services/reports.dart';
import 'calls.dart';
import 'followups.dart';
import 'widgets.dart';

Color statusColor(String s) => switch (s) {
  'Won' => Colors.green.shade700,
  'Lost' ||
  'Not Interested' ||
  'Invalid Number' ||
  'Do Not Contact' => Colors.red.shade700,
  'Qualified' || 'Interested' || 'Negotiation' => Colors.teal,
  'Follow-up Required' => Colors.orange.shade800,
  _ => Colors.blueGrey,
};

class LeadsScreen extends ConsumerStatefulWidget {
  const LeadsScreen({super.key});

  @override
  ConsumerState<LeadsScreen> createState() => _LeadsState();
}

class _LeadsState extends ConsumerState<LeadsScreen> {
  String q = '', view = 'all', sort = 'newest';
  String? status, employeeId, source;
  bool archived = false;
  int page = 50;
  final _sel = <String>{};

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(dbProvider);
    final ops = ref.read(opsProvider);
    Iterable<Lead> src = db.leads.values.where((l) => l.archived == archived);
    switch (view) {
      case 'never':
        src = leadsNeverContacted(src, db.calls.values);
      case 'notconnected':
        src = leadsNotConnected(src, db.calls.values);
      case 'unassigned':
        src = src.where((l) => l.assignedEmployeeId == null);
      case 'stale':
        final cut = DateTime.now().toUtc().subtract(
          Duration(days: db.settings.contactDeadlineDays),
        );
        src = src.where(
          (l) => !l.closed && (l.lastContactedAt ?? l.createdAt).isBefore(cut),
        );
      case 'today':
        final r = rangeFor(Period.today, DateTime.now());
        src = src.where(
          (l) =>
              !l.closed &&
              (l.lastContactedAt == null || !r.contains(l.lastContactedAt!)),
        );
      case 'followup':
        src = src.where((l) => l.nextFollowUp != null);
    }
    final list = src
        .where(
          (l) =>
              (status == null || l.status == status) &&
              (employeeId == null || l.assignedEmployeeId == employeeId) &&
              (source == null || l.source == source) &&
              (q.isEmpty ||
                  '${l.name} ${l.phone} ${l.email} ${l.company} ${l.city} ${l.tags.join(' ')}'
                      .toLowerCase()
                      .contains(q)),
        )
        .toList();
    switch (sort) {
      case 'name':
        list.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
      case 'contacted':
        list.sort(
          (a, b) => (b.lastContactedAt ?? DateTime(2000)).compareTo(
            a.lastContactedAt ?? DateTime(2000),
          ),
        );
      case 'followup':
        list.sort(
          (a, b) => (a.nextFollowUp ?? DateTime(2100)).compareTo(
            b.nextFollowUp ?? DateTime(2100),
          ),
        );
      default:
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    final shown = list.take(page).toList();
    const views = {
      'all': 'All',
      'never': 'Never contacted',
      'today': 'Not contacted today',
      'stale': 'Overdue contact',
      'notconnected': 'Not connected',
      'unassigned': 'Unassigned',
      'followup': 'Has follow-up',
    };
    return Scaffold(
      appBar: AppBar(
        title: Text(_sel.isEmpty ? 'Leads' : '${_sel.length} selected'),
        actions: _sel.isEmpty
            ? [
                IconButton(
                  icon: const Icon(Icons.tune),
                  onPressed: () => _filters(db),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'rr') {
                      guard(context, () async {
                        final un = db.leads.values
                            .where(
                              (l) =>
                                  l.assignedEmployeeId == null &&
                                  !l.archived &&
                                  !l.closed,
                            )
                            .toList();
                        if (un.isEmpty) {
                          toast(context, 'No unassigned leads.');
                          return;
                        }
                        final g = await ops.roundRobin(un);
                        if (context.mounted)
                          toast(
                            context,
                            g.isEmpty
                                ? 'No eligible employees (check active status / limits).'
                                : 'Assigned ${g.values.fold(0, (a, b) => a + b)} leads by round-robin.',
                          );
                      });
                    }
                    if (v == 'workload') _workload(db, ops);
                    if (v == 'archived') setState(() => archived = !archived);
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'rr',
                      child: Text('Round-robin assign unassigned'),
                    ),
                    const PopupMenuItem(
                      value: 'workload',
                      child: Text('Workload summary'),
                    ),
                    PopupMenuItem(
                      value: 'archived',
                      child: Text(
                        archived ? 'Show active leads' : 'Show archived leads',
                      ),
                    ),
                  ],
                ),
              ]
            : [
                IconButton(
                  icon: const Icon(Icons.person_pin),
                  tooltip: 'Assign selected',
                  onPressed: () async {
                    final id = await _pickEmployee(context, db);
                    if (id == null || !context.mounted) return;
                    await guard(context, () async {
                      await ops.assign(
                        db.leads.values
                            .where((l) => _sel.contains(l.id))
                            .toList(),
                        id == '' ? null : id,
                      );
                      setState(_sel.clear);
                    });
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(_sel.clear),
                ),
              ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.person_add),
        label: const Text('New lead'),
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const LeadForm()),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: SearchBox(
              hint: 'Search leads',
              onChanged: (v) => setState(() {
                q = v;
                page = 50;
              }),
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                for (final e in views.entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: ChoiceChip(
                      label: Text(e.value),
                      selected: view == e.key,
                      onSelected: (_) => setState(() => view = e.key),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${list.length} leads${archived ? ' (archived)' : ''}',
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
          ),
          Expanded(
            child: shown.isEmpty
                ? const EmptyState(
                    Icons.people_outline,
                    'No leads match this view.',
                  )
                : ListView.builder(
                    itemCount:
                        shown.length + (list.length > shown.length ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (i == shown.length)
                        return TextButton(
                          onPressed: () => setState(() => page += 50),
                          child: Text(
                            'Load more (${list.length - shown.length} left)',
                          ),
                        );
                      final l = shown[i];
                      return LeadTile(
                        l,
                        db: db,
                        selected: _sel.contains(l.id),
                        onLong: () => setState(() => _sel.add(l.id)),
                        onTap: _sel.isEmpty
                            ? () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => LeadDetail(l.id),
                                ),
                              )
                            : () => setState(
                                () => _sel.contains(l.id)
                                    ? _sel.remove(l.id)
                                    : _sel.add(l.id),
                              ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _filters(Db db) {
    final sources =
        db.leads.values
            .map((l) => l.source)
            .where((s) => s.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    showModalBottomSheet(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, set) {
          void both(VoidCallback f) {
            set(f);
            setState(f);
          }

          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String?>(
                  value: status,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Status'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('Any')),
                    for (final s in db.settings.statuses)
                      DropdownMenuItem(value: s, child: Text(s)),
                  ],
                  onChanged: (v) => both(() => status = v),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String?>(
                  value: employeeId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Employee'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('Any')),
                    for (final e in db.employees.values)
                      DropdownMenuItem(value: e.id, child: Text(e.name)),
                  ],
                  onChanged: (v) => both(() => employeeId = v),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String?>(
                  value: source,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Source'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('Any')),
                    for (final s in sources)
                      DropdownMenuItem(value: s, child: Text(s)),
                  ],
                  onChanged: (v) => both(() => source = v),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: sort,
                  decoration: const InputDecoration(labelText: 'Sort'),
                  items: const [
                    DropdownMenuItem(value: 'newest', child: Text('Newest')),
                    DropdownMenuItem(value: 'name', child: Text('Name')),
                    DropdownMenuItem(
                      value: 'contacted',
                      child: Text('Last contacted'),
                    ),
                    DropdownMenuItem(
                      value: 'followup',
                      child: Text('Next follow-up'),
                    ),
                  ],
                  onChanged: (v) => both(() => sort = v!),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Done'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _workload(Db db, Ops ops) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Workload'),
        content: SizedBox(
          width: 300,
          child: db.employees.length == 0
              ? const Text('No employees')
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final e in db.employees.values.where((e) => e.active))
                      ListTile(
                        dense: true,
                        title: Text(e.name),
                        trailing: Text(
                          '${ops.activeLeadCount(e.id)} active${db.settings.maxActiveLeads > 0 ? ' / ${db.settings.maxActiveLeads}' : ''}',
                        ),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

/// Returns employee id, '' for unassigned, or null if cancelled.
Future<String?> _pickEmployee(BuildContext c, Db db) => showDialog<String>(
  context: c,
  builder: (d) => SimpleDialog(
    title: const Text('Assign to'),
    children: [
      SimpleDialogOption(
        onPressed: () => Navigator.pop(d, ''),
        child: const Text('Unassigned'),
      ),
      for (final e in db.employees.values.where((e) => e.active))
        SimpleDialogOption(
          onPressed: () => Navigator.pop(d, e.id),
          child: Text(e.name),
        ),
    ],
  ),
);

class LeadTile extends StatelessWidget {
  const LeadTile(
    this.l, {
    super.key,
    required this.db,
    required this.onTap,
    this.onLong,
    this.selected = false,
  });

  final Lead l;
  final Db db;
  final VoidCallback onTap;
  final VoidCallback? onLong;
  final bool selected;

  @override
  Widget build(BuildContext context) => ListTile(
    selected: selected,
    onTap: onTap,
    onLongPress: onLong,
    leading: CircleAvatar(
      child: Text(l.name.isEmpty ? '?' : l.name[0].toUpperCase()),
    ),
    title: Text(l.name),
    subtitle: Text(
      '${l.phone}${l.company.isNotEmpty ? ' • ${l.company}' : ''}\n${db.employees.get(l.assignedEmployeeId)?.name ?? 'Unassigned'} • last contact ${fmtDate(l.lastContactedAt)}',
    ),
    isThreeLine: true,
    trailing: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        StatusChip(l.status, color: statusColor(l.status)),
        if (l.nextFollowUp != null)
          Text(
            fmtDate(l.nextFollowUp),
            style: TextStyle(
              fontSize: 10,
              color: l.nextFollowUp!.isBefore(DateTime.now().toUtc())
                  ? Colors.red
                  : null,
            ),
          ),
      ],
    ),
  );
}

class LeadForm extends ConsumerStatefulWidget {
  const LeadForm({
    super.key,
    this.leadId,
    this.prefillPhone,
    this.prefillName,
    this.linkCallId,
  });

  final String? leadId, prefillPhone, prefillName, linkCallId;

  @override
  ConsumerState<LeadForm> createState() => _LeadFormState();
}

class _LeadFormState extends ConsumerState<LeadForm> {
  final _f = GlobalKey<FormState>();
  late final Lead lead;
  late final bool isNew;
  late final TextEditingController name,
      phone,
      phone2,
      email,
      company,
      city,
      source,
      campaign,
      tags,
      notes;

  @override
  void initState() {
    super.initState();
    final ex = widget.leadId == null
        ? null
        : ref.read(dbProvider).leads.get(widget.leadId);
    isNew = ex == null;
    lead =
        ex ??
        Lead(name: widget.prefillName ?? '', phone: widget.prefillPhone ?? '');
    name = TextEditingController(text: lead.name);
    phone = TextEditingController(text: lead.phone);
    phone2 = TextEditingController(text: lead.phone2);
    email = TextEditingController(text: lead.email);
    company = TextEditingController(text: lead.company);
    city = TextEditingController(text: lead.city);
    source = TextEditingController(text: lead.source);
    campaign = TextEditingController(text: lead.campaign);
    tags = TextEditingController(text: lead.tags.join(', '));
    notes = TextEditingController(text: lead.notes);
  }

  Widget _t(
    TextEditingController c,
    String l, {
    TextInputType? k,
    String? Function(String?)? v,
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextFormField(
      controller: c,
      keyboardType: k,
      maxLines: lines,
      decoration: InputDecoration(labelText: l),
      validator: v,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(dbProvider);
    return Scaffold(
      appBar: AppBar(title: Text(isNew ? 'New lead' : 'Edit lead')),
      body: Form(
        key: _f,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _t(
              name,
              'Full name',
              v: (v) => v!.trim().isEmpty ? 'Required' : null,
            ),
            _t(
              phone,
              'Primary phone',
              k: TextInputType.phone,
              v: (v) => isValidPhone(v ?? '') ? null : 'Enter a valid phone',
            ),
            _t(
              phone2,
              'Secondary phone',
              k: TextInputType.phone,
              v: (v) => v!.isEmpty || isValidPhone(v) ? null : 'Invalid phone',
            ),
            _t(
              email,
              'Email',
              k: TextInputType.emailAddress,
              v: (v) => isValidEmail(v ?? '') ? null : 'Invalid email',
            ),
            _t(company, 'Company'),
            _t(city, 'City'),
            _t(source, 'Source'),
            _t(campaign, 'Campaign'),
            _t(tags, 'Tags (comma separated)'),
            DropdownButtonFormField<String>(
              initialValue: lead.priority,
              decoration: const InputDecoration(
                labelText: 'Priority',
              ),
              items: const [
                DropdownMenuItem(value: 'Low', child: Text('Low')),
                DropdownMenuItem(value: 'Medium', child: Text('Medium')),
                DropdownMenuItem(value: 'High', child: Text('High')),
              ],
              onChanged: (v) {
                if (v != null) {
                  lead.priority = v;
                }
              },
            ),
            const SizedBox(height: 10),
            if (isNew)
              DropdownButtonFormField<String>(
                value: db.settings.activeStatuses.contains(lead.status)
                    ? lead.status
                    : null,
                decoration: const InputDecoration(labelText: 'Status'),
                items: [
                  for (final s in db.settings.activeStatuses)
                    DropdownMenuItem(value: s, child: Text(s)),
                ],
                onChanged: (v) {
                  lead.status = v!;
                  lead.statusHistory = [
                    {
                      'status': v,
                      'at': sd(DateTime.now()),
                      'by': db.settings.adminName,
                    },
                  ];
                },
              ),
            if (isNew) const SizedBox(height: 10),
            DropdownButtonFormField<String?>(
              value: lead.assignedEmployeeId,
              decoration: const InputDecoration(labelText: 'Assigned employee'),
              items: [
                const DropdownMenuItem(value: null, child: Text('Unassigned')),
                for (final e in db.employees.values.where((e) => e.active))
                  DropdownMenuItem(value: e.id, child: Text(e.name)),
              ],
              onChanged: (v) {
                lead.assignedEmployeeId = v;
                lead.teamId = db.employees.get(v)?.teamId;
              },
            ),
            const SizedBox(height: 10),
            _t(notes, 'Notes', lines: 3),
            FilledButton(
              onPressed: () => guard(context, () async {
                if (!_f.currentState!.validate()) return;
                lead
                  ..name = name.text.trim()
                  ..phone = phone.text.trim()
                  ..phone2 = phone2.text.trim()
                  ..email = email.text.trim()
                  ..company = company.text.trim()
                  ..city = city.text.trim()
                  ..source = source.text.trim()
                  ..campaign = campaign.text.trim()
                  ..tags = tags.text
                      .split(',')
                      .map((e) => e.trim())
                      .where((e) => e.isNotEmpty)
                      .toList()
                  ..notes = notes.text.trim();
                final ops = ref.read(opsProvider);
                final err = ops.validateLead(lead, isNew: isNew);
                if (err != null) {
                  toast(context, err);
                  return;
                }
                await ops.saveLead(lead);
                if (widget.linkCallId != null) {
                  final c = db.calls.get(widget.linkCallId);
                  if (c != null) {
                    c.leadId = lead.id;
                    await ops.updateCall(c);
                  }
                }
                if (isNew) {
                  await ops.addManualCallLinks(lead);
                }
                if (context.mounted) Navigator.pop(context);
              }),
              child: const Text('Save lead'),
            ),
          ],
        ),
      ),
    );
  }
}

class LeadDetail extends ConsumerWidget {
  const LeadDetail(this.id, {super.key});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(dbProvider);
    final ops = ref.read(opsProvider);
    final l = db.leads.get(id);
    if (l == null)
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(Icons.error_outline, 'Lead not found'),
      );
    final calls = db.calls.values.where((c) => c.leadId == l.id).toList()
      ..sort((a, b) => b.start.compareTo(a.start));
    final fus = db.followUps.values.where((f) => f.leadId == l.id).toList()
      ..sort((a, b) => b.dueAt.compareTo(a.dueAt));
    final sum = leadCallSummary(l.id, calls);
    return Scaffold(
      appBar: AppBar(
        title: Text(l.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => LeadForm(leadId: l.id)),
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (v) => guard(context, () async {
              if (v == 'archive') {
                l.archived = !l.archived;
                await ops.saveLead(l);
              }
              if (v == 'won') await ops.setStatus(l, 'Won');
              if (v == 'lost') await ops.setStatus(l, 'Lost');
              if (v == 'export') {
                final t = ReportTable(
                  'Lead',
                  [
                    'Name',
                    'Phone',
                    'Email',
                    'Company',
                    'Status',
                    'Assigned to',
                    'Notes',
                  ],
                  [
                    [
                      l.name,
                      l.phone,
                      l.email,
                      l.company,
                      l.status,
                      db.employees.get(l.assignedEmployeeId)?.name ?? '',
                      l.notes,
                    ],
                  ],
                );
                final f = await writeCsv(
                  db,
                  t,
                  List.generate(t.headers.length, (i) => i),
                  'lead',
                );
                await Native.shareFile(
                  f.path,
                  'text/csv',
                ).catchError((_) => toast(context, 'Saved to ${f.path}'));
              }
              if (v == 'delete' &&
                  await confirm(
                    context,
                    'Delete lead?',
                    'The lead and its follow-ups are deleted. Call records are kept but unlinked.',
                    ok: 'Delete',
                  )) {
                await ops.deleteLead(l);
                if (context.mounted) Navigator.pop(context);
              }
            }),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'won', child: Text('Mark won')),
              const PopupMenuItem(value: 'lost', child: Text('Mark lost')),
              PopupMenuItem(
                value: 'archive',
                child: Text(l.archived ? 'Unarchive' : 'Archive'),
              ),
              const PopupMenuItem(
                value: 'export',
                child: Text('Export lead (CSV)'),
              ),
              const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              StatusChip(l.status, color: statusColor(l.status)),
              StatusChip('Priority ${l.priority}'),
              if (l.archived) const StatusChip('Archived', color: Colors.grey),
              ...l.tags.map((t) => StatusChip('#$t', color: Colors.indigo)),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.call),
                label: const Text('Call'),
                onPressed: () => Native.dial(l.phone)
                    .catchError((_) => toast(context, 'Dialer unavailable')),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.swap_horiz),
                label: const Text('Status'),
                onPressed: () async {
                  final s = await showDialog<String>(
                    context: context,
                    builder: (d) => SimpleDialog(
                      title: const Text('Change status'),
                      children: [
                        for (final s in db.settings.activeStatuses)
                          SimpleDialogOption(
                            onPressed: () => Navigator.pop(d, s),
                            child: Text(s),
                          ),
                      ],
                    ),
                  );
                  if (s != null && context.mounted)
                    await guard(context, () => ops.setStatus(l, s));
                },
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.person_pin),
                label: const Text('Assign'),
                onPressed: () async {
                  final e = await _pickEmployee(context, db);
                  if (e != null && context.mounted)
                    await guard(
                      context,
                      () => ops.assign([l], e == '' ? null : e),
                    );
                },
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.event),
                label: const Text('Follow-up'),
                onPressed: () => showFollowUpDialog(context, ref, l),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.note_add),
                label: const Text('Note'),
                onPressed: () async {
                  final t = TextEditingController();
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (d) => AlertDialog(
                      title: const Text('Add note'),
                      content: TextField(
                        controller: t,
                        maxLines: 4,
                        autofocus: true,
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(d, false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(d, true),
                          child: const Text('Add'),
                        ),
                      ],
                    ),
                  );
                  if (ok == true &&
                      t.text.trim().isNotEmpty &&
                      context.mounted) {
                    await guard(context, () async {
                      l.notes =
                          '${l.notes}${l.notes.isEmpty ? '' : '\n'}[${fmtDt(DateTime.now())}] ${t.text.trim()}';
                      await ops.saveLead(l);
                    });
                  }
                },
              ),
            ],
          ),
          Section(
            'Details',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Phone: ${l.phone}${l.phone2.isEmpty ? '' : ' / ${l.phone2}'}',
                ),
                if (l.email.isNotEmpty) Text('Email: ${l.email}'),
                if (l.company.isNotEmpty) Text('Company: ${l.company}'),
                if (l.city.isNotEmpty) Text('City: ${l.city}'),
                Text(
                  'Source: ${l.source.isEmpty ? '—' : l.source}${l.campaign.isEmpty ? '' : ' / ${l.campaign}'}',
                ),
                Text(
                  'Assigned: ${db.employees.get(l.assignedEmployeeId)?.name ?? 'Unassigned'}',
                ),
                Text('Created: ${fmtDt(l.createdAt)}'),
                Text('Last contacted: ${fmtDt(l.lastContactedAt)}'),
                Text('Last connected: ${fmtDt(l.lastConnectedAt)}'),
                Text('Next follow-up: ${fmtDt(l.nextFollowUp)}'),
                Text(
                  'Attempts (known outcome): ${sum.attempts} • connected calls: ${sum.connected}',
                ),
                if (l.notes.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(l.notes),
                ],
              ],
            ),
          ),
          Section(
            'Calls (${calls.length})',
            calls.isEmpty
                ? const Text('No calls linked yet')
                : Column(
                    children: [
                      for (final c in calls.take(20)) CallTile(c, db: db),
                    ],
                  ),
          ),
          Section(
            'Follow-ups (${fus.length})',
            fus.isEmpty
                ? const Text('None scheduled')
                : Column(
                    children: [
                      for (final f in fus)
                        FollowUpTile(f, db: db, showLead: false),
                    ],
                  ),
          ),
          Section(
            'Status history',
            Column(
              children: [
                for (final h in l.statusHistory.reversed)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('${h['status']}'),
                    subtitle: Text(fmtDt(pd(h['at']))),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
