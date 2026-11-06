import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:http/http.dart' as http;
import '../constants.dart';

/// Result of a call to one of the newer system endpoints (`/api/v1/...`).
class ApiResult {
  final Map<String, dynamic> data;
  final String? code;
  final String? message;
  const ApiResult(this.data, {this.code, this.message});

  bool get ok => code == null;
  T? get<T>(String key) => data[key] as T?;
  List<Map<String, dynamic>> list(String key) =>
      (data[key] as List? ?? const []).cast<Map<String, dynamic>>();
}

/// Client for the server's game systems (social, market, quests, cargo, ...).
/// Every endpoint takes the session id and form fields and answers zlib-compressed JSON
/// `{err: 0, ...}` or `{err: 1, code, msg}`.
Map<String, dynamic> _decode(List<int> bytes) =>
    jsonDecode(utf8.decode(ZLibDecoder().convert(bytes))) as Map<String, dynamic>;

const _bigAnswer = 16 * 1024;          // zipped bytes

class GameApi {
  static Future<ApiResult> call(String path, String sid,
      [Map<String, Object?> params = const {}]) async {
    try {
      final body = <String, String>{'sid': sid};
      params.forEach((k, v) {
        if (v != null) body[k] = v.toString();
      });
      final r = await http
          .post(Uri.parse('$kBaseUrl$path'), body: body)
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) {
        return ApiResult(const {}, code: 'http_${r.statusCode}', message: 'Server error (${r.statusCode})');
      }
      // a big answer (the map in a built-up city) is unpacked off the screen's thread, so the app never
      // freezes while it reads one (owner 2026-11-06)
      final bytes = r.bodyBytes;
      final m = bytes.length > _bigAnswer ? await Isolate.run(() => _decode(bytes)) : _decode(bytes);
      if ((m['err'] ?? 0) != 0) {
        return ApiResult(m, code: (m['code'] ?? 'error').toString(),
            message: (m['msg'] ?? 'Could not do that. Try again.').toString());
      }
      return ApiResult(m);
    } catch (_) {
      return const ApiResult({}, code: 'network', message: 'Could not reach the server. Check your connection.');
    }
  }

}
