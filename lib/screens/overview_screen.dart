import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

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
    fetchOverview();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Oversikt')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: range,
                    items: ranges.keys
                        .map((k) => DropdownMenuItem(value: k, child: Text(ranges[k]!)))
                        .toList(),
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => range = v);
                      fetchOverview();
                    },
                    decoration: const InputDecoration(labelText: 'Tidsperiode'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: category,
                    items: categories
                        .map((c) => DropdownMenuItem(value: c, child: Text(c == 'all' ? 'Alle' : c)))
                        .toList(),
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => category = v);
                      fetchOverview();
                    },
                    decoration: const InputDecoration(labelText: 'Kategori'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (loading) const LinearProgressIndicator(),
            const SizedBox(height: 8),
            if (aggregates != null) ...[
              Text('Kvitteringer: ${aggregates!['count'] ?? 0}'),
              const SizedBox(height: 8),
              Text('Totalt brukt: ${aggregates!['total_spent'] ?? 0}'),
              const SizedBox(height: 4),
              Text('Totalt spart: ${aggregates!['total_saved'] ?? 0}'),
              const SizedBox(height: 12),
            ],
            ElevatedButton(
              onPressed: () => fetchOverview(detail: true),
              child: const Text('Hent detaljer'),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: receipts == null
                  ? const Center(child: Text('Ingen data'))
                  : ListView.builder(
                      itemCount: receipts!.length,
                      itemBuilder: (context, i) {
                        final r = receipts![i];
                        final created = r['created_at'] ?? r['createdAt'] ?? '';
                        final total = r['total'] ?? r['raw_json']?['total'] ?? '';
                        final saved = r['saved_amount'] ?? r['raw_json']?['saved'] ?? '';
                        final cats = (r['categories'] ?? []).join(', ');
                        return Card(
                          child: ListTile(
                            title: Text('Total: $total  •  Spar: $saved'),
                            subtitle: Text('Kategorier: $cats\n$created'),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
