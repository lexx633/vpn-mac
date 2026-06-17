// limm_diagnostic.dart — Full Test + Status Checkin page.
// Accessible from the app's menu / navigation.
//
// Full Test conforms to the cross-fork contract in docs/TZ-fulltest-optim.md §7:
//   §7.3 egress endpoint: /api/myip (www→vpn→limm mirrors) first, api.ipify.org fallback.
//   §7.4 verdict:         ok = egress != null (any egress = tunnel carries traffic;
//                         chains exit via different nodes — never compare with one IP).
//   §7.2 L4 liveness:     generate_204 through tunnel → browser_ok per profile.
//   §7.5 timeouts:        by transport type (xhttp 8s×3, hy2/tuic 6s×2, tcp 6s×2).
//   §7.7 payload:         per-profile {name, ok, egress_ip, browser_ok, latency_ms}.
//
// Full Test steps (tests ALL outbounds from the selector group):
//   1. Baseline checkin (overrideVpnOn=false)
//   2. Fetch known server IPs from subscription (informational; verdict is egress!=null)
//   3. Iterate all outbounds: selectOutbound → settle → egress via /api/myip → 204 liveness
//   4. POST /api/fulltest with all profile results
//   5. Keep best working profile active → final checkin on the live tunnel
//   6. Send diagnostic log; restore original selection only if nothing worked
//
// Status Checkin: L1 direct TCP ping + tunnel latency (gstatic) → POST /api/checkin.
//
// Buttons:
//   [Full Test]  [Send Diagnostic Log]  [Status Checkin]

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hiddify/features/limm/limm_checkin.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class LimmDiagnosticPage extends ConsumerStatefulWidget {
  const LimmDiagnosticPage({super.key});

  @override
  ConsumerState<LimmDiagnosticPage> createState() => _LimmDiagnosticPageState();
}

class _LimmDiagnosticPageState extends ConsumerState<LimmDiagnosticPage> {
  final _log = StringBuffer();
  final _scrollCtrl = ScrollController();
  bool _testRunning = false;
  bool _checkinRunning = false;
  bool _logRunning = false;
  int _checkinSecondsLeft = 0;
  Timer? _countdownTimer;

  static const _proxyPort  = 12334;   // Hiddify mixed-port (local HTTP proxy)
  static const _serverIP   = '45.95.175.170';
  static const _serverPort = 443;     // VPN server port for L1 TCP probe

  // §7.3 egress: our own /api/myip first, ipify fallback. Hit limm.space (CF) — NOT the
  // www/vpn mirrors: the probe rides the tunnel (exit is outside RU → CF is reachable),
  // and only CF returns the real exit-node IP (CF-Connecting-IP). Direct www via the :443
  // stream-mux would return 127.0.0.1, vpn/Bunny an edge IP (see map-db.md / map-macos.md).
  static const _egressEndpoints = [
    'https://limm.space/api/myip',
    'https://api.ipify.org',
  ];

  /// curl executable: absolute path on macOS/Linux, via PATH on Windows.
  static String get _curl => Platform.isWindows ? 'curl' : '/usr/bin/curl';

  /// Null device for curl -o (discard body).
  static String get _devNull => Platform.isWindows ? 'NUL' : '/dev/null';

  // §7.5 per-transport-type egress timeout/retry budget. Type derived from tag suffix.
  static String _transportType(String tag) {
    final t = tag.toLowerCase();
    if (t.contains('-tc') || t.contains('tuic')) return 'tuic';
    if (t.contains('-hy2') || t.contains('hysteria')) return 'hy2';
    if (t.contains('xhttp')) return 'xhttp';
    return 'tcp'; // reality / ws / cf-ws / relay
  }

  static (int, int) _ftBudget(String type) {
    switch (type) {
      case 'xhttp': return (8, 3);
      case 'hy2':
      case 'tuic':  return (6, 2);
      default:      return (6, 2); // tcp
    }
  }

  // ── Logging ───────────────────────────────────────────────────────────────

