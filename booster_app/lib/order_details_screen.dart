import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'app_shell.dart';

class OrderDetailsScreen extends StatefulWidget {
  const OrderDetailsScreen({
    required this.customerId,
    required this.serviceLabel,
    required this.pickupAddress,
    required this.postedLabel,
    required this.distanceLabel,
    required this.etaLabel,
    required this.onAcceptOrder,
    super.key,
  });

  final String customerId;
  final String serviceLabel;
  final String pickupAddress;
  final String postedLabel;
  final String distanceLabel;
  final String etaLabel;
  final Future<bool> Function() onAcceptOrder;

  @override
  State<OrderDetailsScreen> createState() => _OrderDetailsScreenState();
}

class _OrderDetailsScreenState extends State<OrderDetailsScreen> {
  bool _isAccepting = false;

  Future<void> _acceptOrder() async {
    if (_isAccepting) return;

    setState(() => _isAccepting = true);
    final accepted = await widget.onAcceptOrder();
    if (!mounted) return;

    setState(() => _isAccepting = false);
    if (accepted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Order Details')),
      body: BoosterPageBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              BoosterSurfaceCard(
                child: FutureBuilder<String>(
                  future: _loadOrderCustomerName(widget.customerId),
                  builder: (context, snapshot) {
                    final customerName = snapshot.data ?? 'Customer';
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          customerName,
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          widget.serviceLabel,
                          style: const TextStyle(
                            color: Color(0xFF22D3EE),
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 18),
                        _DetailRow(
                          icon: Icons.location_on_outlined,
                          label: 'Pickup',
                          value: widget.pickupAddress,
                        ),
                        const SizedBox(height: 14),
                        _DetailRow(
                          icon: Icons.near_me_outlined,
                          label: 'Distance',
                          value: widget.distanceLabel,
                        ),
                        const SizedBox(height: 14),
                        _DetailRow(
                          icon: Icons.schedule,
                          label: 'ETA',
                          value: widget.etaLabel,
                        ),
                        if (widget.postedLabel.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          _DetailRow(
                            icon: Icons.access_time,
                            label: 'Posted',
                            value: widget.postedLabel,
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              BoosterSurfaceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Next step',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Accept this order to claim it and move it into your active job flow.',
                      style: TextStyle(
                        color: Colors.grey[600],
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _isAccepting ? null : _acceptOrder,
                        icon: _isAccepting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.check_circle_outline),
                        label: Text(_isAccepting ? 'Accepting...' : 'Accept Order'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF22C55E),
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: const Color(0xFFF59E0B), size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

Future<String> _loadOrderCustomerName(String customerId) async {
  if (customerId.isEmpty) return 'Customer';

  try {
    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(customerId)
        .get();
    final data = snapshot.data() ?? <String, dynamic>{};
    final fullName = data['fullName']?.toString().trim() ?? '';
    if (fullName.isNotEmpty) return fullName;
    final displayName = data['displayName']?.toString().trim() ?? '';
    if (displayName.isNotEmpty) return displayName;
    final email = data['email']?.toString().trim() ?? '';
    if (email.isNotEmpty) return email;
  } catch (_) {
    return 'Customer';
  }

  return 'Customer';
}