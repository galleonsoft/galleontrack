import 'package:flutter/services.dart';
import '../core.dart';
import '../models.dart';

/// Android bridge (Kotlin MainActivity). Only READ_CALL_LOG is requested.
class Native {
  static const _ch = MethodChannel('galleontrack/native');

  static Future<bool> hasCallLogPermission() async {
    try {
      return await _ch.invokeMethod<bool>('hasPermission') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<bool> requestCallLogPermission() async {
    try {
      return await _ch.invokeMethod<bool>('requestPermission') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<List<Map<String, dynamic>>> getCalls(int sinceMs) async {
    final r = await _ch.invokeMethod<List<dynamic>>('getCalls', {'since': sinceMs});
    return (r ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  static Future<void> dial(String number) =>
      _ch.invokeMethod('dial', {'number': number}); // opens the dialer, never auto-calls

  static Future<void> shareFile(String path, String mime) =>
      _ch.invokeMethod('shareFile', {'path': path, 'mime': mime});
}

/// Android CallLog.Calls.TYPE: 1 incoming, 2 outgoing, 3 missed, 4 voicemail,
/// 5 rejected, 6 blocked, 7 answered externally.
({String direction, String outcome}) classifyNative(int type, int durationSec) {
  switch (type) {
    case 1:
      return (direction: Dir.incoming, outcome: durationSec > 0 ? Outcome.connected : Outcome.unknown);
    case 2:
      return (direction: Dir.outgoing, outcome: durationSec > 0 ? Outcome.connected : Outcome.unanswered);
    case 3:
      return (direction: Dir.missed, outcome: Outcome.notConnected);
    case 5:
    case 6:
      return (direction: Dir.rejected, outcome: Outcome.notConnected);
    default:
      return (direction: Dir.unknown, outcome: Outcome.unknown);
  }
}

CallRecord callFromNative(Map<String, dynamic> m, {String? employeeId}) {
  final dur = (m['duration'] as num?)?.toInt() ?? 0;
  final c = classifyNative((m['type'] as num?)?.toInt() ?? 0, dur);
  return CallRecord(
    phone: (m['number'] as String?)?.isNotEmpty == true ? m['number'] as String : 'Unknown',
    contactName: (m['name'] as String?) ?? '',
    direction: c.direction,
    outcome: c.outcome,
    start: DateTime.fromMillisecondsSinceEpoch((m['date'] as num).toInt(), isUtc: true),
    durationSec: dur,
    nativeId: m['id']?.toString(),
    employeeId: employeeId,
    source: 'device',
  );
}
