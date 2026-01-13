import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../local_storage.dart';
import '../services/receipt_db.dart';
import 'history_screen.dart';
import 'add_receipt_screen.dart';

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
  List<String> visibleCategories = [];

  final String baseUrl = 'https://receipt-ai-backend.onrender.com/receipts';

  final ranges = {
    '1d': '1 dag',
    '1w': '1 uke',
    '1m': '1 måned',
    '6m': '6 måneder',
    '12m': '12 måneder',
  };

  // Canonical English category keys (display labels below)
  final categories = [
    'all',
    'other_grocery',
    'meat',
    'frozen_pizza',
    'dairy',
    'bakery',
    'energy_drink',
    'household',
    'alcohol',
    'snus',
    'snacks',
    'produce',
    'soda',
  ];

  // Friendly Norwegian labels for display
  final Map<String, String> categoryLabels = {
    'all': 'Alle',
    'other_grocery': 'Annen dagligvare',
    'meat': 'Kjøtt',
      'frozen_pizza': 'Frossen pizza',
    'dairy': 'Meieri',
    'bakery': 'Bakeverk',
    'energy_drink': 'Energidrikke',
    'household': 'Husholdningsvarer',
    'alcohol': 'Alkohol',
    'snus': 'Snus',
    'snacks': 'Snacks & godteri',
    'produce': 'Frukt & grønt',
    'soda': 'Brus',
  };

  // Map incoming category names (from AI/server or legacy) to canonical keys
  String _mapToCanonicalCategory(Object? rawCat) {
    if (rawCat == null) return 'other_grocery';
    final s = rawCat.toString().toLowerCase();

    // Direct canonical match
    final canonicalKeys = [
      'alcohol', 'snus', 'snacks', 'frozen_pizza', 'other_grocery', 'meat', 'dairy', 'bakery', 'energy_drink', 'household', 'produce', 'soda'
    ];
    if (canonicalKeys.contains(s)) return s;

    // Keyword-based mapping (handles Norwegian variants and small misspellings)
    if (s.contains('alkohol') || s.contains('alcohol')) return 'alcohol';
    if (s.contains('snus')) return 'snus';
    if (s.contains('snacks') || s.contains('godteri') || s.contains('sjokolade') || s.contains('chips')) return 'snacks';
    if (s.contains('frossen') || s.contains('frossen pizza') || s.contains('frozen') || s.contains('pizza')) return 'frozen_pizza';
    if (s.contains('drikke') && (s.contains('energi') || s.contains('energy') || s.contains('red bull') || s.contains('monster'))) return 'energy_drink';
    if (s.contains('drikke') || s.contains('brus') || s.contains('cola') || s.contains('juice') || s.contains('soda')) return 'soda';
    if (s.contains('kjøtt') || s.contains('biff') || s.contains('kylling') || s.contains('fisk') || s.contains('laks')) return 'meat';
    if (s.contains('meieri') || s.contains('melk') || s.contains('ost') || s.contains('yoghurt') || s.contains('fløte')) return 'dairy';
    if (s.contains('brød') || s.contains('boller') || s.contains('bakverk') || s.contains('bake')) return 'bakery';
    if (s.contains('hushold') || s.contains('såpe') || s.contains('tørkepapir') || s.contains('oppvask')) return 'household';
    if (s.contains('frukt') || s.contains('grønt') || s.contains('eple') || s.contains('banan') || s.contains('potet') || s.contains('gulrot')) return 'produce';
    if (s.contains('annet') || s.contains('other') || s.trim().isEmpty) return 'other_grocery';

    // As a last resort, try substring match against canonical keys
    for (final k in canonicalKeys) {
      if (s.contains(k)) return k;
    }

    return 'other_grocery';
  }

  // If item category is missing, use name heuristics to guess category
  String _mapNameToCategory(String? name) {
    if (name == null) return 'other_grocery';
    final s = name.toLowerCase();
    // Normalize some punctuation and remove weight markers that can confuse matching
    final norm = s.replaceAll(RegExp(r'[,\(\)\-]'), ' ');
    // produce keywords
    final produceKeywords = ['eple', 'pære', 'banan', 'potet', 'poteter', 'gulrot', 'paprika', 'tomat', 'agurk', 'salat', 'pear', 'apple', 'hvitløk'];
    for (final k in produceKeywords) {
      if (norm.contains(k)) return 'produce';
    }
    // meat
    final meatKeywords = ['kylling', 'svin', 'storfe', 'biff', 'laks', 'fisk', 'meat', 'chicken', 'salami'];
    for (final k in meatKeywords) {
      if (s.contains(k)) return 'meat';
    }
    // dairy
    final dairyKeywords = ['melk', 'ost', 'fløte', 'yoghurt', 'meieri', 'margarin'];
    for (final k in dairyKeywords) {
      if (s.contains(k)) return 'dairy';
    }
    // bakery
    final bakeryKeywords = ['brød', 'baguette', 'boller', 'bakst', 'bakervarer', 'croissant'];
    for (final k in bakeryKeywords) {
      if (s.contains(k)) return 'bakery';
    }
    // snacks
    final snacksKeywords = ['chips', 'godteri', 'sjokolade', 'snacks', 'kjeks', 'kake'];
    for (final k in snacksKeywords) {
      if (s.contains(k)) return 'snacks';
    }
    // soda / beverages
    final sodaKeywords = ['brus', 'cola', 'fanta', 'sprite', 'drikke', 'soda', 'juice'];
    for (final k in sodaKeywords) {
      if (norm.contains(k)) return 'soda';
    }
    // alcohol
    final alcoholKeywords = ['øl', 'vin', 'vodka', 'whisky', 'akvavit', 'beer', 'wine'];
    for (final k in alcoholKeywords) {
      if (norm.contains(k)) return 'alcohol';
    }
    // energy drink
    final energyKeywords = ['energy', 'energi', 'red bull', 'monster'];
    for (final k in energyKeywords) {
      if (s.contains(k)) return 'energy_drink';
    }
    // household
    final householdKeywords = ['tørkepapir', 'såpe', 'oppvask', 'husholdning', 'clean', 'ren'];
    for (final k in householdKeywords) {
      if (s.contains(k)) return 'household';
    }

    return 'other_grocery';
  }

  @override
  void initState() {
    super.initState();
    () async {
      try {
        await initLocalStorage();
      } catch (_) {}
      try {
        final prefs = await getVisibleCategories();
        if (prefs.isNotEmpty) {
          visibleCategories = prefs;
        } else {
          visibleCategories = categories.where((k) => k != 'all').toList();
        }
      } catch (_) {
        visibleCategories = categories.where((k) => k != 'all').toList();
      }
      await fetchOverview(detail: true);
      if ((receipts == null || receipts!.isEmpty)) {
        // Try SQLite DB first (new flow), then fallback to file-based local storage
        try {
          await ReceiptDb.init();
          final dbLocal = await ReceiptDb.getAllReceipts();
          if (dbLocal.isNotEmpty) {
            setState(() {
              receipts = dbLocal;
              aggregates = {'count': dbLocal.length, 'total_spent': null, 'total_saved': null};
            });
            _computeCategorySums();
          } else {
            final local = await getLocalReceipts();
            if (local.isNotEmpty) {
              setState(() {
                receipts = local;
                aggregates = {'count': local.length, 'total_spent': null, 'total_saved': null};
              });
              _computeCategorySums();
            }
          }
        } catch (_) {
          final local = await getLocalReceipts();
          if (local.isNotEmpty) {
            setState(() {
              receipts = local;
              aggregates = {'count': local.length, 'total_spent': null, 'total_saved': null};
            });
            _computeCategorySums();
          }
        }
      }
    }();
  }

  Future<void> _reconcileWithServer() async {
    // Compute local receipts + aggregates
    List<Map<String, dynamic>> local = [];
    try {
      await ReceiptDb.init();
      final dbLocal = await ReceiptDb.getAllReceipts();
      if (dbLocal.isNotEmpty) local = dbLocal;
    } catch (_) {
      try {
        final fileLocal = await getLocalReceipts();
        if (fileLocal.isNotEmpty) local = fileLocal;
      } catch (_) {}
    }

    final localCount = local.length;
    double localTotal = 0.0;
    double localSaved = 0.0;
    for (final r in local) {
      try {
        final raw = r['raw_json'] ?? r['raw'] ?? r;
        if (raw is Map && raw['items'] is List) {
          for (final it in raw['items']) {
            final p = (it is Map && it['price'] != null) ? it['price'] : 0;
            if (p is num) localTotal += p.toDouble();
            else {
              final s = p?.toString() ?? '';
              final m = RegExp(r'[0-9]+(?:[.,][0-9]{1,2})?').firstMatch(s);
              if (m != null) localTotal += double.tryParse(m.group(0)!.replaceAll(',', '.')) ?? 0.0;
            }
          }
        } else {
          final t = (r['total'] is num) ? (r['total'] as num).toDouble() : double.tryParse((r['total'] ?? '0').toString()) ?? 0.0;
          localTotal += t;
        }
        localSaved += (r['saved_amount'] is num) ? (r['saved_amount'] as num).toDouble() : double.tryParse((r['saved_amount'] ?? '0').toString()) ?? 0.0;
      } catch (_) {}
    }

    // Fetch server aggregates
    Map<String, dynamic>? serverAgg;
    List<dynamic> serverReceipts = [];
    try {
      final uri = Uri.parse(baseUrl).replace(queryParameters: {'range': range, 'detail': 'true'});
      final resp = await http.get(uri).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        serverAgg = (data['aggregates'] ?? data) as Map<String, dynamic>?;
        serverReceipts = data['receipts'] ?? [];
      }
    } catch (_) {}

    final serverCount = (serverAgg != null && serverAgg['count'] != null) ? (serverAgg['count'] is num ? (serverAgg['count'] as num).toInt() : int.tryParse(serverAgg['count'].toString()) ?? 0) : serverReceipts.length;
    final serverTotal = (serverAgg != null && serverAgg['total_spent'] != null) ? double.tryParse(serverAgg['total_spent'].toString()) ?? 0.0 : 0.0;

    if (serverCount == localCount && (serverTotal - localTotal).abs() < 0.01) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Historikk og oversikt stemmer overens')));
      return;
    }

    if (!mounted) return;
    // Show dialog with differences and action to sync
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Avvik funnet'),
          content: SingleChildScrollView(
            child: ListBody(children: [
              Text('Lokalt: $localCount kvitteringer, totalt ${localTotal.toStringAsFixed(2)} kr'),
              Text('Server: $serverCount kvitteringer, totalt ${serverTotal.toStringAsFixed(2)} kr'),
              const SizedBox(height: 8),
              const Text('Vil du synkronisere lokale kvitteringer til serveren? (Dette vil poste lokale kvitteringer uten server-id)'),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Avbryt')),
            FilledButton(onPressed: () async {
              Navigator.of(ctx).pop();
              // Post any local receipts that don't have an `id` field
              int posted = 0;
              for (final r in local) {
                try {
                  final envelope = r;
                  final hasServerId = envelope['id'] != null || envelope['server_id'] != null;
                  if (hasServerId) continue;
                  final raw = envelope['raw'] ?? envelope;
                  final resp = await http.post(Uri.parse(baseUrl), headers: {'Content-Type': 'application/json'}, body: jsonEncode(raw)).timeout(const Duration(seconds: 10));
                  if (resp.statusCode >= 200 && resp.statusCode < 300) posted++;
                } catch (_) {}
              }
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Synkronisert $posted kvitteringer til serveren')));
              await fetchOverview(detail: true);
            }, child: const Text('Synkroniser')),
            const SizedBox(width: 6),
            FilledButton(onPressed: () async {
              Navigator.of(ctx).pop();
              // Refresh overview computed from local history
              await fetchOverview(detail: true);
            }, child: const Text('Oppdater oversikt')),
          ],
        );
      },
    );
  }

  Future<void> fetchOverview({bool detail = false}) async {
    setState(() {
      loading = true;
    });
    try {
      // Prefer local receipts (SQLite DB then file-based) so Overview always reflects history.
      try {
        await ReceiptDb.init();
        final dbLocal = await ReceiptDb.getAllReceipts();
        if (dbLocal.isNotEmpty) {
          setState(() {
            receipts = dbLocal;
            aggregates = {'count': dbLocal.length, 'total_spent': null, 'total_saved': null};
          });
          _computeCategorySums();
          return;
        }
      } catch (_) {}

      try {
        final local = await getLocalReceipts();
        if (local.isNotEmpty) {
          setState(() {
            receipts = local;
            aggregates = {'count': local.length, 'total_spent': null, 'total_saved': null};
          });
          _computeCategorySums();
          return;
        }
      } catch (_) {}

      // No local receipts available, fallback to server-provided aggregates/receipts
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

        // If server says there are zero receipts in this period, normalize all totals to 0
        final intCount = (aggregates != null && aggregates!['count'] != null)
            ? (aggregates!['count'] is num ? (aggregates!['count'] as num).toInt() : int.tryParse(aggregates!['count'].toString()) ?? 0)
            : (receipts != null ? receipts!.length : 0);
        if (intCount == 0) {
          setState(() {
            aggregates = {'count': 0, 'total_spent': 0.0, 'total_saved': 0.0};
            // initialize categorySums to zero for all known categories
            final Map<String, double> sums = {};
            for (final k in categories) {
              if (k == 'all') continue;
              sums[k] = 0.0;
            }
            categorySums = sums;
            receipts = [];
          });
        } else {
          _computeCategorySums();
        }
      } else {
        // Log outcome (avoid printing potentially large/secret body)
        // ignore: avoid_print
        print('Failed to fetch overview: ${resp.statusCode}');
        if (resp.statusCode == 503) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Server utilgjengelig (Database ikke konfigurert). Viser lokale kvitteringer.')));
        }
      }
    } catch (e) {
      // ignore: avoid_print
      print('Error fetching overview: $e');
    } finally {
      // Ensure empty-state is normalized: when there are no receipts, show zeros
      if (receipts == null || receipts!.isEmpty) {
        final zeroAgg = {'count': 0, 'total_spent': 0.0, 'total_saved': 0.0};
        setState(() {
          aggregates = aggregates ?? zeroAgg;
          // initialize categorySums to zero for all known categories
          final Map<String, double> sums = {};
          for (final k in categories) {
            if (k == 'all') continue;
            sums[k] = 0.0;
          }
          categorySums = sums;
          loading = false;
        });
      } else {
        setState(() {
          loading = false;
        });
      }
    }
  }

  void _computeCategorySums() {
    final Map<String, double> sums = {};
    // Ensure all known categories are present (show zero when no data)
    for (final k in categories) {
      if (k == 'all') continue;
      sums[k] = 0.0;
    }
    if (receipts != null) {
      for (final r in receipts!) {
        try {
          final raw = r['raw_json'] ?? r['raw'] ?? r;
          final items = raw['items'] as List<dynamic>?;
          if (items != null) {
            for (final it in items) {
                try {
                  final origCatRaw = it['category'];
                String catKey;
                final name = (it['name'] ?? it['description'] ?? '').toString();
                if (origCatRaw != null && origCatRaw.toString().trim().isNotEmpty) {
                  catKey = _mapToCanonicalCategory(origCatRaw);
                } else {
                  catKey = _mapNameToCategory(name);
                }
                double parsePrice(dynamic p) {
                  try {
                    if (p is num) return p.toDouble();
                    final s = (p ?? '').toString();
                    // Find first number-like substring (supports comma or dot decimals)
                    final m = RegExp(r'[0-9]+(?:[.,][0-9]{1,2})?').firstMatch(s);
                    if (m != null) {
                      final numStr = m.group(0)!.replaceAll(',', '.');
                      return double.tryParse(numStr) ?? 0.0;
                    }
                  } catch (_) {}
                  return 0.0;
                }

                final price = parsePrice(it['price']);
                sums[catKey] = (sums[catKey] ?? 0.0) + price;
              } catch (_) {}
            }
          } else {
            // fallback to receipt total and top-level categories
            final catList = (r['categories'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? ['annet'];
            final total = (r['total'] is num)
                ? (r['total'] as num).toDouble()
                : double.tryParse((r['total'] ?? '0').toString()) ?? 0.0;
            for (final cat in catList) {
              final key = _mapToCanonicalCategory(cat);
              sums[key] = (sums[key] ?? 0.0) + total;
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
    // Always compute total from local receipts/category sums so Overview reflects history.
    double s = 0.0;
    try {
      // Prefer categorySums (already computed from receipts)
      categorySums.forEach((k, v) => s += v);
      return s;
    } catch (_) {
      return 0.0;
    }
  }

  // Compute a simple health score (1-100) based on categories found in receipts.
  // This is purely client-side UI logic for display; it doesn't change backend.
  int computeReceiptHealth(Map<String, dynamic> raw) {
    // base score
    double score = 100.0;
    try {
      final cats = <String>[];
      if (raw['categories'] != null && raw['categories'] is List) {
        cats.addAll((raw['categories'] as List).map((e) => e.toString()));
      }
      // also try items categories
      if (raw['items'] != null && raw['items'] is List) {
        for (final it in raw['items']) {
          try {
            if (it['category'] != null) cats.add(it['category'].toString());
          } catch (_) {}
        }
      }

      // penalties
      for (final c in cats) {
        final lc = c.toLowerCase();
        if (lc.contains('alkohol')) score -= 20;
        if (lc.contains('snus')) score -= 25;
        if (lc.contains('snacks') || lc.contains('godteri')) score -= 15;
        if (lc.contains('frossen') || lc.contains('pizza')) score -= 10;
      }
    } catch (_) {}
    if (score < 1) score = 1;
    if (score > 100) score = 100;
    return score.toInt();
  }

  int computeOverallHealth() {
    if (receipts == null || receipts!.isEmpty) return 100;
    int sum = 0;
    int count = 0;
    for (final r in receipts!) {
      try {
        final raw = r['raw_json'] ?? r['raw'] ?? r;
        final h = computeReceiptHealth(Map<String, dynamic>.from(raw as Map));
        sum += h;
        count += 1;
      } catch (_) {}
    }
    if (count == 0) return 100;
    return (sum / count).round();
  }

  void _showPeriodSelector() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: ranges.keys.map((k) {
              return ListTile(
                title: Text(ranges[k] ?? k),
                onTap: () {
                  setState(() {
                    range = k;
                  });
                  Navigator.of(ctx).pop();
                  fetchOverview(detail: true);
                },
              );
            }).toList(),
          ),
        );
      },
    );
  }

  void _showCategorySelector() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        final Set<String> selected = visibleCategories.toSet();
        return StatefulBuilder(builder: (c, set) {
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Vis kategorier', style: TextStyle(fontWeight: FontWeight.w700)),
                      TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Lukk')),
                    ],
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: categories.where((k) => k != 'all').map((key) {
                      return CheckboxListTile(
                        title: Text(categoryLabels[key] ?? key),
                        value: selected.contains(key),
                        onChanged: (v) {
                          set(() {
                            if (v == true) {
                              selected.add(key);
                            } else {
                              selected.remove(key);
                            }
                          });
                        },
                      );
                    }).toList(),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Avbryt')),
                      const SizedBox(width: 8),
                      FilledButton(onPressed: () async {
                        final list = selected.toList();
                        try {
                          await setVisibleCategories(list);
                        } catch (_) {}
                        if (!mounted) return;
                        setState(() {
                          visibleCategories = list;
                        });
                        Navigator.of(context).pop();
                      }, child: const Text('Lagre')),
                    ],
                  ),
                )
              ],
            ),
          );
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isNarrow = MediaQuery.of(context).size.width < 420;
    return Scaffold(
      appBar: AppBar(title: const Text('Oversikt'), actions: [
        IconButton(
          tooltip: 'Historikk',
          icon: const Icon(Icons.history),
          onPressed: () async {
            final changed = await Navigator.push<bool?>(context, MaterialPageRoute(builder: (_) => const HistoryScreen()));
            if (changed == true) fetchOverview(detail: true);
          },
        ),
        IconButton(
          tooltip: 'Synkroniser / Sjekk',
          icon: const Icon(Icons.sync),
          onPressed: _reconcileWithServer,
        ),
        IconButton(
          tooltip: 'Velg kategorier',
          icon: const Icon(Icons.filter_list),
          onPressed: _showCategorySelector,
        ),
      ]),
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
                  child: isNarrow
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
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
                                      Text('Totalt', style: theme.textTheme.labelSmall),
                                      const SizedBox(height: 6),
                                      Text('${totalSpent.toStringAsFixed(0)} kr',
                                          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  const Text('Periode:', style: TextStyle(fontWeight: FontWeight.w600)),
                                  const SizedBox(width: 8),
                                  TextButton(
                                    onPressed: _showPeriodSelector,
                                    child: Text(ranges[range] ?? range),
                                  ),
                                ]),
                                const SizedBox(height: 8),
                                Text('Kvitteringer: ${aggregates?['count'] ?? 0}', style: theme.textTheme.bodyMedium),
                                const SizedBox(height: 4),
                                Text('Spar totalt: ${aggregates?['total_saved'] ?? 0}', style: theme.textTheme.bodyMedium),
                                const SizedBox(height: 12),
                                Row(children: [
                                  const Text('Sunnhet:', style: TextStyle(fontWeight: FontWeight.w600)),
                                  const SizedBox(width: 8),
                                  _HealthCircle(score: computeOverallHealth()),
                                ]),
                              ],
                            ),
                          ],
                        )
                      : Row(
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
                                      Text('Totalt', style: theme.textTheme.labelSmall),
                                      const SizedBox(height: 6),
                                      Text('${totalSpent.toStringAsFixed(0)} kr',
                                          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
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
                                  Row(children: [
                                    const Text('Periode:', style: TextStyle(fontWeight: FontWeight.w600)),
                                    const SizedBox(width: 8),
                                    TextButton(
                                      onPressed: _showPeriodSelector,
                                      child: Text(ranges[range] ?? range),
                                    ),
                                  ]),
                                  const SizedBox(height: 8),
                                  Text('Kvitteringer: ${aggregates?['count'] ?? 0}', style: theme.textTheme.bodyMedium),
                                  const SizedBox(height: 4),
                                  Text('Spar totalt: ${aggregates?['total_saved'] ?? 0}', style: theme.textTheme.bodyMedium),
                                  const SizedBox(height: 12),
                                  Row(children: [
                                    const Text('Sunnhet:', style: TextStyle(fontWeight: FontWeight.w600)),
                                    const SizedBox(width: 8),
                                    _HealthCircle(score: computeOverallHealth()),
                                  ]),
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
                child: (categorySums.isEmpty)
                    ? Center(child: Text(loading ? 'Laster...' : 'Ingen kvitteringer funnet', style: theme.textTheme.bodyMedium))
                    : GridView.count(
                        crossAxisCount: 2,
                        childAspectRatio: 3,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                      children: (visibleCategories.isNotEmpty ? visibleCategories : categories.where((k) => k != 'all')).where((k) => k != 'all').map((key) {
                          final val = categorySums[key] ?? 0.0;
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
                                      Text(
                                        categoryLabels[key] ?? key,
                                        style: const TextStyle(fontWeight: FontWeight.w600),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 4),
                                      Text('${val.toStringAsFixed(0)} kr', style: theme.textTheme.bodySmall),
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
      floatingActionButton: FloatingActionButton(
        tooltip: 'Legg til kvittering',
        onPressed: () async {
          final added = await Navigator.push<bool?>(context, MaterialPageRoute(builder: (_) => const AddReceiptScreen()));
          if (added == true) fetchOverview(detail: true);
        },
        child: const Icon(Icons.camera_alt),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
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

class _HealthCircle extends StatelessWidget {
  final int score; // 1-100
  const _HealthCircle({required this.score});

  @override
  Widget build(BuildContext context) {
    final pct = (score.clamp(0, 100)) / 100.0;
    Color color;
    if (score >= 75) {
      color = Colors.green;
    } else if (score >= 50) {
      color = Colors.orange;
    } else {
      color = Colors.red;
    }

    return SizedBox(
      width: 56,
      height: 56,
      child: Stack(alignment: Alignment.center, children: [
        SizedBox(
          width: 48,
          height: 48,
          child: CircularProgressIndicator(value: pct, strokeWidth: 6, color: color, backgroundColor: Colors.grey.shade200),
        ),
        Column(mainAxisSize: MainAxisSize.min, children: [
          Text('$score', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          Text('sunn', style: Theme.of(context).textTheme.bodySmall)
        ])
      ]),
    );
  }
}

// history screen import moved to top
