import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:galleontrack/services/database_export_api_service.dart';

// NOTE: plain test() (no widget binding) so dart:io HttpClient is not stubbed.

Future<HttpServer> serve(int status, String body, void Function(HttpRequest, List<int>)? onReq) async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((r) async {
    final bytes = <int>[];
    await for (final c in r) {
      bytes.addAll(c);
    }
    onReq?.call(r, bytes);
    r.response.statusCode = status;
    r.response.headers.contentType = ContentType.json;
    r.response.write(body);
    await r.response.close();
  });
  return s;
}

void main() {
  final manifest = {'exportId': 'abc-123', 'categories': ['leads']};
  final archive = Uint8List.fromList(List.generate(200000, (i) => i % 251));

  test('sends exactly one multipart POST to /api/v1/database-export', () async {
    String? method, path, id;
    List<int>? body;
    final s = await serve(200, '{"status":"received","exportId":"abc-123"}', (r, b) {
      method = r.method; path = r.uri.path; id = r.headers.value('x-export-id'); body = b;
    });
    var last = 0;
    final res = await DatabaseExportApiService().send(
      baseUrl: 'http://127.0.0.1:${s.port}/', archive: archive, manifest: manifest, onProgress: (a, t) => last = a);
    await s.close(force: true);
    expect(res.ok, true);
    expect(method, 'POST');
    expect(path, '/api/v1/database-export');
    expect(id, 'abc-123');
    expect(last, archive.length);
    final text = latin1.decode(body!);
    expect(text.contains('name="manifest"'), true);
    expect(text.contains('filename="database_export.zip"'), true);
  });

  test('response contract handling', () {
    ExportResult p(int c, String b) => DatabaseExportApiService.parseResponse(c, b, 'abc-123');
    expect(p(200, '{"status":"received","exportId":"abc-123"}').state, 'success');
    expect(p(200, '{"status":"received"}').state, 'success');
    expect(p(200, 'OK').state, 'malformed');
    expect(p(200, '{"status":"received","exportId":"other"}').state, 'malformed');
    expect(p(200, '{"status":"rejected","message":"quota"}').state, 'rejected');
    expect(p(400, '{}').state, 'invalid');
    expect(p(401, '').state, 'unauthorized');
    expect(p(403, '').state, 'unauthorized');
    expect(p(503, '').state, 'serverError');
    expect(p(302, '').state, 'invalid');
  });

  test('timeout is reported as uncertain, not as not-received', () async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    s.listen((r) async {
      await Future<void>.delayed(const Duration(seconds: 3));
    });
    final res = await DatabaseExportApiService(timeout: const Duration(milliseconds: 300)).send(
      baseUrl: 'http://127.0.0.1:${s.port}', archive: Uint8List(10), manifest: manifest);
    await s.close(force: true);
    expect(res.state, 'timeout');
    expect(res.uncertain, true);
  });

  test('connection failure and bad URL', () async {
    final res = await DatabaseExportApiService().send(baseUrl: 'http://127.0.0.1:1', archive: Uint8List(10), manifest: manifest);
    expect(res.state, 'connection');
    final bad = await DatabaseExportApiService().send(baseUrl: 'ftp://x', archive: Uint8List(10), manifest: manifest);
    expect(bad.state, 'badUrl');
  });

  test('the export service is the only network-capable code and is only built by the export screen', () {
    final files = Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));
    final netPatterns = [RegExp(r'HttpClient\b'), RegExp(r'package:http/'), RegExp(r'package:dio/'), RegExp(r'WebSocket'), RegExp(r'Socket\.connect'), RegExp(r'dart:html')];
    for (final f in files) {
      final src = f.readAsStringSync();
      final isService = f.path.endsWith('database_export_api_service.dart');
      for (final p in netPatterns) {
        if (!isService) expect(p.hasMatch(src), false, reason: '${f.path} must not use ${p.pattern}');
      }
      if (!isService && !f.path.endsWith('database_ui.dart')) {
        expect(src.contains('DatabaseExportApiService('), false, reason: '${f.path} must not call the export API');
      }
    }
    final ui = File('lib/ui/database_ui.dart').readAsStringSync();
    expect(RegExp(r'\.send\(').allMatches(ui).length, 1); // single call site, inside the confirmed _send()
    expect(ui.indexOf('confirm(context, \'Send data to server?\''), lessThan(ui.indexOf('.send(')));
  });
}
