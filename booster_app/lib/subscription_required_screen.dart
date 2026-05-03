import 'package:flutter/material.dart';

import 'app_shell.dart';

class SubscriptionRequiredScreen extends StatelessWidget {
  const SubscriptionRequiredScreen({
    required this.subscriptionBaseAmountCents,
    required this.subscriptionTaxAmountCents,
    required this.subscriptionCurrencyCode,
    required this.serviceTotalAmountCents,
    super.key,
  });

  final int subscriptionBaseAmountCents;
  final int subscriptionTaxAmountCents;
  final String subscriptionCurrencyCode;
  final int serviceTotalAmountCents;

  int get subscriptionTotalAmountCents =>
      subscriptionBaseAmountCents + subscriptionTaxAmountCents;

  int get combinedTotalAmountCents =>
      serviceTotalAmountCents + subscriptionTotalAmountCents;

  String _money(int cents) => '\$${(cents / 100).toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    final bool hasSubscription = subscriptionBaseAmountCents == 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(hasSubscription ? 'Confirm Payment' : 'Yearly Subscription'),
      ),
      body: BoosterPageBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              BoosterSurfaceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hasSubscription ? 'Service Payment' : 'Subscription Required',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      hasSubscription
                          ? 'Review your service charge below before confirming payment.'
                          : 'Before your first request or provider action, a yearly subscription is required. It will be added to this checkout.',
                      style: const TextStyle(
                        color: Color(0xFF8A8A9A),
                        fontSize: 14,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              BoosterSurfaceCard(
                child: Column(
                  children: [
                    if (!hasSubscription) ...[
                      _Line(
                        label: 'Yearly Subscription',
                        value: _money(subscriptionBaseAmountCents),
                      ),
                      const SizedBox(height: 8),
                      _Line(
                        label: 'Subscription Tax',
                        value: _money(subscriptionTaxAmountCents),
                      ),
                      const SizedBox(height: 8),
                      _Line(
                        label: 'Subscription Total',
                        value: '${_money(subscriptionTotalAmountCents)} $subscriptionCurrencyCode',
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 10),
                        child: Divider(color: Color(0xFFE0E0E8)),
                      ),
                    ],
                    _Line(label: 'Service Total', value: _money(serviceTotalAmountCents)),
                    if (!hasSubscription) ...[
                      const SizedBox(height: 8),
                      _Line(
                        label: 'Checkout Total',
                        value: _money(combinedTotalAmountCents),
                        bold: true,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 18),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Continue to Payment'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({
    required this.label,
    required this.value,
    this.bold = false,
  });

  final String label;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: bold ? const Color(0xFF1A1A2E) : const Color(0xFF8A8A9A),
            fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: bold ? const Color(0xFF1A1A2E) : const Color(0xFF8A8A9A),
            fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
