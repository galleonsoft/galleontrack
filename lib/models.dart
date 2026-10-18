import 'core.dart';

const defaultStatuses = [
  'New', 'Not Contacted', 'Attempted', 'Contacted', 'Connected', 'Qualified',
  'Follow-up Required', 'Interested', 'Negotiation', 'Won', 'Lost',
  'Not Interested', 'Invalid Number', 'Do Not Contact',
];
const closedStatuses = {'Won', 'Lost', 'Not Interested', 'Invalid Number', 'Do Not Contact'};

class Settings {

  Settings();

  bool onboarded = false;
  String workspace = '', business = '', adminName = '', country = 'IN';
  String themeMode = 'system', serverUrl = '', defaultEmployeeId = '', role = 'admin';
  int workStartMin = 540, workEndMin = 1080, weekStart = 1;
  int retentionDays = 0, rrIndex = 0, maxActiveLeads = 0;
  int followUpHour = 10, contactDeadlineDays = 3;
  List<int> workDays = [1, 2, 3, 4, 5];
  List<String> holidays = []; // yyyy-MM-dd (local)
  List<String> statuses = List.of(defaultStatuses);
  List<String> disabledStatuses = [];
  int lastNativeMs = 0;
  DateTime? lastImport, lastBackup;

  List<String> get activeStatuses =>
      statuses.where((s) => !disabledStatuses.contains(s)).toList();

  /// Supports overnight shifts (end <= start) and holidays.
  bool isWorkingTime(DateTime utc) {
    final t = utc.toLocal();
    final key = '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
    if (holidays.contains(key)) return false;
    final m = t.hour * 60 + t.minute;
    final s = workStartMin, e = workEndMin;
    if (s < e) return workDays.contains(t.weekday) && m >= s && m < e;
    if (m >= s) return workDays.contains(t.weekday);
    if (m < e) return workDays.contains(t.weekday == 1 ? 7 : t.weekday - 1);
    return false;
  }

  Map<String, dynamic> toJson() => {
        'onboarded': onboarded, 'workspace': workspace, 'business': business,
        'adminName': adminName, 'country': country, 'themeMode': themeMode,
        'serverUrl': serverUrl, 'defaultEmployeeId': defaultEmployeeId, 'role': role,
        'workStartMin': workStartMin, 'workEndMin': workEndMin, 'weekStart': weekStart,
        'retentionDays': retentionDays, 'rrIndex': rrIndex, 'maxActiveLeads': maxActiveLeads,
        'followUpHour': followUpHour, 'contactDeadlineDays': contactDeadlineDays,
        'workDays': workDays, 'holidays': holidays, 'statuses': statuses,
        'disabledStatuses': disabledStatuses, 'lastNativeMs': lastNativeMs,
        'lastImport': sd(lastImport), 'lastBackup': sd(lastBackup),
      };

  factory Settings.fromJson(Map<String, dynamic> j) {
    final s = Settings();
    s.onboarded = j['onboarded'] ?? false;
    s.workspace = j['workspace'] ?? '';
    s.business = j['business'] ?? '';
    s.adminName = j['adminName'] ?? '';
    s.country = j['country'] ?? 'IN';
    s.themeMode = j['themeMode'] ?? 'system';
    s.serverUrl = j['serverUrl'] ?? '';
    s.defaultEmployeeId = j['defaultEmployeeId'] ?? '';
    s.role = j['role'] ?? 'admin';
    s.workStartMin = j['workStartMin'] ?? 540;
    s.workEndMin = j['workEndMin'] ?? 1080;
    s.weekStart = j['weekStart'] ?? 1;
    s.retentionDays = j['retentionDays'] ?? 0;
    s.rrIndex = j['rrIndex'] ?? 0;
    s.maxActiveLeads = j['maxActiveLeads'] ?? 0;
    s.followUpHour = j['followUpHour'] ?? 10;
    s.contactDeadlineDays = j['contactDeadlineDays'] ?? 3;
    s.workDays = List<int>.from(j['workDays'] ?? [1, 2, 3, 4, 5]);
    s.holidays = List<String>.from(j['holidays'] ?? []);
    s.statuses = List<String>.from(j['statuses'] ?? defaultStatuses);
    s.disabledStatuses = List<String>.from(j['disabledStatuses'] ?? []);
    s.lastNativeMs = j['lastNativeMs'] ?? 0;
    s.lastImport = pd(j['lastImport']);
    s.lastBackup = pd(j['lastBackup']);
    return s;
  }
}