  void _append(String line) {
    setState(() => _log.writeln(line));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  bool get _busy => _testRunning || _checkinRunning || _logRunning;

  // ── Full Test ─────────────────────────────────────────────────────────────

  Future<void> _runFullTest() async {
    if (_busy) return;
    setState(() { _testRunning = true; _log.clear(); });
    try {
      final globalStart = DateTime.now();
      _append('── Full Test начат ${_ts()} ──\n');

      // Step 1: baseline checkin without VPN
      _append('⏳ Чекин (без VPN)…');
      final t1 = DateTime.now();
      final (c1, m1) = await LimmCheckin.shared.perform(overrideVpnOn: false);
      final ms1 = DateTime.now().difference(t1).inMilliseconds;
      _append(c1 == 200
          ? '✓ Чекин (без VPN)  (ok $c1)  [${ms1}ms]'
          : '✗ Чекин (без VPN)  (fail $c1 $m1)  [${ms1}ms]');

      // Step 2: fetch known server IPs from sub
      _append('\n⏳ Получаю список серверов из подписки…');
      final knownIPs = await LimmCheckin.shared.fetchKnownServerIPs();
      _append(knownIPs.isEmpty
          ? '⚠️  Список серверов недоступен (fallback к дефолтному IP)'
          : '✓ IP-адресов серверов: ${knownIPs.length}  (${knownIPs.join(", ")})');

      // Step 3: test all outbounds sequentially
      _append('\n── Тест всех профилей ──');
      final profileResults = await _runProfilesFulltest(knownIPs);

      // Step 4: post all fulltest results
      if (profileResults.isNotEmpty) {
        await LimmCheckin.shared.postAllFulltestResults(profileResults);
        final okCount = profileResults.where((r) => r['ok'] == 1).length;
        _append('\n✓ Результаты отправлены: $okCount/${profileResults.length} профилей работают');
      }

      // Step 5: post-test checkin based on overall result.
      // Pick the best working profile (lowest tunnel latency) — its tunnel is now active.
      final anyOk = profileResults.any((r) => r['ok'] == 1);
      _append('\n⏳ Чекин (итог)…');
      Map<String, dynamic>? best;
      for (final r in profileResults.where((r) => r['ok'] == 1)) {
        final ms = r['latency_ms'] as int?;
        if (best == null) { best = r; continue; }
        final bms = best['latency_ms'] as int?;
        if (ms != null && (bms == null || ms < bms)) best = r;
      }
      final bestTunnelMs = best?['latency_ms'] as int?;
      final bestEgress   = best?['egress_ip'] as String? ?? '';
      final anyBrowserOk = profileResults.any((r) => r['browser_ok'] == 1);
      int cFinal; String mFinal;
      if (anyOk) {
        (cFinal, mFinal) = await LimmCheckin.shared.performPostTest(
          l0: 1, l1: 1, l4: anyBrowserOk ? 1 : 0,
          egressIp: bestEgress, tunnelMs: bestTunnelMs,
        );
      } else {
        (cFinal, mFinal) = await LimmCheckin.shared.perform(overrideVpnOn: false);
      }
      _append(cFinal == 200
          ? '✓ Чекин отправлен  (ok $cFinal)'
          : '✗ Чекин  (fail $cFinal  $mFinal)');

      // Step 6: send diagnostic log
      _append('\n⏳ Отправка диагностического лога…');
      final t6 = DateTime.now();
      final (logOk, logMsg) = await _sendLog();
      final ms6 = DateTime.now().difference(t6).inMilliseconds;
      _append(logOk
          ? '✓ Лог отправлен  ($logMsg)  [${ms6}ms]'
          : '✗ Лог  ($logMsg)  [${ms6}ms]');

      final total = DateTime.now().difference(globalStart).inSeconds;
      _append('\n─────────────────────────────────────');
      _append(anyOk
          ? '✓ OK — хотя бы один профиль работает  [всего ${total}s]'
          : '✗ Все профили не прошли тест  [всего ${total}s]');
      _append('── Full Test завершён ${_ts()} ──');
    } finally {
      setState(() => _testRunning = false);
    }
  }

  // ── Send Diagnostic Log (standalone) ─────────────────────────────────────

  Future<void> _runSendLog() async {
    if (_busy) return;
    setState(() { _logRunning = true; });
    _append('⏳ Отправка диагностического лога…');
    final (ok, msg) = await _sendLog();
    _append(ok
        ? '✓ Лог отправлен  ($msg)'
        : '✗ Ошибка отправки  ($msg)');
    setState(() { _logRunning = false; });
  }

  // ── Status Checkin button ─────────────────────────────────────────────────
  // Measures real latency (3×L1 direct probes avg + tunnel probe if VPN on)
  // so the dashboard Ping column gets filled: row1=latency_ms, row2=tunnel_ms.
  // Total worst case: 3×5s probes + 8s tunnel + 5s POST ≈ 28s → 50s timeout.

  Future<void> _runCheckin() async {
    if (_busy) return;
    setState(() {
      _checkinRunning = true;
      _checkinSecondsLeft = 50;
    });

    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      setState(() {
        _checkinSecondsLeft--;
        if (_checkinSecondsLeft <= 0) t.cancel();
      });
    });

