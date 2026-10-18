import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'db.dart';
import 'services/notification_service.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final dir = (await getApplicationSupportDirectory()).path;
    final db = await Db.open(dir);
    final notif = NotificationService();
    try {
      await notif.init(); // local notifications only; failure must not block the app
    } catch (_) {}
    runApp(ProviderScope(
      overrides: [dbProvider.overrideWith((ref) => db), notificationProvider.overrideWithValue(notif)],
      child: const GalleonApp(),
    ));
  } catch (e) {
    runApp(MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('GalleonTrack')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('The local database could not be opened.\n\n$e\n\n'
              'Your data was not modified. Free up storage space and restart the app; '
              'if the problem persists restore from a local backup.'),
        ),
      ),
    ));
  }
}
