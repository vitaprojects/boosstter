import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'app_shell.dart';
import 'booster_logo.dart';
import 'login_screen.dart';
import 'region_policy.dart';

class PaywallScreen extends StatefulWidget {
  const PaywallScreen({required this.purpose, super.key});

  final String purpose;

  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends State<PaywallScreen> {
  static const int _yearlyBaseCents = 1000;
  static const double _kPrimaryButtonHeight = 52;
  static const double _kPrimaryButtonRadius = 12;
  static const double _kLogoToHeadingSpacing = 20;
  static const double _kHeadingToSubtitleSpacing = 8;

  bool _isLoadingProfile = true;
  bool _isActivating = false;
  SupportedRegion _region = defaultSupportedRegion;

  Future<void> _activateSubscription() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() => _isActivating = true);

    final taxCents = taxAmountForRegion(_yearlyBaseCents, _region);
    final totalCents = _yearlyBaseCents + taxCents;

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .update({
            'isSubscribed': true,
            'subscriptionPlan': 'yearly',
            'subscriptionBaseAmountCents': _yearlyBaseCents,
            'subscriptionTaxAmountCents': taxCents,
            'subscriptionTotalAmountCents': totalCents,
            'subscriptionCurrency': _region.currencyCode,
            'subscriptionRegionCode': _region.code,
            'subscriptionPurpose': widget.purpose,
            'subscriptionStartedAt': FieldValue.serverTimestamp(),
            'subscriptionExpiresAt': Timestamp.fromDate(
              DateTime.now().add(const Duration(days: 365)),
            ),
            'updatedAt': FieldValue.serverTimestamp(),
          });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Yearly subscription activated: ${_formatMoney(totalCents)} ${_region.currencyCode}',
            ),
          ),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to activate subscription: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isActivating = false);
      }
    }
  }

  Future<void> _loadRegion() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) {
        setState(() => _isLoadingProfile = false);
      }
      return;
    }

    final snapshot =
        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get();
    final data = snapshot.data() ?? <String, dynamic>{};
    final regionCode = data['regionCode']?.toString();

    if (mounted) {
      setState(() {
        _region = resolveSupportedRegion(regionCode);
        _isLoadingProfile = false;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _loadRegion();
  }

  String _formatMoney(int cents) {
    final amount = cents / 100;
    return '\$${amount.toStringAsFixed(2)}';
  }

  @override
  Widget build(BuildContext context) {
    final taxCents = taxAmountForRegion(_yearlyBaseCents, _region);
    final totalCents = _yearlyBaseCents + taxCents;
    final moneyStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(color: Colors.grey[200], height: 1.4);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Yearly Subscription'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              if (context.mounted) {
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (context) => const LoginScreen()),
                  (route) => false,
                );
              }
            },
          ),
        ],
      ),
      body: BoosterPageBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child:
                _isLoadingProfile
                    ? const Center(child: CircularProgressIndicator())
                    : LayoutBuilder(
                      builder:
                          (context, constraints) => SingleChildScrollView(
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                minHeight: constraints.maxHeight,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const SizedBox(height: 16),
                                  const Center(
                                    child: BoosterLogo(
                                      size: 98,
                                      compact: true,
                                      showWordmark: true,
                                    ),
                                  ),
                                  const SizedBox(
                                    height: _kLogoToHeadingSpacing,
                                  ),
                                  BoosterSurfaceCard(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Text(
                                          'Subscribe to Continue',
                                          style:
                                              Theme.of(
                                                context,
                                              ).textTheme.headlineMedium,
                                          textAlign: TextAlign.center,
                                        ),
                                        const SizedBox(
                                          height: _kHeadingToSubtitleSpacing,
                                        ),
                                        Text(
                                          'Signup is free. A yearly subscription is required before you can request or provide a service call.',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodyLarge?.copyWith(
                                            color: Colors.grey[100],
                                            fontWeight: FontWeight.w600,
                                            height: 1.35,
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                        const SizedBox(height: 24),
                                        Card(
                                          margin: EdgeInsets.zero,
                                          elevation: 0,
                                          color: const Color(0x14FFFFFF),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              16,
                                            ),
                                          ),
                                          child: RadioListTile<String>(
                                            title: Text(
                                              'Yearly Plan',
                                              style:
                                                  Theme.of(
                                                    context,
                                                  ).textTheme.titleMedium,
                                            ),
                                            subtitle: Text(
                                              '${_formatMoney(_yearlyBaseCents)}/year + tax (${(_region.taxRate * 100).toStringAsFixed(1)}%) in ${_region.name}',
                                              style: Theme.of(
                                                context,
                                              ).textTheme.bodyMedium?.copyWith(
                                                color: Colors.grey[300],
                                              ),
                                            ),
                                            value: 'yearly',
                                            groupValue: 'yearly',
                                            onChanged: null,
                                          ),
                                        ),
                                        const SizedBox(height: 14),
                                        Text(
                                          'Base: ${_formatMoney(_yearlyBaseCents)} ${_region.currencyCode}',
                                          style: moneyStyle,
                                        ),
                                        Text(
                                          'Tax: ${_formatMoney(taxCents)} ${_region.currencyCode}',
                                          style: moneyStyle,
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          'Total: ${_formatMoney(totalCents)} ${_region.currencyCode}',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleLarge?.copyWith(
                                            color: Colors.greenAccent.shade400,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 24),
                                  ElevatedButton(
                                    onPressed:
                                        _isActivating
                                            ? null
                                            : _activateSubscription,
                                    style: ElevatedButton.styleFrom(
                                      minimumSize: const Size(
                                        double.infinity,
                                        _kPrimaryButtonHeight,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(
                                          _kPrimaryButtonRadius,
                                        ),
                                      ),
                                    ),
                                    child:
                                        _isActivating
                                            ? const SizedBox(
                                              width: 18,
                                              height: 18,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                            : const Text(
                                              'Activate Yearly Subscription',
                                            ),
                                  ),
                                  const SizedBox(height: 8),
                                ],
                              ),
                            ),
                          ),
                    ),
          ),
        ),
      ),
    );
  }
}