    // 50s hard timeout
    bool done = false;
    Future.delayed(const Duration(seconds: 50), () {
      if (!done && mounted) {
        done = true;
        _countdownTimer?.cancel();
        setState(() { _checkinRunning = false; _checkinSecondsLeft = 0; });
        _showAlert('❌ Timeout', 'No response in 50s.');
      }
    });

    // Step 1: L1 direct TCP RTT to VPN server (3 probes avg, bypasses proxy and TUN)
    final l1samples = <int>[];
    for (var i = 0; i < 3; i++) {
      final ms = await _tcpPing(_serverIP, _serverPort);
      if (ms != null) l1samples.add(ms);
    }
    final l1 = l1samples.isNotEmpty ? 1 : 0;
    final latencyMs = l1samples.isNotEmpty
        ? l1samples.reduce((a, b) => a + b) ~/ l1samples.length
        : 0;

    // Step 2: check VPN + measure tunnel latency via generate_204 (§7.2 L4), 3 probes avg
    final vpnOn = await LimmCheckin.shared.vpnAvailable();
    int? tunnelMs;
    int tunCount = 0;
    if (vpnOn) {
      final tunSamples = <int>[];
      for (var i = 0; i < 3; i++) {
        final ms = await _probe204(timeout: 8);
        if (ms != null) tunSamples.add(ms);
      }
      tunCount = tunSamples.length;
      if (tunSamples.isNotEmpty) {
        tunnelMs = tunSamples.reduce((a, b) => a + b) ~/ tunSamples.length;
      }
    }

    // Step 3: POST checkin with real latency data. l4 = generate_204 passed (§7.2 L4).
    int code; String msg;
    if (vpnOn) {
      (code, msg) = await LimmCheckin.shared.performPostTest(
        l0: 1, l1: l1, l4: tunnelMs != null ? 1 : 0,
        latencyMs: latencyMs > 0 ? latencyMs : null,
        tunnelMs: tunnelMs,
      );
    } else {
      (code, msg) = await LimmCheckin.shared.perform(overrideVpnOn: false);
    }

