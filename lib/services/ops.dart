import '../core.dart';
import '../db.dart';
import '../models.dart';
import 'call_log_service.dart';

class ImportResult {
  ImportResult(this.added, this.duplicates, this.linked);
  final int added, duplicates, linked;
}

/// Business operations. All persistence goes through role-checked collections.
class Ops {
  Ops(this.db);
  final Db db;

  // ---------- Calls ----------
  Lead? matchLead(String phone) {
    final k = phoneKey(phone);
    if (k.isEmpty) return null;
    final m = db.leads.values.where((l) => phoneKey(l.phone) == k || (l.phone2.isNotEmpty && phoneKey(l.phone2) == k)).toList();
    return m.length == 1 ? m.first : null; // ambiguous matches stay unlinked
  }

  String _dupKey(CallRecord c) => '${c.key}|${c.start.millisecondsSinceEpoch}|${c.durationSec}|${c.direction}';

  /// Incremental, idempotent import. Dedup: native ID first, else exact
  /// number+start+duration+direction. Distinct calls are never merged by fuzzy time.
  Future<ImportResult> importNative(List<Map<String, dynamic>> raw) async {
    final nativeIds = {for (final c in db.calls.values) if (c.nativeId != null) c.nativeId};
    final keys = {for (final c in db.calls.values) _dupKey(c)};
    final fresh = <CallRecord>[];
    var dup = 0, maxMs = db.settings.lastNativeMs;
    for (final m in raw) {
      final c = callFromNative(m, employeeId: db.settings.defaultEmployeeId.isEmpty ? null : db.settings.defaultEmployeeId);
      maxMs = c.start.millisecondsSinceEpoch > maxMs ? c.start.millisecondsSinceEpoch : maxMs;
      if ((c.nativeId != null && nativeIds.contains(c.nativeId)) || keys.contains(_dupKey(c))) {
        dup++;
        continue;
      }
      nativeIds.add(c.nativeId);
      keys.add(_dupKey(c));
      fresh.add(c);
    }
    final linked = await _linkAndUpdateLeads(fresh);
    await db.calls.putAll(fresh);
    db.settings.lastNativeMs = maxMs;
    db.settings.lastImport = DateTime.now().toUtc();
    await db.saveSettingsForce();
    return ImportResult(fresh.length, dup, linked);
  }

  Future<void> addManualCall(CallRecord c) async {
    c.leadId ??= matchLead(c.phone)?.id;
    await _linkAndUpdateLeads([c]);
    await db.calls.put(c);
  }

  Future<int> _linkAndUpdateLeads(List<CallRecord> cs) async {
    final touched = <String, Lead>{};
    var linked = 0;
    final byKey = <String, List<Lead>>{};
    for (final l in db.leads.values) {
      for (final p in [l.phone, l.phone2]) {
        if (p.isNotEmpty) (byKey[phoneKey(p)] ??= []).add(l);
      }
    }
    for (final c in cs) {
      Lead? l = c.leadId != null ? db.leads.get(c.leadId) : null;
      if (l == null) {
        final m = byKey[c.key];
        if (m != null && m.toSet().length == 1) l = m.first;
      }
      if (l == null) continue;
      c.leadId = l.id;
      c.leadStatusAtCall = l.status;
      linked++;
      if (c.direction == Dir.outgoing || c.connected) {
        if (l.lastContactedAt == null || c.start.isAfter(l.lastContactedAt!)) {
          l.lastContactedAt = c.start;
          l.lastCallId = c.id;
        }
      }
      if (c.connected && (l.lastConnectedAt == null || c.start.isAfter(l.lastConnectedAt!))) {
        l.lastConnectedAt = c.start;
      }
      if (c.direction == Dir.outgoing) {
        final next = c.connected ? 'Connected' : 'Attempted';
        if (['New', 'Not Contacted', 'Attempted'].contains(l.status) &&
            db.settings.activeStatuses.contains(next) &&
            !(next == 'Attempted' && l.status == 'Attempted')) {
          _pushStatus(l, next);
        }
      }
      touched[l.id] = l;
    }
    if (touched.isNotEmpty) await db.leads.putAll(touched.values);
    return linked;
  }

  Future<void> updateCall(CallRecord c) async {
    c.updatedAt = DateTime.now().toUtc();
    await db.calls.put(c);
  }

  // ---------- Leads ----------
  void _pushStatus(Lead l, String status) {
    l.status = status;
    l.statusHistory.add({'status': status, 'at': sd(DateTime.now()), 'by': db.settings.adminName});
  }

