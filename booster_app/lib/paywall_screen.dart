import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'booster_logo.dart';
import 'login_screen.dart';

/// Pricing constants (CAD cents)
const int _yearlySubscriptionCents = 900; // $9.00
const int _boostServiceCents = 2000; // $20.00
const double _canadianTaxRate = 0.13;

class PaywallScreen extends StatefulWidget {
  const PaywallScreen({super.key, this.isFirstTimer = true, this.pickupAddress});

  /// If false, subscription row is hidden (user already subscribed)
  final bool isFirstTimer;

  /// Used to compute tax based on region
  final String? pickupAddress;

  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends State<PaywallScreen> {
  bool _isLoading = false;

  bool get _isCanadian {
    final addr = (widget.pickupAddress ?? '').toLowerCase();
    return addr.contains('ontario') ||
        addr.contains('canada') ||
        addr.contains(', on ') ||
        addr.contains(', qc') ||
        addr.contains(', bc');
  }

  int get _taxCents =>
      _isCanadian ? (_boostServiceCents * _canadianTaxRate).round() : 0;

  int get _totalCents =>
      _boostServiceCents +
      _taxCents +
      (widget.isFirstTimer ? _yearlySubscriptionCents : 0);

  String _fmt(int cents) => '\$${(cents / 100).toStringAsFixed(2)}';

  Future<void> _activateAndProceed() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    setState(() => _isLoading = true);
    try {
      if (widget.isFirstTimer) {
        await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
          'isSubscribed': true,
          'yearlySubscriptionPaid': true,
          'subscriptionStartedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red[700],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F3F7),
      appBar: AppBar(
        title: const Text('Confirm & Pay'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              if (context.mounted) {
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                  (route) => false,
                );
              }
            },
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            // Header
            const Center(child: BoosterLogo(size: 64, compact: true)),
            const SizedBox(height: 20),
            Text(
              widget.isFirstTimer ? 'Activate & Request Boost' : 'Request Boost',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              widget.isFirstTimer
                  ? 'One-time yearly access + today\'s service'
                  : 'Confirm service charge for today\'s boost',
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(color: Colors.grey[500]),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),

            // Subscription card (first-timers only)
            if (widget.isFirstTimer) ...[
              _SectionCard(
                icon: Icons.verified_user_rounded,
                iconColor: const Color(0xFF5500FF),
                title: 'Yearly Membership',
                subtitle: 'Unlock unlimited boost requests for 12 months',
                badge: 'First-timer',
                badgeColor: const Color(0xFF5500FF),
                trailing: _fmt(_yearlySubscriptionCents),
              ),
              const SizedBox(height: 12),
            ],

            // Service charge card
            _SectionCard(
              icon: Icons.bolt_rounded,
              iconColor: const Color(0xFF22D3EE),
              title: 'Battery Boost Service',
              subtitle: 'Roadside battery jump-start by a nearby provider',
              trailing: _fmt(_boostServiceCents),
            ),
            const SizedBox(height: 12),

            // Tax card (Canadian)
            if (_isCanadian) ...[
              _SectionCard(
                icon: Icons.receipt_long_rounded,
                iconColor: Colors.grey,
                title: 'HST / Tax (13%)',
                subtitle: 'Canadian regional tax applied to service charge',
                trailing: _fmt(_taxCents),
              ),
              const SizedBox(height: 12),
            ],

            // Total
            Container(
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 20),
              decoration: BoxDecoration(
                color: const Color(0xFF5500FF),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Total Due Today',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        _fmt(_totalCents),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.lock, color: Colors.white, size: 16),
                        SizedBox(width: 6),
                        Text(
                          'Secure',
                          style: TextStyle(color: Colors.white, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),

            // CTA
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _activateAndProceed,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF5500FF),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: _isLoading
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(
                        'Continue to Payment · ${_fmt(_totalCents)}',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 14),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(false),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.grey[600],
                side: const BorderSide(color: Colors.black26),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              child: const Text('Cancel', style: TextStyle(fontSize: 16)),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.lock, size: 14, color: Colors.grey),
                const SizedBox(width: 6),
                Text(
                  'Payments secured by Stripe',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.grey),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.badge,
    this.badgeColor,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final String trailing;
  final String? badge;
  final Color? badgeColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE1E2EA)),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: iconColor, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    if (badge != null) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: badgeColor?.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: badgeColor?.withValues(alpha: 0.4) ??
                                Colors.transparent,
                          ),
                        ),
                        child: Text(
                          badge!,
                          style: TextStyle(
                            color: badgeColor,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            trailing,
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 16,
              color: Color(0xFF1F2233),
            ),
          ),
        ],
      ),
    );
  }
}


class _PaywallScreenState extends State<PaywallScreen> {
  String _selectedPlan = 'monthly';

  Future<void> _activateSubscription() async {
    User? user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update({
        'isSubscribed': true,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Subscription activated!')),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to activate subscription: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Booster'),
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
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 40),
            const Center(child: BoosterLogo(size: 86, compact: true)),
            const SizedBox(height: 24),
            Text(
              'Unlock Booster Premium',
              style: Theme.of(context).textTheme.headlineMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Text(
              'Get access to ride requests, priority matching, and exclusive features.',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Colors.grey[400],
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 40),
            Text(
              'Choose your plan:',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 20),
            Card(
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: RadioListTile<String>(
                title: Text(
                  'Monthly Plan',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                subtitle: Text(
                  '\$9.99/month',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.grey[400],
                  ),
                ),
                value: 'monthly',
                groupValue: _selectedPlan,
                onChanged: (value) {
                  setState(() => _selectedPlan = value!);
                },
              ),
            ),
            const SizedBox(height: 12),
            Card(
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: RadioListTile<String>(
                title: Text(
                  'Yearly Plan',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                subtitle: Text(
                  '\$99/year (Save 17%)',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.grey[400],
                  ),
                ),
                value: 'yearly',
                groupValue: _selectedPlan,
                onChanged: (value) {
                  setState(() => _selectedPlan = value!);
                },
              ),
            ),
            const Spacer(),
            ElevatedButton(
              onPressed: _activateSubscription,
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('Activate Subscription'),
            ),
          ],
        ),
      ),
    );
  }
}