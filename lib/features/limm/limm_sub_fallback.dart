import 'dart:convert';
import 'dart:io';

import 'package:hiddify/core/model/constants.dart';

/// Subscription host fallback. The remote profile is fetched by the Go core from whatever URL
/// is stored on it; if that host (e.g. limm.space via Cloudflare) is ISP-blocked the server
/// list stops refreshing. This probes the mirror hosts (www direct → vpn Bunny → limm CF) and
/// returns the first that serves a VALID subscription, so the profile is registered against a
/// reachable host at install time.
///
/// Validation rejects a provider block-page served with HTTP 200 — registering it could replace
/// working servers with junk.
class LimmSubFallback {
  /// Returns the first mirror URL serving a valid sub, or the www (direct) URL as a last resort.
  static Future<String> resolveWorkingUrl() async {
    for (final host in Constants.limmSubHosts) {
      final url = "https://$host${Constants.limmSubPath}";
      HttpClient? client;
      try {
        client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
        final req = await client.getUrl(Uri.parse(url));
        final resp = await req.close().timeout(const Duration(seconds: 8));
        if (resp.statusCode == 200) {
          final body = await resp.transform(utf8.decoder).join();
          if (_isValidSub(body)) return url;
        }
      } catch (_) {
        // try next mirror
      } finally {
        client?.close(force: true);
      }
    }
    return "https://${Constants.limmSubHosts.first}${Constants.limmSubPath}";
  }

  static bool _isValidSub(String body) {
    final t = body.trim();
    if (t.length < 8) return false;
    final low = t.toLowerCase();
    if (low.contains("<html") || low.contains("<!doctype") || low.contains("<body")) {
      return false;
    }
    bool hasScheme(String s) =>
        s.contains("vless://") ||
        s.contains("vmess://") ||
        s.contains("hysteria2://") ||
        s.contains("hy2://") ||
        s.contains("trojan://");
    if (hasScheme(t)) return true;
    try {
      final clean = t.replaceAll("\n", "").replaceAll("\r", "");
      final decoded = utf8.decode(base64.decode(base64.normalize(clean)));
      return hasScheme(decoded);
    } catch (_) {
      return false;
    }
  }
}