  String? validateLead(Lead l, {bool isNew = false}) {
    if (l.name.trim().isEmpty) return 'Name is required';
    if (!isValidPhone(l.phone)) return 'Enter a valid phone number';
    if (!isValidEmail(l.email)) return 'Enter a valid email';
    final k = phoneKey(l.phone);
    if (db.leads.values.any((o) => o.id != l.id && !o.archived && phoneKey(o.phone) == k)) {
      return 'A lead with this phone number already exists';
    }
    return null;
  }

  Future<void> saveLead(Lead l) async {
    await db.leads.put(l);
    await db.audit('lead', l.id, 'save');
  }

  Future<void> setStatus(Lead l, String status) async {
    if (l.status == status) return;
    _pushStatus(l, status);
    if (l.closed) {
      l.nextFollowUp = null;
      final open = db.followUps.values.where((f) => f.leadId == l.id && f.open).toList();
      for (final f in open) {
        f.status = 'cancelled';
        f.updatedAt = DateTime.now().toUtc();
      }
      await db.followUps.putAll(open);
    }
    await db.leads.put(l);
    await db.audit('lead', l.id, 'status', status);
  }

  Future<void> assign(Iterable<Lead> leads, String? employeeId) async {
    final e = db.employees.get(employeeId);
    for (final l in leads) {
      l.assignedEmployeeId = employeeId;
      l.teamId = e?.teamId;
    }
    await db.leads.putAll(leads);
    for (final l in leads) {
      await db.audit('lead', l.id, 'assign', employeeId ?? 'unassigned');
    }
  }

  int activeLeadCount(String employeeId) => db.leads.values
      .where((l) => l.assignedEmployeeId == employeeId && !l.archived && !l.closed).length;

