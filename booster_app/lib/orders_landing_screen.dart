import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'app_shell.dart';
import 'auth_routing.dart';
import 'boost_service_options.dart';
import 'customer_order_tracker_screen.dart';
import 'customer_screen.dart';
import 'home_screen.dart';
import 'main_bottom_nav.dart';
import 'profile_screen.dart';
import 'provider_status_screen.dart';

class OrdersLandingScreen extends StatefulWidget {
  const OrdersLandingScreen({
    this.showBottomNav = true,
    super.key,
  });

  final bool showBottomNav;

  @override
  State<OrdersLandingScreen> createState() => _OrdersLandingScreenState();
}

class _OrdersLandingScreenState extends State<OrdersLandingScreen> {
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _profileSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _customerOrdersSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _assignedOrdersSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _invitedOrdersSub;

  String? _role;
  bool _isLoading = true;
  final Map<String, _OrderListItem> _customerOrders = <String, _OrderListItem>{};
  final Map<String, _OrderListItem> _assignedOrders = <String, _OrderListItem>{};
  final Map<String, _OrderListItem> _invitedOrders = <String, _OrderListItem>{};
  List<_OrderListItem> _mergedOrders = const <_OrderListItem>[];

  bool get _isDriverRole => _role == driverRole;

  @override
  void initState() {
    super.initState();
    _bindProfileAndOrders();
  }

  @override
  void dispose() {
    _profileSub?.cancel();
    _customerOrdersSub?.cancel();
    _assignedOrdersSub?.cancel();
    _invitedOrdersSub?.cancel();
    super.dispose();
  }

