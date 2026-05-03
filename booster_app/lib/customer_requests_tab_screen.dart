import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'app_shell.dart';
import 'customer_order_tracker_screen.dart';
import 'customer_screen.dart';

class CustomerRequestsTabScreen extends StatefulWidget {
  const CustomerRequestsTabScreen({
    this.showBottomNav = true,
    super.key,
  });

  final bool showBottomNav;

  @override
  State<CustomerRequestsTabScreen> createState() => _CustomerRequestsTabScreenState();
}

class _CustomerRequestsTabScreenState extends State<CustomerRequestsTabScreen> {
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _latestRequestSub;
  late final Timer _ticker;

  String? _requestId;
  String? _status;
  DateTime? _requestCreatedAt;
  DateTime? _searchStartedAt;
  String _pickupAddress = 'No pickup address yet';
  int? _etaMinutes;
  double? _distanceKm;
  bool _isRestartingSearch = false;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
    _watchLatestRequest();
  }

  @override
  void dispose() {
    _ticker.cancel();
    _latestRequestSub?.cancel();
    super.dispose();
  }

  bool get _hasTrackableRequest {
    final status = _status;
    if (status == null) return false;
    return status != 'completed' &&
        status != 'cancelled' &&
        status != 'no_boosters_available';
  }

  bool get _needsSearchAgainAction {
    final status = _status;
    return status == 'no_boosters_available';
  }

  bool get _showCountdown {
    final status = _status;
    return status == 'paid' ||
        status == 'pending' ||
        status == 'searching' ||
        status == 'accepted' ||
        status == 'en_route' ||
        status == 'arrived' ||
        status == 'no_boosters_available';
  }

  DateTime? _toDateTime(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return null;
  }

  Duration _countdownRemaining() {
    final anchor = _searchStartedAt ?? _requestCreatedAt;
    if (anchor == null) {
      return Duration.zero;
    }
    final endTime = anchor.add(const Duration(minutes: 20));
    final remaining = endTime.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  String _formatRemaining(Duration remaining) {
    final minutes = remaining.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = remaining.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  void _watchLatestRequest() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return;
    }

    _latestRequestSub?.cancel();
    _latestRequestSub = FirebaseFirestore.instance
        .collection('requests')
        .where('customerId', isEqualTo: user.uid)
        .snapshots()
        .listen((snapshot) {
      if (!mounted) return;
      if (snapshot.docs.isEmpty) {
        setState(() {
          _requestId = null;
          _status = null;
          _requestCreatedAt = null;
          _searchStartedAt = null;
          _pickupAddress = 'No pickup address yet';
          _etaMinutes = null;
          _distanceKm = null;
        });
        return;
      }

      // Sort client-side (no composite index required)
      final sorted = snapshot.docs.toList()
        ..sort((a, b) {
          final aTs = a.data()['timestamp'];
          final bTs = b.data()['timestamp'];
          final aTime = aTs is Timestamp ? aTs.millisecondsSinceEpoch : 0;
          final bTime = bTs is Timestamp ? bTs.millisecondsSinceEpoch : 0;
          return bTime.compareTo(aTime); // descending
        });
      final latest = sorted.first;
      final data = latest.data();
      setState(() {
        _requestId = latest.id;
        _status = (data['status'] ?? 'pending').toString();
        _requestCreatedAt = _toDateTime(data['timestamp']);
        _searchStartedAt = _toDateTime(data['dispatchAttemptedAt']) ?? _toDateTime(data['timestamp']);
        _pickupAddress = (data['pickupAddress'] ?? 'No pickup address yet').toString();
        _etaMinutes = (data['driverEtaMinutes'] as num?)?.toInt();
        _distanceKm = (data['driverDistanceKm'] as num?)?.toDouble();
      });
    });
  }

  Future<void> _restartSearch() async {
    final requestId = _requestId;
    if (requestId == null || _isRestartingSearch) {
      return;
    }

    setState(() => _isRestartingSearch = true);
    try {
      final callable = FirebaseFunctions.instanceFor(region: 'northamerica-northeast1')
          .httpsCallable('dispatchBoosterNotifications');
      final response = await callable.call(<String, dynamic>{'requestId': requestId});
      final data = Map<String, dynamic>.from(response.data as Map<dynamic, dynamic>);
      final notifiedCount = (data['notifiedCount'] as num?)?.toInt() ?? 0;

      if (!mounted) return;
      setState(() {
        _searchStartedAt = DateTime.now();
        _status = notifiedCount > 0 ? 'searching' : 'no_boosters_available';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            notifiedCount > 0
                ? 'Search restarted. Notified $notifiedCount providers.'
                : 'Search restarted. No providers available yet.',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to restart search right now.')),
      );
    } finally {
      if (mounted) {
        setState(() => _isRestartingSearch = false);
      }
    }
  }

  String _statusTitle() {
    switch (_status) {
      case 'awaiting_payment':
        return 'Payment required to dispatch';
      case 'paid':
      case 'pending':
      case 'searching':
        return 'Finding nearby provider';
      case 'accepted':
      case 'en_route':
        return 'Provider on the way';
      case 'arrived':
        return 'Provider has arrived';
      case 'completed':
        return 'Request completed';
      case 'cancelled':
        return 'Request cancelled';
      case 'no_boosters_available':
        return 'No providers available';
      default:
        return 'No active request';
    }
  }

  Color _statusTone() {
    switch (_status) {
      case 'accepted':
      case 'en_route':
        return const Color(0xFF2563EB);
      case 'arrived':
        return const Color(0xFF16A34A);
      case 'completed':
        return const Color(0xFF0F766E);
      case 'no_boosters_available':
      case 'cancelled':
        return const Color(0xFFDC2626);
      case 'awaiting_payment':
        return const Color(0xFFD97706);
      case 'paid':
      case 'pending':
      case 'searching':
        return const Color(0xFF4338CA);
      default:
        return const Color(0xFF64748B);
    }
  }

  String _statusBadge() {
    switch (_status) {
      case 'accepted':
      case 'en_route':
        return 'EN ROUTE';
      case 'arrived':
        return 'ARRIVED';
      case 'completed':
        return 'COMPLETED';
      case 'cancelled':
        return 'CANCELLED';
      case 'no_boosters_available':
        return 'NO PROVIDER';
      case 'awaiting_payment':
        return 'PAYMENT NEEDED';
      case 'paid':
      case 'pending':
      case 'searching':
        return 'SEARCHING';
      default:
        return 'NO ACTIVE ORDER';
    }
  }

  String _statusSubtitle() {
    if (_status == 'accepted' || _status == 'en_route') {
      if (_etaMinutes != null && _distanceKm != null) {
        return 'ETA ${_etaMinutes!} min • ${_distanceKm!.toStringAsFixed(1)} km away';
      }
      return 'Live tracking is available for this request.';
    }
    if (_status == 'awaiting_payment') {
      return 'Complete payment from the Request tab to dispatch your provider.';
    }
    if (_status == 'paid' || _status == 'pending' || _status == 'searching') {
      return 'Your request is active and we are notifying nearby providers now.';
    }
    if (_status == null) {
      return 'Start a request to track status updates here.';
    }
    return 'Open Request tab for additional actions.';
  }

  void _openTracker() {
    final requestId = _requestId;
    if (requestId == null) {
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CustomerOrderTrackerScreen(requestId: requestId),
      ),
    );
  }

  void _openRequestFlow() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const CustomerScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final countdown = _countdownRemaining();
    final tone = _statusTone();
    final hasActiveOrder = _status != null;

    return Scaffold(
      body: BoosterPageBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFEFF3FF), Color(0xFFF8FAFF)],
                  ),
                  border: Border.all(color: const Color(0xFFDFE7FF)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: tone.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(Icons.radar_rounded, color: tone),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Orders',
                            style: TextStyle(
                              color: Color(0xFF1A1A2E),
                              fontSize: 28,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.3,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Request status, tracking, and countdown in one place.',
                            style: TextStyle(
                              color: Color(0xFF64748B),
                              fontSize: 13,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              BoosterSurfaceCard(
                borderColor: tone.withValues(alpha: 0.45),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: tone.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        _statusBadge(),
                        style: TextStyle(
                          color: tone,
                          fontWeight: FontWeight.w800,
                          fontSize: 11,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _statusTitle(),
                      style: const TextStyle(
                        color: Color(0xFF0F172A),
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _statusSubtitle(),
                      style: const TextStyle(
                        color: Color(0xFF64748B),
                        fontSize: 14,
                        height: 1.45,
                      ),
                    ),
                    if (_showCountdown) ...[
                      const SizedBox(height: 14),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'COUNTDOWN',
                              style: TextStyle(
                                color: Color(0xFFCBD5E1),
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8,
                              ),
                            ),
                            Text(
                              '${_formatRemaining(countdown)} / 20:00',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 26,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.6,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (hasActiveOrder) ...[
                      const SizedBox(height: 14),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFF),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.place_outlined, color: Color(0xFF2563EB)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _pickupAddress,
                                style: const TextStyle(
                                  color: Color(0xFF334155),
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    if (_needsSearchAgainAction) ...[
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _isRestartingSearch ? null : _restartSearch,
                          icon: _isRestartingSearch
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.refresh_rounded),
                          label: Text(
                            _isRestartingSearch ? 'Restarting Search...' : 'Restart Search',
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    if (_hasTrackableRequest)
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _openTracker,
                          icon: const Icon(Icons.map_outlined),
                          label: const Text('Open Live Tracker'),
                        ),
                      )
                    else
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _openRequestFlow,
                          icon: const Icon(Icons.add_circle_outline),
                          label: const Text('Start New Request'),
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
