// limm_checkin.dart — background diagnostic checkin every 15 min.
// Mirrors LimmCheckin.swift (V2rayU) and LimmCheckinWorker.kt (Android).
//
// Injection via --dart-define at build time:
//   LIMM_TOKEN   — auth token for /api/checkin
//   LIMM_BUILD_SHA — 7-char git SHA for app_version tag
//
// Proxy: Hiddify mixed-port at 127.0.0.1:12334 (HTTP).
// L0/L1 probes use --noproxy '*' so they bypass TUN routing.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LimmCheckin {
  static final LimmCheckin shared = LimmCheckin._();
  LimmCheckin._();

  Timer? _timer;
  String? _cachedAppVersion;

  // ── Constants ─────────────────────────────────────────────────────────────
  static const _apiBase   = 'https://limm.space/api';
  // Injected at CI build time: flutter build macos --dart-define=LIMM_TOKEN=... --dart-define=LIMM_BUILD_SHA=...
  static const _token     = String.fromEnvironment('LIMM_TOKEN',     defaultValue: '');
  static const _buildSha  = String.fromEnvironment('LIMM_BUILD_SHA', defaultValue: 'dev');
  static String get _clientKind => Platform.isMacOS ? 'macos-hiddify' : 'windows-hiddify';
  static const _clientLabel = 'pc hid';
  static const _serverIP   = '45.95.175.170';
  static const _serverPort = 443;            // VPN server port for L1 TCP probe
  static const _proxyPort  = 12334;          // Hiddify mixed-port (HTTP)

  /// curl executable: on Windows it lives in System32 and is found via PATH;
  /// on macOS/Linux use the absolute path (sandboxed apps may have a minimal PATH).
  static String get _curl => Platform.isWindows ? 'curl' : '/usr/bin/curl';

  /// App version string for checkin: "hiddify-{semver}+{sha}" — e.g. "hiddify-4.1.2.10+626a4d5".
  /// PackageInfo reads the version baked in by flutter build (--build-name / --build-number).
  /// _buildSha is the git SHA injected at CI time via --dart-define=LIMM_BUILD_SHA.
  Future<String> _appVersion() async {
    if (_cachedAppVersion != null) return _cachedAppVersion!;
    try {
      final info = await PackageInfo.fromPlatform();
      _cachedAppVersion = 'hiddify-${info.version}+$_buildSha';
    } catch (_) {
      _cachedAppVersion = 'hiddify+$_buildSha';
    }
    return _cachedAppVersion!;
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  void start() {
    if (_token.isEmpty) return;
    _runAsync();                            // immediate first run
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 15), (_) => _runAsync());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _runAsync() => perform().ignore();

  // ── UID ───────────────────────────────────────────────────────────────────

  Future<String> clientUid() async {
    final prefs = await SharedPreferences.getInstance();
    var uid = prefs.getString('limmClientUID');
    if (uid == null || uid.isEmpty) {
      uid = 'mac2-${DateTime.now().millisecondsSinceEpoch}';
      await prefs.setString('limmClientUID', uid);
    }
    return uid;
  }

  Future<String> get _uid => clientUid();

  // ── VPN availability check ─────────────────────────────────────────────────

  /// Returns true if Hiddify proxy is available (VPN on indicator).
  /// Uses socket check first, then curl fallback.
  Future<bool> vpnAvailable() async {
    // 1. Socket check (fast)
    try {
      final sock = await Socket.connect('127.0.0.1', _proxyPort,
          timeout: const Duration(seconds: 1));
      sock.destroy();
      return true;
    } catch (_) {}
    // 2. Curl fallback — try a request through proxy
    try {
      final r = await Process.run(_curl, [
        '--max-time', '3', '--connect-timeout', '2',
        '-s', '-o', '/dev/null',
        '--proxy', 'http://127.0.0.1:$_proxyPort',
        'http://1.1.1.1',
      ]);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  // ── Main checkin ──────────────────────────────────────────────────────────

  /// Full checkin with L0-L4 probes.
  /// [overrideVpnOn]: null = auto-detect via vpnAvailable(), false = skip VPN probes.
  Future<(int, String)> perform({bool? overrideVpnOn}) async {
    final uid = await _uid;

    // L0: direct internet (bypasses TUN via --noproxy '*')
    final l0 = await _curlDirect('http://1.1.1.1', timeout: 5) ? 1 : 0;

    // L1: direct TCP RTT to VPN server (3 probes, avg; bypasses HTTP proxy and TUN)
    int l1 = 0;
    int latencyMs = 0;
    final l1samples = <int>[];
    for (var i = 0; i < 3; i++) {
      final ms = await _tcpPing(_serverIP, _serverPort);
      if (ms != null) { l1 = 1; l1samples.add(ms); }
    }
    if (l1samples.isNotEmpty) {
      latencyMs = l1samples.reduce((a, b) => a + b) ~/ l1samples.length;
    }

    final vpnOn = overrideVpnOn ?? await vpnAvailable();

    int l2 = 0, l3 = 0, l4 = 0;
    String egressIp = '';
    int? tunnelMs;
    String tgStatus = 'down', gglStatus = 'down', chgptStatus = 'down';

    if (vpnOn) {
      // L2/L3: connect to VPN server through HTTP proxy
      final l2body = await _curlProxy('https://$_serverIP:443',
          port: _proxyPort, timeout: 10);
      l2 = l2body != null ? 1 : 0;
      l3 = l2;

      // L4: egress IP through tunnel
      final ip = await _curlProxy('https://api.ipify.org',
          port: _proxyPort, timeout: 15);
      if (ip != null && ip.isNotEmpty) {
        egressIp = ip.trim();
        l4 = egressIp == _serverIP ? 1 : 0;
      }

      // Tunnel latency (gstatic generate_204 through proxy, 3 probes avg)
      final tunSamples = <int>[];
      for (var i = 0; i < 3; i++) {
        final tStart = DateTime.now();
        final tOk = await _curlProxy('https://www.gstatic.com/generate_204',
            port: _proxyPort, timeout: 5);
        if (tOk != null) tunSamples.add(DateTime.now().difference(tStart).inMilliseconds);
      }
      if (tunSamples.isNotEmpty) {
        tunnelMs = tunSamples.reduce((a, b) => a + b) ~/ tunSamples.length;
      }

      // Services (parallel)
      final svcResults = await Future.wait([
        _probeService('https://web.telegram.org/',             port: _proxyPort),
        _probeService('https://www.google.com/search?q=test',  port: _proxyPort),
        _probeService('https://chatgpt.com/',                  port: _proxyPort),
      ]);
      tgStatus    = svcResults[0];
      gglStatus   = svcResults[1];
      chgptStatus = svcResults[2];
    }

    final payload = <String, dynamic>{
      'client_uid':   uid,
      'kind':         _clientKind,
      'label':        _clientLabel,
      'app_version':  await _appVersion(),
      'l0_local_net': l0,
      'l1_tcp443':    l1,
      'l2_handshake': l2,
      'l3_tunnel':    l3,
      'l4_dest':      l4,
      'vpn_running':  vpnOn ? 1 : 0,
      'raw': {
        'egress_ip':     egressIp,
        'dest_google':   gglStatus,
        'dest_telegram': tgStatus,
        'services': {'tg': tgStatus, 'ggl': gglStatus, 'chgpt': chgptStatus},
      },
    };
    if (latencyMs > 0) payload['latency_ms'] = latencyMs;
    if (tunnelMs != null) payload['tunnel_ms'] = tunnelMs;

    return _postCheckin(payload);
  }

  /// Lightweight checkin for post-Full-Test — no probes, direct POST.
  /// Reports vpn_running=1 with data we already know from the test.
  Future<(int, String)> performQuick({int? egressLatencyMs}) async {
    final uid = await _uid;
    final payload = <String, dynamic>{
      'client_uid':   uid,
      'kind':         _clientKind,
      'label':        _clientLabel,
      'app_version':  await _appVersion(),
      'l0_local_net': 1, 'l1_tcp443': 1, 'l2_handshake': 1, 'l3_tunnel': 1, 'l4_dest': 1,
      'vpn_running':  1,
      'raw': {
        'egress_ip':     _serverIP,
        'dest_google':   'ok',
        'dest_telegram': 'ok',
        'services': {'tg': 'ok', 'ggl': 'ok', 'chgpt': 'ok'},
      },
    };
    if (egressLatencyMs != null) payload['tunnel_ms'] = egressLatencyMs;
    return _postCheckin(payload);
  }

  /// Full post-test checkin with all measured data from Full Test.
  /// Use this instead of performQuick to get proper ping values in dashboard.
  Future<(int, String)> performPostTest({
    required int l0,
    required int l1,
    required int l4,
    String egressIp = '',
    int? latencyMs,      // L1 direct RTT to VPN server
    int? tunnelMs,       // latency through VPN tunnel
    String tgStatus = 'down',
    String gglStatus = 'down',
    String chgptStatus = 'down',
  }) async {
    final uid = await _uid;
    final payload = <String, dynamic>{
      'client_uid':   uid,
      'kind':         _clientKind,
      'label':        _clientLabel,
      'app_version':  await _appVersion(),
      'l0_local_net': l0,
      'l1_tcp443':    l1,
      'l2_handshake': l4,   // if L4 passed, handshake must have worked
      'l3_tunnel':    l4,
      'l4_dest':      l4,
      'vpn_running':  1,    // VPN IS running (we verified socket before calling this)
      'raw': {
        'egress_ip':     egressIp,
        'dest_google':   gglStatus,
        'dest_telegram': tgStatus,
        'services': {'tg': tgStatus, 'ggl': gglStatus, 'chgpt': chgptStatus},
      },
    };
    if (latencyMs != null && latencyMs > 0) payload['latency_ms'] = latencyMs;
    if (tunnelMs != null) payload['tunnel_ms'] = tunnelMs;
    return _postCheckin(payload);
  }

  /// Send a minimal diagnostic log entry to /api/applog with proper auth.
  Future<(int, String)> sendLog() async {
    if (_token.isEmpty) return (0, 'no token');
    final uid = await _uid;
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      final req = await client.postUrl(Uri.parse('$_apiBase/applog'));
      req.headers
        ..contentType = ContentType.json
        ..add('Authorization', 'Bearer $_token');
      req.write(jsonEncode({
        'client_uid':  uid,
        'kind':        _clientKind,
        'label':       _clientLabel,
        'app_version': await _appVersion(),
        'ts':          DateTime.now().millisecondsSinceEpoch ~/ 1000,
      }));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      client.close();
      return (resp.statusCode, body);
    } catch (e) {
      return (0, e.toString());
    }
  }

  /// POST per-profile Full Test results to /api/fulltest for dashboard Profiles column.
  Future<void> postFulltestResult({
    required String profileName,
    required bool ok,
    int? latencyMs,
  }) async {
    if (_token.isEmpty) return;
    final uid = await _uid;
    final profile = <String, dynamic>{'name': profileName, 'ok': ok ? 1 : 0};
    if (latencyMs != null && latencyMs > 0) profile['latency_ms'] = latencyMs;
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      final req = await client.postUrl(Uri.parse('$_apiBase/fulltest'));
      req.headers
        ..contentType = ContentType.json
        ..add('Authorization', 'Bearer $_token');
      req.write(jsonEncode({
        'client_uid': uid,
        'kind': _clientKind,
        'profiles': [profile],
      }));
      await req.close();
      client.close();
    } catch (_) {}
  }

  // ── Probes ────────────────────────────────────────────────────────────────

  /// Pure TCP connect RTT to VPN server — bypasses HTTP proxy and TUN alike.
  /// Returns elapsed ms on first accepted connection, null on timeout/error.
  Future<int?> _tcpPing(String host, int port, {int timeoutSec = 5}) async {
    try {
      final t0 = DateTime.now();
      final sock = await Socket.connect(host, port,
          timeout: Duration(seconds: timeoutSec));
      final ms = DateTime.now().difference(t0).inMilliseconds;
      sock.destroy();
      return ms;
    } catch (_) {
      return null;
    }
  }

  /// Direct HTTP probe, bypassing TUN via --noproxy '*'.
  Future<bool> _curlDirect(String url, {int timeout = 6}) async {
    try {
      final r = await Process.run(_curl, [
        '--max-time',      '$timeout',
        '--connect-timeout', '${(timeout - 1).clamp(1, timeout)}',
        '-s', '-o', '/dev/null',
        '--noproxy', '*',
        url,
      ]);
      return r.exitCode == 0 || r.exitCode == 52 || r.exitCode == 35 || r.exitCode == 56;
    } catch (_) {
      return false;
    }
  }

  /// HTTP request through Hiddify HTTP proxy.
  Future<String?> _curlProxy(String url,
      {required int port, int timeout = 10}) async {
    try {
      final r = await Process.run(_curl, [
        '--max-time',      '$timeout',
        '--connect-timeout', '${(timeout - 2).clamp(2, timeout)}',
        '-s',
        '--proxy', 'http://127.0.0.1:$port',
        url,
      ]);
      if (r.exitCode != 0 && r.exitCode != 52 && r.exitCode != 200) return null;
      return r.stdout.toString().trim();
    } catch (_) {
      return null;
    }
  }

  /// HTTP status probe through proxy. Returns "ok" / "blocked" / "down".
  Future<String> _probeService(String url, {required int port}) async {
    try {
      final r = await Process.run(_curl, [
        '--max-time',      '12',
        '--connect-timeout', '10',
        '-s', '-o', '/dev/null', '-w', '%{http_code}',
        '--proxy', 'http://127.0.0.1:$port',
        url,
      ]);
      final code = int.tryParse(r.stdout.toString().trim()) ?? 0;
      if (code == 0)   return 'down';
      if (code == 451) return 'blocked';
      return 'ok';
    } catch (_) {
      return 'down';
    }
  }

  // ── POST ──────────────────────────────────────────────────────────────────

  Future<(int, String)> _postCheckin(Map<String, dynamic> payload) async {
    if (_token.isEmpty) return (0, 'no token');
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 20);
      final req = await client.postUrl(Uri.parse('$_apiBase/checkin'));
      req.headers
        ..contentType = ContentType.json
        ..add('Authorization', 'Bearer $_token');
      req.write(jsonEncode(payload));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      client.close();
      return (resp.statusCode, body);
    } catch (e) {
      return (0, e.toString());
    }
  }
}
