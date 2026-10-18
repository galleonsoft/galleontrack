import 'dart:math';

final _rng = Random.secure();

/// RFC-4122 v4 UUID.
String newId() {
  final b = List<int>.generate(16, (_) => _rng.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// Keeps a leading '+' and digits only.
String normalizePhone(String raw) {
  final t = raw.trim();
  final d = t.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.isEmpty) return '';
  return t.startsWith('+') ? '+$d' : d;
}

/// Matching key: last 10 digits (so +91 98765 43210 == 09876543210).
String phoneKey(String raw) {
  final d = raw.replaceAll(RegExp(r'[^0-9]'), '');
  return d.length > 10 ? d.substring(d.length - 10) : d;
}

bool isValidPhone(String raw) {
  final d = raw.replaceAll(RegExp(r'[^0-9]'), '');
  return d.length >= 5 && d.length <= 15;
}

bool isValidEmail(String s) =>
    s.isEmpty || RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s);

DateTime? pd(dynamic v) => v == null ? null : DateTime.parse(v as String).toUtc();
String? sd(DateTime? d) => d?.toUtc().toIso8601String();

enum Role { readOnly, employee, manager, admin }

Role roleFrom(String? s) =>
    Role.values.firstWhere((r) => r.name == s, orElse: () => Role.admin);

extension RoleX on Role {
  int get rank => index;
  String get label => switch (this) {
        Role.readOnly => 'Read-only',
        Role.employee => 'Employee',
        Role.manager => 'Manager',
        Role.admin => 'Administrator',
      };
}

class PermissionDenied implements Exception {
  PermissionDenied(this.what);
  final String what;
  @override
  String toString() => 'Permission denied: $what';
}

class Dir {
  static const incoming = 'incoming', outgoing = 'outgoing', missed = 'missed',
      rejected = 'rejected', unknown = 'unknown';
  static const all = [incoming, outgoing, missed, rejected, unknown];
}

class Outcome {
  static const connected = 'connected', notConnected = 'notConnected',
      unanswered = 'unanswered', unknown = 'unknown';
  static const all = [connected, notConnected, unanswered, unknown];
}

/// Half-open range [from, to).
class Range {
  const Range(this.from, this.to);
  final DateTime from, to;
  bool contains(DateTime t) => !t.isBefore(from) && t.isBefore(to);
  int get days => max(1, to.difference(from).inHours ~/ 24);
}

enum Period { today, yesterday, thisWeek, thisMonth, lastMonth, custom }

const periodLabels = {
  Period.today: 'Today',
  Period.yesterday: 'Yesterday',
  Period.thisWeek: 'This week',
  Period.thisMonth: 'This month',
  Period.lastMonth: 'Previous month',
  Period.custom: 'Custom',
};

Range rangeFor(Period p, DateTime now, {int weekStart = 1, Range? custom}) {
  final today = DateTime(now.year, now.month, now.day);
  switch (p) {
    case Period.today:
      return Range(today, DateTime(today.year, today.month, today.day + 1));
    case Period.yesterday:
      return Range(DateTime(today.year, today.month, today.day - 1), today);
    case Period.thisWeek:
      final off = (today.weekday - weekStart + 7) % 7;
      final s = DateTime(today.year, today.month, today.day - off);
      return Range(s, DateTime(s.year, s.month, s.day + 7));
    case Period.thisMonth:
      return Range(DateTime(now.year, now.month), DateTime(now.year, now.month + 1));
    case Period.lastMonth:
      return Range(DateTime(now.year, now.month - 1), DateTime(now.year, now.month));
    case Period.custom:
      return custom ?? rangeFor(Period.today, now);
  }
}

/// Spreadsheet formula-injection safe CSV cell.
String csvCell(Object? v) {
  var s = v == null ? '' : v.toString();
  if (v is! num && s.isNotEmpty && '=+-@\t\r'.contains(s[0])) s = "'$s";
  if (s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r')) {
    s = '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

String toCsv(List<String> headers, List<List<Object?>> rows) {
  final b = StringBuffer('\uFEFF');
  b.write('${headers.map(csvCell).join(',')}\r\n');
  for (final r in rows) {
    b.write('${r.map(csvCell).join(',')}\r\n');
  }
  return b.toString();
}

String maskPhone(String p) =>
    p.length <= 4 ? p : '${'*' * (p.length - 4)}${p.substring(p.length - 4)}';
