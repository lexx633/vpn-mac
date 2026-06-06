// limm_diagnostic.dart — Full Test + Status Checkin page.
// Accessible from the app's menu / navigation.
//
// Full Test steps:
//   1. Check-in without VPN (L0/L1 direct probes only)
//   2. Measure L1 direct RTT to VPN server (3 probes, avg)
//   3. Test current profile: egress IP, tunnel latency, service checks
//   4. Post-test checkin with all measured data → updates limm.space/stat dashboard
//   5. POST /api/fulltest with profile result
//   6. Send diagnostic log
//
// Row 1 Ping (latency_ms): direct TCP RTT to VPN server (no tunnel, L1 probe)
// Row 2 Ping (tunnel_ms): RTT through VPN tunnel (gstatic generate_204)
//
// Buttons:
//   [Full Test]  [Send Diagnostic Log]  [Status Checkin]

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hiddify/features/limm/limm_checkin.dart';

class LimmDiagnosticPage extends StatefulWidget {
  const LimmDiagnosticPage({super.key});

  @override
  State<LimmDiagnosticPage> createState() => _LimmDiagnosticPageState();
}

class _LimmDiagnosticPageState extends State<LimmDiagnosticPage> {
  final _log = StringBuffer();
  final _scrollCtrl = ScrollController();
  bool _testRunning = false;
  bool _checkinRunning = false;
  bool _logRunning = false;
  int _checkinSecondsLeft = 0;
  Timer? _countdownTimer;

  static const _proxyPort = 12334;
  static const _serverIP  = '45.95.175.170';

  /// curl executable: absolute path on macOS/Linux, via PATH on Windows.
  static String get _curl => Platform.isWindows ? 'curl' : _curl;

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
    final globalStart = DateTime.now();
    _append('── Full Test начат ${_ts()} ──\n');

    // Step 1: checkin without VPN (L0/L1 baseline)
    _append('⏳ Чекин (без VPN)…');
    final t1 = DateTime.now();
    final (c1, m1) = await LimmCheckin.shared.perform(overrideVpnOn: false);
    final ms1 = DateTime.now().difference(t1).inMilliseconds;
    _append(c1 == 200
        ? '✓ Чекин (без VPN)  (ok $c1)  [${ms1}ms]'
        : '✗ Чекин (без VPN)  (fail $c1 $m1)  [${ms1}ms]');

    // Step 2: measure L1 RTT — direct TCP to VPN server (3 probes, bypasses TUN)
    _append('\n⏳ Пинг L1 (прямой, до VPN-сервера)…');
    final l1samples = <int>[];
    for (var i = 0; i < 3; i++) {
      final t = DateTime.now();
      final ok = await _curlDirect('http://$_serverIP:$_proxyPort', timeout: 5);
      if (ok) l1samples.add(DateTime.now().difference(t).inMilliseconds);
    }
    final l1 = l1samples.isNotEmpty ? 1 : 0;
    final latencyMs = l1samples.isNotEmpty
        ? l1samples.reduce((a, b) => a + b) ~/ l1samples.length
        : 0;
    _append(l1 == 1
        ? '✓ Пинг L1  ${latencyMs}ms (среднее из ${l1samples.length} проб)'
        : '✗ Пинг L1  недоступен (ISP блок или сервер упал)');

    // Step 3: test current profile through proxy
    _append('\n── Текущий профиль ──\n');

    // 3a: egress IP
    _append('⏳ Egress IP (api.ipify.org)…');
    final t3a = DateTime.now();
    final ip = await _curlProxy('https://api.ipify.org', timeout: 20);
    final ms3a = DateTime.now().difference(t3a).inMilliseconds;
    final egressIp = ip?.trim() ?? '';
    final l4 = egressIp == _serverIP ? 1 : 0;

    if (egressIp.isNotEmpty) {
      _append(l4 == 1
          ? '✓ Egress IP  $egressIp  = VPN ✓  [${ms3a}ms]'
          : '✗ Egress IP  $egressIp  ≠ VPN  [${ms3a}ms]');
    } else {
      _append('✗ Egress IP  (нет ответа)  [${ms3a}ms]');
    }

