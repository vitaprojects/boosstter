import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class TransactionTrackingScreen extends StatelessWidget {
  const TransactionTrackingScreen({super.key});

  String _fmtCadCents(int cents) => '\$${(cents / 100).toStringAsFixed(2)}';

  Color _statusColor(String status) {
    switch (status) {
      case 'paid':
        return const Color(0xFFF59E0B);
      case 'accepted':
      case 'en_route':
        return const Color(0xFF0EA5E9);
      case 'completed':
        return const Color(0xFF16A34A);
      case 'expired':
      case 'cancelled':
        return const Color(0xFFEF4444);
      default:
        return const Color(0xFF6B7280);
    }
  }

  String _serviceLabel(String serviceType) {
    switch (serviceType) {
      case 'tow':
        return 'Tow Assistance';
      case 'mobile_mechanic':
        return 'Mobile Mechanic';
      default:
        return 'Battery Boost';
    }
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'paid':
        return 'Waiting for Provider';
      case 'accepted':
        return 'Provider Accepted';
      case 'en_route':
        return 'Provider En Route';
      case 'completed':
        return 'Completed';
      case 'expired':
        return 'Expired';
      case 'cancelled':
        return 'Cancelled';
      default:
        return status;
    }
  }

  String _formatTime(Timestamp? ts) {
    if (ts == null) {
      return 'Unknown time';
    }
    final dt = ts.toDate().toLocal();
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '${dt.year}-$month-$day $hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final userId = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      appBar: AppBar(title: const Text('Transaction Tracking')),
      body: userId == null
          ? const Center(child: Text('Sign in to view transactions'))
          : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('requests')
                  .where('customerId', isEqualTo: userId)
                  .orderBy('timestamp', descending: true)
                  .limit(30)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (snapshot.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('Could not load transactions: ${snapshot.error}'),
                    ),
                  );
                }

                final docs = snapshot.data?.docs ?? <QueryDocumentSnapshot<Map<String, dynamic>>>[];
                if (docs.isEmpty) {
                  return const Center(
                    child: Text('No transactions yet'),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.all(14),
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final doc = docs[index];
                    final data = doc.data();
                    final status = (data['status'] ?? 'pending').toString();
                    final serviceType = (data['serviceType'] ?? 'boost').toString();
                    final pickupAddress = (data['pickupAddress'] ?? 'No pickup address').toString();
                    final timestamp = data['timestamp'] as Timestamp?;
                    final paidAt = data['paidAt'] as Timestamp?;
                    final acceptedAt = data['acceptedAt'] as Timestamp?;
                    final completedAt = data['completedAt'] as Timestamp?;
                    final cancelledAt = data['cancelledAt'] as Timestamp?;
                    final expiredAt = data['expiredAt'] as Timestamp?;
                    final paymentAmount = (data['paymentAmount'] as num?)?.toInt() ??
                      (data['totalChargeCents'] as num?)?.toInt() ??
                      (data['creditedAmountCents'] as num?)?.toInt() ??
                      0;
                    final paymentProvider = (data['paymentProvider'] ?? 'in_app').toString();
                    final creditApplied = data['creditApplied'] == true;
                    final creditedAmount = (data['creditedAmountCents'] as num?)?.toInt() ?? 0;
                    final refundRequestStatus = (data['refundRequestStatus'] ?? 'none').toString();
                    final statusColor = _statusColor(status);

                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFE5E7EB)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _serviceLabel(serviceType),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: statusColor.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  _statusLabel(status),
                                  style: TextStyle(
                                    color: statusColor,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            pickupAddress,
                            style: const TextStyle(color: Color(0xFF4B5563)),
                          ),
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF8FAFC),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: const Color(0xFFE5E7EB)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Payment: ${paymentAmount > 0 ? _fmtCadCents(paymentAmount) : 'N/A'} • ${paymentProvider.toUpperCase()}',
                                  style: const TextStyle(
                                    color: Color(0xFF0F172A),
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12,
                                  ),
                                ),
                                if (creditApplied || creditedAmount > 0) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    'Credit applied: ${_fmtCadCents(creditedAmount)}',
                                    style: const TextStyle(
                                      color: Color(0xFF065F46),
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                                if (refundRequestStatus != 'none') ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    'Refund request: $refundRequestStatus',
                                    style: const TextStyle(
                                      color: Color(0xFF7C3AED),
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _ActivityChip(
                                label: 'Requested ${_formatTime(timestamp)}',
                                color: const Color(0xFF475569),
                              ),
                              if (paidAt != null)
                                _ActivityChip(
                                  label: 'Paid ${_formatTime(paidAt)}',
                                  color: const Color(0xFFCA8A04),
                                ),
                              if (acceptedAt != null)
                                _ActivityChip(
                                  label: 'Accepted ${_formatTime(acceptedAt)}',
                                  color: const Color(0xFF0EA5E9),
                                ),
                              if (completedAt != null)
                                _ActivityChip(
                                  label: 'Completed ${_formatTime(completedAt)}',
                                  color: const Color(0xFF16A34A),
                                ),
                              if (cancelledAt != null)
                                _ActivityChip(
                                  label: 'Cancelled ${_formatTime(cancelledAt)}',
                                  color: const Color(0xFFDC2626),
                                ),
                              if (expiredAt != null)
                                _ActivityChip(
                                  label: 'Expired ${_formatTime(expiredAt)}',
                                  color: const Color(0xFFDC2626),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Request ID: ${doc.id}',
                            style: const TextStyle(
                              color: Color(0xFF6B7280),
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Created: ${_formatTime(timestamp)}',
                            style: const TextStyle(
                              color: Color(0xFF6B7280),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}

class _ActivityChip extends StatelessWidget {
  const _ActivityChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
