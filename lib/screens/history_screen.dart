import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../local_storage.dart';
import '../services/receipt_db.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<Map<String, dynamic>> entries = [];
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _loadEntries();
  }

  Future<void> _loadEntries() async {
    try {
      try {
        await ReceiptDb.init();
        final local = await ReceiptDb.getAllReceipts();
        setState(() => entries = local);
      } catch (_) {
        await initLocalStorage();
        final local = await getLocalReceipts();
        setState(() => entries = local);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Historikk'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(_changed),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: entries.isEmpty
            ? Center(child: Text('Ingen lagrede kvitteringer', style: Theme.of(context).textTheme.bodyLarge))
            : ListView.separated(
                itemCount: entries.length,
                separatorBuilder: (context, index) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final e = entries[i];
                  final created = e['createdAt'] ?? e['created_at'] ?? '';
                    // Support both formats:
                    // - legacy: parsed result stored directly (top-level keys like 'items', 'total')
                    // - wrapped: parsed result stored under 'raw' or 'raw_json'
                      final rawCandidate = e['raw'] ?? e['raw_json'];
                      final raw = (rawCandidate is Map) ? rawCandidate : e;
                  final title = (raw['merchant'] != null) ? raw['merchant'].toString() : 'Kvittering ${i + 1}';
                  final total = (raw['total'] != null) ? raw['total'].toString() : '';
                  final summary = (raw['summary'] != null) ? raw['summary'].toString() : null;

                  final items = (raw['items'] is List) ? List.from(raw['items'] as List) : null;

                  return Card(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    child: ExpansionTile(
                      title: Row(children: [
                        Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600))),
                        if (total != '') Text('$total kr', style: Theme.of(context).textTheme.bodyMedium),
                      ]),
                      subtitle: Text(created.toString()),
                      children: [
                        if (items != null && items.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: items.map<Widget>((it) {
                                final Map item = (it is Map) ? it : {'name': it.toString()};
                                final name = (item['name'] ?? '').toString();

                                // price (line total)
                                final rawPrice = item['price'];
                                final price = rawPrice != null ? (double.tryParse(rawPrice.toString()) ?? 0.0) : 0.0;
                                final priceStr = price.toStringAsFixed(2);

                                // quantity & unit price
                                final qtyRaw = item['quantity'];
                                final qty = qtyRaw != null ? (int.tryParse(qtyRaw.toString()) ?? 1) : 1;
                                final rawUnit = item['unit_price'];
                                final unit = rawUnit != null ? (double.tryParse(rawUnit.toString()) ?? 0.0) : 0.0;

                                // discount (saved on this line)
                                final rawDisc = item['discount'];
                                final disc = rawDisc != null ? (double.tryParse(rawDisc.toString()) ?? 0.0) : 0.0;

                                // Build subtitle parts
                                final parts = <String>[];
                                if (qty > 1) parts.add('Antall: $qty');
                                if (unit > 0) parts.add('Stykkpris: ${unit.toStringAsFixed(2)} kr');
                                if (disc > 0) parts.add('Rabatt: ${disc.toStringAsFixed(2)} kr');

                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 6),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(child: Text(name, style: const TextStyle(fontWeight: FontWeight.w600))),
                                          Text('${priceStr} kr', style: Theme.of(context).textTheme.bodyMedium),
                                        ],
                                      ),
                                      if (parts.isNotEmpty)
                                        Padding(
                                          padding: const EdgeInsets.only(top: 4),
                                          child: Text(parts.join(' • '), style: Theme.of(context).textTheme.bodySmall),
                                        ),
                                    ],
                                  ),
                                );
                              }).toList(),
                            ),
                          )
                        else if (summary != null)
                          Padding(padding: const EdgeInsets.all(12), child: Text(summary))
                        else
                          Padding(padding: const EdgeInsets.all(12), child: SelectableText(const JsonEncoder.withIndent('  ').convert(raw))),

                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                            TextButton(
                                onPressed: () {}, child: const Text('Del')),
                            const SizedBox(width: 8),
                            FilledButton(
                                onPressed: () async {
                              // capture navigator early to avoid using BuildContext after async gaps
                              final navigator = Navigator.of(context);

                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('Bekreft sletting'),
                                  content: const Text('Er du sikker på at du vil slette denne kvitteringen?'),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Avbryt')),
                                    FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Slett')),
                                  ],
                                ),
                              );
                              if (confirm != true) return;

                              // Remove from local UI list
                              setState(() {
                                entries.removeAt(i);
                                _changed = true;
                              });

                              // Attempt best-effort backend delete if an `id` exists
                              try {
                                final id = e['id'] ?? e['row']?['id'];
                                if (id != null) {
                                  final url = Uri.parse('https://receipt-ai-backend.onrender.com/receipts/$id');
                                  await http.delete(url).timeout(const Duration(seconds: 8));
                                }
                              } catch (_) {}

                              // Try best-effort to delete any local image path referenced
                              try {
                                final img = (e['imagePath'] ?? e['image'] ?? e['localPath'])?.toString();
                                if (img != null && img.isNotEmpty) {
                                  final f = File(img);
                                  if (await f.exists()) await f.delete();
                                }
                              } catch (_) {}

                              // Persist deletion to local storage when possible
                                try {
                                final localId = (e['local_id'] ?? e['localId'] ?? e['local-id'])?.toString();
                                if (localId != null && localId.isNotEmpty) {
                                  try {
                                    await ReceiptDb.deleteByLocalId(localId);
                                  } catch (_) {
                                    await deleteLocalReceiptByLocalId(localId);
                                  }
                                }
                              } catch (_) {}

                              // Close history and notify Overview to refresh immediately
                              if (!mounted) return;
                              navigator.pop(true);
                            }, child: const Text('Slett')),
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
