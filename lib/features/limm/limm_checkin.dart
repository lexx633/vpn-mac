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
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LimmCheckin {
  static final LimmCheckin shared = LimmCheckin._();
  LimmCheckin._();

  Timer? _timer;
  String? _cachedAppVersion;
  Set<String>? _cachedServerIPs;
  DateTime? _cachedServerIPsAt;

  // ── Constants ─────────────────────────────────────────────────────────────
  static const _apiBase   = 'https://limm.space/api';
  // Injected at CI build time: flutter build macos --dart-define=LIMM_TOKEN=... --dart-define=LIMM_BUILD_SHA=...
  static const _token     = String.fromEnvironment('LIMM_TOKEN',     defaultValue: '');
  static const _buildSha  = String.fromEnvironment('LIMM_BUILD_SHA', defaultValue: 'dev');
  static String get _clientKind => Platform.isMacOS ? 'macos-hiddify' : 'windows-hiddify';
  static const _clientLabel = 'pc hid';
  static const _serverIP   = '45.95.175.170'; // fallback / L1 probe target
  static const _serverPort = 443;            // VPN server port for L1 TCP probe
  static const _proxyPort  = 12334;          // Hiddify mixed-port (HTTP)

  // Sub URLs in priority order (direct www first, then Bunny CDN, then CF).
  static const _subURLs = [
    'https://www.limm.space/vpn/sub',
    'https://vpn.limm.space/vpn/sub',
    'https://limm.space/vpn/sub',
  ];

  // §7.3 egress: own /api/myip first, ipify fallback. Hit limm.space (CF) — NOT the www/vpn
  // mirrors: the probe rides the tunnel (exit outside RU → CF reachable) and only CF returns
  // the real exit-node IP (CF-Connecting-IP). www via :443 mux → 127.0.0.1, Bunny → edge IP.
  static const _egressEndpoints = [
    'https://limm.space/api/myip',
    'https://api.ipify.org',
  ];

  /// curl executable: on Windows it lives in System32 and is found via PATH;
  /// on macOS/Linux use the absolute path (sandboxed apps may have a minimal PATH).
  static String get _curl => Platform.isWindows ? 'curl' : '/usr/bin/curl';

  /// Null device for curl -o (discard body).
  static String get _devNull => Platform.isWindows ? 'NUL' : '/dev/null';

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

  // ── Sub IP cache ──────────────────────────────────────────────────────────

  /// Fetch sub from the server and parse all server IPs from it.
  /// Tries each mirror URL in order; returns empty set on complete failure.
  Future<Set<String>> _fetchSubIPs() async {
    for (final url in _subURLs) {
      try {
        final r = await Process.run(_curl, [
          '--max-time', '10', '--connect-timeout', '6',
          '-s', '--noproxy', '*',
          '-H', 'Authorization: Bearer $_token',
          url,
        ]);
        if (r.exitCode != 0) continue;
        final ips = _parseIPsFromSub(r.stdout.toString());
        if (ips.isNotEmpty) return ips;
      } catch (_) {}
    }
    return {};
  }

  Set<String> _parseIPsFromSub(String body) {
    final ips = <String>{};
    String decoded = body.trim();
    try {
      final compact = decoded.replaceAll('\n', '').replaceAll('\r', '');
      decoded = utf8.decode(base64.decode(compact));
    } catch (_) {} // already plain text
    for (final line in decoded.split('\n')) {
      final l = line.trim();
      if (l.isEmpty) continue;
      try {
        final uri = Uri.parse(l);
        if (uri.host.isNotEmpty) ips.add(uri.host);
      } catch (_) {}
    }
    return ips;
  }

  /// Public access to the server IPs set (for use in limm_diagnostic.dart).
  Future<Set<String>> fetchKnownServerIPs() => _knownServerIPs();

  /// Returns the set of known server IPs, fetched from sub and cached for 30 min.
  /// Falls back to {_serverIP} if the sub is unreachable.
  Future<Set<String>> _knownServerIPs() async {
    if (_cachedServerIPs != null && _cachedServerIPsAt != null &&
        DateTime.now().difference(_cachedServerIPsAt!) < const Duration(minutes: 30)) {
      return _cachedServerIPs!;
    }
    final ips = await _fetchSubIPs();
    if (ips.isNotEmpty) {
      _cachedServerIPs = ips;
      _cachedServerIPsAt = DateTime.now();
      return ips;
    }
    return {_serverIP};
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

  /// Returns true if Hiddify proxy is available AND the upstream tunnel is alive.
  /// Socket check is a fast pre-flight only — port listening ≠ tunnel working.
  Future<bool> vpnAvailable() async {
    // 1. Fast pre-flight: if port isn't listening at all, skip curl
    bool portListening = false;
    try {
      final sock = await Socket.connect('127.0.0.1', _proxyPort,
          timeout: const Duration(seconds: 1));
      sock.destroy();
      portListening = true;
    } catch (_) {}
    if (!portListening) return false;

    // 2. Curl probe through proxy — confirms upstream tunnel is alive, not just port open
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
      // L2 (§7.2): transport up — reach the VPN server through the tunnel, no internet egress yet.
      final l2body = await _curlProxy('https://$_serverIP:443',
          port: _proxyPort, timeout: 10);
      l2 = l2body != null ? 1 : 0;

      // L3 (§7.2/§7.4): egress IP obtained through the tunnel → traffic flows out.
      // §7.3 /api/myip first, ipify fallback. Don't gate on an IP set — server decides the node.
      final ip = await _egressViaProxy(timeout: 15);
      if (ip != null && ip.isNotEmpty) { egressIp = ip.trim(); l3 = 1; }

      // L4 (§7.2): generate_204 through the tunnel → real browsing works; also yields tunnel latency.
      final tunSamples = <int>[];
      for (var i = 0; i < 3; i++) {
        final ms = await _probe204(port: _proxyPort, timeout: 5);
        if (ms != null) tunSamples.add(ms);
      }
      if (tunSamples.isNotEmpty) {
        tunnelMs = tunSamples.reduce((a, b) => a + b) ~/ tunSamples.length;
        l4 = 1;
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

    // browser_ok — честный признак «трафик идёт через туннель»: реальная страница
    // загрузилась (сервис ok / egress подтверждён / generate_204 прошёл). В TUN/прокси
    // проба ipify (l4) флакает, поэтому page-load надёжнее. См. api.py verdict-логику.
    final browserOk = (l4 == 1 ||
            tunnelMs != null ||
            tgStatus == 'ok' || gglStatus == 'ok' || chgptStatus == 'ok')
        ? 1 : 0;

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
      'browser_ok':   vpnOn ? browserOk : 0,
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
      'browser_ok':   1,
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
    // browser_ok — реальная страница прошла через туннель (см. perform()/api.py).
    final browserOk = (l4 == 1 ||
            tunnelMs != null ||
            tgStatus == 'ok' || gglStatus == 'ok' || chgptStatus == 'ok')
        ? 1 : 0;
    // §7.2 boundary: L3 = egress/tunnel carries traffic out; L2 = transport up (handshake).
    // If we got egress or a 204, the transport is definitely up too.
    final l3 = (egressIp.isNotEmpty || tunnelMs != null) ? 1 : 0;
    final l2 = (l3 == 1 || browserOk == 1) ? 1 : 0;
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
      'browser_ok':   browserOk,
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

  /// Read last [maxLines] lines from a log file in the app support directory.
  /// Returns empty string if file doesn't exist or on any error.
  Future<String> _readLogTail(String filename, {int maxLines = 150}) async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/$filename');
      if (!await file.exists()) return '';
      final lines = await file.readAsLines();
      if (lines.isEmpty) return '';
      final tail = lines.length > maxLines
          ? lines.sublist(lines.length - maxLines)
          : lines;
      return tail.join('\n');
    } catch (_) {
      return '';
    }
  }

  /// Send diagnostic log bundle to /api/applog.
  /// Includes last 150 lines of box.log (sing-box core) and app.log (Hiddify app).
  Future<(int, String)> sendLog() async {
    if (_token.isEmpty) return (0, 'no token');
    final uid = await _uid;
    try {
      // Read sing-box core log and Hiddify app log in parallel
      final results = await Future.wait([
        _readLogTail('box.log', maxLines: 150),
        _readLogTail('app.log', maxLines: 150),
      ]);
      final boxLog = results[0];
      final appLog = results[1];

      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 20);
      try {
        final req = await client.postUrl(Uri.parse('$_apiBase/applog'));
        req.headers
          ..contentType = ContentType.json
          ..add('Authorization', 'Bearer $_token');
        final payload = <String, dynamic>{
          'client_uid':  uid,
          'kind':        _clientKind,
          'label':       _clientLabel,
          'app_version': await _appVersion(),
          'ts':          DateTime.now().millisecondsSinceEpoch ~/ 1000,
          if (boxLog.isNotEmpty) 'box_log': boxLog,
          if (appLog.isNotEmpty) 'app_log': appLog,
        };
        req.write(jsonEncode(payload));
        final resp = await req.close();
        final body = await resp.transform(utf8.decoder).join();
        return (resp.statusCode, body);
      } finally {
        client.close();
      }
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
      try {
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
      } finally {
        client.close();
      }
    } catch (_) {}
  }

  /// POST all profile Full Test results in one call to /api/fulltest.
  /// [profiles] — list of {name, ok, latency_ms?} maps.
  Future<void> postAllFulltestResults(List<Map<String, dynamic>> profiles) async {
    if (_token.isEmpty || profiles.isEmpty) return;
    final uid = await _uid;
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final req = await client.postUrl(Uri.parse('$_apiBase/fulltest'));
        req.headers
          ..contentType = ContentType.json
          ..add('Authorization', 'Bearer $_token');
        req.write(jsonEncode({'client_uid': uid, 'kind': _clientKind, 'profiles': profiles}));
        await req.close();
      } finally {
        client.close();
      }
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

  /// Egress IP through the tunnel (§7.3): limm.space/api/myip (CF) first, ipify fallback.
  /// Parses {"ip": "..."} from our endpoint; ipify returns the raw IP. Loopback/private
  /// values are rejected (a mirror that didn't traverse CF would echo 127.0.0.1).
  Future<String?> _egressViaProxy({int timeout = 15}) async {
    for (final ep in _egressEndpoints) {
      final isMyip = ep.contains('/api/myip');
      final body = await _curlProxy(ep, port: _proxyPort, timeout: timeout);
      if (body != null) {
        final ip = isMyip ? _parseMyip(body) : body.trim();
        if (ip != null && _isUsableEgress(ip)) return ip;
      }
    }
    return null;
  }

  String? _parseMyip(String body) {
    try {
      final m = jsonDecode(body);
      final ip = (m is Map) ? m['ip'] : null;
      if (ip is String && ip.trim().isNotEmpty) return ip.trim();
    } catch (_) {}
    return null;
  }

  bool _isUsableEgress(String ip) {
    if (ip.isEmpty) return false;
    if (ip.startsWith('127.') || ip == '::1' || ip.startsWith('10.') ||
        ip.startsWith('192.168.') || ip.startsWith('169.254.')) return false;
    if (ip.startsWith('172.')) {
      final parts = ip.split('.');
      final o2 = parts.length > 1 ? int.tryParse(parts[1]) : null;
      if (o2 != null && o2 >= 16 && o2 <= 31) return false;
    }
    return true;
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
      if (r.exitCode != 0) return null;
      final body = r.stdout.toString().trim();
      return body.isEmpty ? null : body;
    } catch (_) {
      return null;
    }
  }

  /// §7.2 L4 liveness: generate_204 through proxy. Returns elapsed ms on 204/200, else null.
  /// Checks http_code, not body — generate_204 returns an empty body by design, so a
  /// body-based probe would always misread it as a failure (and tunnel_ms would never set).
  Future<int?> _probe204({required int port, int timeout = 5}) async {
    try {
      final t0 = DateTime.now();
      final r = await Process.run(_curl, [
        '--max-time',        '$timeout',
        '--connect-timeout', '${(timeout - 2).clamp(2, timeout)}',
        '-s', '-o', _devNull, '-w', '%{http_code}',
        '--proxy', 'http://127.0.0.1:$port',
        'https://www.gstatic.com/generate_204',
      ]);
      final code = int.tryParse(r.stdout.toString().trim()) ?? 0;
      if (code == 204 || code == 200) {
        return DateTime.now().difference(t0).inMilliseconds;
      }
      return null;
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
      try {
        final req = await client.postUrl(Uri.parse('$_apiBase/checkin'));
        req.headers
          ..contentType = ContentType.json
          ..add('Authorization', 'Bearer $_token');
        req.write(jsonEncode(payload));
        final resp = await req.close();
        final body = await resp.transform(utf8.decoder).join();
        return (resp.statusCode, body);
      } finally {
        client.close();
      }
    } catch (e) {
      return (0, e.toString());
    }
  }
}