class Employee {
  Employee({
    String? id, required this.name, this.code = '', this.phone = '', this.email = '',
    this.teamId, this.role = 'employee', this.active = true, this.notes = '',
    DateTime? createdAt, DateTime? updatedAt,
  })  : id = id ?? newId(),
        createdAt = createdAt ?? DateTime.now().toUtc(),
        updatedAt = updatedAt ?? DateTime.now().toUtc();
  final String id;
  String name, code, phone, email, role, notes;
  String? teamId;
  bool active;
  DateTime createdAt, updatedAt;

  Map<String, dynamic> toJson() => {
        'id': id, 'name': name, 'code': code, 'phone': phone, 'email': email,
        'teamId': teamId, 'role': role, 'active': active, 'notes': notes,
        'createdAt': sd(createdAt), 'updatedAt': sd(updatedAt),
      };
  factory Employee.fromJson(Map<String, dynamic> j) => Employee(
        id: j['id'], name: j['name'], code: j['code'] ?? '', phone: j['phone'] ?? '',
        email: j['email'] ?? '', teamId: j['teamId'], role: j['role'] ?? 'employee',
        active: j['active'] ?? true, notes: j['notes'] ?? '',
        createdAt: pd(j['createdAt']), updatedAt: pd(j['updatedAt']),
      );
}

class Team {
  Team({String? id, required this.name, this.leaderId, DateTime? createdAt})
      : id = id ?? newId(),
        createdAt = createdAt ?? DateTime.now().toUtc();
  final String id;
  String name;
  String? leaderId;
  DateTime createdAt;
  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'leaderId': leaderId, 'createdAt': sd(createdAt)};
  factory Team.fromJson(Map<String, dynamic> j) => Team(
      id: j['id'], name: j['name'], leaderId: j['leaderId'], createdAt: pd(j['createdAt']));
}

class Lead {
  Lead({
    String? id, required this.name, required this.phone, this.phone2 = '', this.email = '',
    this.company = '', this.city = '', this.source = '', this.campaign = '',
    this.assignedEmployeeId, this.teamId, this.status = 'New', this.priority = 'Medium',
    List<String>? tags, this.notes = '', DateTime? createdAt, this.lastContactedAt,
    this.lastConnectedAt, this.nextFollowUp, this.lastCallId, this.archived = false,
    List<Map<String, dynamic>>? statusHistory, this.isDemo = false,
  })  : id = id ?? newId(),
        tags = tags ?? [],
        createdAt = createdAt ?? DateTime.now().toUtc(),
        statusHistory = statusHistory ??
            [{'status': status, 'at': sd(DateTime.now().toUtc()), 'by': ''}];
  final String id;
  String name, phone, phone2, email, company, city, source, campaign, status, priority, notes;
  String? assignedEmployeeId, teamId, lastCallId;
  List<String> tags;
  DateTime createdAt;
  DateTime? lastContactedAt, lastConnectedAt, nextFollowUp;
  bool archived, isDemo;
  List<Map<String, dynamic>> statusHistory;

  bool get closed => closedStatuses.contains(status);

