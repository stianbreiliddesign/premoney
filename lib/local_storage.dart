import 'dart:io';
import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

/// Simple local storage helpers using Hive. The app must add these packages
/// to `pubspec.yaml`: hive_flutter, path_provider

Future<void> initLocalStorage() async {
  await Hive.initFlutter();
  await Hive.openBox('receipts');
}

Future<void> saveReceiptLocally(Map<String, dynamic> parsed, String imagePath) async {
  final box = Hive.box('receipts');

  String? destPath;
  try {
    final docs = await getApplicationDocumentsDirectory();
    final receiptsDir = Directory('${docs.path}/receipts');
    if (!await receiptsDir.exists()) await receiptsDir.create(recursive: true);
    final fileName = 'rcpt_${DateTime.now().millisecondsSinceEpoch}${imagePath != null ? _extFrom(imagePath) : '.jpg'}';
    final dest = File('${receiptsDir.path}/$fileName');
    await File(imagePath).copy(dest.path);
    destPath = dest.path;
  } catch (_) {
    // ignore file copy errors; still store JSON
    destPath = null;
  }

  final entry = {
    'raw': parsed,
    'imagePath': destPath,
    'createdAt': DateTime.now().toIso8601String(),
    'synced': false,
  };

  await box.add(entry);
}

List<Map<String, dynamic>> getLocalReceipts() {
  final box = Hive.box('receipts');
  return box.values.map((v) {
    if (v is Map) return Map<String, dynamic>.from(v as Map);
    if (v is String) return jsonDecode(v) as Map<String, dynamic>;
    return Map<String, dynamic>.from(v as Map<dynamic, dynamic>);
  }).toList();
}

Future<void> markLocalReceiptSynced(int index) async {
  final box = Hive.box('receipts');
  final v = box.getAt(index);
  if (v is Map) {
    v['synced'] = true;
    await box.putAt(index, v);
  }
}

String _extFrom(String path) {
  try {
    final ext = path.split('.').last;
    return ext.isNotEmpty ? '.$ext' : '.jpg';
  } catch (_) {
    return '.jpg';
  }
}
