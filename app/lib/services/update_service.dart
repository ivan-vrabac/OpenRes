import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../branding.dart';

/// Information about the newest published build (`<UPDATE_URL>/latest.json`, written by the
/// build script when it publishes an APK).
class BuildInfo {
  final String version;
  final int build;
  final int size;
  final String sha256;
  final String date;
  final String apk;
  final List<String> notes;
  BuildInfo(this.version, this.build, this.size, this.sha256, this.date, this.apk, this.notes);

  factory BuildInfo.fromJson(Map<String, dynamic> j) => BuildInfo(
        j['version'] as String? ?? '?',
        (j['build'] as num? ?? 0).toInt(),
        (j['size'] as num? ?? 0).toInt(),
        j['sha256'] as String? ?? '',
        j['date'] as String? ?? '',
        j['apk'] as String? ?? 'openres.apk',
        ((j['notes'] as List?) ?? const []).cast<String>(),
      );

  bool get isNewer => build > Branding.buildNumber;
}

/// Checks for, downloads and installs app updates (Android only; needs UPDATE_URL).
class UpdateService {
  static const _ch = MethodChannel('openres/updater');

  static bool get supported =>
      !kIsWeb && Platform.isAndroid && Branding.updateUrl.isNotEmpty;

  static Uri _u(String path) => Uri.parse('${Branding.updateUrl.replaceAll(RegExp(r'/$'), '')}/$path');

  /// The newest published build, or null if it can't be reached.
  static Future<BuildInfo?> latest() async {
    if (!supported) return null;
    try {
      final r = await http.get(_u('latest.json?t=${DateTime.now().millisecondsSinceEpoch}'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      return BuildInfo.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Downloads [info]'s APK with Android's download manager (it goes on when the player leaves
  /// the screen or the app and resumes after a dropped connection; calling this again picks up
  /// the same download), verifies size and SHA-256, then opens the system installer.
  /// [onProgress] gets 0..1 and a note ("Waiting for the connection…"). Returns null on success
  /// or an error message.
  static Future<String?> downloadAndInstall(BuildInfo info, void Function(double, String?) onProgress) async {
    try {
      final dir = await _ch.invokeMethod<String>('updateDir');
      if (dir == null) return 'No storage for the download';
      final file = File('$dir/update-${info.build}.apk');
      final start = (await _ch.invokeMethod<Map>('download', {
        'url': _u('${info.apk}?b=${info.build}').toString(), 'build': info.build, 'size': info.size,
      }))!;
      if (start['error'] == 'space') {
        return 'Not enough free space: the update needs ${fmtSize((start['need'] as num).toInt())}, '
            'the phone has ${fmtSize((start['free'] as num).toInt())} free';
      }
      final id = (start['id'] as num).toInt();
      while (true) {
        final p = (await _ch.invokeMethod<Map>('progress', {'id': id}))!;
        final status = p['status'] as String;
        final done = (p['done'] as num? ?? 0).toInt();
        final total = (p['total'] as num? ?? 0).toInt() > 0 ? (p['total'] as num).toInt() : info.size;
        if (status == 'done') break;
        if (status == 'failed' || status == 'gone') {
          await _ch.invokeMethod('cancel', {'id': id});
          return 'Download failed (${p['reason'] ?? status}). Tap again to retry';
        }
        onProgress(total > 0 ? done / total : 0,
            status == 'paused' ? 'Waiting for the connection… (continues by itself)'
                : 'You can leave this screen or the app; the download goes on');
        await Future.delayed(const Duration(milliseconds: 500));
      }
      onProgress(1, null);
      if (info.size > 0 && await file.length() != info.size) {
        await file.delete();
        await _ch.invokeMethod('cancel', {'id': id});
        return 'The download was incomplete, please try again';
      }
      if (info.sha256.isNotEmpty) {
        final digest = await sha256.bind(file.openRead()).first;
        if (digest.toString() != info.sha256.toLowerCase()) {
          await file.delete();
          await _ch.invokeMethod('cancel', {'id': id});
          return 'The download is corrupted, please try again';
        }
      }
      final res = await _ch.invokeMethod<String>('install', {'path': file.path});
      if (res == 'permission') {
        return 'Allow "Install unknown apps" for this app, then tap Install again';
      }
      return res == 'started' ? null : 'Could not start the installer';
    } catch (e) {
      return 'Update failed: $e';
    }
  }

  /// A download of [build] the download manager already has (started earlier), so the dialog
  /// can show and continue it.
  static Future<bool> hasDownload(int build) async {
    if (!supported) return false;
    try {
      return ((await _ch.invokeMethod<num>('known', {'build': build})) ?? -1) >= 0;
    } catch (_) {
      return false;
    }
  }

  /// After a successful update (the new version is running), delete the downloaded APKs of this
  /// build and older ones (owner 2026-10-24). A newer one that is not installed yet is kept.
  static Future<void> cleanupOldDownloads() async {
    if (!supported) return;
    try {
      await _ch.invokeMethod('cleanup', {'build': Branding.buildNumber});
    } catch (_) {}
    try {
      final dir = await _ch.invokeMethod<String>('updateDir');
      if (dir == null) return;
      await for (final f in Directory(dir).list()) {
        final m = RegExp(r'update-(\d+)\.apk$').firstMatch(f.path);
        if (f is File && m != null && int.parse(m.group(1)!) <= Branding.buildNumber) {
          await f.delete();
        }
      }
    } catch (_) {}
  }
  static String fmtSize(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