  Map<String, dynamic> toJson() => {
        'id': id, 'name': name, 'phone': phone, 'phone2': phone2, 'email': email,
        'company': company, 'city': city, 'source': source, 'campaign': campaign,
        'assignedEmployeeId': assignedEmployeeId, 'teamId': teamId, 'status': status,
        'priority': priority, 'tags': tags, 'notes': notes, 'createdAt': sd(createdAt),
        'lastContactedAt': sd(lastContactedAt), 'lastConnectedAt': sd(lastConnectedAt),
        'nextFollowUp': sd(nextFollowUp), 'lastCallId': lastCallId, 'archived': archived,
        'statusHistory': statusHistory, 'isDemo': isDemo,
      };
  factory Lead.fromJson(Map<String, dynamic> j) => Lead(
        id: j['id'], name: j['name'], phone: j['phone'], phone2: j['phone2'] ?? '',
        email: j['email'] ?? '', company: j['company'] ?? '', city: j['city'] ?? '',
        source: j['source'] ?? '', campaign: j['campaign'] ?? '',
        assignedEmployeeId: j['assignedEmployeeId'], teamId: j['teamId'],
        status: j['status'] ?? 'New', priority: j['priority'] ?? 'Medium',
        tags: List<String>.from(j['tags'] ?? []), notes: j['notes'] ?? '',
        createdAt: pd(j['createdAt']), lastContactedAt: pd(j['lastContactedAt']),
        lastConnectedAt: pd(j['lastConnectedAt']), nextFollowUp: pd(j['nextFollowUp']),
        lastCallId: j['lastCallId'], archived: j['archived'] ?? false,
        statusHistory: (j['statusHistory'] as List? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map)).toList(),
        isDemo: j['isDemo'] ?? false,
      );
}

class CallRecord {
  CallRecord({
    String? id, required this.phone, this.contactName = '', this.employeeId, this.teamId,
    required this.direction, required this.outcome, required this.start,
    this.durationSec = 0, this.nativeId, this.leadId, this.notes = '',
    this.needsFollowUp = false, this.followUpDue, this.leadStatusAtCall,
    this.source = 'manual', DateTime? createdAt, DateTime? updatedAt,
  })  : id = id ?? newId(),
        normalized = normalizePhone(phone),
        createdAt = createdAt ?? DateTime.now().toUtc(),
        updatedAt = updatedAt ?? DateTime.now().toUtc();
  final String id;
  String phone, contactName, direction, outcome, notes, source;
  final String normalized;
  String? employeeId, teamId, nativeId, leadId, leadStatusAtCall;
  DateTime start;
  int durationSec;
  bool needsFollowUp;
  DateTime? followUpDue;
  DateTime createdAt, updatedAt;

  DateTime get end => start.add(Duration(seconds: durationSec));
  String get key => phoneKey(phone);
  bool get connected => outcome == Outcome.connected;

  Map<String, dynamic> toJson() => {
        'id': id, 'phone': phone, 'normalized': normalized, 'contactName': contactName,
        'employeeId': employeeId, 'teamId': teamId, 'direction': direction,
        'outcome': outcome, 'start': sd(start), 'end': sd(end), 'durationSec': durationSec,
        'nativeId': nativeId, 'leadId': leadId, 'notes': notes,
        'needsFollowUp': needsFollowUp, 'followUpDue': sd(followUpDue),
        'leadStatusAtCall': leadStatusAtCall, 'source': source,
        'createdAt': sd(createdAt), 'updatedAt': sd(updatedAt),
      };
  factory CallRecord.fromJson(Map<String, dynamic> j) => CallRecord(
        id: j['id'], phone: j['phone'], contactName: j['contactName'] ?? '',
        employeeId: j['employeeId'], teamId: j['teamId'],
        direction: j['direction'] ?? Dir.unknown, outcome: j['outcome'] ?? Outcome.unknown,
        start: pd(j['start'])!, durationSec: j['durationSec'] ?? 0, nativeId: j['nativeId'],
        leadId: j['leadId'], notes: j['notes'] ?? '', needsFollowUp: j['needsFollowUp'] ?? false,
        followUpDue: pd(j['followUpDue']), leadStatusAtCall: j['leadStatusAtCall'],
        source: j['source'] ?? 'manual', createdAt: pd(j['createdAt']),
        updatedAt: pd(j['updatedAt']),
      );
}

