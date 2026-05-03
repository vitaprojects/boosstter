import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'app_shell.dart';
import 'customer_order_tracker_screen.dart';
import 'customer_requests_tab_screen.dart';
import 'driver_screen.dart';
import 'home_screen.dart';
import 'main_bottom_nav.dart';
import 'orders_landing_screen.dart';
import 'profile_screen.dart';
import 'provider_status_screen.dart';

class CustomerPaymentConfirmationScreen extends StatefulWidget {
  const CustomerPaymentConfirmationScreen({
    required this.requestId,
    required this.serviceLabel,
    required this.totalAmountCents,
    super.key,
  });

  final String requestId;
  final String serviceLabel;
  final int totalAmountCents;

  @override
  State<CustomerPaymentConfirmationScreen> createState() =>
      _CustomerPaymentConfirmationScreenState();
}

class _CustomerPaymentConfirmationScreenState
    extends State<CustomerPaymentConfirmationScreen> {
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _requestSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _driverSub;

  String _status = 'paid';
  String? _driverId;
  int? _etaMinutes;
  double? _distanceKm;

  void _onTabSelected(MainTab tab) {
    if (tab == MainTab.request) return;

    final Widget destination;
    switch (tab) {
      case MainTab.home:
        destination = const HomeScreen();
        break;
      case MainTab.request:
        return;
      case MainTab.provider:
        destination = const ProviderStatusScreen();
        break;
      case MainTab.orders:
        destination = const OrdersLandingScreen();
        break;
      case MainTab.profile:
        destination = const ProfileScreen();
        break;
    }

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => destination),
    );
  }

  @override
  void initState() {
    super.initState();
    _watchRequest();
  }

  @override
  void dispose() {
    _requestSub?.cancel();
    _driverSub?.cancel();
    super.dispose();
  }

  void _watchRequest() {
    _requestSub?.cancel();
    _requestSub = FirebaseFirestore.instance
        .collection('requests')
        .doc(widget.requestId)
        .snapshots()
        .listen((snapshot) {
      if (!snapshot.exists || !mounted) return;
      final data = snapshot.data() ?? <String, dynamic>{};
      final driverId = data['driverId']?.toString();
      setState(() {
        _status = (data['status'] ?? 'paid').toString();
        _driverId = (driverId == null || driverId.isEmpty) ? null : driverId;
      });
      _watchDriver();
    });
  }

  void _watchDriver() {
    _driverSub?.cancel();
    final driverId = _driverId;
    if (driverId == null) {
      if (mounted) {
        setState(() {
          _etaMinutes = null;
          _distanceKm = null;
        });
      }
      return;
    }

    _driverSub = FirebaseFirestore.instance
        .collection('users')
        .doc(driverId)
        .snapshots()
        .listen((snapshot) {
      if (!snapshot.exists || !mounted) return;
      final data = snapshot.data() ?? <String, dynamic>{};
      setState(() {
        _etaMinutes = (data['etaMinutes'] as num?)?.toInt();
        _distanceKm = (data['distanceKm'] as num?)?.toDouble();
      });
    });
  }

  String _headline() {
    switch (_status) {
      case 'accepted':
      case 'en_route':
        return 'Provider accepted your request';
      case 'arrived':
        return 'Provider arrived at your location';
      case 'completed':
        return 'Service completed';
      case 'cancelled':
        return 'Request cancelled';
      case 'no_boosters_available':
        return 'No providers available right now';
      default:
        return 'Payment confirmed';
    }
  }

  String _subtitle() {
    if ((_status == 'accepted' || _status == 'en_route') &&
        _etaMinutes != null &&
        _distanceKm != null) {
      return 'ETA ${_etaMinutes!} min • ${_distanceKm!.toStringAsFixed(1)} km away';
    }
    if (_status == 'paid' || _status == 'searching' || _status == 'pending') {
      return 'We are notifying nearby providers now. Keep this page open for live updates.';
    }
    if (_status == 'no_boosters_available') {
      return 'Please try again shortly or update your pickup location.';
    }
    return 'Track your provider in real-time from the live tracker.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Payment Confirmation')),
      body: BoosterPageBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              BoosterSurfaceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Payment Received',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.serviceLabel,
                      style: const TextStyle(
                        color: Color(0xFF8A8A9A),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Total Paid: \$${(widget.totalAmountCents / 100).toStringAsFixed(2)}',
                      style: const TextStyle(
                        color: Color(0xFFF59E0B),
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              BoosterSurfaceCard(
                borderColor: const Color(0xFF22D3EE).withValues(alpha: 0.4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _headline(),
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _subtitle(),
                      style: const TextStyle(color: Color(0xFF8A8A9A)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (_etaMinutes != null || _distanceKm != null)
                BoosterSurfaceCard(
                  child: Row(
                    children: [
                      Expanded(
                        child: _MetricTile(
                          label: 'ETA',
                          value: _etaMinutes == null ? '--' : '${_etaMinutes!} min',
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _MetricTile(
                          label: 'Distance',
                          value: _distanceKm == null
                              ? '--'
                              : '${_distanceKm!.toStringAsFixed(1)} km',
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          CustomerOrderTrackerScreen(requestId: widget.requestId),
                    ),
                  );
                },
                icon: const Icon(Icons.map_outlined),
                label: const Text('Open Live Tracker'),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: MainBottomNavBar(
        currentTab: MainTab.request,
        onTabSelected: _onTabSelected,
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: const Color(0xFFF2F2F7),
        border: Border.all(color: const Color(0xFFE0E0E8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF8A8A9A),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              color: Color(0xFF1A1A2E),
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
