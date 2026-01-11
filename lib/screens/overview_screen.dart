import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../local_storage.dart';

class OverviewScreen extends StatefulWidget {
  const OverviewScreen({super.key});

  @override
  State<OverviewScreen> createState() => _OverviewScreenState();
}

class _OverviewScreenState extends State<OverviewScreen> {
  String range = '1m';
  String category = 'all';
  bool loading = false;
  Map<String, dynamic>? aggregates;
  List<dynamic>? receipts;
  Map<String, double> categorySums = {};

  final String baseUrl = 'https://receipt-ai-backend.onrender.com/receipts';

  final ranges = {
    '1d': '1 dag',
    '1w': '1 uke',
    '1m': '1 måned',
    '6m': '6 måneder',
    '12m': '12 måneder',
  };

  final categories = ['all', 'snus', 'alkohol', 'snacks_godteri', 'frossen_pizza', 'annet'];

  @override
  void initState() {
    super.initState();
    () async {
      try {
        await initLocalStorage();
      } catch (_) {}
      await fetchOverview(detail: true);
      if ((receipts == null || receipts!.isEmpty)) {
        // load local receipts as fallback
        final local = getLocalReceipts();
        if (local.isNotEmpty) {
          setState(() {
            receipts = local;
            aggregates = {'count': local.length, 'total_spent': null, 'total_saved': null};
          });
          _computeCategorySums();
        }
      }
    }();
  }

  Future<void> fetchOverview({bool detail = false}) async {
    setState(() {
      loading = true;
    });
    try {
      final params = <String, String>{'range': range};
      if (category != 'all') params['category'] = category;
      if (detail) params['detail'] = 'true';
      final uri = Uri.parse(baseUrl).replace(queryParameters: params);
      final resp = await http.get(uri).timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        setState(() {
          aggregates = data['aggregates'] ?? data;
          receipts = data['receipts'] ?? [];
        });
        _computeCategorySums();
      } else {
        // ignore: avoid_print
        print('Failed to fetch overview: ${resp.statusCode} ${resp.body}');
      }
    } catch (e) {
      // ignore: avoid_print
      print('Error fetching overview: $e');
    } finally {
      setState(() {
        loading = false;
      });
    }
  }

  void _computeCategorySums() {
    final Map<String, double> sums = {};
    if (receipts != null) {
      for (final r in receipts!) {
        try {
          final raw = r['raw_json'] ?? r['raw'] ?? r;
          final items = raw['items'] as List<dynamic>?;
          if (items != null) {
            for (final it in items) {
              final cat = (it['category'] ?? 'annet').toString();
              final price = (it['price'] is num) ? (it['price'] as num).toDouble() : double.tryParse((it['price'] ?? '0').toString()) ?? 0.0;
              sums[cat] = (sums[cat] ?? 0.0) + price;
            }
          } else {
            // fallback to receipt total
            final catList = (r['categories'] as List<dynamic>?)?.map((e) => e.toString())?.toList() ?? ['annet'];
            final total = (r['total'] is num) ? (r['total'] as num).toDouble() : double.tryParse((r['total'] ?? '0').toString()) ?? 0.0;
            for (final cat in catList) {
              sums[cat] = (sums[cat] ?? 0.0) + total;
            }
          }
        } catch (_) {
          // ignore parse errors per receipt
        }
      }
    }
    setState(() {
      categorySums = sums;
    });
  }

  double get totalSpent {
    if (aggregates != null && aggregates!['total_spent'] != null) {
      final v = aggregates!['total_spent'];
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString()) ?? 0.0;
    }
    double s = 0.0;
    categorySums.forEach((k, v) => s += v);
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Oversikt')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            children: [
              // Top card with donut
              Card(
                elevation: 2,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 160,
                        height: 160,
                        child: CustomPaint(
                          painter: _DonutPainter(),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Totalt',
                                  style: theme.textTheme.labelSmall,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '${totalSpent.toStringAsFixed(0)} kr',
                                  style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 20),
                      // quick stats
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Period: ${ranges[range]}', style: theme.textTheme.bodyLarge),
                            const SizedBox(height: 8),
                            Text('Kvitteringer: ${aggregates?['count'] ?? 0}', style: theme.textTheme.bodyMedium),
                            const SizedBox(height: 4),
                            Text('Spar totalt: ${aggregates?['total_saved'] ?? 0}', style: theme.textTheme.bodyMedium),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Categories header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Kategorier', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  TextButton(
                    onPressed: () => fetchOverview(detail: true),
                    child: const Text('Oppdater'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Category list
              Expanded(
                child: categorySums.isEmpty
                    ? Center(child: Text(loading ? 'Laster...' : 'Ingen kvitteringer funnet', style: theme.textTheme.bodyMedium))
                    : GridView.count(
                        crossAxisCount: 2,
                        childAspectRatio: 3,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                        children: categorySums.entries.map((e) {
                          return Container(
                            decoration: BoxDecoration(
                              color: Colors.grey.shade50,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            child: Row(
                              children: [
                                Container(
                                  width: 10,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(colors: [Colors.blue.shade400, Colors.purple.shade400]),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(e.key, style: const TextStyle(fontWeight: FontWeight.w600)),
                                      const SizedBox(height: 4),
                                      Text('${e.value.toStringAsFixed(0)} kr', style: theme.textTheme.bodySmall),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width / 2) - 6;
    final basePaint = Paint()
      ..color = Colors.grey.shade200
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, basePaint);

    final progPaint = Paint()
      ..shader = const LinearGradient(colors: [Color(0xFF4F46E5), Color(0xFF06B6D4)]).createShader(Rect.fromCircle(center: center, radius: radius))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;

    // For now show 100% arc (design focus). Could be adapted to budget.
    final sweep = 2 * 3.1415926535 * 0.85; // 85% filled visually
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), -3.14159 / 2, sweep, false, progPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