    // 3b: tunnel latency (gstatic generate_204 through proxy)
    int? tunnelMs;
    if (egressIp.isNotEmpty) {
      _append('⏳ Пинг туннель (gstatic)…');
      final tTun = DateTime.now();
      final tOk = await _curlProxy('https://www.gstatic.com/generate_204', timeout: 8);
      if (tOk != null) {
        tunnelMs = DateTime.now().difference(tTun).inMilliseconds;
        _append('✓ Пинг туннель  ${tunnelMs}ms');
      } else {
        _append('✗ Пинг туннель  (нет ответа)');
      }

      // 3c: service checks (parallel)
      _append('⏳ Сервисы (Telegram / Google / ChatGPT)…');
      final svcResults = await Future.wait([
        _probeService('https://web.telegram.org/'),
        _probeService('https://www.google.com/search?q=test'),
        _probeService('https://chatgpt.com/'),
      ]);
      final tg    = svcResults[0];
      final ggl   = svcResults[1];
      final chgpt = svcResults[2];

      final tgIcon    = tg    == 'ok' ? '✓' : '✗';
      final gglIcon   = ggl   == 'ok' ? '✓' : '✗';
      final chgptIcon = chgpt == 'ok' ? '✓' : '✗';
      _append('$tgIcon Telegram=$tg  $gglIcon Google=$ggl  $chgptIcon ChatGPT=$chgpt');

      // Step 4: post-test checkin with full measured data
      _append('\n⏳ Чекин (VPN on, с данными)…');
      final t4 = DateTime.now();
      final (c4, _) = await LimmCheckin.shared.performPostTest(
        l0: 1, l1: l1, l4: l4,
        egressIp: egressIp,
        latencyMs: latencyMs > 0 ? latencyMs : null,
        tunnelMs: tunnelMs,
        tgStatus: tg, gglStatus: ggl, chgptStatus: chgpt,
      );
      final ms4 = DateTime.now().difference(t4).inMilliseconds;
      _append(c4 == 200
          ? '✓ Чекин (VPN on)  (ok $c4)  [${ms4}ms]'
          : '✗ Чекин (VPN on)  (fail $c4)  [${ms4}ms]');

      // Step 5: POST /api/fulltest with profile result
      await LimmCheckin.shared.postFulltestResult(
        profileName: 'текущий',
        ok: l4 == 1,
        latencyMs: tunnelMs,
      );
    } else {
      // Profile didn't work — still send correct VPN-on state if socket listening
      final vpnOn = await LimmCheckin.shared.vpnAvailable();
      if (vpnOn) {
        _append('\n⏳ Чекин (VPN on, профиль не прошёл)…');
        final (cN, _) = await LimmCheckin.shared.performPostTest(
          l0: 1, l1: l1, l4: 0,
          latencyMs: latencyMs > 0 ? latencyMs : null,
        );
        _append(cN == 200
            ? '✓ Чекин (VPN on, l4=0)  (ok $cN)'
            : '✗ Чекин (VPN on, l4=0)  (fail $cN)');

        await LimmCheckin.shared.postFulltestResult(
          profileName: 'текущий',
          ok: false,
        );
      }
    }

    // Step 6: send diagnostic log
    _append('\n⏳ Отправка диагностического лога…');
    final t6 = DateTime.now();
    final (logOk, logMsg) = await _sendLog();
    final ms6 = DateTime.now().difference(t6).inMilliseconds;
    _append(logOk
        ? '✓ Лог отправлен  ($logMsg)  [${ms6}ms]'
        : '✗ Лог отправлен  ($logMsg)  [${ms6}ms]');

    final total = DateTime.now().difference(globalStart).inSeconds;
    _append('\n─────────────────────────────────────');
    _append(l4 == 1 ? '✓ OK  [всего ${total}s]' : '✗ Есть ошибки  [всего ${total}s]');
    _append('── Full Test завершён ${_ts()} ──');

    setState(() => _testRunning = false);
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

  Future<void> _runCheckin() async {
    if (_busy) return;
    setState(() {
      _checkinRunning = true;
      _checkinSecondsLeft = 30;
    });

    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      setState(() {
        _checkinSecondsLeft--;
        if (_checkinSecondsLeft <= 0) t.cancel();
      });
    });

    // 30s hard timeout
    bool done = false;
    Future.delayed(const Duration(seconds: 30), () {
      if (!done && mounted) {
        done = true;
        _countdownTimer?.cancel();
        setState(() { _checkinRunning = false; _checkinSecondsLeft = 0; });
        _showAlert('❌ Timeout', 'No response in 30 seconds. Check VPN connection.');
      }
    });

    // Use performQuick: instant POST (<2s) if VPN available, no heavy curl probes.
    // Full perform() takes 30-75s and always hit the 30s timeout.
    final vpnOn = await LimmCheckin.shared.vpnAvailable();
    final (code, msg) = vpnOn
        ? await LimmCheckin.shared.performQuick()
        : await LimmCheckin.shared.perform(overrideVpnOn: false);
    if (!done && mounted) {
      done = true;
      _countdownTimer?.cancel();
      setState(() { _checkinRunning = false; _checkinSecondsLeft = 0; });
      if (code == 200) {
        _showAlert('✅ Checkin sent', 'Status updated on limm.space/stat');
      } else {
        _showAlert('❌ Checkin failed', 'code=$code  $msg');
      }
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Direct curl bypassing TUN via --noproxy '*'.
  Future<bool> _curlDirect(String url, {int timeout = 5}) async {
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

  /// HTTP status probe through proxy. Returns "ok" / "blocked" / "down".
  Future<String> _probeService(String url) async {
    try {
      final r = await Process.run(_curl, [
        '--max-time',        '12',
        '--connect-timeout', '10',
        '-s', '-o', '/dev/null', '-w', '%{http_code}',
        '--proxy', 'http://127.0.0.1:$_proxyPort',
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

  Future<(bool, String)> _sendLog() async {
    final (code, body) = await LimmCheckin.shared.sendLog();
    return (code == 200, '$code $body');
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
