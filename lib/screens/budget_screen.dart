import 'package:flutter/material.dart';
import '../local_storage.dart';

class BudgetScreen extends StatefulWidget {
  const BudgetScreen({super.key});

  @override
  State<BudgetScreen> createState() => _BudgetScreenState();
}

class _BudgetScreenState extends State<BudgetScreen> {
  final _totalCtrl = TextEditingController();
  final Map<String, TextEditingController> _catCtrls = {};
  bool _saving = false;

  final Map<String, String> _categoryLabels = {
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
    'other_grocery': 'Annet',
  };

  @override
  void initState() {
    super.initState();
    for (final k in _categoryLabels.keys) {
      _catCtrls[k] = TextEditingController();
    }
    () async {
      try {
        final b = await getBudgets();
        if (b != null) {
          if (b['total'] != null) _totalCtrl.text = b['total'].toString();
          final per = b['per_category'] as Map<String, dynamic>?;
          if (per != null) {
            per.forEach((k, v) {
              if (_catCtrls.containsKey(k)) _catCtrls[k]!.text = v?.toString() ?? '';
            });
          }
        }
      } catch (_) {}
    }();
  }

  @override
  void dispose() {
    _totalCtrl.dispose();
    for (final c in _catCtrls.values) c.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final total = double.tryParse(_totalCtrl.text.replaceAll(',', '.')) ?? 0.0;
      final Map<String, double> per = {};
      _catCtrls.forEach((k, ctrl) {
        final v = double.tryParse(ctrl.text.replaceAll(',', '.')) ?? 0.0;
        per[k] = v;
      });
      final payload = {'total': total, 'per_category': per};
      await setBudgets(payload);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Budsjett lagret')));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Kunne ikke lagre budsjett: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Budsjett')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              TextField(
                controller: _totalCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Total budsjett (kr)',
                  border: OutlineInputBorder(),
                  helperText: 'Sett et månedlig totalbudsjett',
                ),
              ),
              const SizedBox(height: 12),
              const Divider(),
              const SizedBox(height: 8),
              const Align(alignment: Alignment.centerLeft, child: Text('Per-kategori (valgfritt)', style: TextStyle(fontWeight: FontWeight.w600))),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.separated(
                  itemCount: _categoryLabels.keys.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (ctx, idx) {
                    final key = _categoryLabels.keys.elementAt(idx);
                    return TextField(
                      controller: _catCtrls[key],
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: _categoryLabels[key],
                        border: const OutlineInputBorder(),
                      ),
                    );
                  },
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Avbryt')),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _saving ? null : _save, child: _saving ? const CircularProgressIndicator() : const Text('Lagre')),
                ],
              )
            ],
          ),
        ),
      ),
    );
  }
}
