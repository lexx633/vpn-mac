// limm VPN — diagnostic page: connectivity test + log send to limm.space
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class LimmDiagnosticPage extends ConsumerStatefulWidget {
  const LimmDiagnosticPage({super.key});

  @override
  ConsumerState<LimmDiagnosticPage> createState() => _LimmDiagnosticPageState();
}

class _LimmDiagnosticPageState extends ConsumerState<LimmDiagnosticPage> {
  final _log = StringBuffer();
  bool _running = false;

  void _append(String line) {
    setState(() => _log.writeln(line));
  }

  Future<void> _runTest() async {
    if (_running) return;
    setState(() {
      _running = true;
      _log.clear();
    });
    _append("── limm VPN Diagnostic ──");

    // 1. Direct connectivity
    _append("\n[1] Direct internet...");
    try {
      final r = await InternetAddress.lookup("limm.space");
      _append("✓ DNS OK → ${r.first.address}");
    } catch (e) {
      _append("✗ DNS failed: $e");
    }

    // 2. Egress IP via HTTP proxy
    _append("\n[2] Egress IP through proxy (port 12334)...");
    final egressIP = await _curlViaProxy("https://api.ipify.org", port: 12334);
    if (egressIP != null) {
      final isVPN = egressIP.trim() == "45.95.175.170";
      _append("${isVPN ? '✓' : '✗'} IP: ${egressIP.trim()}  ${isVPN ? '= VPN ✓' : '≠ VPN'}");
    } else {
      _append("✗ No response via proxy");
    }

    // 3. Server reachability
    _append("\n[3] Server ping...");
    final ping = await _curlViaProxy("https://45.95.175.170:443", port: 12334, timeoutSec: 8);
    _append(ping != null ? "✓ Server reachable" : "✗ Server unreachable");

    // 4. Send report
    _append("\n[4] Sending report...");
    final sent = await _sendReport(egressIP?.trim());
    _append(sent ? "✓ Report sent to limm.space" : "✗ Report send failed");

    _append("\n── Done ──");
    setState(() => _running = false);
  }

  Future<String?> _curlViaProxy(String url, {required int port, int timeoutSec = 15}) async {
    try {
      final result = await Process.run("/usr/bin/curl", [
        "--max-time", "$timeoutSec", "-s",
        "--proxy", "http://127.0.0.1:$port",
        url,
      ]);
      final out = result.stdout.toString().trim();
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _sendReport(String? egressIP) async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);
      final req = await client.postUrl(Uri.parse(Constants.limmMonitorUrl));
      req.headers.contentType = ContentType.json;
      final body = jsonEncode({
        "kind": "macos",
        "label": "limm-mac2",
        "egress_ip": egressIP ?? "",
        "vpn_ok": egressIP == "45.95.175.170",
        "ts": DateTime.now().toIso8601String(),
      });
      req.write(body);
      final resp = await req.close();
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("limm VPN Diagnostic")),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            ElevatedButton.icon(
              onPressed: _running ? null : _runTest,
              icon: _running
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.play_arrow_rounded),
              label: Text(_running ? "Running..." : "Run Test & Send Report"),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.all(12),
                width: double.infinity,
                child: SingleChildScrollView(
                  child: Text(
                    _log.isEmpty ? "Press the button to start diagnostics." : _log.toString(),
                    style: const TextStyle(
                      fontFamily: "monospace",
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
}
