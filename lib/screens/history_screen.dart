import 'dart:convert';

import 'package:flutter/material.dart';
import '../local_storage.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<Map<String, dynamic>> entries = [];

  @override
  void initState() {
    super.initState();
    try {
      final local = getLocalReceipts();
      setState(() => entries = local);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Historikk')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: entries.isEmpty
            ? Center(child: Text('Ingen lagrede kvitteringer', style: Theme.of(context).textTheme.bodyLarge))
            : ListView.separated(
                itemCount: entries.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final e = entries[i];
                  final created = e['createdAt'] ?? e['created_at'] ?? '';
                  final raw = e['raw'] ?? e['raw_json'] ?? {};
                  final title = (raw is Map && raw['merchant'] != null) ? raw['merchant'].toString() : 'Kvittering ${i + 1}';
                  final total = (raw is Map && raw['total'] != null) ? raw['total'].toString() : '';
                  final summary = (raw is Map && raw['summary'] != null) ? raw['summary'].toString() : null;

                  return Card(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    child: ExpansionTile(
                      title: Row(children: [
                        Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600))),
                        if (total != '') Text('$total kr', style: Theme.of(context).textTheme.bodyMedium),
                      ]),
                      subtitle: Text(created.toString()),
                      children: [
                        if (summary != null) Padding(padding: const EdgeInsets.all(12), child: Text(summary)),
                        if (summary == null) Padding(padding: const EdgeInsets.all(12), child: SelectableText(const JsonEncoder.withIndent('  ').convert(raw))),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                            TextButton(onPressed: () {}, child: const Text('Del')),
                            const SizedBox(width: 8),
                            FilledButton(onPressed: () {}, child: const Text('Slett')),
                          ]),
                        )
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }
}
