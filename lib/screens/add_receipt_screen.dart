import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'overview_screen.dart';

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
      appBar: AppBar(title: const Text('Analyserer kvittering'), actions: [
        IconButton(
          tooltip: 'Oversikt',
          icon: const Icon(Icons.list),
          onPressed: () async {
            // Navigate to Overview screen
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const OverviewScreen()),
            );
          },
        ),
      ]),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (image != null) Image.file(image!, height: 220),
            const SizedBox(height: 16),

            if (isAnalyzing)
              const Text(
                'Analyserer kvittering...',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),

            if (errorMessage != null) ...[
              const SizedBox(height: 16),
              Text(
                errorMessage!,
                style: const TextStyle(color: Colors.red),
              ),
            ],

            if (aiResult != null) ...[
              const SizedBox(height: 16),
              const Text(
                'AI-resultat:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: SingleChildScrollView(
                  child: Text(
                    const JsonEncoder.withIndent('  ').convert(aiResult),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
