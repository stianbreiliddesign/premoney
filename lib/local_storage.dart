import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'app_state.dart';

/// Local storage helper for receipts.
File? _storageFile;

Future<File?> _ensureStorageFile() async {
  if (_storageFile != null) return _storageFile;
  try {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/receipts.json');
    if (!await f.exists()) await f.writeAsString('[]');
    _storageFile = f;
    return _storageFile;
  } catch (_) {
    _storageFile = null;
    return null;
  }
}

Future<void> initLocalStorage() async {
  await _ensureStorageFile();
}

Map<String, dynamic> _standardizeEnvelope(Map<String, dynamic> incoming) {
  final now = DateTime.now();
  final raw = (incoming['raw'] is Map) ? Map<String, dynamic>.from(incoming['raw'] as Map) : Map<String, dynamic>.from(incoming);
  final created = incoming['created_at'] ?? incoming['createdAt'] ?? now.toIso8601String();
  final localId = (incoming['local_id'] ?? incoming['localId'] ?? incoming['local-id'] ?? now.millisecondsSinceEpoch.toString()).toString();
  final imagePath = incoming['imagePath'] ?? incoming['image_path'] ?? incoming['image'] ?? '';
  final envelope = <String, dynamic>{
    'created_at': created,
    'local_id': localId,
    'imagePath': imagePath,
    'raw': raw,
  };
  if (incoming['id'] != null) envelope['id'] = incoming['id'];
  return envelope;
}

Future<void> saveReceiptLocally(Map<String, dynamic> parsed, [String? imagePath]) async {
  try {
    final f = await _ensureStorageFile();
    if (f == null) return;
    final content = await f.readAsString();
    final List<dynamic> list = (content.trim().isEmpty) ? [] : jsonDecode(content) as List<dynamic>;
    final incoming = Map<String, dynamic>.from(parsed);
    if (imagePath != null) incoming['imagePath'] = imagePath;
    final entry = _standardizeEnvelope(incoming);
    list.insert(0, entry);
    await f.writeAsString(const JsonEncoder().convert(list));
    try {
      receiptsRevision.value++;
    } catch (_) {}
  } catch (_) {
    // ignore
  }
}

Future<List<Map<String, dynamic>>> getLocalReceipts() async {
  try {
    final f = await _ensureStorageFile();
    if (f == null) return [];
    final content = await f.readAsString();
    if (content.trim().isEmpty) return [];
    final List<dynamic> list = jsonDecode(content) as List<dynamic>;
    // Filter out any receipts that were marked hidden (backup of edited receipts)
    final parsed = list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    return parsed.where((m) {
      try {
        final hidden = m['_hidden'] ?? m['hidden'] ?? false;
        if (hidden is bool) return !hidden;
        return true;
      } catch (_) {
        return true;
      }
    }).toList();
  } catch (_) {
    return [];
  }
}

Future<void> deleteLocalReceiptByLocalId(String localId) async {
  try {
    final f = await _ensureStorageFile();
    if (f == null) return;
    final content = await f.readAsString();
    final List<dynamic> list = (content.trim().isEmpty) ? [] : jsonDecode(content) as List<dynamic>;
    list.removeWhere((e) {
      try {
        final m = Map<String, dynamic>.from(e as Map);
        // match by common local id fields
        final id = (m['local_id'] ?? m['localId'] ?? m['local-id'])?.toString();
        if (id != null && id == localId) return true;
        // match by DB-saved id stored in `_saved.id` or top-level `id`
        try {
          final savedId = (m['_saved'] is Map) ? (m['_saved']['id']) : null;
          if (savedId != null && savedId.toString() == localId) return true;
        } catch (_) {}
        final topId = m['id']?.toString();
        if (topId != null && topId == localId) return true;
        return false;
      } catch (_) {
        return false;
      }
    });
    await f.writeAsString(const JsonEncoder().convert(list));
    try {
      receiptsRevision.value++;
    } catch (_) {}
  } catch (_) {}
}

/// Mark a local receipt as hidden instead of removing it. This preserves a
/// backup of the original parsed/envelope but hides it from `getLocalReceipts()`
/// so the user won't see the original after editing.
Future<void> markLocalReceiptHidden(String localId) async {
  try {
    final f = await _ensureStorageFile();
    if (f == null) return;
    final content = await f.readAsString();
    final List<dynamic> list = (content.trim().isEmpty) ? [] : jsonDecode(content) as List<dynamic>;
    bool changed = false;
    final updated = list.map((e) {
      try {
        final m = Map<String, dynamic>.from(e as Map);
          final id = (m['local_id'] ?? m['localId'] ?? m['local-id'])?.toString();
          if (id == localId) {
            m['_hidden'] = true;
            changed = true;
          } else {
            // also support matching by DB-saved id (`_saved.id`) or top-level `id`
            try {
              final savedId = (m['_saved'] is Map) ? (m['_saved']['id']) : null;
              if (savedId != null && savedId.toString() == localId) {
                m['_hidden'] = true;
                changed = true;
              }
            } catch (_) {}
            final topId = m['id']?.toString();
            if (!changed && topId != null && topId == localId) {
              m['_hidden'] = true;
              changed = true;
            }
          }
        return m;
      } catch (_) {
        return e;
      }
    }).toList();
    if (changed) {
      await f.writeAsString(const JsonEncoder().convert(updated));
      try { receiptsRevision.value++; } catch (_) {}
    }
  } catch (_) {}
}

Future<List<String>> getVisibleCategories() async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/settings.json');
    if (!await f.exists()) return [];
    final content = await f.readAsString();
    if (content.trim().isEmpty) return [];
    final Map<String, dynamic> data = jsonDecode(content) as Map<String, dynamic>;
    final List<dynamic>? list = data['visible_categories'] as List<dynamic>?;
    if (list == null) return [];
    return list.map((e) => e.toString()).toList();
  } catch (_) {
    return [];
  }
}

Future<void> setVisibleCategories(List<String> cats) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/settings.json');
    final Map<String, dynamic> data = {'visible_categories': cats};
    await f.writeAsString(const JsonEncoder().convert(data));
  } catch (_) {}
}

/// Budgets are stored inside `settings.json` under the key `budgets`.
Future<Map<String, dynamic>?> getBudgets() async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/settings.json');
    if (!await f.exists()) return null;
    final content = await f.readAsString();
    if (content.trim().isEmpty) return null;
    final Map<String, dynamic> data = jsonDecode(content) as Map<String, dynamic>;
    final b = data['budgets'];
    if (b == null) return null;
    if (b is Map) return Map<String, dynamic>.from(b as Map);
    return null;
  } catch (_) {
    return null;
  }
}

Future<void> setBudgets(Map<String, dynamic> budgets) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/settings.json');
    Map<String, dynamic> data = {};
    if (await f.exists()) {
      final content = await f.readAsString();
      if (content.trim().isNotEmpty) {
        data = jsonDecode(content) as Map<String, dynamic>;
      }
    }
    data['budgets'] = budgets;
    await f.writeAsString(const JsonEncoder().convert(data));
  } catch (_) {}
}