class FollowUp {
  FollowUp({
    String? id, required this.leadId, this.employeeId, required this.dueAt,
    this.priority = 'Medium', this.type = 'Call', this.description = '',
    this.status = 'pending', this.completedAt, this.outcome = '', this.callId,
    this.remindMinutesBefore = 15, DateTime? createdAt, DateTime? updatedAt,
  })  : id = id ?? newId(),
        createdAt = createdAt ?? DateTime.now().toUtc(),
        updatedAt = updatedAt ?? DateTime.now().toUtc();
  final String id;
  String leadId, priority, type, description, status, outcome;
  String? employeeId, callId;
  DateTime dueAt, createdAt, updatedAt;
  DateTime? completedAt;
  int remindMinutesBefore;

  bool get open => status == 'pending';
  bool get overdue => open && dueAt.isBefore(DateTime.now().toUtc());
  bool get dueToday {
    final d = dueAt.toLocal(), n = DateTime.now();
    return open && d.year == n.year && d.month == n.month && d.day == n.day;
  }

  /// Display state: Pending, Due Today, Overdue, Completed, Cancelled.
  String get label =>
      !open ? (status == 'completed' ? 'Completed' : 'Cancelled')
          : overdue ? 'Overdue' : dueToday ? 'Due Today' : 'Pending';

  Map<String, dynamic> toJson() => {
        'id': id, 'leadId': leadId, 'employeeId': employeeId, 'dueAt': sd(dueAt),
        'priority': priority, 'type': type, 'description': description, 'status': status,
        'completedAt': sd(completedAt), 'outcome': outcome, 'callId': callId,
        'remindMinutesBefore': remindMinutesBefore, 'createdAt': sd(createdAt),
        'updatedAt': sd(updatedAt),
      };
  factory FollowUp.fromJson(Map<String, dynamic> j) => FollowUp(
        id: j['id'], leadId: j['leadId'], employeeId: j['employeeId'], dueAt: pd(j['dueAt'])!,
        priority: j['priority'] ?? 'Medium', type: j['type'] ?? 'Call',
        description: j['description'] ?? '', status: j['status'] ?? 'pending',
        completedAt: pd(j['completedAt']), outcome: j['outcome'] ?? '', callId: j['callId'],
        remindMinutesBefore: j['remindMinutesBefore'] ?? 15,
        createdAt: pd(j['createdAt']), updatedAt: pd(j['updatedAt']),
      );
}

class ExcludedNumber {
  ExcludedNumber({String? id, required this.phone, this.reason = '', this.active = true,
      this.createdBy = '', DateTime? createdAt})
      : id = id ?? newId(),
        createdAt = createdAt ?? DateTime.now().toUtc();
  final String id;
  String phone, reason, createdBy;
  bool active;
  DateTime createdAt;
  String get normalized => normalizePhone(phone);
  Map<String, dynamic> toJson() => {
        'id': id, 'phone': phone, 'normalized': normalized, 'reason': reason,
        'active': active, 'createdBy': createdBy, 'createdAt': sd(createdAt),
      };
  factory ExcludedNumber.fromJson(Map<String, dynamic> j) => ExcludedNumber(
      id: j['id'], phone: j['phone'], reason: j['reason'] ?? '', active: j['active'] ?? true,
      createdBy: j['createdBy'] ?? '', createdAt: pd(j['createdAt']));
}

class ExportHistory {
  ExportHistory({String? id, required this.url, required this.categories,
      required this.counts, required this.sizeBytes, required this.status,
      this.error = '', DateTime? at})
      : id = id ?? newId(),
        at = at ?? DateTime.now().toUtc();
  final String id; // equals the export ID sent to the server
  String url, status, error;
  List<String> categories;
  Map<String, int> counts;
  int sizeBytes;
  DateTime at;
  Map<String, dynamic> toJson() => {
        'id': id, 'url': url, 'categories': categories, 'counts': counts,
        'sizeBytes': sizeBytes, 'status': status, 'error': error, 'at': sd(at),
      };
  factory ExportHistory.fromJson(Map<String, dynamic> j) => ExportHistory(
        id: j['id'], url: j['url'] ?? '', categories: List<String>.from(j['categories'] ?? []),
        counts: Map<String, int>.from(j['counts'] ?? {}), sizeBytes: j['sizeBytes'] ?? 0,
        status: j['status'] ?? '', error: j['error'] ?? '', at: pd(j['at']),
      );
}
