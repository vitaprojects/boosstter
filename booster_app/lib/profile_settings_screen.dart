import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';

import 'service_commerce.dart';

class ProfileSettingsScreen extends StatefulWidget {
  const ProfileSettingsScreen({super.key});

  @override
  State<ProfileSettingsScreen> createState() => _ProfileSettingsScreenState();
}

class _ProfileSettingsScreenState extends State<ProfileSettingsScreen> {
  bool _isLoading = true;
  bool _isSaving = false;

  bool _isAvailable = false;
  bool _receiveRequestNotifications = true;
  bool _providesBoost = true;
  bool _providesTow = false;
  bool _providesMechanic = false;
  String _pricingCurrency = defaultPricingCurrency;
  String _preferredPaymentProvider = defaultPaymentProvider;

  final TextEditingController _phoneController = TextEditingController();
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
    _phoneController.dispose();
    _boostPriceController.dispose();
    _towPriceController.dispose();
    _mechanicPriceController.dispose();
    super.dispose();
  }

  Future<void> _loadProfileSettings() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    try {
      final userDoc =
          await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
      final data = userDoc.data() ?? <String, dynamic>{};
      final offered =
          (data['offeredServices'] as Map<String, dynamic>?) ?? <String, dynamic>{};
      final pricing = (data['providerPricingCents'] as Map<String, dynamic>?) ??
          (data['providerPricingCadCents'] as Map<String, dynamic>?) ??
          <String, dynamic>{};
      final detectedCurrency = (data['providerPricingCurrency'] as String?)?.toUpperCase() ??
          await _detectPricingCurrency(data);

      if (!mounted) return;
      setState(() {
        _isAvailable = (data['isAvailable'] as bool?) ?? false;
        _receiveRequestNotifications =
            (data['receiveServiceRequestNotifications'] as bool?) ?? true;
        _providesBoost = (offered[serviceTypeBoost] as bool?) ?? true;
        _providesTow = (offered[serviceTypeTow] as bool?) ?? false;
        _providesMechanic = (offered[serviceTypeMechanic] as bool?) ?? false;
        _pricingCurrency = detectedCurrency;
        _preferredPaymentProvider =
            (data['preferredPaymentProvider'] as String?) ?? defaultPaymentProvider;
        _phoneController.text = (data['phoneNumber'] ?? data['phone'] ?? '').toString();

        _boostPriceController.text =
            (((pricing[serviceTypeBoost] as num?)?.toInt() ??
                        defaultServicePriceCents[serviceTypeBoost]!) /
                    100)
                .toStringAsFixed(2);
        _towPriceController.text =
            (((pricing[serviceTypeTow] as num?)?.toInt() ??
                        defaultServicePriceCents[serviceTypeTow]!) /
                    100)
                .toStringAsFixed(2);
        _mechanicPriceController.text =
            (((pricing[serviceTypeMechanic] as num?)?.toInt() ??
                        defaultServicePriceCents[serviceTypeMechanic]!) /
                    100)
                .toStringAsFixed(2);
      });
    } catch (_) {
      // Defaults keep the settings page usable offline.
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<String> _detectPricingCurrency(Map<String, dynamic> data) async {
    final latitude = (data['latitude'] as num?)?.toDouble();
    final longitude = (data['longitude'] as num?)?.toDouble();
    if (latitude == null || longitude == null || (latitude == 0 && longitude == 0)) {
      return defaultPricingCurrency;
    }

    try {
      final placemarks = await placemarkFromCoordinates(latitude, longitude);
      final isoCode = placemarks.first.isoCountryCode?.toUpperCase();
      if (isoCode != null) return currencyForCountry(isoCode);
    } catch (_) {
      // Fall through to default currency.
    }
    return defaultPricingCurrency;
  }

  int _parsePriceToCents(String value, {required int fallback}) {
    final parsed = double.tryParse(value.trim());
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

    final boostCents = _parsePriceToCents(
      _boostPriceController.text,
      fallback: defaultServicePriceCents[serviceTypeBoost]!,
    );
    final towCents = _parsePriceToCents(
      _towPriceController.text,
      fallback: defaultServicePriceCents[serviceTypeTow]!,
    );
    final mechanicCents = _parsePriceToCents(
      _mechanicPriceController.text,
      fallback: defaultServicePriceCents[serviceTypeMechanic]!,
    );

    setState(() => _isSaving = true);
    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'isAvailable': _isAvailable,
        'receiveServiceRequestNotifications': _receiveRequestNotifications,
        'offeredServices': <String, bool>{
          serviceTypeBoost: _providesBoost,
          serviceTypeTow: _providesTow,
          serviceTypeMechanic: _providesMechanic,
        },
        'providerPricingCurrency': _pricingCurrency,
        'providerPricingCents': <String, int>{
          serviceTypeBoost: boostCents,
          serviceTypeTow: towCents,
          serviceTypeMechanic: mechanicCents,
        },
        'providerPricingCadCents': <String, int>{
          serviceTypeBoost: boostCents,
          serviceTypeTow: towCents,
          serviceTypeMechanic: mechanicCents,
        },
        'preferredPaymentProvider': _preferredPaymentProvider,
        'phoneNumber': _phoneController.text.trim(),
        'supportedPaymentProviders': supportedPaymentProviders,
        'platformAdminRate': defaultAdminRate,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Service settings saved.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save service settings. Please try again.')),
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
    required IconData icon,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(color: Color(0x08000000), blurRadius: 12, offset: Offset(0, 4)),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFF5500FF).withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: const Color(0xFF5500FF)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
                    ),
                  ],
                ),
              ),
              Switch(value: enabled, onChanged: onChanged),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: priceController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Default customer price ($_pricingCurrency)',
              hintText: hint,
              prefixText: currencySymbolFor(_pricingCurrency),
              helperText: '10% platform fee is split automatically; provider keeps the rest.',
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
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(title: const Text('Service Settings')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'Provider controls',
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Set availability, notification preference, service pricing, and preferred payment rail. Customers see your price before payment; tax and payout split are added automatically.',
                    style: TextStyle(color: Color(0xFF64748B), height: 1.35),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Phone number for paid orders',
                      prefixIcon: Icon(Icons.phone_outlined),
                      helperText: 'Only shared after payment confirmation.',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Column(
                      children: [
                        SwitchListTile(
                          value: _isAvailable,
                          onChanged: (value) => setState(() => _isAvailable = value),
                          title: const Text('Available for service requests'),
                          subtitle: const Text('Slide off when you do not want new orders.'),
                          secondary: const Icon(Icons.online_prediction),
                        ),
                        const Divider(height: 1),
                        SwitchListTile(
                          value: _receiveRequestNotifications,
                          onChanged: (value) =>
                              setState(() => _receiveRequestNotifications = value),
                          title: const Text('Service request notifications'),
                          subtitle: const Text('Turn off to stop incoming order alerts.'),
                          secondary: const Icon(Icons.notifications_active_outlined),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFBFDBFE)),
                    ),
                    child: Text(
                      'Currency: $_pricingCurrency • Canadian customers pay 13% tax • Admin split: 10%',
                      style: const TextStyle(
                        color: Color(0xFF1E3A8A),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _serviceTile(
                    title: 'Regular Battery Boost',
                    subtitle: 'Default boost pricing for all app users',
                    enabled: _providesBoost,
                    onChanged: (value) => setState(() => _providesBoost = value),
                    priceController: _boostPriceController,
                    hint: '25.00',
                    icon: Icons.battery_charging_full,
                  ),
                  _serviceTile(
                    title: 'Tow Assistance',
                    subtitle: 'Tow requests near your location',
                    enabled: _providesTow,
                    onChanged: (value) => setState(() => _providesTow = value),
                    priceController: _towPriceController,
                    hint: '30.00',
                    icon: Icons.local_shipping_outlined,
                  ),
                  _serviceTile(
                    title: 'Mobile Mechanic',
                    subtitle: 'On-site mechanic service requests',
                    enabled: _providesMechanic,
                    onChanged: (value) => setState(() => _providesMechanic = value),
                    priceController: _mechanicPriceController,
                    hint: '35.00',
                    icon: Icons.build_circle_outlined,
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: _preferredPaymentProvider,
                    items: supportedPaymentProviders
                        .map(
                          (provider) => DropdownMenuItem<String>(
                            value: provider,
                            child: Text(provider.toUpperCase()),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _preferredPaymentProvider = value);
                      }
                    },
                    decoration: const InputDecoration(
                      labelText: 'Preferred payment provider',
                      prefixIcon: Icon(Icons.payments_outlined),
                      helperText: 'Stripe and Paystack are preferred; card/wallet are fallback rails.',
                    ),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isSaving ? null : _saveProfileSettings,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        backgroundColor: const Color(0xFF5500FF),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      child: _isSaving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              'Save Service Settings',
                              style: TextStyle(fontWeight: FontWeight.w800),
                            ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
