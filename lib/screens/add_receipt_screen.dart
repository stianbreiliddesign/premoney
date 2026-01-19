import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../local_storage.dart';
import '../services/receipt_db.dart';

class AddReceiptScreen extends StatefulWidget {
  final Map<String, dynamic>? initialParsed;
  final String? initialImagePath;
  const AddReceiptScreen({super.key, this.initialParsed, this.initialImagePath});

  @override
  State<AddReceiptScreen> createState() => _AddReceiptScreenState();
}

class _AddReceiptScreenState extends State<AddReceiptScreen> {
  File? image;
  bool isAnalyzing = false;
  String? errorMessage;
  Map<String, dynamic>? aiResult;
  // Editor state after AI result: mutable copy for user edits
  Map<String, dynamic>? editedReceipt;
  String? _originalCreatedAt;
  List<Map<String, dynamic>> editedItems = [];
  String? _editingLocalId;
  final TextEditingController _nameController = TextEditingController();
  int splitShare = 1; // 1 means user paid whole receipt, up to 5
  // stack to support single-step undo during editing
  final List<Map<String, dynamic>> _undoStack = [];
  // Development helper: keep AI result visible after analysis instead of
  // immediately returning to Overview. Toggle to `false` to restore
  // previous behaviour.
  final bool devShowAiResultBeforeClose = true;

  // Production backend on Render. Change if you want to point to local dev.
  final String backendUrl = 'https://receipt-ai-backend.onrender.com/analyze-image';
  final String receiptsUrl = 'https://receipt-ai-backend.onrender.com/receipts';

