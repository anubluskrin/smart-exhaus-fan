import 'dart:convert';

import 'package:flutter/material.dart';

import 'api_http.dart' as http;
import 'constants.dart';

class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key});

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _comment = TextEditingController();

  int _rating = 5;
  bool _busy = false;
  String? _statusMsg;
  bool _statusOk = false;
  String _lastOrigin = originOf(kBaseUrl);

  @override
  void initState() {
    super.initState();
    sessionNotifier.addListener(_onSessionChange);
  }

  @override
  void dispose() {
    sessionNotifier.removeListener(_onSessionChange);
    _name.dispose();
    _comment.dispose();
    super.dispose();
  }

  void _onSessionChange() {
    final nextOrigin = originOf(kBaseUrl);
    if (nextOrigin != _lastOrigin && mounted) {
      setState(() {
        _lastOrigin = nextOrigin;
        _statusMsg = null;
      });
    } else if (mounted) {
      setState(() {});
    }
  }

  int? _extractRetryAfterSec(http.Response res) {
    final header = res.headers['retry-after'];
    if (header != null) {
      final n = int.tryParse(header.trim());
      if (n != null && n > 0) return n;
    }
    try {
      final m = jsonDecode(res.body);
      if (m is Map<String, dynamic> && m['retry_after_sec'] is num) {
        return (m['retry_after_sec'] as num).toInt();
      }
    } catch (_) {}
    return null;
  }

  String _extractError(http.Response res) {
    try {
      final m = jsonDecode(res.body);
      if (m is Map<String, dynamic> && m['error'] is String) {
        return m['error'] as String;
      }
    } catch (_) {}
    return 'Gagal mengirim masukan (HTTP ${res.statusCode})';
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (kBaseUrl.isEmpty) {
      setState(() {
        _statusOk = false;
        _statusMsg = 'Alamat server belum diatur di tab Pengaturan.';
      });
      return;
    }

    final comment = _comment.text.trim();
    if (comment.isEmpty) {
      setState(() {
        _statusOk = false;
        _statusMsg = 'Komentar wajib diisi.';
      });
      return;
    }

    final epoch = kSessionEpoch;
    final targetOrigin = originOf(kBaseUrl);
    final name = _name.text.trim();

    setState(() {
      _busy = true;
      _statusMsg = null;
    });

    try {
      final uri = Uri.parse('$kBaseUrl/api/feedback');
      final headers = {'Content-Type': 'application/json'};
      final body = jsonEncode({
        if (name.isNotEmpty) 'name': name,
        'rating': _rating,
        'comment': comment,
      });

      final res = await (isAdminSession
              ? http.postAdmin(uri, headers: headers, body: body)
              : http.postPublic(uri, headers: headers, body: body))
          .timeout(const Duration(seconds: 8));

      if (!mounted || kSessionEpoch != epoch || originOf(kBaseUrl) != targetOrigin) {
        return;
      }

      if (res.statusCode == 201) {
        _name.clear();
        _comment.clear();
        setState(() {
          _rating = 5;
          _statusOk = true;
          _statusMsg = 'Terima kasih! Masukan Anda sudah terkirim.';
        });
        return;
      }

      if (res.statusCode == 429) {
        final waitSec = _extractRetryAfterSec(res);
        setState(() {
          _statusOk = false;
          _statusMsg = waitSec != null
              ? 'Terlalu banyak kiriman. Coba lagi dalam $waitSec detik.'
              : 'Terlalu banyak kiriman. Coba lagi beberapa saat.';
        });
        return;
      }

      if (res.statusCode == 401) {
        setState(() {
          _statusOk = false;
          _statusMsg = 'Masukan hanya dibuka untuk Admin pada server ini.';
        });
        return;
      }

      setState(() {
        _statusOk = false;
        _statusMsg = _extractError(res);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _statusOk = false;
        _statusMsg = 'Gagal menghubungi server. Periksa koneksi Anda.';
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          children: [
            const Text(
              'Masukan Pengunjung',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              'Bagikan penilaian atau saran Anda setelah melihat demo alat.',
              style: TextStyle(fontSize: 13, color: kMuted),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: kLine),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF15325C), Color(0xFF0F2646)],
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Penilaian', style: TextStyle(fontSize: 14, color: kMuted)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (int i = 1; i <= 5; i++)
                        IconButton(
                          key: Key('feedback_star_$i'),
                          onPressed: _busy ? null : () => setState(() => _rating = i),
                          icon: Icon(
                            i <= _rating ? Icons.star : Icons.star_border,
                            color: i <= _rating ? const Color(0xFFFACC15) : kMuted,
                            size: 30,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('feedback_name'),
                    controller: _name,
                    maxLength: 40,
                    enabled: !_busy,
                    decoration: InputDecoration(
                      labelText: 'Nama (opsional)',
                      filled: true,
                      fillColor: kCard,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: kLine),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    key: const Key('feedback_comment'),
                    controller: _comment,
                    maxLength: 500,
                    maxLines: 4,
                    enabled: !_busy,
                    decoration: InputDecoration(
                      labelText: 'Komentar / saran',
                      alignLabelWithHint: true,
                      filled: true,
                      fillColor: kCard,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: kLine),
                      ),
                    ),
                  ),
                  if (_statusMsg != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _statusMsg!,
                      style: TextStyle(
                        fontSize: 13,
                        color: _statusOk ? const Color(0xFF4ADE80) : const Color(0xFFF87171),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton(
                    key: const Key('feedback_submit'),
                    onPressed: _busy ? null : _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: kAccent,
                      foregroundColor: const Color(0xFF08213F),
                      minimumSize: const Size.fromHeight(50),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: Text(
                      _busy ? 'Mengirim...' : 'Kirim masukan',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