    if (!done && mounted) {
      done = true;
      _countdownTimer?.cancel();
      setState(() { _checkinRunning = false; _checkinSecondsLeft = 0; });
      final pingInfo = latencyMs > 0
          ? 'Прямой  ${latencyMs}ms  (среднее ${l1samples.length}/3)\n'
            'Туннель  ${tunnelMs != null ? "${tunnelMs}ms  (среднее $tunCount/3)" : "нет данных"}'
          : 'Прямой  недоступен';
      if (code == 200) {
        _showAlert('✅ Checkin sent', '$pingInfo\nStatus updated on limm.space/stat');
      } else {
        _showAlert('❌ Checkin failed', 'code=$code  $msg');
      }
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Pure TCP connect RTT — bypasses HTTP proxy and TUN alike.
  /// Returns elapsed ms on connection, null on error/timeout.
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

  Future<(bool, String)> _sendLog() async {
    final (code, body) = await LimmCheckin.shared.sendLog();
    return (code == 200, '$code $body');
  }

  /// Curl through Hiddify proxy with --no-keepalive so each call uses a fresh connection.
  /// Critical for switching outbounds: keepalive would reuse the old tunnel.
  Future<String?> _curlProxyNoKA(String url, {int timeout = 18}) async {
    try {
      final r = await Process.run(_curl, [
        '--max-time',        '$timeout',
        '--connect-timeout', '${(timeout - 2).clamp(2, timeout)}',
        '-s', '--no-keepalive',
        '--proxy', 'http://127.0.0.1:$_proxyPort',
        url,
      ]);
      final out = r.stdout.toString().trim();
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  static const _ftSkipTags  = {'direct', 'block', 'dns-out', 'GLOBAL', 'REJECT'};
  static const _ftSkipTypes = {'selector', 'urltest', 'dns', 'block', 'direct'};

  /// Egress IP through the active tunnel (§7.3): limm.space/api/myip (CF) first, ipify fallback.
  /// Each call uses --no-keepalive so it rides the freshly-switched outbound.
  Future<String?> _egressViaProxy({required int timeout}) async {
    for (final ep in _egressEndpoints) {
      final isMyip = ep.contains('/api/myip');
      final body = await _curlProxyNoKA(ep, timeout: timeout);
      if (body != null) {
        final ip = isMyip ? _parseMyip(body) : body.trim();
        if (ip != null && _isUsableEgress(ip)) return ip;
      }
    }
    return null;
  }

  /// Parse {"ip":"..."} from /api/myip.
  String? _parseMyip(String body) {
    try {
      final m = jsonDecode(body);
      final ip = (m is Map) ? m['ip'] : null;
      if (ip is String && ip.trim().isNotEmpty) return ip.trim();
    } catch (_) {}
    return null;
  }

  /// A real egress can't be loopback/private — if a mirror returned 127.0.0.1 / 10.* /
  /// 192.168.* etc. it isn't the true exit IP, so treat it as no egress.
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

  /// §7.2 L4 liveness: generate_204 through the tunnel. Returns elapsed ms on 204/200,
  /// null otherwise. Uses http_code (not body) — generate_204 has an empty body by design,
  /// so a body-based check would always read it as a failure.
  Future<int?> _probe204({required int timeout}) async {
    try {
      final t0 = DateTime.now();
      final r = await Process.run(_curl, [
        '--max-time',        '$timeout',
        '--connect-timeout', '${(timeout - 2).clamp(2, timeout)}',
        '-s', '-o', _devNull, '-w', '%{http_code}',
        '--no-keepalive',
        '--proxy', 'http://127.0.0.1:$_proxyPort',
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

  /// Test all outbounds in the main selector group sequentially (§7 contract).
  /// Switches each outbound, settles routing, probes egress (§7.4 ok = egress != null)
  /// and a generate_204 liveness signal (§7.2). On exit leaves the best working profile
  /// active (so step 5/6 log through a live tunnel); restores original only if none worked.
  Future<List<Map<String, dynamic>>> _runProfilesFulltest(Set<String> knownIPs) async {
    final results = <Map<String, dynamic>>[];

    final coreService = ref.read(hiddifyCoreServiceProvider);
    final groups = coreService.latest;

    // Find the main selector group (selectable == true)
    OutboundGroup? sel;
    for (final g in groups) {
      if (g.type.toLowerCase() == 'selector' && g.selectable) { sel = g; break; }
    }
    if (sel == null) {
      _append('⚠️  Selector group не найден — нет профилей для теста');
      return results;
    }

    final groupTag = sel.tag;
    final originalTag = sel.selected;
    _append('Selector: "$groupTag"  текущий: "$originalTag"');

    final testable = sel.items
        .where((i) => !_ftSkipTags.contains(i.tag) && !_ftSkipTypes.contains(i.type.toLowerCase()))
        .toList();
    _append('Профилей: ${testable.length}\n');

    String? bestTag;       // best working profile → kept active for log phase (F1.1)
    int? bestMs;

    try {
      for (final item in testable) {
        final tag = item.tag;
        final display = item.tagDisplay.isNotEmpty ? item.tagDisplay : tag;
        final ttype = _transportType(tag);
        final (timeout, retries) = _ftBudget(ttype);
        _append('    $display…');

        final switched = await coreService.selectOutbound(groupTag, tag).run();
        if (!switched.isRight()) {
          _append('  ✗ $display  (switch failed)');
          results.add({'name': display, 'ok': 0});
          continue;
        }

        await Future.delayed(const Duration(milliseconds: 1800));

        // §7.4 egress probe — success ends retries (only the failing profile pays).
        String? egressIp;
        int? tunnelMs;
        for (var attempt = 1; attempt <= retries; attempt++) {
          final t = DateTime.now();
          egressIp = await _egressViaProxy(timeout: timeout);
          if (egressIp != null) { tunnelMs = DateTime.now().difference(t).inMilliseconds; break; }
          if (attempt < retries) await Future.delayed(const Duration(milliseconds: 500));
        }

        // §7.4 verdict: any egress = tunnel carries traffic. Never compare with a single IP.
        final ok = egressIp != null;
        // §7.2 L4 liveness only on live profiles (dead ones never reach here).
        final browserOk = ok && (await _probe204(timeout: timeout)) != null;
        final known = ok && knownIPs.contains(egressIp);

        _append(ok
            ? '  ✓ $display  $egressIp  [${tunnelMs}ms]'
              '${browserOk ? '  204✓' : '  204✗'}${known ? '' : '  (egress вне sub)'}'
            : '  ✗ $display  нет ответа');

        final profile = <String, dynamic>{'name': display, 'ok': ok ? 1 : 0};
        if (egressIp != null) profile['egress_ip'] = egressIp;
        if (tunnelMs != null) profile['latency_ms'] = tunnelMs;
        profile['browser_ok'] = browserOk ? 1 : 0;
        results.add(profile);

        if (ok && (bestMs == null || (tunnelMs ?? 1 << 30) < bestMs)) {
          bestTag = tag;
          bestMs = tunnelMs ?? (1 << 30);
        }
      }
    } finally {
      // F1.1 — keep the best working tunnel active for the checkin+log phase.
      // If nothing worked, restore the user's original selection.
      final restoreTag = bestTag ?? (originalTag.isNotEmpty ? originalTag : null);
      if (restoreTag != null) {
        await coreService.selectOutbound(groupTag, restoreTag).run();
        await Future.delayed(const Duration(milliseconds: 800));
        _append(bestTag != null
            ? '\n✓ Активен рабочий профиль: "$bestTag"'
            : '\n↺ Восстановлен: "$restoreTag"');
      }
    }

    return results;
  }

  String _ts() {
    final n = DateTime.now();
    return '${n.hour.toString().padLeft(2,'0')}:'
        '${n.minute.toString().padLeft(2,'0')}:'
        '${n.second.toString().padLeft(2,'0')}';
  }

  void _showAlert(String title, String body) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final checkinLabel = _checkinRunning
        ? 'Checkin… ${_checkinSecondsLeft}s'
        : 'Status Checkin';

    return Scaffold(
      appBar: AppBar(title: const Text('limm VPN — Diagnostic')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // ── Buttons row ──────────────────────────────────────────────
            Row(
              children: [
                // Full Test (wide)
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: _busy ? null : _runFullTest,
                    icon: _testRunning
                        ? const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.play_arrow_rounded),
                    label: Text(_testRunning ? 'Running…' : 'Full Test'),
                  ),
                ),
                const SizedBox(width: 8),
                // Send Diagnostic Log
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _busy ? null : _runSendLog,
                    icon: _logRunning
                        ? const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.upload_rounded),
                    label: Text(_logRunning ? 'Sending…' : 'Send Log'),
                  ),
                ),
                const SizedBox(width: 8),
                // Status Checkin
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _busy ? null : _runCheckin,
                    icon: _checkinRunning
                        ? const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.sync_rounded),
                    label: Text(checkinLabel),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // ── Log output ───────────────────────────────────────────────
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.all(12),
                width: double.infinity,
                child: SingleChildScrollView(
                  controller: _scrollCtrl,
                  child: Text(
                    _log.isEmpty ? 'Press Full Test to start.' : _log.toString(),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      color: Colors.lightGreenAccent,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _scrollCtrl.dispose();
    super.dispose();
  }
}