  Future<bool> _checkServerHealth() async {
    try {
      final uri = Uri.parse(backendUrl.replaceFirst('/analyze-image', '/'));
      final resp = await http.get(uri).timeout(const Duration(seconds: 2));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
  final ImagePicker _picker = ImagePicker();

  // Human-friendly category names (key -> norsk label)
  static const Map<String, String> _categoryNames = {
    // Norwegian canonical keys
    'kjøtt': 'Kjøtt',
    'frukt_grønt': 'Frukt og grønnsaker',
    'bakervarer': 'Bakeri',
    'meieri': 'Meieri',
    'snacks': 'Snacks',
    'frossen_pizza': 'Frossent',
    'alkohol': 'Alkohol',
    'snus': 'Snus',
    'husholdning': 'Husholdning',
    'energidrikk': 'Energidrikk',
    'brus': 'Brus',
    'drikkevarer': 'Drikkevarer',
    'personlig_pleie': 'Personlig pleie',
    'rengjøring': 'Rengjøring',
    'elektronikk': 'Elektronikk',
    'klær': 'Klær',
    'apotek': 'Apotek',
    'annet': 'Annet',
    // English/alternate keys (aliases commonly used by other parts)
    'meat': 'Kjøtt',
    'produce': 'Frukt og grønnsaker',
    'bakery': 'Bakeri',
    'dairy': 'Meieri',
    'frozen_pizza': 'Frossent',
    'alcohol': 'Alkohol',
    'household': 'Husholdning',
    'energy_drink': 'Energidrikk',
    'soda': 'Brus',
    'beverages': 'Drikkevarer',
    'personal_care': 'Personlig pleie',
    'cleaning': 'Rengjøring',
    'electronics': 'Elektronikk',
    'clothing': 'Klær',
    'pharmacy': 'Apotek',
    'other': 'Annet'
  };

  String _labelForCategoryKey(dynamic k) {
    try {
      if (k == null) return 'Ukjent kategori';
      final key = k.toString();
      // normalize: lower, replace spaces/hyphens with underscore
      final norm = key.toLowerCase().replaceAll(RegExp(r"[\s\-]+"), '_');
      // common alias map from english->norwegian canonical keys
      const Map<String, String> alias = {
        'frozen_pizza': 'frossen_pizza',
        'frozenpizza': 'frossen_pizza',
        'energy_drink': 'energidrikk',
        'energydrink': 'energidrikk',
        'soda': 'brus',
        'produce': 'frukt_grønt',
        'meat': 'kjøtt',
        'bakery': 'bakervarer',
        'dairy': 'meieri',
        'other': 'annet',
        'household': 'husholdning'
      };
      final mapped = alias[norm] ?? norm;
      if (_categoryNames.containsKey(mapped)) return _categoryNames[mapped]!;
      if (_categoryNames.containsKey(key)) return _categoryNames[key]!;
      // fallback: prettify underscore-separated key
      final parts = mapped.split('_');
      final pretty = parts.map((p) => p.isEmpty ? '' : p[0].toUpperCase() + p.substring(1)).join(' ');
      return pretty.isEmpty ? 'Ukjent kategori' : pretty;
    } catch (_) {
      return 'Ukjent kategori';
    }
  }

  // Compute totals (total and saved) from the current edited items taking
  // `quantity` and `_included` into account. Returns a map with keys
  // 'total' and 'saved' as doubles.
  Map<String, double> _computeEditedTotals() {
    double total = 0.0;
    double saved = 0.0;
    for (final it in editedItems) {
      try {
        if (it['_included'] != true) continue;
        final p = it['unit_price'] ?? it['unitPrice'] ?? it['price'];
        final d = it['discount'];
        double pn = 0.0;
        if (p is num) {
          pn = p.toDouble();
        } else {
          final m = RegExp(r'[0-9]+(?:[.,][0-9]{1,2})?').firstMatch((p ?? '').toString());
          if (m != null) pn = double.tryParse(m.group(0)!.replaceAll(',', '.')) ?? 0.0;
        }
        double dn = 0.0;
        if (d != null) {
          if (d is num) dn = d.toDouble();
          else {
            final m = RegExp(r'[0-9]+(?:[.,][0-9]{1,2})?').firstMatch(d.toString());
            if (m != null) dn = double.tryParse(m.group(0)!.replaceAll(',', '.')) ?? 0.0;
          }
        }
        int qty = 1;
        try {
          if (it['quantity'] is num) qty = (it['quantity'] as num).toInt();
          else qty = int.tryParse(it['quantity']?.toString() ?? '1') ?? 1;
          if (qty < 1) qty = 1;
        } catch (_) {
          qty = 1;
        }
        total += pn * qty;
        saved += dn * qty;
      } catch (_) {}
    }
    return {'total': total, 'saved': saved};
  }

  @override
  void initState() {
    super.initState();
    // If opened for editing an existing receipt, prime the editor
    if (widget.initialParsed != null) {
      // support being passed either the raw parsed object or a full envelope
      final ip = widget.initialParsed!;
      if (ip['raw'] != null) {
        // full envelope passed from History storage — extract local id from
        // multiple possible locations so deletion/hide logic can find it.
        String? findLocalId(Map m) {
          try {
            return (m['local_id'] ?? m['localId'] ?? m['local-id'])?.toString();
          } catch (_) {
            return null;
          }
        }

        // Try top-level, then nested `raw`, then nested `row`/`data` variants.
        _editingLocalId ??= (ip['local_id'] ?? ip['localId'] ?? ip['local-id'])?.toString()
          ?? ((ip['row'] is Map) ? findLocalId(Map<String, dynamic>.from(ip['row'])) : null)
          ?? ((ip['data'] is Map) ? findLocalId(Map<String, dynamic>.from(ip['data'])) : null)
          ?? ((ip['_saved'] is Map && ip['_saved']['id'] != null) ? ip['_saved']['id']?.toString() : null)
          ?? (ip['id']?.toString());

        aiResult = (ip['raw'] is Map) ? Map<String, dynamic>.from(ip['raw']) : ip['raw'];
        // capture original created_at if present so edits preserve chronology
        try {
          _originalCreatedAt = (ip['created_at'] ?? ip['createdAt'] ?? (ip['raw'] is Map ? (ip['raw']['created_at'] ?? ip['raw']['createdAt']) : null))?.toString();
        } catch (_) {}
      } else {
        // Could be a raw parsed object or legacy structure
        aiResult = ip;
        // Also attempt to find a local id inside the raw object
        try {
          final candidate = ip;
            _editingLocalId ??= (candidate['local_id'] ?? candidate['localId'] ?? candidate['local-id'])?.toString();
            if (_editingLocalId == null && candidate['raw'] is Map) {
              final nested = Map<String, dynamic>.from(candidate['raw']);
              _editingLocalId ??= (nested['local_id'] ?? nested['localId'] ?? nested['local-id'])?.toString();
            }
            // Also accept DB-saved id in `_saved.id` or top-level `id`
            if (_editingLocalId == null) {
              try {
                if (candidate['_saved'] is Map && candidate['_saved']['id'] != null) {
                  _editingLocalId = (candidate['_saved']['id']).toString();
                }
              } catch (_) {}
            }
            _editingLocalId ??= candidate['id']?.toString();
        } catch (_) {}
      }
      editedReceipt = Map<String, dynamic>.from(aiResult!);
        final its = (editedReceipt!['items'] is List) ? List.from(editedReceipt!['items']) : [];
            editedItems = its.map<Map<String, dynamic>>((e) {
        final m = (e is Map) ? Map<String, dynamic>.from(e) : {'name': e.toString()};
        m['_included'] = true;
        // normalize quantity if present
        try {
          final q = (e is Map) ? (e['quantity'] ?? e['qty'] ?? e['amount_qty'] ?? e['amount'] ?? 1) : 1;
                if (q is num) {
                  m['quantity'] = q.toInt();
                } else {
                  m['quantity'] = int.tryParse(q.toString()) ?? 1;
                }
                if ((m['quantity'] is int) && (m['quantity'] as int) < 1) {
                  m['quantity'] = 1;
                }
        } catch (_) {
          m['quantity'] = 1;
        }
        // capture unit price (preserve original unit price separately)
        try {
          final pval = (e is Map) ? (e['unit_price'] ?? e['unitPrice'] ?? e['price']) : null;
          double pn = 0.0;
          if (pval is num) pn = pval.toDouble();
          else {
            final mres = RegExp(r'[0-9]+(?:[.,][0-9]{1,2})?').firstMatch((pval ?? '').toString());
            if (mres != null) pn = double.tryParse(mres.group(0)!.replaceAll(',', '.')) ?? 0.0;
          }
          m['unit_price'] = pn;
        } catch (_) {
          m['unit_price'] = 0.0;
        }
        // Prefer backend-provided sub_category/over_category when available
        try {
          if (e is Map) {
            if (e['sub_category'] != null) {
              m['category'] = e['sub_category'];
              m['sub_category'] = e['sub_category'];
            }
            if (e['over_category'] != null) {
              m['over_category'] = e['over_category'];
              m['category'] = m['category'] ?? e['over_category'];
            }
          }
        } catch (_) {}
        return m;
      }).toList();
      _nameController.text = (editedReceipt!['display_name'] ?? editedReceipt!['merchant'] ?? '').toString();
      splitShare = (editedReceipt!['split'] is int) ? editedReceipt!['split'] as int : 1;
      if (widget.initialImagePath != null) image = File(widget.initialImagePath!);
    }
    // If opened with only an initial image (from Overview picker), start analysis
    if (widget.initialParsed == null && widget.initialImagePath != null) {
      image = File(widget.initialImagePath!);
      Future.microtask(() => sendImageToBackend());
    }
  }

  Future<void> _pickCategoryForItem(int idx) async {
    try {
      final cats = await getVisibleCategories();
      // merge visible categories with full known set to ensure all are shown
      final available = <String>{};
      for (final c in cats) {
        available.add(c.toString());
      }
      for (final k in _categoryNames.keys) {
        available.add(k);
      }

      final sorted = available.toList()..sort((a,b){
        final la = _categoryNames[a] ?? a;
        final lb = _categoryNames[b] ?? b;
        return la.compareTo(lb);
      });

      final choice = await showDialog<String?>(context: context, builder: (ctx) {
        return SimpleDialog(
          title: const Text('Velg kategori'),
          children: sorted.map((key) => SimpleDialogOption(onPressed: () => Navigator.of(ctx).pop(key), child: Text(_labelForCategoryKey(key)))).toList(),
        );
      });
      if (!mounted) return;
      if (choice != null) {
        setState(() {
          editedItems[idx]['category'] = choice;
        });
      }
    } catch (e) {
      // ignore
    }
  }

  Future<void> openCamera() async {
    try {
      // Request a resized image to reduce upload size and speed up processing
      final XFile? picked = await _picker.pickImage(source: ImageSource.camera, imageQuality: 75, maxWidth: 1200, maxHeight: 1600);
      if (picked == null) {
        return;
      }
      setState(() {
        image = File(picked.path);
        errorMessage = null;
        aiResult = null;
      });
      await sendImageToBackend();
    } catch (e) {
      setState(() {
        errorMessage = 'Kunne ikke åpne kamera: ${e.toString()}';
      });
    }
  }

  Future<void> openGallery() async {
    try {
      final XFile? picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 1600, maxHeight: 2400);
      if (picked == null) {
        return;
      }
      setState(() {
        image = File(picked.path);
        errorMessage = null;
        aiResult = null;
      });
      await sendImageToBackend();
    } catch (e) {
      setState(() {
        errorMessage = 'Kunne ikke åpne galleri: ${e.toString()}';
      });
    }
  }

  Future<void> _showImageSourcePicker() async {
    if (!mounted) return;
    showModalBottomSheet<void>(context: context, builder: (ctx) {
      return SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.camera_alt), title: const Text('Ta bilde'), onTap: () { Navigator.of(ctx).pop(); openCamera(); }),
          ListTile(leading: const Icon(Icons.photo_library), title: const Text('Velg fra galleri'), onTap: () { Navigator.of(ctx).pop(); openGallery(); }),
          const SizedBox(height: 8),
        ]),
      );
    });
  }

  Future<void> sendImageToBackend() async {
    if (image == null) return;
    // Check server health first; if server is down, save locally and return to overview.
    final healthOk = await _checkServerHealth();
    if (!healthOk) {
      // Server unreachable: do NOT auto-save. Prepare an empty AI result
      // so the user can edit and explicitly press 'Lagre' to persist.
      setState(() {
        aiResult = {'items': [], 'total': null, 'note': 'Server utilgjengelig'};
        editedReceipt = Map<String, dynamic>.from(aiResult!);
        editedItems = <Map<String, dynamic>>[];
        _nameController.text = '';
        splitShare = 1;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Server utilgjengelig — rediger og trykk Lagre for å lagre lokalt')));
      }
      return;
    }
    setState(() {
      isAnalyzing = true;
      errorMessage = null;
      aiResult = null;
    });

    try {
      final uri = Uri.parse(backendUrl);
      final request = http.MultipartRequest('POST', uri);

      final ext = image!.path.split('.').last.toLowerCase();
      String mimeType;
      switch (ext) {
        case 'jpg':
        case 'jpeg':
          mimeType = 'image/jpeg';
          break;
        case 'png':
          mimeType = 'image/png';
          break;
        case 'gif':
          mimeType = 'image/gif';
          break;
        case 'heic':
        case 'heif':
          mimeType = 'image/heic';
          break;
        default:
          mimeType = 'image/jpeg';
      }

      final parts = mimeType.split('/');
      final multipartFile = await http.MultipartFile.fromPath(
        'image',
        image!.path,
        contentType: MediaType(parts[0], parts[1]),
      );
      request.files.add(multipartFile);

      final streamedResponse = await request.send().timeout(const Duration(seconds: 60));
      final responseBody = await streamedResponse.stream.bytesToString();
      debugPrint('Backend status: ${streamedResponse.statusCode}');
      debugPrint('Backend body: $responseBody');

      if (streamedResponse.statusCode != 200) {
        setState(() {
          errorMessage = 'Serverfeil (${streamedResponse.statusCode}): $responseBody';
        });
        return;
      }

      final parsed = jsonDecode(responseBody);
      if (parsed is! Map<String, dynamic>) {
        setState(() {
          errorMessage = 'Ugyldig responsformat fra serveren';
        });
        return;
      }

      final raw = parsed['raw'] ?? parsed;
      final items = (raw['items'] is List) ? List.from(raw['items'] as List) : null;
      if (items == null || items.isEmpty) {
        setState(() {
          errorMessage = 'AI svarte uten linjeelementer. Prøv igjen.';
        });
        return;
      }

      // Compute saved_amount from per-item discounts (if provided by AI)
      try {
        double sumDiscounts = 0.0;
        double sumPrices = 0.0;
        for (final it in items) {
          try {
            final p = it['unit_price'] ?? it['unitPrice'] ?? it['price'];
            double priceNum = 0.0;
            if (p is num) {
              priceNum = p.toDouble();
            } else {
              final s = (p ?? '').toString();
              final m = RegExp(r'[0-9]+(?:[.,][0-9]{1,2})?').firstMatch(s);
              if (m != null) priceNum = double.tryParse(m.group(0)!.replaceAll(',', '.')) ?? 0.0;
            }
            sumPrices += priceNum;

            final d = it['discount'];
            double discNum = 0.0;
            if (d != null) {
              if (d is num) {
                discNum = d.toDouble();
              } else {
                final sd = d.toString();
                final md = RegExp(r'[0-9]+(?:[.,][0-9]{1,2})?').firstMatch(sd);
                if (md != null) discNum = double.tryParse(md.group(0)!.replaceAll(',', '.')) ?? 0.0;
              }
            }
            sumDiscounts += discNum;
          } catch (_) {}
        }
        // Attach computed fields so downstream saving and UI can read them
        parsed['saved_amount'] = (parsed['saved_amount'] ?? sumDiscounts);
        parsed['total'] = (parsed['total'] ?? sumPrices);
      } catch (_) {}

      // Note: we allow items without explicit categories from AI. The overview
      // will attempt name-based heuristics to map missing categories.

      // Attempt to save parsed receipt on server
      try {
        final saveResp = await http
            .post(Uri.parse(receiptsUrl), headers: {"Content-Type": "application/json"}, body: jsonEncode(parsed))
            .timeout(const Duration(seconds: 15));
        debugPrint('Save receipt status: ${saveResp.statusCode}');
        debugPrint('Save receipt body: ${saveResp.body}');
          if (saveResp.statusCode >= 200 && saveResp.statusCode < 300) {
          // Server saved successfully — prepare UI for editing but DO NOT auto-save locally.
            setState(() {
            if (raw is Map) {
              aiResult = Map<String, dynamic>.from(raw);
            } else {
              aiResult = <String, dynamic>{};
            }
            // prepare editable copy
            editedReceipt = Map<String, dynamic>.from(aiResult!);
              final its = (editedReceipt!['items'] is List) ? List.from(editedReceipt!['items']) : [];
              editedItems = its.map<Map<String, dynamic>>((e) {
                final m = (e is Map) ? Map<String, dynamic>.from(e) : {'name': e.toString()};
                m['_included'] = true;
                try {
                  final q = (e is Map) ? (e['quantity'] ?? e['qty'] ?? e['amount_qty'] ?? e['amount'] ?? 1) : 1;
                  if (q is num) {
                    m['quantity'] = q.toInt();
                  } else {
                    m['quantity'] = int.tryParse(q.toString()) ?? 1;
                  }
                  if ((m['quantity'] is int) && (m['quantity'] as int) < 1) {
                    m['quantity'] = 1;
                  }
                } catch (_) {
                  m['quantity'] = 1;
                }
                // preserve unit price
                try {
                  final pval = (e is Map) ? (e['unit_price'] ?? e['unitPrice'] ?? e['price']) : null;
                  double pn = 0.0;
                  if (pval is num) pn = pval.toDouble();
                  else {
                    final mres = RegExp(r'[0-9]+(?:[.,][0-9]{1,2})?').firstMatch((pval ?? '').toString());
                    if (mres != null) pn = double.tryParse(mres.group(0)!.replaceAll(',', '.')) ?? 0.0;
                  }
                  m['unit_price'] = pn;
                } catch (_) {
                  m['unit_price'] = 0.0;
                }
                // Prefer backend-provided sub_category/over_category when available
                try {
                  if (e is Map) {
                    if (e['sub_category'] != null) {
                      m['category'] = e['sub_category'];
                      m['sub_category'] = e['sub_category'];
                    }
                    if (e['over_category'] != null) {
                      m['over_category'] = e['over_category'];
                      m['category'] = m['category'] ?? e['over_category'];
                    }
                  }
                } catch (_) {}
                return m;
              }).toList();
            _nameController.text = (editedReceipt!['display_name'] ?? editedReceipt!['merchant'] ?? '').toString();
            splitShare = (editedReceipt!['split'] is int) ? editedReceipt!['split'] as int : 1;
          });
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Kvittering lagret på serveren')));
            if (!devShowAiResultBeforeClose) Navigator.pop(context, true);
          }
        } else {
          // If the server reports DB not configured (503) or other failures, save locally as a fallback.
          final body = saveResp.body;
          if (saveResp.statusCode == 503 || body.toLowerCase().contains('database not configured')) {
            // DB not configured on server — prepare editor but DO NOT auto-save locally.
            setState(() {
              if (raw is Map) {
                aiResult = Map<String, dynamic>.from(raw);
              } else {
                aiResult = <String, dynamic>{};
              }
              // prepare editable copy
              editedReceipt = Map<String, dynamic>.from(aiResult!);
              final its = (editedReceipt!['items'] is List) ? List.from(editedReceipt!['items']) : [];
              editedItems = its.map<Map<String, dynamic>>((e) {
                final m = (e is Map) ? Map<String, dynamic>.from(e) : {'name': e.toString()};
                m['_included'] = true;
                try {
                  final q = (e is Map) ? (e['quantity'] ?? e['qty'] ?? e['amount_qty'] ?? e['amount'] ?? 1) : 1;
                  if (q is num) m['quantity'] = q.toInt();
                  else m['quantity'] = int.tryParse(q.toString()) ?? 1;
                  if ((m['quantity'] is int) && (m['quantity'] as int) < 1) m['quantity'] = 1;
                } catch (_) {
                  m['quantity'] = 1;
                }
                // preserve unit price for display so changing quantity doesn't
                // alter the shown unit price
                try {
                  final pval = (e is Map) ? (e['unit_price'] ?? e['unitPrice'] ?? e['price']) : null;
                  double pn = 0.0;
                  if (pval is num) pn = pval.toDouble();
                  else {
                    final mres = RegExp(r'[0-9]+(?:[.,][0-9]{1,2})?').firstMatch((pval ?? '').toString());
                    if (mres != null) pn = double.tryParse(mres.group(0)!.replaceAll(',', '.')) ?? 0.0;
                  }
                  m['unit_price'] = pn;
                } catch (_) {
                  m['unit_price'] = 0.0;
                }
                return m;
              }).toList();
              _nameController.text = (editedReceipt!['display_name'] ?? editedReceipt!['merchant'] ?? '').toString();
              splitShare = (editedReceipt!['split'] is int) ? editedReceipt!['split'] as int : 1;
            });
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Serverlagring mislyktes — lagret lokalt')));
              if (!devShowAiResultBeforeClose) Navigator.pop(context, true);
            }
          } else {
            setState(() {
              errorMessage = 'Lagret mislyktes: ${saveResp.statusCode} ${saveResp.body}';
            });
          }
        }
      } catch (e) {
        // Network or other error while saving — try SQLite DB first, then fallback to file.
        // Network or other error while saving — prepare UI for editing but DO NOT auto-save locally.
        setState(() {
          if (raw is Map) {
            aiResult = Map<String, dynamic>.from(raw);
          } else {
            aiResult = <String, dynamic>{};
          }
          // prepare editable copy
          editedReceipt = Map<String, dynamic>.from(aiResult!);
          final its = (editedReceipt!['items'] is List) ? List.from(editedReceipt!['items']) : [];
          editedItems = its.map<Map<String, dynamic>>((e) {
            final m = (e is Map) ? Map<String, dynamic>.from(e) : {'name': e.toString()};
            m['_included'] = true;
            try {
              if (e is Map) {
                if (e['sub_category'] != null) {
                  m['category'] = e['sub_category'];
                  m['sub_category'] = e['sub_category'];
                }
                if (e['over_category'] != null) {
                  m['over_category'] = e['over_category'];
                  m['category'] = m['category'] ?? e['over_category'];
                }
                // try to preserve quantity/unit_price if present
                final q = (e['quantity'] ?? e['qty'] ?? e['amount_qty'] ?? e['amount']);
                if (q != null) {
                  if (q is num) m['quantity'] = q.toInt();
                  else m['quantity'] = int.tryParse(q.toString()) ?? 1;
                }
                final pval = (e['unit_price'] ?? e['unitPrice'] ?? e['price']);
                if (pval != null) {
                  if (pval is num) m['unit_price'] = pval.toDouble();
                  else {
                    final mres = RegExp(r'[0-9]+(?:[.,][0-9]{1,2})?').firstMatch(pval.toString());
                    if (mres != null) m['unit_price'] = double.tryParse(mres.group(0)!.replaceAll(',', '.')) ?? 0.0;
                  }
                }
              }
            } catch (_) {}
            return m;
          }).toList();
          _nameController.text = (editedReceipt!['display_name'] ?? editedReceipt!['merchant'] ?? '').toString();
          splitShare = (editedReceipt!['split'] is int) ? editedReceipt!['split'] as int : 1;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Kunne ikke lagre på server: ${e.toString()}. Rediger og trykk Lagre for å lagre lokalt.')));
          if (!devShowAiResultBeforeClose) Navigator.pop(context, true);
        }
      }
    } on TimeoutException catch (_) {
      setState(() {
        errorMessage = 'Tidsavbrudd ved opplasting. Prøv igjen.';
      });
    } catch (e) {
      setState(() {
        errorMessage = 'Klarte ikke analysere kvitteringen: ${e.toString()}';
      });
    } finally {
      setState(() {
        isAnalyzing = false;
      });
    }
  }

  Future<void> sendParsedReceiptToBackend(Map<String, dynamic> parsed) async {
    try {
      final resp = await http
          .post(Uri.parse(receiptsUrl), headers: {"Content-Type": "application/json"}, body: jsonEncode(parsed))
          .timeout(const Duration(seconds: 15));
      debugPrint('Save receipt status: ${resp.statusCode}');
      debugPrint('Save receipt body: ${resp.body}');
    } catch (e) {
      debugPrint('Failed to save receipt: $e');
    }
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Analyser kvittering'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              // Image preview card
              Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                clipBehavior: Clip.hardEdge,
                elevation: 2,
                child: Container(
                  height: 260,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: image != null
                      ? Image.file(image!, fit: BoxFit.cover, width: double.infinity)
                      : Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.camera_alt_outlined, size: 56, color: Colors.grey[500]),
                              const SizedBox(height: 8),
                              Text('Ingen bilde valgt', style: Theme.of(context).textTheme.bodyMedium),
                            ],
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 14),

              // Analysis / loading card
              if (isAnalyzing)
                Card(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          const SizedBox(width: 36, height: 36, child: CircularProgressIndicator(strokeWidth: 3)),
                          const SizedBox(width: 12),
                          Expanded(child: Text('Analyserer kvittering...', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
                        ]),
                        const SizedBox(height: 12),
                        const LinearProgressIndicator(minHeight: 6),
                        const SizedBox(height: 8),
                        Text('Vent et øyeblikk mens AI analyserer bildet.', style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                ),

              if (errorMessage != null) ...[
                const SizedBox(height: 12),
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(children: [
                      Row(children: [
                        const Icon(Icons.error_outline, color: Colors.redAccent),
                        const SizedBox(width: 8),
                        Expanded(child: Text(errorMessage!, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer))),
                      ]),
                      const SizedBox(height: 8),
                      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Avbryt')),
                        const SizedBox(width: 8),
                        FilledButton(onPressed: () {
                          setState(() {
                            errorMessage = null;
                            isAnalyzing = true;
                          });
                          sendImageToBackend();
                        }, child: const Text('Prøv igjen')),
                      ])
                    ]),
                  ),
                ),
              ],

              const SizedBox(height: 12),

              // AI result area
              if (aiResult != null) ...[
                Card(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('AI - Sammendrag', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                              const SizedBox(height: 6),
                              Text('Rask oversikt over nøkkeltall', style: Theme.of(context).textTheme.bodySmall),
                            ]),
                            Row(children: [
                              IconButton(onPressed: () { /* copy JSON */ }, icon: const Icon(Icons.copy_outlined)),
                              IconButton(onPressed: () { /* share */ }, icon: const Icon(Icons.share_outlined)),
                            ])
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(children: [
                          Builder(builder: (ctx) {
                            final totals = _computeEditedTotals();
                            final displayTotal = (editedReceipt != null) ? totals['total']!.toStringAsFixed(2) : (aiResult?['total']?.toString() ?? '-');
                            final displaySaved = (editedReceipt != null) ? totals['saved']!.toStringAsFixed(2) : (aiResult?['saved_amount']?.toString() ?? '-');
                            return Row(children: [
                              _statPill('Totalt', '$displayTotal kr', context),
                              const SizedBox(width: 12),
                              _statPill('Spar', '$displaySaved kr', context),
                            ]);
                          }),
                        ]),
                        const SizedBox(height: 12),
                        ExpansionTile(
                          title: const Text('Detaljer (vis JSON)'),
                          children: [
                            Container(
                              width: double.infinity,
                              color: Theme.of(context).colorScheme.surfaceContainerHighest,
                              padding: const EdgeInsets.all(12),
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: SelectableText(const JsonEncoder.withIndent('  ').convert(aiResult), style: Theme.of(context).textTheme.bodySmall),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        // Editor controls: rename, include/exclude items, split selector
                        const SizedBox(height: 8),
                        Text('Rediger kvittering', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _nameController,
                          decoration: const InputDecoration(labelText: 'Navn på kvittering (valgfritt)'),
                        ),
                        const SizedBox(height: 8),
                        Row(children: [
                          const Text('Deling (din andel):', style: TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(width: 12),
                          DropdownButton<int>(value: splitShare, items: List.generate(5, (i) => i + 1).map((v) => DropdownMenuItem(value: v, child: Text('1/$v'))).toList(), onChanged: (v) { if (v != null) setState(() => splitShare = v); }),
                          const SizedBox(width: 12),
                          const Expanded(child: Text('Velg hvor mange deler kvitteringen skal splittes i (1-5).'))
                        ]),
                        const SizedBox(height: 12),
                        Text('Varer (fjern varer som ikke gjelder din andel):', style: Theme.of(context).textTheme.bodyMedium),
                        const SizedBox(height: 8),
                        Column(
                          children: editedItems.asMap().entries.map((entry) {
                            final idx = entry.key;
                            final item = entry.value;
                            final name = (item['name'] ?? item['description'] ?? '').toString();
                            final price = item['price']?.toString() ?? '';
                            final included = item['_included'] == true;
                            return Dismissible(
                              key: Key('item-$idx-${name.substring(0, name.length.clamp(0,8))}'),
                              direction: DismissDirection.endToStart,
                              background: Container(color: Colors.redAccent, alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 12), child: const Icon(Icons.delete, color: Colors.white)),
                              onDismissed: (_) {
                                setState(() {
                                  final removed = editedItems.removeAt(idx);
                                  _undoStack.add(removed);
                                });
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                  content: const Text('Vare fjernet'),
                                  action: SnackBarAction(label: 'Angre', onPressed: () {
                                    if (_undoStack.isNotEmpty) {
                                      setState(() { editedItems.insert(idx, _undoStack.removeLast()); });
                                    }
                                  }),
                                ));
                              },
                              child: CheckboxListTile(
                                title: Text(name),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                    if (price.isNotEmpty) Builder(builder: (_) {
                                      double pn = 0.0;
                                      final p = item['unit_price'] ?? item['unitPrice'] ?? item['price'];
                                      if (p is num) pn = p.toDouble();
                                      else {
                                        final m = RegExp(r'[0-9]+(?:[.,][0-9]{1,2})?').firstMatch((p ?? '').toString());
                                        if (m != null) pn = double.tryParse(m.group(0)!.replaceAll(',', '.')) ?? 0.0;
                                      }
                                      final qty = (item['quantity'] is num) ? (item['quantity'] as num).toInt() : (int.tryParse(item['quantity']?.toString() ?? '1') ?? 1);
                                      final lineTotal = pn * (qty < 1 ? 1 : qty);
                                      return Text('${pn.toStringAsFixed(2)} kr${qty > 1 ? ' — ${qty} stk = ${lineTotal.toStringAsFixed(2)} kr' : ''}');
                                    }),
                                    const SizedBox(height: 4),
                                    GestureDetector(
                                      onTap: () => _pickCategoryForItem(idx),
                                      child: Text(
                                        _labelForCategoryKey(item['category'] ?? item['category_name'] ?? item['cat']),
                                        style: const TextStyle(fontSize: 12, color: Colors.blueAccent, decoration: TextDecoration.underline),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Row(children: [
                                      const Text('Antall:', style: TextStyle(fontSize: 12)),
                                      const SizedBox(width: 8),
                                      Builder(builder: (ctx) {
                                        final curQty = (item['quantity'] is num) ? (item['quantity'] as num).toInt() : (int.tryParse(item['quantity']?.toString() ?? '1') ?? 1);
                                        return Row(children: [
                                          SizedBox(
                                            width: 32,
                                            height: 32,
                                            child: IconButton(
                                              padding: EdgeInsets.zero,
                                              iconSize: 18,
                                              onPressed: () {
                                                if (curQty <= 1) return;
                                                setState(() {
                                                  final now = (editedItems[idx]['quantity'] is num) ? (editedItems[idx]['quantity'] as num).toInt() : (int.tryParse(editedItems[idx]['quantity']?.toString() ?? '1') ?? 1);
                                                  editedItems[idx]['quantity'] = (now > 1) ? now - 1 : 1;
                                                });
                                              },
                                              icon: const Icon(Icons.remove),
                                            ),
                                          ),
                                          Padding(
                                            padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                            child: Text('$curQty stk', style: const TextStyle(fontSize: 13)),
                                          ),
                                          SizedBox(
                                            width: 32,
                                            height: 32,
                                            child: IconButton(
                                              padding: EdgeInsets.zero,
                                              iconSize: 18,
                                              onPressed: () {
                                                setState(() {
                                                  final now = (editedItems[idx]['quantity'] is num) ? (editedItems[idx]['quantity'] as num).toInt() : (int.tryParse(editedItems[idx]['quantity']?.toString() ?? '1') ?? 1);
                                                  editedItems[idx]['quantity'] = now + 1;
                                                });
                                              },
                                              icon: const Icon(Icons.add),
                                            ),
                                          ),
                                        ]);
                                      }),
                                    ]),
                                  ],
                                ),
                                value: included,
                                onChanged: (v) {
                                  setState(() {
                                    editedItems[idx]['_included'] = v == true;
                                  });
                                },
                                controlAffinity: ListTileControlAffinity.leading,
                              ),
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 12),
                        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Avbryt')),
                          const SizedBox(width: 8),
                            FilledButton(onPressed: () async {
                            // Prepare final payload from edited state and persist locally
                            final payload = Map<String, dynamic>.from(editedReceipt ?? aiResult ?? {});
                            // Preserve original created date when editing existing receipt.
                            // If we don't have `_originalCreatedAt` (edge cases), try to
                            // look it up from local storage by `_editingLocalId` so
                            // edits don't change the original capture date.
                            if (_originalCreatedAt != null) {
                              payload['created_at'] = _originalCreatedAt;
                            } else if (_editingLocalId != null) {
                              try {
                                final localList = await getLocalReceipts();
                                for (final e in localList) {
                                  try {
                                    final m = Map<String, dynamic>.from(e);
                                    final lid = (m['local_id'] ?? m['localId'] ?? m['local-id'])?.toString();
                                    final savedId = (m['_saved'] is Map) ? (m['_saved']['id']) : null;
                                    final topId = m['id']?.toString();
                                    if (lid != null && lid == _editingLocalId) {
                                      payload['created_at'] = m['created_at'] ?? m['createdAt'] ?? payload['created_at'];
                                      break;
                                    }
                                    if (savedId != null && savedId.toString() == _editingLocalId) {
                                      payload['created_at'] = m['created_at'] ?? m['createdAt'] ?? payload['created_at'];
                                      break;
                                    }
                                    if (topId != null && topId == _editingLocalId) {
                                      payload['created_at'] = m['created_at'] ?? m['createdAt'] ?? payload['created_at'];
                                      break;
                                    }
                                  } catch (_) {}
                                }
                              } catch (_) {}
                            }
                            payload['display_name'] = (_nameController.text.trim().isEmpty) ? null : _nameController.text.trim();
                            payload['split'] = splitShare;
                            // Filter included items and recompute totals
                            final kept = editedItems.where((it) => it['_included'] == true).map((it) {
                              final copy = Map<String, dynamic>.from(it);
                              copy.remove('_included');
                              return copy;
                            }).toList();
                            payload['items'] = kept;
                            double total = 0.0;
                            double saved = 0.0;
                            for (final it in kept) {
                              try {
                                final p = it['unit_price'] ?? it['unitPrice'] ?? it['price'];
                                final d = it['discount'];
                                double pn = 0.0;
                                if (p is num) {
                                  pn = p.toDouble();
                                } else {
                                  final m = RegExp(r'[0-9]+(?:[.,][0-9]{1,2})?').firstMatch((p ?? '').toString());
                                  if (m != null) pn = double.tryParse(m.group(0)!.replaceAll(',', '.')) ?? 0.0;
                                }
                                double dn = 0.0;
                                if (d != null) {
                                  if (d is num) {
                                    dn = d.toDouble();
                                  } else {
                                    final m = RegExp(r'[0-9]+(?:[.,][0-9]{1,2})?').firstMatch(d.toString());
                                    if (m != null) dn = double.tryParse(m.group(0)!.replaceAll(',', '.')) ?? 0.0;
                                  }
                                }
                                int qty = 1;
                                try {
                                  if (it['quantity'] is num) qty = (it['quantity'] as num).toInt();
                                  else qty = int.tryParse(it['quantity']?.toString() ?? '1') ?? 1;
                                  if (qty < 1) qty = 1;
                                } catch (_) {
                                  qty = 1;
                                }
                                total += pn * qty;
                                saved += dn * qty;
                              } catch (_) {}
                            }
                            payload['total'] = total;
                            payload['saved_amount'] = saved;
                            // If we were editing an existing local envelope, try to
                            // update the existing DB row first. If `ReceiptDb`
                            // exposes an update method we call it dynamically; if
                            // that fails we fall back to deleting/hiding the old
                            // entry so we can insert a fresh one.
                            bool handledByUpdate = false;
                            if (_editingLocalId != null) {
                              try {
                                // dynamic call: if method doesn't exist this will
                                // throw and we fall back.
                                await (ReceiptDb as dynamic).updateReceipt(_editingLocalId!, payload, image?.path);
                                handledByUpdate = true;
                              } catch (_) {
                                handledByUpdate = false;
                              }
                              if (!handledByUpdate) {
                                // Try to delete the original saved envelope; if deletion
                                // fails (DB or file), mark it hidden as a backup so it
                                // doesn't appear in History or Overview.
                                bool deleted = false;
                                try {
                                  await ReceiptDb.deleteByLocalId(_editingLocalId!);
                                  deleted = true;
                                } catch (_) {}
                                if (!deleted) {
                                  try {
                                    await deleteLocalReceiptByLocalId(_editingLocalId!);
                                    deleted = true;
                                  } catch (_) {}
                                }
                                if (!deleted) {
                                  try {
                                    await markLocalReceiptHidden(_editingLocalId!);
                                  } catch (_) {}
                                }
                              }
                            }
                            else {
                              // No explicit `local_id` known — try best-effort to find
                              // and remove any existing record that references a DB id
                              // stored in `_saved.id` or top-level `id` on the payload.
                              String? dbId;
                              try {
                                if (payload['_saved'] is Map && payload['_saved']['id'] != null) dbId = payload['_saved']['id'].toString();
                              } catch (_) {}
                              dbId ??= payload['id']?.toString();
                              if (dbId != null) {
                                bool handledDb = false;
                                try {
                                  await (ReceiptDb as dynamic).updateReceipt(dbId, payload, image?.path);
                                  handledDb = true;
                                } catch (_) { handledDb = false; }
                                if (!handledDb) {
                                  bool deleted = false;
                                  try {
                                    await ReceiptDb.deleteByLocalId(dbId);
                                    deleted = true;
                                  } catch (_) {}
                                  if (!deleted) {
                                    try {
                                      await deleteLocalReceiptByLocalId(dbId);
                                      deleted = true;
                                    } catch (_) {}
                                  }
                                  if (!deleted) {
                                    try {
                                      await markLocalReceiptHidden(dbId);
                                    } catch (_) {}
                                  }
                                } else {
                                  handledByUpdate = true;
                                }
                              }
                            }
                            // Remove any embedded DB ids so a new local record
                            // does not keep the old `_saved.id`/`id` and cause
                            // accidental duplicates in History.
                            try {
                              payload.remove('_saved');
                            } catch (_) {}
                            try {
                              payload.remove('id');
                            } catch (_) {}
                            // Persist locally (try ReceiptDb then file fallback)
                            if (!handledByUpdate) {
                              try {
                                await ReceiptDb.insertReceipt(payload, image?.path);
                              } catch (_) {
                                try {
                                  await saveReceiptLocally(payload, image?.path);
                                } catch (_) {}
                              }
                            } else {
                              // Already updated the existing DB row — nothing else to do.
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Kvittering oppdatert')));
                              Navigator.pop(context, true);
                              return;
                            }
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Kvittering lagret lokalt')));
                            Navigator.pop(context, true);
                          }, child: const Text('Lagre')),
                        ])
                      ],
                    ),
                  ),
                ),
              ],

              // Spacer if content small
              const SizedBox(height: 12),
            ],
          ),
          ),
        ),
      ),
        floatingActionButton: FloatingActionButton(
          tooltip: 'Åpne kamera eller galleri',
          onPressed: _showImageSourcePicker,
          child: const Icon(Icons.camera_alt),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }

  Widget _statPill(String label, String value, BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer, borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        Text(value, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
      ]),
    );
  }
}