  void _onTabSelected(BuildContext context, MainTab tab) {
    if (tab == MainTab.orders) return;

    final Widget destination;
    switch (tab) {
      case MainTab.home:
        destination = const HomeScreen();
        break;
      case MainTab.request:
        destination = const CustomerScreen();
        break;
      case MainTab.provider:
        destination = const ProviderStatusScreen();
        break;
      case MainTab.orders:
        return;
      case MainTab.profile:
        destination = const ProfileScreen();
        break;
    }

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => destination),
    );
  }

  void _bindProfileAndOrders() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() {
        _isLoading = false;
        _role = null;
      });
      return;
    }

    _profileSub?.cancel();
    _profileSub = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .snapshots()
        .listen((snapshot) {
      final data = snapshot.data() ?? <String, dynamic>{};
      final nextRole = normalizeRole(data['role']) ?? customerRole;
      final roleChanged = nextRole != _role;

      if (roleChanged) {
        _stopOrderStreams();
        _customerOrders.clear();
        _assignedOrders.clear();
        _invitedOrders.clear();
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _role = nextRole;
        _isLoading = false;
      });

      if (roleChanged) {
        _startOrderStreams(nextRole, user.uid);
      }
    }, onError: (_) {
      if (!mounted) {
        return;
      }
      setState(() => _isLoading = false);
    });
  }

  void _stopOrderStreams() {
    _customerOrdersSub?.cancel();
    _assignedOrdersSub?.cancel();
    _invitedOrdersSub?.cancel();
    _customerOrdersSub = null;
    _assignedOrdersSub = null;
    _invitedOrdersSub = null;
  }

  void _startOrderStreams(String role, String uid) {
    if (role == driverRole) {
      _assignedOrdersSub = FirebaseFirestore.instance
          .collection('requests')
          .where('driverId', isEqualTo: uid)
          .limit(80)
          .snapshots()
          .listen((snapshot) {
        _assignedOrders
          ..clear()
          ..addAll(_snapshotToOrderMap(snapshot));
        _rebuildMergedOrders();
      });

      _invitedOrdersSub = FirebaseFirestore.instance
          .collection('requests')
          .where('notifiedDriverIds', arrayContains: uid)
          .limit(80)
          .snapshots()
          .listen((snapshot) {
        final map = _snapshotToOrderMap(snapshot);
        _invitedOrders
          ..clear()
          ..addAll(
            map.map((id, order) {
              final isPendingUnassigned =
                  order.status == 'pending' && (order.driverId == null || order.driverId!.isEmpty);
              return MapEntry(id, isPendingUnassigned ? order : order.copyWith(hidden: true));
            }),
          );
        _rebuildMergedOrders();
      });
      return;
    }

    _customerOrdersSub = FirebaseFirestore.instance
        .collection('requests')
        .where('customerId', isEqualTo: uid)
        .limit(80)
        .snapshots()
        .listen((snapshot) {
      _customerOrders
        ..clear()
        ..addAll(_snapshotToOrderMap(snapshot));
      _rebuildMergedOrders();
    });
  }

  Map<String, _OrderListItem> _snapshotToOrderMap(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) {
    final result = <String, _OrderListItem>{};
    for (final doc in snapshot.docs) {
      final data = doc.data();
      result[doc.id] = _OrderListItem(
        id: doc.id,
        status: (data['status'] ?? 'pending').toString(),
        serviceType: (data['serviceType'] ?? 'boost').toString(),
        vehicleType: data['vehicleType']?.toString(),
        towType: data['towType']?.toString(),
        pickupAddress: (data['pickupAddress'] ?? 'Pickup location').toString(),
        customerId: data['customerId']?.toString(),
        driverId: data['driverId']?.toString(),
        timestamp: _toDateTime(data['timestamp']),
        statusUpdatedAt: _toDateTime(data['statusUpdatedAt']),
        totalAmountCents: _intOrNull(data['paymentAmount']) ??
            _sumMoney(
              _intOrNull(data['serviceBaseAmount']),
              _intOrNull(data['serviceTaxAmount']),
              _intOrNull(data['subscriptionBaseAmount']),
              _intOrNull(data['subscriptionTaxAmount']),
            ),
      );
    }
    return result;
  }

  DateTime? _toDateTime(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return null;
  }

  int? _intOrNull(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }

  int? _sumMoney(int? a, int? b, int? c, int? d) {
    final values = <int?>[a, b, c, d];
    if (values.every((value) => value == null)) {
      return null;
    }
    return (a ?? 0) + (b ?? 0) + (c ?? 0) + (d ?? 0);
  }

  void _rebuildMergedOrders() {
    final merged = <String, _OrderListItem>{};
    if (_isDriverRole) {
      for (final entry in _invitedOrders.entries) {
        if (!entry.value.hidden) {
          merged[entry.key] = entry.value;
        }
      }
      for (final entry in _assignedOrders.entries) {
        merged[entry.key] = entry.value;
      }
    } else {
      merged.addAll(_customerOrders);
    }

    final sorted = merged.values.toList(growable: false)
      ..sort((a, b) {
        final aMs = (a.timestamp ?? a.statusUpdatedAt)?.millisecondsSinceEpoch ?? 0;
        final bMs = (b.timestamp ?? b.statusUpdatedAt)?.millisecondsSinceEpoch ?? 0;
        return bMs.compareTo(aMs);
      });

    if (!mounted) {
      return;
    }
    setState(() => _mergedOrders = sorted);
  }

  bool _isActiveStatus(String status) {
    return status == 'awaiting_payment' ||
        status == 'paid' ||
        status == 'pending' ||
        status == 'searching' ||
        status == 'accepted' ||
        status == 'en_route' ||
        status == 'arrived';
  }

  _OrderListItem? _activeOrder() {
    for (final order in _mergedOrders) {
      if (_isActiveStatus(order.status)) {
        return order;
      }
    }
    return null;
  }

  int _countByStatus(bool Function(String status) matcher) {
    return _mergedOrders.where((order) => matcher(order.status)).length;
  }

  String _moneyLabel(int? amountCents) {
    if (amountCents == null || amountCents <= 0) {
      return 'N/A';
    }
    return '\$${(amountCents / 100.0).toStringAsFixed(2)}';
  }

  String _serviceLabel(_OrderListItem order) {
    if (order.serviceType == 'tow') {
      final towType = order.towType ?? '';
      if (towType == towTypeCar) return 'Tow • Car';
      if (towType == towTypePickupVan) return 'Tow • Pickup/Van';
      if (towType == towTypeSuv) return 'Tow • SUV';
      return 'Tow Service';
    }

    final vehicleType = order.vehicleType;
    if (vehicleType == electricVehicleType) {
      return 'Battery Boost • Electric';
    }
    return 'Battery Boost • Regular';
  }

  String _relativeTime(DateTime? timestamp) {
    if (timestamp == null) {
      return 'just now';
    }
    final diff = DateTime.now().difference(timestamp);
    if (diff.inMinutes < 1) {
      return '${diff.inSeconds.clamp(0, 59)}s ago';
    }
    if (diff.inHours < 1) {
      return '${diff.inMinutes}m ago';
    }
    if (diff.inDays < 1) {
      return '${diff.inHours}h ago';
    }
    return '${diff.inDays}d ago';
  }

  _OrderStatusMeta _statusMeta(String status) {
    switch (status) {
      case 'awaiting_payment':
        return const _OrderStatusMeta(
          title: 'Awaiting Payment',
          badge: 'PAY NOW',
          color: Color(0xFFD97706),
          icon: Icons.credit_card,
        );
      case 'paid':
      case 'pending':
      case 'searching':
        return const _OrderStatusMeta(
          title: 'Searching Providers',
          badge: 'SEARCHING',
          color: Color(0xFF4F46E5),
          icon: Icons.radar,
        );
      case 'accepted':
      case 'en_route':
        return const _OrderStatusMeta(
          title: 'Provider En Route',
          badge: 'ON THE WAY',
          color: Color(0xFF2563EB),
          icon: Icons.near_me,
        );
      case 'arrived':
        return const _OrderStatusMeta(
          title: 'Provider Arrived',
          badge: 'ARRIVED',
          color: Color(0xFF0F766E),
          icon: Icons.place,
        );
      case 'completed':
        return const _OrderStatusMeta(
          title: 'Completed',
          badge: 'COMPLETED',
          color: Color(0xFF16A34A),
          icon: Icons.check_circle,
        );
      case 'cancelled':
        return const _OrderStatusMeta(
          title: 'Cancelled',
          badge: 'CANCELLED',
          color: Color(0xFFDC2626),
          icon: Icons.cancel,
        );
      case 'no_boosters_available':
        return const _OrderStatusMeta(
          title: 'No Provider Available',
          badge: 'NO MATCH',
          color: Color(0xFFB45309),
          icon: Icons.search_off,
        );
      default:
        return const _OrderStatusMeta(
          title: 'Pending',
          badge: 'PENDING',
          color: Color(0xFF64748B),
          icon: Icons.hourglass_bottom,
        );
    }
  }

  void _openOrder(_OrderListItem order) {
    if (_isDriverRole) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ProviderStatusScreen(showBottomNav: false)),
      );
      return;
    }

    if (_isActiveStatus(order.status) || order.status == 'no_boosters_available') {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => CustomerOrderTrackerScreen(requestId: order.id)),
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CustomerScreen(showBottomNav: false)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeOrder = _activeOrder();
    final activeCount = _countByStatus(_isActiveStatus);
    final completedCount = _countByStatus((status) => status == 'completed');
    final issueCount = _countByStatus(
      (status) => status == 'cancelled' || status == 'no_boosters_available',
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(_isDriverRole ? 'Provider Orders' : 'Your Orders'),
      ),
      body: BoosterPageBackground(
        child: SafeArea(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  children: [
                    _OrdersHeroCard(
                      isDriver: _isDriverRole,
                      activeCount: activeCount,
                      completedCount: completedCount,
                      issueCount: issueCount,
                    ),
                    const SizedBox(height: 14),
                    if (activeOrder != null) ...[
                      _ActiveOrderSpotlight(
                        order: activeOrder,
                        statusMeta: _statusMeta(activeOrder.status),
                        serviceLabel: _serviceLabel(activeOrder),
                        amountLabel: _moneyLabel(activeOrder.totalAmountCents),
                        updatedLabel: _relativeTime(activeOrder.statusUpdatedAt ?? activeOrder.timestamp),
                        onOpen: () => _openOrder(activeOrder),
                        isDriver: _isDriverRole,
                      ),
                      const SizedBox(height: 14),
                    ],
                    BoosterSurfaceCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _isDriverRole ? 'Recent Opportunities & Jobs' : 'Recent Transactions',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _isDriverRole
                                ? 'Pending invites and assigned jobs are shown newest first.'
                                : 'Track every request state from payment to completion.',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: const Color(0xFF64748B)),
                          ),
                          const SizedBox(height: 14),
                          if (_mergedOrders.isEmpty)
                            _EmptyOrdersState(isDriver: _isDriverRole)
                          else
                            ..._mergedOrders.take(12).map((order) {
                              final meta = _statusMeta(order.status);
                              return _OrderRowCard(
                                orderId: order.id,
                                status: meta,
                                serviceLabel: _serviceLabel(order),
                                pickupAddress: order.pickupAddress,
                                amountLabel: _moneyLabel(order.totalAmountCents),
                                timeLabel: _relativeTime(order.timestamp ?? order.statusUpdatedAt),
                                onTap: () => _openOrder(order),
                              );
                            }),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ),
      bottomNavigationBar: widget.showBottomNav
          ? MainBottomNavBar(
              currentTab: MainTab.orders,
              onTabSelected: (tab) => _onTabSelected(context, tab),
            )
          : null,
    );
  }
}

