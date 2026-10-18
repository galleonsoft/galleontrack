import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/call_log_service.dart';
import 'widgets.dart';

/// Imports device calls into Hive. Permission is requested only here, with an explanation.
Future<void> importDeviceCalls(BuildContext context, WidgetRef ref) async {
  final db = ref.read(dbProvider);
  final ops = ref.read(opsProvider);
  if (!await Native.hasCallLogPermission()) {
    if (!context.mounted) return;
    final ok = await confirm(
        context, 'Call-log access',
        'GalleonTrack reads the Android call log only to copy call history into its own local database on this device. '
        'Nothing is uploaded. You can decline and add calls manually.',
        ok: 'Continue');
    if (!ok) return;
    if (!await Native.requestCallLogPermission()) {
      if (context.mounted) {
        toast(context, 'Call-log permission not granted. You can still add calls manually, or enable it in system settings.');
      }
      return;
    }
  }
  try {
    final raw = await Native.getCalls(db.settings.lastNativeMs);
    final r = await ops.importNative(raw);
    if (context.mounted) toast(context, 'Imported ${r.added} new, skipped ${r.duplicates} duplicates, linked ${r.linked} to leads.');
  } catch (e) {
    if (context.mounted) toast(context, 'Call import is not available on this device or build ($e). Use manual entry.');
  }
}
