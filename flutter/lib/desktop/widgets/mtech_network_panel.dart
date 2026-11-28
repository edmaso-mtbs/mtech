import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Painel "Rede deste computador": IP local, IP publico e provedor de internet.
/// O IP local e lido do sistema ao abrir. O IP publico e o provedor so sao
/// consultados quando o usuario clica em "Atualizar".
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

  List<_LocalAddr> _locals = [];
  String _publicIp = '';
  String _provider = '';
  String _error = '';
  bool _loading = false;
  String _copied = '';

  @override
  void initState() {
    super.initState();
    _loadLocal();
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
                    },
              child: Text(_loading ? 'Consultando…' : 'Atualizar'),
            ),
          ),
        ],
      ),
    );
  }
}