class _OrderStatusMeta {
  const _OrderStatusMeta({
    required this.title,
    required this.badge,
    required this.color,
    required this.icon,
  });

  final String title;
  final String badge;
  final Color color;
  final IconData icon;
}

class _OrderListItem {
  const _OrderListItem({
    required this.id,
    required this.status,
    required this.serviceType,
    required this.pickupAddress,
    required this.customerId,
    required this.driverId,
    required this.timestamp,
    required this.statusUpdatedAt,
    required this.totalAmountCents,
    this.vehicleType,
    this.towType,
    this.hidden = false,
  });

  final String id;
  final String status;
  final String serviceType;
  final String? vehicleType;
  final String? towType;
  final String pickupAddress;
  final String? customerId;
  final String? driverId;
  final DateTime? timestamp;
  final DateTime? statusUpdatedAt;
  final int? totalAmountCents;
  final bool hidden;

  _OrderListItem copyWith({bool? hidden}) {
    return _OrderListItem(
      id: id,
      status: status,
      serviceType: serviceType,
      vehicleType: vehicleType,
      towType: towType,
      pickupAddress: pickupAddress,
      customerId: customerId,
      driverId: driverId,
      timestamp: timestamp,
      statusUpdatedAt: statusUpdatedAt,
      totalAmountCents: totalAmountCents,
      hidden: hidden ?? this.hidden,
    );
  }
}

