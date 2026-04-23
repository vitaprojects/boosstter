import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'login_screen.dart';

class DriverScreen extends StatefulWidget {
  const DriverScreen({super.key});

  @override
  State<DriverScreen> createState() => _DriverScreenState();
}

class _DriverScreenState extends State<DriverScreen> {
  bool _isAvailable = false;
  Timer? _locationTimer;
  Position? _currentPosition;

  // Active job state
  String? _activeRequestId;
  String? _activeRequestStatus; // pending | accepted | en_route | completed
  String? _activePickupAddress;
  double? _activePickupLat;
  double? _activePickupLng;
  String? _activeVehicleType;
  String? _activePlugType;
  StreamSubscription<QuerySnapshot>? _activeJobSub;

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
      setState(() {
        _isAvailable = doc['isAvailable'] ?? false;
      });
      if (_isAvailable) _startLocationUpdates();
    }

    // Re-attach to any in-progress job
    _watchActiveJob();
  }

  void _watchActiveJob() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _activeJobSub?.cancel();
    _activeJobSub = FirebaseFirestore.instance
        .collection('requests')
        .where('driverId', isEqualTo: user.uid)
        .where('status', whereIn: ['pending', 'awaiting_payment', 'paid', 'accepted', 'en_route'])
        .orderBy('timestamp', descending: true)
        .limit(1)
        .snapshots()
        .listen((snap) {
          if (!mounted) return;
          if (snap.docs.isEmpty) {
            setState(() {
              _activeRequestId = null;
              _activeRequestStatus = null;
              _activePickupAddress = null;
              _activePickupLat = null;
              _activePickupLng = null;
              _activeVehicleType = null;
              _activePlugType = null;
            });
          } else {
            final doc = snap.docs.first;
            final data = doc.data();
            setState(() {
              _activeRequestId = doc.id;
              _activeRequestStatus = data['status'];
              _activePickupAddress = data['pickupAddress'];
              _activePickupLat = (data['pickupLatitude'] as num?)?.toDouble();
              _activePickupLng = (data['pickupLongitude'] as num?)?.toDouble();
              _activeVehicleType = data['vehicleType']?.toString();
              _activePlugType = data['plugType']?.toString();
            });
          }
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
    try {
      await FirebaseFirestore.instance
          .collection('requests')
          .doc(requestId)
          .update({
        'status': 'awaiting_payment',
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

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Give a Boost',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        iconTheme: const IconThemeData(color: Colors.white),
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
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _buildAvailabilityCard(),
          const SizedBox(height: 24),
          if (_hasActiveJob) ...[
            _buildActiveJobCard(),
            const SizedBox(height: 24),
          ],
          if (!_hasActiveJob) ...[
            Text(
              _isAvailable ? 'Incoming Requests' : 'Go Available to See Requests',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            if (_isAvailable) _buildIncomingRequestsList(),
          ],
        ],
      ),
    );
  }

  Widget _buildAvailabilityCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _isAvailable
              ? const Color(0xFF22C55E).withValues(alpha: 0.5)
              : Colors.grey.withValues(alpha: 0.2),
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
                    color: _isAvailable ? const Color(0xFF22C55E) : Colors.grey[400],
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                if (_isAvailable && _currentPosition != null)
                  Text(
                    'Location updating every 5s',
                    style: TextStyle(color: Colors.grey[500], fontSize: 12),
                  )
                else
                  Text(
                    'Toggle to start receiving requests',
                    style: TextStyle(color: Colors.grey[500], fontSize: 12),
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
    final status = _activeRequestStatus ?? 'pending';
    final Color statusColor;
    final IconData statusIcon;
    final String statusLabel;
    final String actionLabel;
    final String nextStatus;

    switch (status) {
      case 'pending':
        statusColor = const Color(0xFFF59E0B);
        statusIcon = Icons.hourglass_top;
        statusLabel = 'New Boost Request';
        actionLabel = 'Accept Request';
        nextStatus = 'awaiting_payment';
        break;
      case 'awaiting_payment':
        statusColor = const Color(0xFFF59E0B);
        statusIcon = Icons.payment;
        statusLabel = 'Waiting for Customer Payment';
        actionLabel = '';
        nextStatus = '';
        break;
      case 'paid':
        statusColor = const Color(0xFF22C55E);
        statusIcon = Icons.check_circle;
        statusLabel = 'Payment Received — Head to Customer';
        actionLabel = "I'm En Route";
        nextStatus = 'en_route';
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
        statusIcon = Icons.electric_bolt;
        statusLabel = 'En Route — Boosting Now';
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
                        _activeVehicleType == 'electric'
                            ? Icons.ev_station
                            : Icons.directions_car,
                        color: const Color(0xFF22C55E),
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _activeVehicleType == 'electric'
                              ? 'Electric vehicle${_activePlugType == null ? '' : ' • $_activePlugType'}'
                              : 'Regular vehicle',
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
                      if (status == 'pending') {
                        _acceptRequest(_activeRequestId!);
                      } else {
                        _updateJobStatus(nextStatus);
                      }
                    },
                  ),
                ),
                if (status == 'awaiting_payment') ...[
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: statusColor),
                      ),
                      const SizedBox(width: 8),
                      Text('Waiting for customer to pay...',
                          style: TextStyle(color: statusColor, fontSize: 13)),
                    ],
                  ),
                ],
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
          .where('status', isEqualTo: 'pending')
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
        if (docs.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(32),
            alignment: Alignment.center,
            child: Column(
              children: [
                Icon(Icons.electric_bolt,
                    color: Colors.grey[600], size: 48),
                const SizedBox(height: 12),
                Text(
                  'Waiting for boost requests...',
                  style:
                      TextStyle(color: Colors.grey[500], fontSize: 15),
                ),
              ],
            ),
          );
        }
        return Column(
          children: docs.map((doc) {
            final data = doc.data() as Map<String, dynamic>;
            final address = data['pickupAddress'] ?? 'Unknown location';
            final vehicleType = data['vehicleType']?.toString();
            final plugType = data['plugType']?.toString();
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
                      const Text('Boost Request',
                          style: TextStyle(
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
                          vehicleType == 'electric'
                              ? Icons.ev_station
                              : Icons.directions_car,
                          color: const Color(0xFF22D3EE),
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            vehicleType == 'electric'
                                ? 'Electric${plugType == null ? '' : ' • $plugType'}'
                                : 'Regular',
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

  String _formatTimeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${diff.inHours}h ago';
  }
}