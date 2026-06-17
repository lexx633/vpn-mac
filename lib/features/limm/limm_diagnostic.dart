// limm_diagnostic.dart — Full Test + Status Checkin page.
// Accessible from the app's menu / navigation.
//
// Full Test steps (tests ALL outbounds from the selector group):
//   1. Baseline checkin (overrideVpnOn=false)
//   2. Fetch known server IPs from subscription
//   3. Iterate all outbounds: selectOutbound → wait 1.8s → egress IP via proxy → ok?
//   4. POST /api/fulltest with all profile results
//   5. Final checkin (VPN on if any profile passed, off otherwise)
//   6. Send diagnostic log
//
// Status Checkin: L1 direct TCP ping + tunnel latency (gstatic) → POST /api/checkin.
//
// Buttons:
//   [Full Test]  [Send Diagnostic Log]  [Status Checkin]

import 'dart:async';
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

  /// curl executable: absolute path on macOS/Linux, via PATH on Windows.
  static String get _curl => Platform.isWindows ? 'curl' : '/usr/bin/curl';

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

      // Step 5: post-test checkin based on overall result
      final anyOk = profileResults.any((r) => r['ok'] == 1);
      _append('\n⏳ Чекин (итог)…');
      final bestTunnelMs = profileResults
          .where((r) => r['ok'] == 1 && r.containsKey('latency_ms'))
          .map<int>((r) => r['latency_ms'] as int)
          .fold<int?>(null, (best, ms) => best == null || ms < best ? ms : best);
      int cFinal; String mFinal;
      if (anyOk) {
        (cFinal, mFinal) = await LimmCheckin.shared.performPostTest(
          l0: 1, l1: 1, l4: 1, tunnelMs: bestTunnelMs,
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

    // Step 2: check VPN + measure tunnel latency (3 probes avg)
    final vpnOn = await LimmCheckin.shared.vpnAvailable();
    int? tunnelMs;
    int tunCount = 0;
    if (vpnOn) {
      final tunSamples = <int>[];
      for (var i = 0; i < 3; i++) {
        final tStart = DateTime.now();
        final tOk = await _curlProxy('https://www.gstatic.com/generate_204', timeout: 8);
        if (tOk != null) tunSamples.add(DateTime.now().difference(tStart).inMilliseconds);
      }
      tunCount = tunSamples.length;
      if (tunSamples.isNotEmpty) {
        tunnelMs = tunSamples.reduce((a, b) => a + b) ~/ tunSamples.length;
      }
    }

    // Step 3: POST checkin with real latency data
    int code; String msg;
    if (vpnOn) {
      (code, msg) = await LimmCheckin.shared.performPostTest(
        l0: 1, l1: l1, l4: 0,    // l4 unknown without full egress probe
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

  /// HTTP request through Hiddify HTTP proxy.
  Future<String?> _curlProxy(String url, {int timeout = 15}) async {
    try {
      final r = await Process.run(_curl, [
        '--max-time',        '$timeout',
        '--connect-timeout', '${(timeout - 2).clamp(2, timeout)}',
        '-s',
        '--proxy', 'http://127.0.0.1:$_proxyPort',
        url,
      ]);
      final out = r.stdout.toString().trim();
      return out.isEmpty ? null : out;
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

  /// Test all outbounds in the main selector group sequentially.
  /// Switches each outbound, waits for routing to settle, tests egress IP.
  /// Restores the original selection on exit (success or error).
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

    // Extend known IPs with any IP-like hosts from OutboundInfo
    final allIPs = {...knownIPs};
    for (final item in sel.items) {
      final h = item.host;
      if (RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(h)) allIPs.add(h);
    }

    final testable = sel.items
        .where((i) => !_ftSkipTags.contains(i.tag) && !_ftSkipTypes.contains(i.type.toLowerCase()))
        .toList();
    _append('Профилей: ${testable.length}\n');

    try {
      for (final item in testable) {
        final tag = item.tag;
        final display = item.tagDisplay.isNotEmpty ? item.tagDisplay : tag;
        _append('    $display…');

        final switched = await coreService.selectOutbound(groupTag, tag).run();
        final switchOk = switched.isRight();
        if (!switchOk) {
          _append('  ✗ $display  (switch failed)');
          results.add({'name': display, 'ok': 0});
          continue;
        }

        await Future.delayed(const Duration(milliseconds: 1800));

        String? egressIp;
        int? tunnelMs;
        for (var attempt = 1; attempt <= 2; attempt++) {
          final t = DateTime.now();
          egressIp = await _curlProxyNoKA('https://api.ipify.org', timeout: 18);
          if (egressIp != null) { tunnelMs = DateTime.now().difference(t).inMilliseconds; break; }
          if (attempt < 2) await Future.delayed(const Duration(milliseconds: 500));
        }

        final ok = egressIp != null && allIPs.contains(egressIp.trim());
        _append(ok
            ? '  ✓ $display  ${egressIp!.trim()}  [${tunnelMs}ms]'
            : '  ✗ $display  ${egressIp ?? "нет ответа"}');

        final profile = <String, dynamic>{'name': display, 'ok': ok ? 1 : 0};
        if (tunnelMs != null && ok) profile['latency_ms'] = tunnelMs;
        results.add(profile);
      }
    } finally {
      if (originalTag.isNotEmpty) {
        await coreService.selectOutbound(groupTag, originalTag).run();
        _append('\n↺ Восстановлен: "$originalTag"');
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