class _OrdersHeroCard extends StatelessWidget {
  const _OrdersHeroCard({
    required this.isDriver,
    required this.activeCount,
    required this.completedCount,
    required this.issueCount,
  });

  final bool isDriver;
  final int activeCount;
  final int completedCount;
  final int issueCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0F172A), Color(0xFF1D4ED8), Color(0xFF0EA5E9)],
        ),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 18, offset: Offset(0, 8)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              isDriver ? 'PROVIDER OPERATIONS' : 'CUSTOMER TRANSACTIONS',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 11,
                letterSpacing: 0.8,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            isDriver ? 'Order Command Center' : 'Order Status Dashboard',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            isDriver
                ? 'See new opportunities, monitor active jobs, and track completions.'
                : 'Monitor payment, dispatch, live arrival, and completion in one timeline.',
            style: const TextStyle(
              color: Color(0xFFE2E8F0),
              fontSize: 13,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _MetricTile(label: 'Active', value: '$activeCount'),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _MetricTile(label: 'Completed', value: '$completedCount'),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _MetricTile(label: 'Issues', value: '$issueCount'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFFE2E8F0),
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActiveOrderSpotlight extends StatelessWidget {
  const _ActiveOrderSpotlight({
    required this.order,
    required this.statusMeta,
    required this.serviceLabel,
    required this.amountLabel,
    required this.updatedLabel,
    required this.onOpen,
    required this.isDriver,
  });

  final _OrderListItem order;
  final _OrderStatusMeta statusMeta;
  final String serviceLabel;
  final String amountLabel;
  final String updatedLabel;
  final VoidCallback onOpen;
  final bool isDriver;

  @override
  Widget build(BuildContext context) {
    return BoosterSurfaceCard(
      borderColor: statusMeta.color.withValues(alpha: 0.4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: statusMeta.color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(statusMeta.icon, color: statusMeta.color),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Active Order',
                      style: Theme.of(context)
                          .textTheme
                          .labelMedium
                          ?.copyWith(color: const Color(0xFF64748B)),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      statusMeta.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                  ],
                ),
              ),
              _StatusBadge(statusMeta: statusMeta),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  serviceLabel,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  order.pickupAddress,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: const Color(0xFF475569)),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Icon(Icons.payments_outlined, size: 16, color: Color(0xFF0F766E)),
                    const SizedBox(width: 6),
                    Text(
                      amountLabel,
                      style: const TextStyle(
                        color: Color(0xFF0F766E),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      updatedLabel,
                      style: const TextStyle(
                        color: Color(0xFF64748B),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: onOpen,
              icon: Icon(isDriver ? Icons.work_history : Icons.map_outlined),
              label: Text(isDriver ? 'Manage Active Job' : 'Open Live Tracker'),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.statusMeta});

  final _OrderStatusMeta statusMeta;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: statusMeta.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        statusMeta.badge,
        style: TextStyle(
          color: statusMeta.color,
          fontWeight: FontWeight.w800,
          fontSize: 11,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _OrderRowCard extends StatelessWidget {
  const _OrderRowCard({
    required this.orderId,
    required this.status,
    required this.serviceLabel,
    required this.pickupAddress,
    required this.amountLabel,
    required this.timeLabel,
    required this.onTap,
  });

  final String orderId;
  final _OrderStatusMeta status;
  final String serviceLabel;
  final String pickupAddress;
  final String amountLabel;
  final String timeLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE2E8F0)),
          color: Colors.white,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: status.color.withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(status.icon, color: status.color, size: 19),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          serviceLabel,
                          style: const TextStyle(
                            color: Color(0xFF0F172A),
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      Text(
                        amountLabel,
                        style: const TextStyle(
                          color: Color(0xFF0F766E),
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    pickupAddress,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _StatusBadge(statusMeta: status),
                      const Spacer(),
                      Text(
                        timeLabel,
                        style: const TextStyle(
                          color: Color(0xFF94A3B8),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Order #${orderId.substring(0, 6).toUpperCase()}',
                    style: const TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyOrdersState extends StatelessWidget {
  const _EmptyOrdersState({required this.isDriver});

  final bool isDriver;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        children: [
          Icon(
            isDriver ? Icons.notifications_active_outlined : Icons.receipt_long_outlined,
            size: 34,
            color: const Color(0xFF64748B),
          ),
          const SizedBox(height: 10),
          Text(
            isDriver ? 'No order activity yet' : 'No transactions yet',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          Text(
            isDriver
                ? 'When customers request service nearby, it will appear here.'
                : 'Your request and payment timeline will appear here after your first order.',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: const Color(0xFF64748B)),
          ),
        ],
      ),
    );
  }
}