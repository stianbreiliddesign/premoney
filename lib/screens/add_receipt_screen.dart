import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'overview_screen.dart';
import '../local_storage.dart';

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

  static const backendUrl =
      'https://receipt-ai-backend.onrender.com/analyze-image';

  String get receiptsUrl => backendUrl.replaceAll('/analyze-image', '/receipts');

  final ImagePicker picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    openCamera();
  }

  Future<void> openCamera() async {
    final XFile? photo = await picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
    );

    if (photo == null) {
      Navigator.pop(context);
      return;
    }

    setState(() {
      image = File(photo.path);
    });

    await sendImageToBackend();
  }

  Future<void> sendImageToBackend() async {
    if (image == null) return;

    setState(() {
      isAnalyzing = true;
      errorMessage = null;
      aiResult = null;
    });

    try {
      final request = http.MultipartRequest('POST', Uri.parse(backendUrl));

      // Determine a sensible MIME type from extension (fallback)
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
      final file = await http.MultipartFile.fromPath(
        'image',
        image!.path,
        contentType: MediaType(parts[0], parts[1]),
      );
      request.files.add(file);

      // Add a timeout so the UI doesn't hang indefinitely
      final streamedResponse =
          await request.send().timeout(const Duration(seconds: 30));
      final responseBody = await streamedResponse.stream.bytesToString();

      // Debug log for server response
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

      try {
        final parsed = jsonDecode(responseBody);
        if (parsed is Map<String, dynamic>) {
          setState(() {
            aiResult = parsed;
          });
          // Save locally immediately
          try {
            await initLocalStorage();
          } catch (_) {}
          try {
            await saveReceiptLocally(parsed, image!.path);
          } catch (_) {}

          // Send parsed receipt to backend for persistence (non-blocking)
          sendParsedReceiptToBackend(parsed);
        } else {
          setState(() {
            errorMessage = 'Ugyldig responsformat fra serveren';
          });
        }
      } catch (e) {
        setState(() {
          errorMessage = 'Kunne ikke parse serverrespons';
        });
      }
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
          .post(Uri.parse(receiptsUrl),
              headers: {"Content-Type": "application/json"}, body: jsonEncode(parsed))
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
        actions: [
          IconButton(
            tooltip: 'Oversikt',
            icon: const Icon(Icons.list),
            onPressed: () async {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const OverviewScreen()),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
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
                  color: Theme.of(context).colorScheme.surfaceVariant,
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
                    child: Row(children: [
                      const Icon(Icons.error_outline, color: Colors.redAccent),
                      const SizedBox(width: 8),
                      Expanded(child: Text(errorMessage!, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer))),
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
                              color: Theme.of(context).colorScheme.surfaceVariant,
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
                          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Legg til i oversikt')),
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
