import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/platform_model.dart';

/// Painel "Rede deste computador": IP local, IP publico e provedor de internet.
/// O IP local e lido do sistema ao abrir. O IP publico e o provedor so sao
/// consultados quando o usuario clica em "Atualizar".
/// Tambem traz o botao "Permitir conexao na rede local", que liga o acesso
/// direto por IP e libera o programa no Firewall do Windows (uma unica
/// janela de permissao do Windows).
class MtechNetworkPanel extends StatefulWidget {
  const MtechNetworkPanel({Key? key}) : super(key: key);

  @override
  State<MtechNetworkPanel> createState() => _MtechNetworkPanelState();
}

class _LocalAddr {
  final String name;
  final String ip;
  _LocalAddr(this.name, this.ip);
}

class _MtechNetworkPanelState extends State<MtechNetworkPanel> {
  static const Color _mtechRed = Color(0xFFED1C24);
  static const String _ruleName = 'Suporte M-Tech (rede local)';

  List<_LocalAddr> _locals = [];
  String _publicIp = '';
  String _provider = '';
  String _error = '';
  bool _loading = false;
  String _copied = '';

  // Conexao local
  bool _statusKnown = false;
  bool _directOn = false;
  bool _firewallOn = false;
  bool _busy = false;
  String _msg = '';

  bool get _lanReady => _directOn && _firewallOn;

  @override
  void initState() {
    super.initState();
    _loadLocal();
    _refreshStatus();
  }

  List<int> _utf16le(String text) {
    final bytes = <int>[];
    for (final u in text.codeUnits) {
      bytes.add(u & 0xFF);
      bytes.add((u >> 8) & 0xFF);
    }
    return bytes;
  }

  Future<bool> _checkFirewall() async {
    if (!Platform.isWindows) return true;
    try {
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        "if (Get-NetFirewallRule -DisplayName '$_ruleName' -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }",
      ]).timeout(const Duration(seconds: 15));
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> _refreshStatus() async {
    bool direct = false;
    try {
      direct = mainGetBoolOptionSync(kOptionDirectServer);
    } catch (_) {}
    final fw = await _checkFirewall();
    if (!mounted) return;
    setState(() {
      _directOn = direct;
      _firewallOn = fw;
      _statusKnown = true;
    });
  }

  /// Liga o acesso direto por IP e libera o programa no firewall.
  Future<void> _enableLan() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _msg = '';
    });
    try {
      try {
        await mainSetBoolOption(kOptionDirectServer, true);
      } catch (_) {}
      if (Platform.isWindows) {
        final exe = Platform.resolvedExecutable.replaceAll("'", "''");
        final script =
            "Remove-NetFirewallRule -DisplayName '$_ruleName' -ErrorAction SilentlyContinue; "
            "New-NetFirewallRule -DisplayName '$_ruleName' -Direction Inbound -Program '$exe' -Action Allow -Profile Private,Domain | Out-Null";
        final enc = base64.encode(_utf16le(script));
        await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          "Start-Process -FilePath powershell -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand','$enc'",
        ]);
      }
      await _refreshStatus();
      if (!mounted) return;
      setState(() {
        if (!_directOn) {
          _msg =
              'Para ativar, abra Configurações > Segurança, clique em Desbloquear e marque "Habilitar acesso direto por IP".';
        } else if (!_firewallOn) {
          _msg =
              'O Windows não liberou o firewall. Tente de novo e clique em Sim na janela de permissão.';
        } else {
          _msg = 'Conexão local liberada.';
        }
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  bool _isVirtual(String name) {
    final n = name.toLowerCase();
    const marks = [
      'vethernet',
      'vmware',
      'vmnet',
      'virtualbox',
      'vbox',
      'docker',
      'wsl',
      'hyper-v',
      'bluetooth',
      'loopback',
    ];
    return marks.any((m) => n.contains(m));
  }

  Future<void> _loadLocal() async {
    final all = <_LocalAddr>[];
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final i in ifaces) {
        for (final a in i.addresses) {
          all.add(_LocalAddr(i.name, a.address));
        }
      }
    } catch (_) {}
    final real = all.where((e) => !_isVirtual(e.name)).toList();
    if (!mounted) return;
    setState(() => _locals = real.isNotEmpty ? real : all);
  }

  Future<void> _loadPublic() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = '';
    });
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.getUrl(Uri.parse('https://ipinfo.io/json'));
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        throw Exception('HTTP ${res.statusCode}');
      }
      final body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 8));
      final data = jsonDecode(body);
      final ip = (data['ip'] ?? '').toString();
      final org = (data['org'] ?? '')
          .toString()
          .replaceFirst(RegExp(r'^AS\d+\s*'), '');
      if (!mounted) return;
      setState(() {
        _publicIp = ip;
        _provider = org;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Não foi possível consultar. Verifique a internet.';
      });
    } finally {
      client.close(force: true);
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    setState(() => _copied = text);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && _copied == text) {
        setState(() => _copied = '');
      }
    });
  }

  Widget _line(String label, String value, {bool copy = false}) {
    const grey = Colors.grey;
    final shown = value.isEmpty ? '-' : value;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: grey)),
          if (copy && value.isNotEmpty)
            InkWell(
              onTap: () => _copy(value),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(shown,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 6),
                  Icon(_copied == value ? Icons.check : Icons.copy,
                      size: 13, color: grey),
                ],
              ),
            )
          else
            Text(shown,
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  List<Widget> _lanSection() {
    if (!_statusKnown) return [];
    final detail =
        'Acesso direto: ${_directOn ? "ativado" : "desativado"}. Firewall: ${_firewallOn ? "liberado" : "bloqueado"}.';
    return [
      const SizedBox(height: 12),
      const Text('Conexão local',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
      Text(_lanReady ? 'Liberada' : 'Não liberada',
          style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: _lanReady ? Colors.green : _mtechRed)),
      if (!_lanReady)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(detail,
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ),
      if (!_lanReady)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: OutlinedButton(
            onPressed: _busy ? null : _enableLan,
            child: Text(_busy ? 'Aguarde…' : 'Permitir conexão na rede local',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12)),
          ),
        ),
      if (_msg.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(_msg,
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    if (_locals.isEmpty) {
      rows.add(_line('IP local', ''));
    } else {
      for (final l in _locals) {
        rows.add(_line(
            _locals.length > 1 ? 'IP local (${l.name})' : 'IP local', l.ip,
            copy: true));
      }
    }
    return Container(
      margin: const EdgeInsets.only(left: 20, right: 11, top: 14, bottom: 6),
      padding: const EdgeInsets.only(left: 10),
      decoration: const BoxDecoration(
        border: Border(left: BorderSide(color: _mtechRed, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Rede deste computador',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          ...rows,
          _line('IP público', _publicIp, copy: true),
          _line('Provedor de internet', _provider),
          ..._lanSection(),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_error,
                  style: const TextStyle(fontSize: 11, color: _mtechRed)),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _loading
                  ? null
                  : () {
                      _loadLocal();
                      _loadPublic();
                      _refreshStatus();
                    },
              child: Text(_loading ? 'Consultando…' : 'Atualizar'),
            ),
          ),
        ],
      ),
    );
  }
}
