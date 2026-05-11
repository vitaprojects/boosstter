import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/services.dart';
import 'login_screen.dart';
import 'customer_screen.dart';

class DriverScreen extends StatefulWidget {
  const DriverScreen({super.key});

  @override
  State<DriverScreen> createState() => _DriverScreenState();
}

class _DriverScreenState extends State<DriverScreen> {
  bool _isAvailable = false;
  Timer? _locationTimer;
  Position? _currentPosition;
  int _providerTabIndex = 0; // 0=Order, 1=Requests

  // Active job state
  String? _activeRequestId;
  String? _activeRequestStatus; // pending | accepted | en_route | completed
  String? _activeServiceType;
  String? _activePickupAddress;
  double? _activePickupLat;
  double? _activePickupLng;
  String? _activeVehicleType;
  String? _activePlugType;
  String? _activeTowReason;
  StreamSubscription<QuerySnapshot>? _activeJobSub;
  StreamSubscription<QuerySnapshot>? _cancelledJobSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _incomingAlertSub;

  bool _providesBoost = true;
  bool _providesTow = false;
  bool _providesMechanic = false;
  String? _lastAlertedRequestId;

  String? _recentCancelledRequestId;
  String? _recentCancelledBy;
  DateTime? _recentCancelledAt;
  String? _recentCancelledServiceType;
  String? _recentCancelledPickupAddress;

  bool get _hasActiveJob =>
      _activeRequestId != null &&
      _activeRequestStatus != null &&
      _activeRequestStatus != 'completed' &&
      _activeRequestStatus != 'cancelled';

  @override
  void initState() {
    super.initState();
    _loadDriverData();
  }

  @override
  void dispose() {
    _locationTimer?.cancel();
    _activeJobSub?.cancel();
    _cancelledJobSub?.cancel();
    _incomingAlertSub?.cancel();
    super.dispose();
  }

  Future<void> _loadDriverData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();

    if (doc.exists && mounted) {
      final data = doc.data() ?? <String, dynamic>{};
      final offered = (data['offeredServices'] as Map<String, dynamic>?) ?? <String, dynamic>{};
      setState(() {
        _isAvailable = (data['isAvailable'] as bool?) ?? false;
        _providesBoost = (offered['boost'] as bool?) ?? true;
        _providesTow = (offered['tow'] as bool?) ?? false;
        _providesMechanic = (offered['mobile_mechanic'] as bool?) ?? false;
      });
      if (_isAvailable) _startLocationUpdates();
    }

