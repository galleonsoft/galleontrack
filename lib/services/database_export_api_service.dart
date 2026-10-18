import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// THE ONLY network-capable code in the application.
///
/// Contract: POST {baseUrl}/api/v1/database-export  (multipart/form-data)
///   part "manifest": application/json  (the manifest.json also contained in the ZIP)
///   part "archive":  application/zip   (database_export.zip)
///   header X-Export-Id: <exportId>; optional Authorization: Bearer <token> (never stored)
/// Success (HTTP 200/201/202), JSON body: {"status":"received","exportId":"<same id>", "message":"..."}
/// Rejection (any 2xx/4xx), JSON body: {"status":"rejected","message":"..."}
/// It is only ever called from the explicit, confirmed UI action.
class ExportResult {
  ExportResult(this.state, this.message, {this.httpStatus});
  /// success | rejected | invalid | unauthorized | serverError | malformed |
  /// timeout | connection | cancelled | badUrl
  final String state;
  final String message;
  final int? httpStatus;
  bool get ok => state == 'success';
  /// After a timeout the server may or may not have stored the package.
  bool get uncertain => state == 'timeout';
}

class ExportCancelToken {
  bool cancelled = false;
  HttpClientRequest? _req;
  void cancel() {
    cancelled = true;
    try {
      _req?.abort();
    } catch (_) {}
  }
}

class DatabaseExportApiService {
  DatabaseExportApiService({this.timeout = const Duration(minutes: 2)});
  final Duration timeout;
  static const path = '/api/v1/database-export';

  static Uri? endpoint(String base) {
    var b = base.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    final u = Uri.tryParse('$b$path');
    if (u == null || !(u.scheme == 'https' || u.scheme == 'http') || u.host.isEmpty) return null;
    return u;
  }

  Future<ExportResult> send({
    required String baseUrl,
    required Uint8List archive,
    required Map<String, dynamic> manifest,
    String? authToken,
    void Function(int sent, int total)? onProgress,
    ExportCancelToken? cancel,
  }) async {
    final uri = endpoint(baseUrl);
    if (uri == null) return ExportResult('badUrl', 'Enter a valid http(s) server URL.');
    final exportId = manifest['exportId'] as String;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.postUrl(uri);
      cancel?._req = req;
      final boundary = '----gt${DateTime.now().microsecondsSinceEpoch}';
      final head = utf8.encode(
          '--$boundary\r\nContent-Disposition: form-data; name="manifest"\r\n'
          'Content-Type: application/json\r\n\r\n${jsonEncode(manifest)}\r\n'
          '--$boundary\r\nContent-Disposition: form-data; name="archive"; filename="database_export.zip"\r\n'
          'Content-Type: application/zip\r\n\r\n');
      final tail = utf8.encode('\r\n--$boundary--\r\n');
      req.headers.contentType = ContentType('multipart', 'form-data', parameters: {'boundary': boundary});
      req.headers.set('X-Export-Id', exportId);
      if (authToken != null && authToken.trim().isNotEmpty) {
        req.headers.set('Authorization', 'Bearer ${authToken.trim()}');
      }
      req.contentLength = head.length + archive.length + tail.length;
      req.add(head);
      const chunk = 64 * 1024;
      for (var i = 0; i < archive.length; i += chunk) {
        if (cancel?.cancelled == true) {
          cancel!.cancel();
          return ExportResult('cancelled', 'Export cancelled. Nothing was changed locally.');
        }
        final end = min(i + chunk, archive.length);
        req.add(Uint8List.sublistView(archive, i, end));
        await req.flush();
        onProgress?.call(end, archive.length);
      }
      req.add(tail);
      final resp = await req.close().timeout(timeout);
      final body = await resp.transform(utf8.decoder).join().timeout(timeout);
      return parseResponse(resp.statusCode, body, exportId);
    } on TimeoutException {
      return ExportResult('timeout',
          'The server did not answer in time. The package may or may not have been received — check with the server before retrying.');
    } on SocketException {
      return ExportResult('connection', 'Could not reach the server (no internet or server unreachable).');
    } on HandshakeException {
      return ExportResult('connection', 'Secure connection failed (TLS/certificate error).');
    } catch (_) {
      if (cancel?.cancelled == true) return ExportResult('cancelled', 'Export cancelled. Nothing was changed locally.');
      return ExportResult('connection', 'The upload failed before completing.');
    } finally {
      client.close(force: true);
    }
  }

  /// Public for tests. Interprets the documented response contract.
  static ExportResult parseResponse(int status, String body, String exportId) {
    Map<String, dynamic>? j;
    try {
      final d = jsonDecode(body);
      if (d is Map<String, dynamic>) j = d;
    } catch (_) {}
    final msg = (j?['message'] as String?) ?? '';
    if (status == 401 || status == 403) {
      return ExportResult('unauthorized', 'The server refused authorization (HTTP $status).', httpStatus: status);
    }
    if (status >= 500) return ExportResult('serverError', 'Server error (HTTP $status). $msg'.trim(), httpStatus: status);
    if (j != null && j['status'] == 'rejected') {
      return ExportResult('rejected', msg.isEmpty ? 'The server rejected the export.' : msg, httpStatus: status);
    }
    if (status == 400 || status == 413 || status == 415 || status == 422) {
      return ExportResult('invalid', 'The server found the request invalid (HTTP $status). $msg'.trim(), httpStatus: status);
    }
    if (status >= 200 && status < 300) {
      if (j == null || j['status'] != 'received') {
        return ExportResult('malformed', 'The server answered HTTP $status but not in the documented format. Receipt is not confirmed.', httpStatus: status);
      }
      final echoed = j['exportId'];
      if (echoed != null && echoed != exportId) {
        return ExportResult('malformed', 'The server confirmed a different export ID. Receipt is not confirmed.', httpStatus: status);
      }
      return ExportResult('success', msg.isEmpty ? 'The server confirmed receipt.' : msg, httpStatus: status);
    }
    return ExportResult('invalid', 'Unexpected response (HTTP $status).', httpStatus: status);
  }
}