  /// Deterministic round-robin: active employees ordered by (name, id); pointer
  /// persisted in settings; employees at the active-lead limit are skipped.
  Future<Map<String, int>> roundRobin(List<Lead> leads, {String? teamId}) async {
    final emps = db.employees.values.where((e) => e.active && (teamId == null || e.teamId == teamId)).toList()
      ..sort((a, b) {
        final c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    final given = <String, int>{};
    if (emps.isEmpty) return given;
    final load = {for (final e in emps) e.id: activeLeadCount(e.id)};
    final max = db.settings.maxActiveLeads;
    var idx = db.settings.rrIndex;
    for (final l in leads) {
      Employee? pick;
      for (var tries = 0; tries < emps.length; tries++) {
        final e = emps[idx % emps.length];
        idx++;
        if (max == 0 || load[e.id]! < max) {
          pick = e;
          break;
        }
      }
      if (pick == null) break; // everyone at capacity
      l.assignedEmployeeId = pick.id;
      l.teamId = pick.teamId;
      load[pick.id] = load[pick.id]! + 1;
      given[pick.id] = (given[pick.id] ?? 0) + 1;
    }
    db.settings.rrIndex = idx % emps.length;
    await db.leads.putAll(leads.where((l) => given.isNotEmpty && l.assignedEmployeeId != null));
    await db.saveSettingsForce();
    return given;
  }

  Future<void> deleteLead(Lead l) async {
    await db.followUps.deleteAll(db.followUps.values.where((f) => f.leadId == l.id).map((f) => f.id));
    final cs = db.calls.values.where((c) => c.leadId == l.id).toList();
    for (final c in cs) {
      c.leadId = null;
    }
    await db.calls.putAll(cs);
    await db.leads.delete(l.id);
    await db.audit('lead', l.id, 'delete');
  }

  // ---------- Follow-ups ----------
  String? validateFollowUp(FollowUp f) {
    final l = db.leads.get(f.leadId);
    if (l == null) return 'Lead not found';
    if (l.status == 'Do Not Contact') return 'Lead is marked Do Not Contact';
    if (l.closed) return 'Lead is closed';
    return null;
  }

  Future<void> saveFollowUp(FollowUp f) async {
    f.updatedAt = DateTime.now().toUtc();
    await db.followUps.put(f);
    await _refreshNext(f.leadId);
  }

  Future<void> completeFollowUp(FollowUp f, String outcome) async {
    f.status = 'completed';
    f.completedAt = DateTime.now().toUtc();
    f.outcome = outcome;
    await saveFollowUp(f);
  }

  Future<void> cancelFollowUp(FollowUp f) async {
    f.status = 'cancelled';
    await saveFollowUp(f);
  }

  Future<void> reschedule(FollowUp f, DateTime due) async {
    f.dueAt = due.toUtc();
    f.status = 'pending';
    await saveFollowUp(f);
    await db.audit('followup', f.id, 'reschedule');
  }

  Future<void> _refreshNext(String leadId) async {
    final l = db.leads.get(leadId);
    if (l == null) return;
    final open = db.followUps.values.where((f) => f.leadId == leadId && f.open).toList()
      ..sort((a, b) => a.dueAt.compareTo(b.dueAt));
    l.nextFollowUp = open.isEmpty ? null : open.first.dueAt;
    await db.leads.put(l);
  }

  // ---------- Exclusions ----------
  Future<void> exclude(String phone, String reason) async {
    final k = phoneKey(phone);
    final ex = db.excluded.values.where((e) => phoneKey(e.phone) == k).toList();
    if (ex.isNotEmpty) {
      ex.first.active = true;
      await db.excluded.put(ex.first);
    } else {
      await db.excluded.put(ExcludedNumber(phone: phone, reason: reason, createdBy: db.settings.adminName));
    }
  }

  // ---------- Retention ----------
  Future<int> purgeCallsOlderThan(int days) async {
    final cut = DateTime.now().toUtc().subtract(Duration(days: days));
    final ids = db.calls.values.where((c) => c.start.isBefore(cut)).map((c) => c.id).toList();
    await db.calls.deleteAll(ids);
    return ids.length;
  }

  // ---------- Demo data ----------
  Future<void> createDemoData() async {
    final now = DateTime.now();
    final team = Team(name: 'Demo Sales');
    final emps = [for (final n in ['Demo Asha', 'Demo Ravi', 'Demo Meera']) Employee(name: n, teamId: team.id, notes: 'DEMO DATA')];
    await db.teams.put(team);
    await db.employees.putAll(emps);
    final leads = <Lead>[];
    for (var i = 0; i < 12; i++) {
      leads.add(Lead(
        name: 'Demo Lead ${i + 1}', phone: '+91 90000 ${10000 + i}', company: 'Demo Co ${i % 4}',
        source: ['Website', 'Referral', 'Ad'][i % 3], assignedEmployeeId: emps[i % 3].id,
        teamId: team.id, tags: ['demo'], isDemo: true));
    }
    await db.leads.putAll(leads);
    final calls = <CallRecord>[];
    for (var i = 0; i < 60; i++) {
      final dir = [Dir.outgoing, Dir.incoming, Dir.missed, Dir.outgoing][i % 4];
      final dur = dir == Dir.missed || i % 5 == 0 ? 0 : 20 + (i * 37) % 400;
      calls.add(CallRecord(
        phone: leads[i % 12].phone, contactName: leads[i % 12].name, employeeId: emps[i % 3].id,
        teamId: team.id, direction: dir,
        outcome: dir == Dir.missed ? Outcome.notConnected : dur > 0 ? Outcome.connected : Outcome.unanswered,
        start: now.subtract(Duration(hours: i * 7, minutes: i * 3)).toUtc(), durationSec: dur,
        notes: 'DEMO', source: 'demo'));
    }
    await _linkAndUpdateLeads(calls);
    await db.calls.putAll(calls);
  }

  Future<void> removeDemoData() async {
    await db.calls.deleteAll(db.calls.values.where((c) => c.source == 'demo').map((c) => c.id));
    final demoLeads = db.leads.values.where((l) => l.isDemo).map((l) => l.id).toSet();
    await db.followUps.deleteAll(db.followUps.values.where((f) => demoLeads.contains(f.leadId)).map((f) => f.id));
    await db.leads.deleteAll(demoLeads);
    final emps = db.employees.values.where((e) => e.notes == 'DEMO DATA').map((e) => e.id).toList();
    await db.employees.deleteAll(emps);
    await db.teams.deleteAll(db.teams.values.where((t) => t.name == 'Demo Sales').map((t) => t.id));
  }
}

extension LeadCallLinking on Ops {
  /// After creating a lead, link existing calls with the same number.
  Future<void> addManualCallLinks(Lead l) async {
    final k = phoneKey(l.phone);
    final cs = db.calls.values.where((c) => c.leadId == null && c.key == k).toList();
    if (cs.isEmpty) return;
    for (final c in cs) {
      c.leadId = l.id;
      c.leadStatusAtCall = l.status;
      if (c.direction == Dir.outgoing || c.connected) {
        if (l.lastContactedAt == null || c.start.isAfter(l.lastContactedAt!)) { l.lastContactedAt = c.start; l.lastCallId = c.id; }
      }
      if (c.connected && (l.lastConnectedAt == null || c.start.isAfter(l.lastConnectedAt!))) l.lastConnectedAt = c.start;
    }
    await db.calls.putAll(cs);
    await db.leads.put(l);
  }
}
