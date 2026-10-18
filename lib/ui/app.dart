import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models.dart';
import '../services/call_log_service.dart';
import '../core.dart';
import 'calls.dart';
import 'dashboard.dart';
import 'followups.dart';
import 'leads.dart';
import 'more.dart';
import 'widgets.dart';

export 'widgets.dart' show dbProvider;

ThemeData _theme(Brightness b) {
  final cs = ColorScheme.fromSeed(seedColor: const Color(0xFF1E3A8A), brightness: b);
  return ThemeData(
    useMaterial3: true,
    colorScheme: cs,
    visualDensity: VisualDensity.compact,
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder(), isDense: true),
  );
}

class GalleonApp extends ConsumerWidget {
  const GalleonApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(dbProvider);
    final mode = switch (db.settings.themeMode) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    return MaterialApp(
      title: 'GalleonTrack',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: mode,
      home: db.settings.onboarded ? const Shell() : const Onboarding(),
    );
  }
}

class Onboarding extends ConsumerStatefulWidget {
  const Onboarding({super.key});
  @override
  ConsumerState<Onboarding> createState() => _OnboardingState();
}

class _OnboardingState extends ConsumerState<Onboarding> {
  final _f = GlobalKey<FormState>();
  final _biz = TextEditingController(), _ws = TextEditingController(text: 'Main workspace'), _admin = TextEditingController();
  bool _demo = false, _perm = false, _busy = false;
  String _theme = 'system';

  Future<void> _finish() async {
    if (!_f.currentState!.validate()) return;
    setState(() => _busy = true);
    final db = ref.read(dbProvider);
    final ops = ref.read(opsProvider);
    final me = Employee(name: _admin.text.trim(), role: 'admin', notes: 'Workspace administrator');
    db.settings
      ..business = _biz.text.trim()
      ..workspace = _ws.text.trim()
      ..adminName = _admin.text.trim()
      ..themeMode = _theme
      ..defaultEmployeeId = me.id
      ..role = 'admin'
      ..onboarded = false;
    await db.saveSettingsForce();
    await db.employees.put(me);
    if (_perm) await Native.requestCallLogPermission(); // optional; denial is fine
    if (_demo) await ops.createDemoData();
    db.settings.onboarded = true;
    await db.saveSettingsForce();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Welcome to GalleonTrack')),
        body: Form(
          key: _f,
          child: ListView(padding: const EdgeInsets.all(16), children: [
            const Card(child: Padding(padding: EdgeInsets.all(12), child: Text(
                'GalleonTrack works fully offline. Everything you enter stays on this device in a local database. '
                'No account is needed. Data leaves the device only if you open Database → Export to server, '
                'choose what to send and confirm.'))),
            const SizedBox(height: 12),
            TextFormField(controller: _biz, decoration: const InputDecoration(labelText: 'Business name'), validator: (v) => v!.trim().isEmpty ? 'Required' : null),
            const SizedBox(height: 12),
            TextFormField(controller: _ws, decoration: const InputDecoration(labelText: 'Workspace name'), validator: (v) => v!.trim().isEmpty ? 'Required' : null),
            const SizedBox(height: 12),
            TextFormField(controller: _admin, decoration: const InputDecoration(labelText: 'Administrator name'), validator: (v) => v!.trim().isEmpty ? 'Required' : null),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [ButtonSegment(value: 'system', label: Text('System')), ButtonSegment(value: 'light', label: Text('Light')), ButtonSegment(value: 'dark', label: Text('Dark'))],
              selected: {_theme},
              onSelectionChanged: (s) => setState(() => _theme = s.first),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Allow call-log access now (optional)'),
              subtitle: const Text('Used only to import call history into this device\'s database. You can skip and enter calls manually.'),
              value: _perm, onChanged: (v) => setState(() => _perm = v)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Add clearly-labelled demo data'),
              subtitle: const Text('Sample employees, leads and calls marked "Demo". Removable in Settings.'),
              value: _demo, onChanged: (v) => setState(() => _demo = v)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _busy ? null : _finish, child: Text(_busy ? 'Setting up…' : 'Create workspace')),
          ]),
        ),
      );
}

class Shell extends ConsumerStatefulWidget {
  const Shell({super.key});
  @override
  ConsumerState<Shell> createState() => _ShellState();
}

class _ShellState extends ConsumerState<Shell> {
  int _i = 0;
  static const _dest = [
    (Icons.dashboard_outlined, Icons.dashboard, 'Dashboard'),
    (Icons.call_outlined, Icons.call, 'Calls'),
    (Icons.people_outline, Icons.people, 'Leads'),
    (Icons.event_available_outlined, Icons.event_available, 'Follow-ups'),
    (Icons.more_horiz, Icons.more_horiz, 'More'),
  ];
  @override
  Widget build(BuildContext context) {
    const pages = [DashboardScreen(), CallsScreen(), LeadsScreen(), FollowUpsScreen(), MoreScreen()];
    final wide = MediaQuery.of(context).size.width >= 700;
    final body = IndexedStack(index: _i, children: pages);
    return Scaffold(
      body: wide
          ? Row(children: [
              NavigationRail(
                selectedIndex: _i,
                onDestinationSelected: (i) => setState(() => _i = i),
                labelType: NavigationRailLabelType.all,
                destinations: [for (final d in _dest) NavigationRailDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: Text(d.$3))],
              ),
              Expanded(child: body),
            ])
          : body,
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _i,
              onDestinationSelected: (i) => setState(() => _i = i),
              destinations: [for (final d in _dest) NavigationDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: d.$3)],
            ),
    );
  }
}