    // Re-attach to any in-progress job
    _watchActiveJob();
    _watchRecentCancellation();
    _watchIncomingOrderAlerts();
  }

  bool _supportsService(String? serviceType) {
    switch (serviceType) {
      case 'tow':
        return _providesTow;
      case 'mobile_mechanic':
        return _providesMechanic;
      default:
        return _providesBoost;
    }
  }

  String _serviceLabel(String? serviceType) {
    switch (serviceType) {
      case 'tow':
        return 'Tow';
      case 'mobile_mechanic':
        return 'Mobile Mechanic';
      default:
        return 'Battery Boost';
    }
  }

  void _watchIncomingOrderAlerts() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _incomingAlertSub?.cancel();
    _incomingAlertSub = FirebaseFirestore.instance
        .collection('requests')
        .where('driverId', isEqualTo: user.uid)
        .where('status', isEqualTo: 'paid')
        .orderBy('timestamp', descending: true)
        .limit(1)
        .snapshots()
        .listen((snapshot) {
      if (!mounted || snapshot.docs.isEmpty) return;

      final doc = snapshot.docs.first;
      final serviceType = doc.data()['serviceType']?.toString();
      if (!_supportsService(serviceType)) {
        return;
      }

      if (_lastAlertedRequestId == doc.id) {
        return;
      }

      _lastAlertedRequestId = doc.id;
      SystemSound.play(SystemSoundType.alert);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('New ${_serviceLabel(serviceType)} request available near you.'),
          duration: const Duration(seconds: 3),
        ),
      );
    });
  }

  void _watchActiveJob() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _activeJobSub?.cancel();
    _activeJobSub = FirebaseFirestore.instance
        .collection('requests')
        .where('driverId', isEqualTo: user.uid)
      .where('status', whereIn: ['paid', 'accepted', 'en_route'])
        .orderBy('timestamp', descending: true)
        .limit(1)
        .snapshots()
        .listen((snap) {
          if (!mounted) return;
          if (snap.docs.isEmpty) {
            setState(() {
              _activeRequestId = null;
              _activeRequestStatus = null;
              _activeServiceType = null;
              _activePickupAddress = null;
              _activePickupLat = null;
              _activePickupLng = null;
              _activeVehicleType = null;
              _activePlugType = null;
              _activeTowReason = null;
            });
          } else {
            final doc = snap.docs.first;
            final data = doc.data();
            setState(() {
              _activeRequestId = doc.id;
              _activeRequestStatus = data['status'];
              _activeServiceType = data['serviceType']?.toString();
              _activePickupAddress = data['pickupAddress'];
              _activePickupLat = (data['pickupLatitude'] as num?)?.toDouble();
              _activePickupLng = (data['pickupLongitude'] as num?)?.toDouble();
              _activeVehicleType = data['vehicleType']?.toString();
              _activePlugType = data['plugType']?.toString();
              _activeTowReason = data['towReason']?.toString();
            });
          }
        });
  }

  void _watchRecentCancellation() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _cancelledJobSub?.cancel();
    _cancelledJobSub = FirebaseFirestore.instance
        .collection('requests')
        .where('driverId', isEqualTo: user.uid)
        .where('status', isEqualTo: 'cancelled')
        .orderBy('cancelledAt', descending: true)
        .limit(1)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      if (snap.docs.isEmpty) {
        setState(() {
          _recentCancelledRequestId = null;
          _recentCancelledBy = null;
          _recentCancelledAt = null;
          _recentCancelledServiceType = null;
          _recentCancelledPickupAddress = null;
        });
        return;
      }

      final doc = snap.docs.first;
      final data = doc.data();
      final cancelledTimestamp = data['cancelledAt'] as Timestamp?;
      setState(() {
        _recentCancelledRequestId = doc.id;
        _recentCancelledBy = data['cancelledBy']?.toString() ?? 'customer';
        _recentCancelledAt = cancelledTimestamp?.toDate();
        _recentCancelledServiceType = data['serviceType']?.toString();
        _recentCancelledPickupAddress = data['pickupAddress']?.toString();
      });
    });
  }

  void _startLocationUpdates() {
    _locationTimer?.cancel();
    _locationTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      await _updateLocation();
    });
  }

  void _stopLocationUpdates() {
    _locationTimer?.cancel();
    _locationTimer = null;
  }

  Future<void> _updateLocation() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      if (!mounted) return;
      setState(() => _currentPosition = position);
      await _pushLocationToFirestore();
    } catch (_) {}
  }

  Future<void> _pushLocationToFirestore() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null && _currentPosition != null) {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update({
        'isAvailable': _isAvailable,
        'latitude': _currentPosition!.latitude,
        'longitude': _currentPosition!.longitude,
      });
    }
  }

  Future<void> _toggleAvailability(bool value) async {
    if (value) {
      final permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Location permission required to go available')),
          );
        }
        return;
      }
      setState(() => _isAvailable = true);
      _startLocationUpdates();
      await _updateLocation(); // immediate first push
    } else {
      setState(() => _isAvailable = false);
      _stopLocationUpdates();
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .update({'isAvailable': false});
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(value ? 'You are now Available' : 'You are now Offline')),
      );
    }
  }

  Future<void> _acceptRequest(String requestId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    if (_hasActiveJob && _activeRequestId != null && _activeRequestId != requestId) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Complete your current order before accepting another one.'),
          ),
        );
      }
      return;
    }

    try {
      await FirebaseFirestore.instance
          .collection('requests')
          .doc(requestId)
          .update({
        'status': 'accepted',
        'driverId': user.uid,
        'driverEmail': user.email ?? '',
        'acceptedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to accept: $e')),
        );
      }
    }
  }

  Future<void> _updateJobStatus(String status) async {
    if (_activeRequestId == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('requests')
          .doc(_activeRequestId)
          .update({'status': status});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Update failed: $e')));
      }
    }
  }

  Future<void> _openRequestPage() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set(
        {
          'userId': user.uid,
          'email': user.email,
          'role': 'customer',
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CustomerScreen()),
    );
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: Text(
          _providerTabIndex == 0 ? 'Order' : 'Requests',
          style: const TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.bold),
        ),
        iconTheme: const IconThemeData(color: Color(0xFF0F172A)),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: () async {
              _stopLocationUpdates();
              _activeJobSub?.cancel();
              final user = FirebaseAuth.instance.currentUser;
              if (user != null) {
                await FirebaseFirestore.instance
                    .collection('users')
                    .doc(user.uid)
                    .update({'isAvailable': false});
              }
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
      body: _buildOrderPage(),
      bottomNavigationBar: NavigationBar(
        backgroundColor: Colors.white,
        indicatorColor: const Color(0xFF8B5CF6).withValues(alpha: 0.18),
        selectedIndex: _providerTabIndex,
        onDestinationSelected: (index) async {
          if (index == 1) {
            await _openRequestPage();
            if (!mounted) return;
            setState(() => _providerTabIndex = 0);
            return;
          }
          setState(() => _providerTabIndex = 0);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long),
            label: 'Order',
          ),
          NavigationDestination(
            icon: Icon(Icons.inbox_outlined),
            selectedIcon: Icon(Icons.inbox),
            label: 'Requests',
          ),
        ],
      ),
    );
  }

  Widget _buildOrderPage() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _buildAvailabilityCard(),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Transaction Summary',
                style: TextStyle(
                  color: Color(0xFF0F172A),
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Order ID: ${_activeRequestId ?? 'No active order'}',
                style: const TextStyle(color: Color(0xFF334155), fontSize: 13),
              ),
              const SizedBox(height: 4),
              Text(
                'Status: ${_activeRequestStatus ?? 'idle'}',
                style: const TextStyle(color: Color(0xFF334155), fontSize: 13),
              ),
              const SizedBox(height: 4),
              Text(
                'Service: ${_activeServiceType == 'tow' ? 'Tow Assistance' : _activeServiceType == 'mobile_mechanic' ? 'Mobile Mechanic' : 'Battery Boost'}',
                style: const TextStyle(color: Color(0xFF334155), fontSize: 13),
              ),
              if ((_activeServiceType == 'tow' || _activeServiceType == 'mobile_mechanic') &&
                  _activeTowReason != null) ...[
                const SizedBox(height: 4),
                Text(
                  _activeServiceType == 'mobile_mechanic'
                      ? 'Issue Type: $_activeTowReason'
                      : 'Tow Reason: $_activeTowReason',
                  style: const TextStyle(color: Color(0xFF334155), fontSize: 13),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),
        if (_hasActiveJob) ...[
          _buildActiveJobCard(),
        ] else ...[
          if (_recentCancelledRequestId != null) ...[
            _buildCancelledRequestCard(),
            const SizedBox(height: 12),
          ],
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: Text(
              _isAvailable
                  ? 'No active orders right now. Keep Requests tab open to catch new jobs quickly.'
                  : 'Go available to start receiving new orders.',
              style: const TextStyle(color: Color(0xFF475569)),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Text(
          'Pending Request Orders',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: const Color(0xFF0F172A),
                fontWeight: FontWeight.w800,
              ),
        ),
        const SizedBox(height: 10),
        if (_isAvailable)
          _buildIncomingRequestsList()
        else
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: const Text(
              'Go available to view pending request orders in your area.',
              style: TextStyle(color: Color(0xFF475569)),
            ),
          ),
        const SizedBox(height: 16),
        _buildOrderHistoryList(),
      ],
    );
  }

  Widget _buildRequestsPage() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _buildAvailabilityCard(),
        const SizedBox(height: 20),
        Text(
          _isAvailable ? 'Incoming Orders' : 'Go Available to See Orders',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        if (_isAvailable) _buildIncomingRequestsList(),
      ],
    );
  }

  Widget _buildAvailabilityCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _isAvailable
              ? const Color(0xFF22C55E).withValues(alpha: 0.5)
              : const Color(0xFFE5E7EB),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: _isAvailable
                  ? const Color(0xFF22C55E).withValues(alpha: 0.15)
                  : Colors.grey.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              _isAvailable ? Icons.bolt : Icons.bolt_outlined,
              color: _isAvailable ? const Color(0xFF22C55E) : Colors.grey,
              size: 26,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isAvailable ? 'Available for Boosts' : 'Currently Offline',
                  style: TextStyle(
                    color: _isAvailable ? const Color(0xFF16A34A) : const Color(0xFF334155),
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                if (_isAvailable && _currentPosition != null)
                  Text(
                    'Location updating every 5s',
                    style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                  )
                else
                  Text(
                    'Toggle to start receiving requests',
                    style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                  ),
              ],
            ),
          ),
          Switch(
            value: _isAvailable,
            onChanged: _hasActiveJob ? null : _toggleAvailability,
            activeColor: const Color(0xFF22C55E),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveJobCard() {
    final status = _activeRequestStatus ?? 'paid';
    final isTowOrder = _activeServiceType == 'tow';
    final isMechanicOrder = _activeServiceType == 'mobile_mechanic';
    final Color statusColor;
    final IconData statusIcon;
    final String statusLabel;
    final String actionLabel;
    final String nextStatus;

    switch (status) {
      case 'paid':
        statusColor = const Color(0xFFF59E0B);
        statusIcon = Icons.hourglass_top;
        statusLabel = isTowOrder
            ? 'Paid Tow Request'
            : isMechanicOrder
                ? 'Paid Mechanic Request'
                : 'Paid Boost Request';
        actionLabel = 'Accept Request';
        nextStatus = 'accepted';
        break;
      case 'accepted':
        statusColor = const Color(0xFF6366F1);
        statusIcon = Icons.directions_car;
        statusLabel = 'Heading to Customer';
        actionLabel = "I'm En Route";
        nextStatus = 'en_route';
        break;
      case 'en_route':
        statusColor = const Color(0xFF22D3EE);
        statusIcon = isTowOrder
          ? Icons.local_shipping
          : isMechanicOrder
            ? Icons.build_circle
            : Icons.electric_bolt;
        statusLabel = isTowOrder
          ? 'En Route — Towing in Progress'
          : isMechanicOrder
            ? 'En Route — Mechanical Service'
            : 'En Route — Boosting Now';
        actionLabel = 'Mark Completed';
        nextStatus = 'completed';
        break;
      default:
        statusColor = Colors.grey;
        statusIcon = Icons.info_outline;
        statusLabel = status;
        actionLabel = '';
        nextStatus = '';
    }

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: statusColor.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.12),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(
              children: [
                Icon(statusIcon, color: statusColor, size: 22),
                const SizedBox(width: 10),
                Text(
                  statusLabel,
                  style: TextStyle(
                    color: statusColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ),
          // Pickup info
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.location_on,
                        color: Color(0xFF6366F1), size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _activePickupAddress ?? 'Pickup location not set',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
                if (_activeVehicleType != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        isTowOrder
                            ? Icons.local_shipping
                          : isMechanicOrder
                            ? Icons.build
                            : (_activeVehicleType == 'electric'
                                ? Icons.ev_station
                                : Icons.directions_car),
                        color: const Color(0xFF22C55E),
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isTowOrder
                              ? 'Tow service${_activeTowReason == null ? '' : ' • $_activeTowReason'}'
                            : isMechanicOrder
                              ? 'Mechanic service${_activeTowReason == null ? '' : ' • $_activeTowReason'}'
                              : (_activeVehicleType == 'electric'
                                  ? 'Electric vehicle${_activePlugType == null ? '' : ' • $_activePlugType'}'
                                  : 'Regular vehicle'),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (_activePickupLat != null && _activePickupLng != null &&
                    _currentPosition != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.near_me,
                          color: Color(0xFF22D3EE), size: 16),
                      const SizedBox(width: 6),
                      Text(
                        '${(Geolocator.distanceBetween(_currentPosition!.latitude, _currentPosition!.longitude, _activePickupLat!, _activePickupLng!) / 1000).toStringAsFixed(1)} km away',
                        style: const TextStyle(
                          color: Color(0xFF22D3EE),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 20),
                if (actionLabel.isNotEmpty)
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: Icon(statusIcon, size: 18),
                    label: Text(actionLabel),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: statusColor,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () {
                      if (status == 'paid') {
                        _acceptRequest(_activeRequestId!);
                      } else {
                        _updateJobStatus(nextStatus);
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIncomingRequestsList() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const SizedBox.shrink();

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('requests')
          .where('driverId', isEqualTo: user.uid)
          .where('status', isEqualTo: 'paid')
          .orderBy('timestamp', descending: true)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Text('Error: ${snapshot.error}',
              style: const TextStyle(color: Colors.red));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final docs = snapshot.data!.docs;
        final filteredDocs = docs.where((doc) {
          final data = doc.data() as Map<String, dynamic>;
          final serviceType = data['serviceType']?.toString();
          return _supportsService(serviceType);
        }).toList();

        if (filteredDocs.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(32),
            alignment: Alignment.center,
            child: Column(
              children: [
                Icon(Icons.electric_bolt,
                    color: Colors.grey[600], size: 48),
                const SizedBox(height: 12),
                Text(
                  'Waiting for pending orders for your services...',
                  style:
                      TextStyle(color: Colors.grey[500], fontSize: 15),
                ),
              ],
            ),
          );
        }
        return Column(
          children: filteredDocs.map((doc) {
            final data = doc.data() as Map<String, dynamic>;
            final serviceType = data['serviceType']?.toString() ?? 'boost';
            final address = data['pickupAddress'] ?? 'Unknown location';
            final vehicleType = data['vehicleType']?.toString();
            final plugType = data['plugType']?.toString();
            final towReason = data['towReason']?.toString();
            final ts = data['timestamp'] as Timestamp?;
            final timeAgo = ts != null
                ? _formatTimeAgo(ts.toDate())
                : '';
            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: const Color(0xFFF59E0B).withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.person, color: Color(0xFF6366F1), size: 18),
                      const SizedBox(width: 8),
                        Text(
                          serviceType == 'tow'
                            ? 'Tow Request'
                            : serviceType == 'mobile_mechanic'
                              ? 'Mechanic Request'
                              : 'Boost Request',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 15)),
                      const Spacer(),
                      if (timeAgo.isNotEmpty)
                        Text(timeAgo,
                            style: TextStyle(
                                color: Colors.grey[500], fontSize: 12)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.location_on,
                          color: Color(0xFFF59E0B), size: 16),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(address,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 13)),
                      ),
                    ],
                  ),
                  if (vehicleType != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(
                          serviceType == 'tow'
                              ? Icons.local_shipping
                              : serviceType == 'mobile_mechanic'
                                ? Icons.build
                              : (vehicleType == 'electric'
                                  ? Icons.ev_station
                                  : Icons.directions_car),
                          color: const Color(0xFF22D3EE),
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            serviceType == 'tow'
                                ? 'Tow${towReason == null ? '' : ' • $towReason'}'
                              : serviceType == 'mobile_mechanic'
                                ? 'Mechanic${towReason == null ? '' : ' • $towReason'}'
                                : (vehicleType == 'electric'
                                    ? 'Electric${plugType == null ? '' : ' • $plugType'}'
                                    : 'Regular'),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => _acceptRequest(doc.id),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6366F1),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: const Text('Accept & Go',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildCancelledRequestCard() {
    final serviceLabel = _recentCancelledServiceType == 'tow'
        ? 'Tow Assistance'
        : _recentCancelledServiceType == 'mobile_mechanic'
            ? 'Mobile Mechanic'
            : 'Battery Boost';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF3F1D1D),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFCA5A5).withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.cancel_outlined, color: Color(0xFFFCA5A5), size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Recent Cancellation',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
              ),
              if (_recentCancelledAt != null)
                Text(
                  _formatTimeAgo(_recentCancelledAt!),
                  style: const TextStyle(color: Color(0xFFFECACA), fontSize: 12),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '$serviceLabel request was cancelled by ${_recentCancelledBy ?? 'customer'}.',
            style: const TextStyle(color: Color(0xFFFEE2E2), fontSize: 13),
          ),
          if (_recentCancelledPickupAddress != null) ...[
            const SizedBox(height: 6),
            Text(
              _recentCancelledPickupAddress!,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'Request ID: ${_recentCancelledRequestId ?? 'unknown'}',
            style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildOrderHistoryList() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const SizedBox.shrink();

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('requests')
          .where('driverId', isEqualTo: user.uid)
          .limit(50)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const SizedBox.shrink();
        }
        if (!snapshot.hasData) {
          return const SizedBox.shrink();
        }

        final docs = [...snapshot.data!.docs];
        docs.sort((a, b) {
          final aTs = (a.data() as Map<String, dynamic>)['timestamp'] as Timestamp?;
          final bTs = (b.data() as Map<String, dynamic>)['timestamp'] as Timestamp?;
          final aMillis = aTs?.millisecondsSinceEpoch ?? 0;
          final bMillis = bTs?.millisecondsSinceEpoch ?? 0;
          return bMillis.compareTo(aMillis);
        });

        final historyDocs = docs.where((doc) {
          final data = doc.data() as Map<String, dynamic>;
          final status = (data['status'] ?? '').toString();
          return status == 'completed' || status == 'cancelled' || status == 'expired';
        }).take(10).toList();

        if (historyDocs.isEmpty) {
          return const SizedBox.shrink();
        }

        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF111827),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Order History',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 10),
              ...historyDocs.map((doc) {
                final data = doc.data() as Map<String, dynamic>;
                final status = (data['status'] ?? 'unknown').toString();
                final serviceType = (data['serviceType'] ?? 'boost').toString();
                final address = (data['pickupAddress'] ?? 'No pickup address').toString();
                final statusColor = status == 'completed'
                    ? const Color(0xFF22C55E)
                    : const Color(0xFFEF4444);

                final serviceLabel = serviceType == 'tow'
                    ? 'Tow'
                    : serviceType == 'mobile_mechanic'
                        ? 'Mechanic'
                        : 'Boost';

                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            serviceLabel,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            status,
                            style: TextStyle(
                              color: statusColor,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        address,
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }

  String _formatTimeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${diff.inHours}h ago';
  }
}