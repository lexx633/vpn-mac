// limm_diagnostic.dart — Full Test + Status Checkin page.
// Accessible from the app's menu / navigation.
//
// Full Test steps:
//   1. Check-in without VPN (L0/L1 direct probes only)
//   2. Test current profile: egress IP via Hiddify HTTP proxy (12334)
//   3. Post-test checkin (performQuick) → updates limm.space/stat dashboard
//   4. Send diagnostic log
//
// "Send Status Checkin" button — runs full perform() with 30s countdown.

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
  int _checkinSecondsLeft = 0;
  Timer? _countdownTimer;

  static const _proxyPort = 12334;
  static const _serverIP  = '45.95.175.170';

  // ── Logging ───────────────────────────────────────────────────────────────

  void _append(String line) {
    setState(() => _log.writeln(line));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  // ── Full Test ─────────────────────────────────────────────────────────────

  Future<void> _runFullTest() async {
    if (_testRunning) return;
    setState(() { _testRunning = true; _log.clear(); });
    final globalStart = DateTime.now();
    _append('── Full Test начат ${_ts()} ──\n');

    // Step 1: checkin without VPN
    _append('⏳ Чекин (без VPN)…');
    final t1 = DateTime.now();
    final (c1, m1) = await LimmCheckin.shared.perform(overrideVpnOn: false);
    final ms1 = DateTime.now().difference(t1).inMilliseconds;
    _append(c1 == 200
        ? '✓ Чекин (без VPN)  (ok $c1)  [${ms1}ms]'
        : '✗ Чекин (без VPN)  (fail $c1)  [${ms1}ms]');

    // Step 2: test current profile via proxy
    _append('\n── Профиль ──\n');
    _append('⏳ ▸ Текущий профиль…');
    final t2 = DateTime.now();
    final ip = await _curlProxy('https://api.ipify.org', timeout: 20);
    final ms2 = DateTime.now().difference(t2).inMilliseconds;
    bool profileOk = false;
    if (ip != null && ip.isNotEmpty) {
      final isVpn = ip.trim() == _serverIP;
      profileOk = isVpn;
      _append(isVpn
          ? '✓ ▸ Текущий профиль  ($ip  = VPN ✓)  [${ms2}ms]'
          : '✗ ▸ Текущий профиль  ($ip  ≠ VPN)  [${ms2}ms]');
    } else {
      _append('✗ ▸ Текущий профиль  (нет ответа от api.ipify.org)  [${ms2}ms]');
    }

    // Step 3: post-test checkin if profile OK
    if (profileOk) {
      _append('\n⏳ Чекин (VPN on)…');
      final t3 = DateTime.now();
      final (c3, _) = await LimmCheckin.shared.performQuick(egressLatencyMs: ms2);
      final ms3 = DateTime.now().difference(t3).inMilliseconds;
      _append(c3 == 200
          ? '✓ Чекин (VPN on)  (ok $c3)  [${ms3}ms]'
          : '✗ Чекин (VPN on)  (fail $c3)  [${ms3}ms]');
    }

    // Step 4: send log
    _append('\n⏳ Отправка диагностического лога…');
    final t4 = DateTime.now();
    final (logOk, logMsg) = await _sendLog();
    final ms4 = DateTime.now().difference(t4).inMilliseconds;
    _append(logOk
        ? '✓ Отправка диагностического лога  ($logMsg)  [${ms4}ms]'
        : '✗ Отправка диагностического лога  ($logMsg)  [${ms4}ms]');

    final total = DateTime.now().difference(globalStart).inSeconds;
    _append('\n─────────────────────────────────────');
    _append(profileOk ? '✓ OK  [всего ${total}s]' : '✗ Есть ошибки  [всего ${total}s]');
    _append('── Full Test завершён ${_ts()} ──');

    setState(() => _testRunning = false);
  }

  // ── Checkin button ────────────────────────────────────────────────────────

  Future<void> _runCheckin() async {
    if (_checkinRunning) return;
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

    final (code, msg) = await LimmCheckin.shared.perform();
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

  Future<String?> _curlProxy(String url, {int timeout = 15}) async {
    try {
      final r = await Process.run('/usr/bin/curl', [
        '--max-time',      '$timeout',
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
    try {
      final uid = await LimmCheckin.shared.clientUid();
      // send a simple log payload (Hiddify doesn't expose xray log file directly)
      final r = await Process.run('/usr/bin/curl', [
        '--max-time', '20',
        '--connect-timeout', '10',
        '-s', '-X', 'POST',
        '-H', 'Content-Type: application/json',
        '-d', '{"client_uid":"$uid","kind":"macos","label":"mac2","platform":"macos-hiddify"}',
        'https://limm.space/api/log',
      ]);
      if (r.exitCode == 0) {
        final body = r.stdout.toString().trim();
        return (true, '200 $body');
      }
      return (false, 'curl exit ${r.exitCode}');
    } catch (e) {
      return (false, e.toString());
    }
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
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final checkinLabel = _checkinRunning
        ? 'Sending… ${_checkinSecondsLeft}s'
        : 'Send Status Checkin';

    return Scaffold(
      appBar: AppBar(title: const Text('limm VPN — Diagnostic')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // ── Buttons row ──────────────────────────────────────────────
            Row(
              children: [
                // Full Test
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: (_testRunning || _checkinRunning) ? null : _runFullTest,
                    icon: _testRunning
                        ? const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.play_arrow_rounded),
                    label: Text(_testRunning ? 'Running…' : 'Full Test'),
                  ),
                ),
                const SizedBox(width: 10),
                // Send Status Checkin
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: (_testRunning || _checkinRunning) ? null : _runCheckin,
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
