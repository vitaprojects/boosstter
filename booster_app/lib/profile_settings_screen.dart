import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class ProfileSettingsScreen extends StatefulWidget {
  const ProfileSettingsScreen({super.key});

  @override
  State<ProfileSettingsScreen> createState() => _ProfileSettingsScreenState();
}

class _ProfileSettingsScreenState extends State<ProfileSettingsScreen> {
  bool _isLoading = true;
  bool _isSaving = false;

  bool _providesBoost = true;
  bool _providesTow = false;
  bool _providesMechanic = false;

  final TextEditingController _boostPriceController = TextEditingController();
  final TextEditingController _towPriceController = TextEditingController();
  final TextEditingController _mechanicPriceController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadProfileSettings();
  }

  @override
  void dispose() {
    _boostPriceController.dispose();
    _towPriceController.dispose();
    _mechanicPriceController.dispose();
    super.dispose();
  }

  Future<void> _loadProfileSettings() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      return;
    }

    try {
      final userDoc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
      final data = userDoc.data() ?? <String, dynamic>{};

      final offered = (data['offeredServices'] as Map<String, dynamic>?) ?? <String, dynamic>{};
      final pricing = (data['providerPricingCadCents'] as Map<String, dynamic>?) ?? <String, dynamic>{};

      if (!mounted) return;
      setState(() {
        _providesBoost = (offered['boost'] as bool?) ?? true;
        _providesTow = (offered['tow'] as bool?) ?? false;
        _providesMechanic = (offered['mobile_mechanic'] as bool?) ?? false;

        _boostPriceController.text = (((pricing['boost'] as num?)?.toInt() ?? 2500) / 100).toStringAsFixed(2);
        _towPriceController.text = (((pricing['tow'] as num?)?.toInt() ?? 3000) / 100).toStringAsFixed(2);
        _mechanicPriceController.text = (((pricing['mobile_mechanic'] as num?)?.toInt() ?? 3500) / 100).toStringAsFixed(2);
      });
    } catch (_) {
      // Keep defaults when profile cannot be loaded.
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  int _parsePriceToCents(String value, {required int fallback}) {
    final normalized = value.trim();
    if (normalized.isEmpty) return fallback;
    final parsed = double.tryParse(normalized);
    if (parsed == null || parsed <= 0) return fallback;
    return (parsed * 100).round();
  }

  Future<void> _saveProfileSettings() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _isSaving) return;

    if (!(_providesBoost || _providesTow || _providesMechanic)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enable at least one service type to continue.')),
      );
      return;
    }

    final boostCents = _parsePriceToCents(_boostPriceController.text, fallback: 2500);
    final towCents = _parsePriceToCents(_towPriceController.text, fallback: 3000);
    final mechanicCents = _parsePriceToCents(_mechanicPriceController.text, fallback: 3500);

    setState(() => _isSaving = true);
    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'offeredServices': {
          'boost': _providesBoost,
          'tow': _providesTow,
          'mobile_mechanic': _providesMechanic,
        },
        'providerPricingCadCents': {
          'boost': boostCents,
          'tow': towCents,
          'mobile_mechanic': mechanicCents,
        },
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile services and pricing saved.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save profile settings. Please try again.')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Widget _serviceTile({
    required String title,
    required String subtitle,
    required bool enabled,
    required ValueChanged<bool> onChanged,
    required TextEditingController priceController,
    required String hint,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E4ED)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(color: Color(0xFF6B7280)),
                    ),
                  ],
                ),
              ),
              Switch(
                value: enabled,
                onChanged: onChanged,
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: priceController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Your price (CAD)',
              hintText: hint,
              prefixText: '\$',
              enabled: enabled,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Service Types & Pricing')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'Provider Setup',
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Choose services you provide and set your default pricing. You can still request services from Home anytime.',
                    style: Theme.of(context)
                        .textTheme
                        .bodyLarge
                        ?.copyWith(color: const Color(0xFF6B7280)),
                  ),
                  const SizedBox(height: 16),
                  _serviceTile(
                    title: 'Battery Boost',
                    subtitle: 'Roadside battery boost requests',
                    enabled: _providesBoost,
                    onChanged: (v) => setState(() => _providesBoost = v),
                    priceController: _boostPriceController,
                    hint: '25.00',
                  ),
                  _serviceTile(
                    title: 'Tow Assistance',
                    subtitle: 'Tow requests near your location',
                    enabled: _providesTow,
                    onChanged: (v) => setState(() => _providesTow = v),
                    priceController: _towPriceController,
                    hint: '30.00',
                  ),
                  _serviceTile(
                    title: 'Mobile Mechanic',
                    subtitle: 'On-site mechanic service requests',
                    enabled: _providesMechanic,
                    onChanged: (v) => setState(() => _providesMechanic = v),
                    priceController: _mechanicPriceController,
                    hint: '35.00',
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isSaving ? null : _saveProfileSettings,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        backgroundColor: const Color(0xFF5500FF),
                        foregroundColor: Colors.white,
                      ),
                      child: _isSaving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Text(
                              'Save Settings',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
