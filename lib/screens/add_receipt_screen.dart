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
  const AddReceiptScreen({super.key});

  @override
  State<AddReceiptScreen> createState() => _AddReceiptScreenState();
}

class _AddReceiptScreenState extends State<AddReceiptScreen> {
  File? image;
  bool isAnalyzing = false;
  String? errorMessage;
  Map<String, dynamic>? aiResult;
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

  Future<void> openCamera() async {
    try {
      final XFile? picked = await _picker.pickImage(source: ImageSource.camera, imageQuality: 85);
      if (picked == null) return;
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

  Future<void> sendImageToBackend() async {
    if (image == null) return;
    // Check server health first; if server is down, save locally and return to overview.
    final healthOk = await _checkServerHealth();
    if (!healthOk) {
      try {
        await ReceiptDb.insertReceipt({'raw': {'items': [], 'total': null, 'note': 'Saved without parse - server unreachable'}}, image?.path);
      } catch (_) {
        try {
          await saveReceiptLocally({'raw': {'items': [], 'total': null, 'note': 'Saved without parse - server unreachable'}}, image?.path);
        } catch (_) {}
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Server utilgjengelig — lagret lokalt')));
        Navigator.pop(context, true);
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
      // ignore: avoid_print
      print('Backend status: ${streamedResponse.statusCode}');
      // ignore: avoid_print
      print('Backend body: $responseBody');

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

      // Note: we allow items without explicit categories from AI. The overview
      // will attempt name-based heuristics to map missing categories.

      // Attempt to save parsed receipt on server
      try {
        final saveResp = await http
            .post(Uri.parse(receiptsUrl), headers: {"Content-Type": "application/json"}, body: jsonEncode(parsed))
            .timeout(const Duration(seconds: 15));
        // ignore: avoid_print
        print('Save receipt status: ${saveResp.statusCode}');
        // ignore: avoid_print
        print('Save receipt body: ${saveResp.body}');
        if (saveResp.statusCode >= 200 && saveResp.statusCode < 300) {
          // Server saved successfully — still persist locally so history reflects all receipts
          try {
            await ReceiptDb.insertReceipt(parsed, image?.path);
          } catch (_) {}
          setState(() {
            aiResult = raw as Map<String, dynamic>;
          });
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Kvittering lagret på serveren')));
            if (!devShowAiResultBeforeClose) Navigator.pop(context, true);
          }
        } else {
          // If the server reports DB not configured (503) or other failures, save locally as a fallback.
          final body = saveResp.body;
          if (saveResp.statusCode == 503 || body.toLowerCase().contains('database not configured')) {
            try {
              await ReceiptDb.insertReceipt(parsed, image?.path);
            } catch (_) {
              try {
                await saveReceiptLocally(parsed, image?.path);
              } catch (_) {}
            }
            setState(() {
              aiResult = raw as Map<String, dynamic>;
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
        try {
          await ReceiptDb.insertReceipt(parsed, image?.path);
          setState(() {
            aiResult = raw as Map<String, dynamic>;
          });
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Kunne ikke lagre på server: ${e.toString()}. Lagret lokalt.')));
            if (!devShowAiResultBeforeClose) Navigator.pop(context, true);
          }
        } catch (_) {
          try {
            await saveReceiptLocally(parsed, image?.path);
            setState(() {
              aiResult = raw as Map<String, dynamic>;
            });
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Kunne ikke lagre på server: ${e.toString()}. Lagret lokalt (fil).')));
              if (!devShowAiResultBeforeClose) Navigator.pop(context, true);
            }
          } catch (_) {
            setState(() {
              errorMessage = 'Kunne ikke lagre kvittering på server: ${e.toString()}';
            });
          }
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
      // ignore: avoid_print
      print('Save receipt status: ${resp.statusCode}');
      // ignore: avoid_print
      print('Save receipt body: ${resp.body}');
    } catch (e) {
      // ignore: avoid_print
      print('Failed to save receipt: $e');
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
                          _statPill('Totalt', '${aiResult?['total'] ?? '-'} kr', context),
                          const SizedBox(width: 12),
                          _statPill('Spar', '${aiResult?['saved_amount'] ?? '-'} kr', context),
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
                        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Ferdig')),
                          const SizedBox(width: 8),
                          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Legg til i oversikt')),
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
          tooltip: 'Åpne kamera',
          onPressed: openCamera,
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
