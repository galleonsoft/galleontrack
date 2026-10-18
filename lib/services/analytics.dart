import '../core.dart';
import '../models.dart';

/// Formulas (documented in README):
///  connectionRate = connected OUTGOING / (connected OUTGOING + unanswered OUTGOING) * 100
///                   (outgoing calls with unknown outcome are excluded).
///  missedRate     = missed / (incoming + missed + rejected) * 100
///  avgConnected   = totalConnectedSeconds / connected calls
///  callsPerWorkingDay = total / number of distinct local days that contain a call within working time (min 1)
class CallStats {
  int total = 0, incoming = 0, outgoing = 0, missed = 0, rejected = 0;
  int connected = 0, unanswered = 0, unknownOutcome = 0;
  int connectedOutgoing = 0, unansweredOutgoing = 0;
  int connectedSeconds = 0, inHours = 0, outHours = 0, connectedSecondsInHours = 0;
  DateTime? firstInHours, lastInHours;

  double get avgConnected => connected == 0 ? 0 : connectedSeconds / connected;
  double? get connectionRate {
    final d = connectedOutgoing + unansweredOutgoing;
    return d == 0 ? null : connectedOutgoing * 100 / d;
  }

  double? get missedRate {
    final d = incoming + missed + rejected;
    return d == 0 ? null : missed * 100 / d;
  }
}

CallStats computeStats(Iterable<CallRecord> calls, Settings s) {
  final st = CallStats();
  for (final c in calls) {
    st.total++;
    switch (c.direction) {
      case Dir.incoming:
        st.incoming++;
      case Dir.outgoing:
        st.outgoing++;
      case Dir.missed:
        st.missed++;
      case Dir.rejected:
        st.rejected++;
    }
    switch (c.outcome) {
      case Outcome.connected:
        st.connected++;
        st.connectedSeconds += c.durationSec;
        if (c.direction == Dir.outgoing) st.connectedOutgoing++;
      case Outcome.unanswered:
        st.unanswered++;
        if (c.direction == Dir.outgoing) st.unansweredOutgoing++;
      case Outcome.unknown:
        st.unknownOutcome++;
    }
    if (s.isWorkingTime(c.start)) {
      st.inHours++;
      if (c.connected) st.connectedSecondsInHours += c.durationSec;
      if (st.firstInHours == null || c.start.isBefore(st.firstInHours!)) st.firstInHours = c.start;
      if (st.lastInHours == null || c.start.isAfter(st.lastInHours!)) st.lastInHours = c.start;
    } else {
      st.outHours++;
    }
  }
  return st;
}

/// Bucketed counts: hourly if the range is one day, else daily.
({List<int> values, List<String> labels}) bucketCounts(
    Iterable<CallRecord> calls, Range r, bool Function(CallRecord) pick) {
  final hourly = r.days <= 1;
  final n = hourly ? 24 : r.days.clamp(1, 62);
  final v = List<int>.filled(n, 0);
  for (final c in calls) {
    if (!pick(c)) continue;
    final t = c.start.toLocal();
    final i = hourly ? t.hour : DateTime(t.year, t.month, t.day).difference(r.from).inDays;
    if (i >= 0 && i < n) v[i]++;
  }
  final labels = List.generate(n, (i) => hourly ? '$i' : '${r.from.add(Duration(days: i)).day}');
  return (values: v, labels: labels);
}

Map<String, int> durationBuckets(Iterable<CallRecord> calls) {
  final m = {'<30s': 0, '30s-2m': 0, '2-5m': 0, '>5m': 0};
  for (final c in calls.where((c) => c.connected)) {
    final d = c.durationSec;
    final k = d < 30 ? '<30s' : d < 120 ? '30s-2m' : d < 300 ? '2-5m' : '>5m';
    m[k] = m[k]! + 1;
  }
  return m;
}

/// Attempts = outgoing calls linked to the lead whose outcome is known.
/// Unknown outcomes are NOT counted as failed connections.
({int attempts, int connected, DateTime? lastAttempt}) leadCallSummary(
    String leadId, Iterable<CallRecord> calls) {
  var a = 0, c = 0;
  DateTime? last;
  for (final x in calls) {
    if (x.leadId != leadId) continue;
    if (x.connected) c++;
    if (x.direction == Dir.outgoing && x.outcome != Outcome.unknown) {
      a++;
      if (last == null || x.start.isAfter(last)) last = x.start;
    }
  }
  return (attempts: a, connected: c, lastAttempt: last);
}

/// Never contacted: no lastContactedAt and no linked outgoing call.
List<Lead> leadsNeverContacted(Iterable<Lead> leads, Iterable<CallRecord> calls) {
  final contacted = {for (final c in calls.where((c) => c.leadId != null && c.direction == Dir.outgoing)) c.leadId};
  return leads.where((l) => !l.archived && !l.closed && l.lastContactedAt == null && !contacted.contains(l.id)).toList();
}

/// Not connected: at least one known-outcome attempt, zero connected calls.
List<Lead> leadsNotConnected(Iterable<Lead> leads, Iterable<CallRecord> calls) {
  final out = <Lead>[];
  final list = calls.toList();
  for (final l in leads.where((l) => !l.archived && !l.closed)) {
    final s = leadCallSummary(l.id, list);
    if (s.attempts > 0 && s.connected == 0 && l.lastConnectedAt == null) out.add(l);
  }
  return out;
}

class EmployeeRow {
  EmployeeRow(this.employee, this.stats, this.leadsContacted, this.fuDone, this.fuTotal);
  final Employee employee;
  final CallStats stats;
  final int leadsContacted, fuDone, fuTotal;
}

List<EmployeeRow> employeePerformance(
    Iterable<Employee> emps, Iterable<CallRecord> calls, Iterable<FollowUp> fus, Settings s, Range r) {
  return emps.map((e) {
    final cs = calls.where((c) => c.employeeId == e.id).toList();
    final f = fus.where((x) => x.employeeId == e.id && r.contains(x.dueAt)).toList();
    return EmployeeRow(
      e, computeStats(cs, s), cs.where((c) => c.leadId != null).map((c) => c.leadId).toSet().length,
      f.where((x) => x.status == 'completed').length, f.where((x) => x.status != 'cancelled').length);
  }).toList();
}

String fmtDuration(num sec) {
  final s = sec.round();
  if (s < 60) return '${s}s';
  final h = s ~/ 3600, m = (s % 3600) ~/ 60;
  return h > 0 ? '${h}h ${m}m' : '${m}m ${s % 60}s';
}
