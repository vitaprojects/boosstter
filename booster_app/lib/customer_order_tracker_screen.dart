import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'app_shell.dart';
import 'customer_requests_tab_screen.dart';
import 'home_screen.dart';
import 'main_bottom_nav.dart';
import 'orders_landing_screen.dart';
import 'profile_screen.dart';
import 'provider_status_screen.dart';

class CustomerOrderTrackerScreen extends StatefulWidget {
  const CustomerOrderTrackerScreen({
    required this.requestId,
    super.key,
  });

  final String requestId;

  @override
  State<CustomerOrderTrackerScreen> createState() =>
      _CustomerOrderTrackerScreenState();
}

class _CustomerOrderTrackerScreenState extends State<CustomerOrderTrackerScreen> {
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _requestSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _driverSub;

  String _status = 'pending';
  String _pickupAddress = 'Pickup location';
  LatLng? _pickupLatLng;
  String? _driverId;
  String _driverName = 'Provider';
  String _driverEmail = '';
  String _driverPhone = '';
  LatLng? _driverLatLng;
  DateTime? _driverUpdatedAt;
  int? _etaMinutes;
  double? _distanceKm;
  bool _isTrackingConnected = false;

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

  DateTime? _toDateTime(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return null;
  }

  void _watchRequest() {
    _requestSub?.cancel();
    _requestSub = FirebaseFirestore.instance
        .collection('requests')
        .doc(widget.requestId)
        .snapshots()
        .listen((snapshot) {
      if (!snapshot.exists || !mounted) {
        return;
      }

      final data = snapshot.data() ?? <String, dynamic>{};
      final lat = (data['pickupLatitude'] as num?)?.toDouble();
      final lng = (data['pickupLongitude'] as num?)?.toDouble();
      final driverId = data['driverId']?.toString();

      setState(() {
        _status = (data['status'] ?? 'pending').toString();
        _pickupAddress = data['pickupAddress']?.toString() ?? 'Pickup location';
        _pickupLatLng = (lat != null && lng != null) ? LatLng(lat, lng) : null;
        _driverId = (driverId == null || driverId.isEmpty) ? null : driverId;
      });

      _watchDriver();
    });
  }

  void _watchDriver() {
    _driverSub?.cancel();
    final driverId = _driverId;
    if (driverId == null) {
      setState(() {
        _driverName = 'Provider';
        _driverEmail = '';
        _driverPhone = '';
        _driverLatLng = null;
        _driverUpdatedAt = null;
        _isTrackingConnected = false;
      });
      return;
    }

    _driverSub = FirebaseFirestore.instance
        .collection('users')
        .doc(driverId)
        .snapshots()
        .listen((snapshot) {
      if (!snapshot.exists || !mounted) {
        return;
      }

      final data = snapshot.data() ?? <String, dynamic>{};
      final fullName = (data['fullName'] ?? '').toString().trim();
      final email = (data['email'] ?? '').toString().trim();
      final phone = (data['phone'] ?? '').toString().trim();
      final lat = (data['latitude'] as num?)?.toDouble();
      final lng = (data['longitude'] as num?)?.toDouble();
      final etaMinutes = (data['etaMinutes'] as num?)?.toInt();
      final distanceKm = (data['distanceKm'] as num?)?.toDouble();

      setState(() {
        _driverName = fullName.isNotEmpty ? fullName : (email.isNotEmpty ? email : 'Provider');
        _driverEmail = email;
        _driverPhone = phone;
        _driverLatLng = (lat != null && lng != null) ? LatLng(lat, lng) : null;
        _driverUpdatedAt = _toDateTime(data['locationUpdatedAt']) ?? _toDateTime(data['updatedAt']);
        _etaMinutes = etaMinutes;
        _distanceKm = distanceKm;
        _isTrackingConnected = true;
      });
    }, onError: (_) {
      if (!mounted) return;
      setState(() => _isTrackingConnected = false);
    }, onDone: () {
      if (!mounted) return;
      setState(() => _isTrackingConnected = false);
    });
  }

  String _statusTitle() {
    switch (_status) {
      case 'pending':
      case 'searching':
      case 'paid':
        return 'Looking for the nearest service provider';
      case 'accepted':
      case 'en_route':
        return 'Provider is on the way';
      case 'arrived':
        return 'Provider has arrived';
      case 'completed':
        return 'Order completed';
      case 'cancelled':
        return 'Order cancelled';
      case 'no_boosters_available':
        return 'No providers available nearby';
      default:
        return 'Order in progress';
    }
  }

  String _statusSubtitle() {
    if (_status == 'accepted' || _status == 'en_route') {
      if (_distanceKm != null && _etaMinutes != null) {
        return '${_distanceKm!.toStringAsFixed(1)} km away • ETA ${_etaMinutes!} min';
      }
      return 'A provider accepted your order and is heading to your location.';
    }
    if (_status == 'pending' || _status == 'searching' || _status == 'paid') {
      return 'Your request is active and being matched with nearby providers.';
    }
    if (_status == 'arrived') {
      return 'Your provider reached the pickup location.';
    }
    if (_status == 'completed') {
      return 'This service request is complete.';
    }
    if (_status == 'no_boosters_available') {
      return 'Try adjusting pickup location and requesting again.';
    }
    return 'Tracking is active.';
  }

  Color _statusPillColor() {
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
        return const Color(0xFFB45309);
      default:
        return const Color(0xFF64748B);
    }
  }

  String _statusPillText() {
    switch (_status) {
      case 'accepted':
      case 'en_route':
        return 'EN ROUTE';
      case 'arrived':
        return 'ARRIVED';
      case 'completed':
        return 'DONE';
      case 'cancelled':
        return 'CANCELLED';
      case 'no_boosters_available':
        return 'NO MATCH';
      default:
        return 'SEARCHING';
    }
  }

  @override
  Widget build(BuildContext context) {
    final markers = <Marker>{
      if (_pickupLatLng != null)
        Marker(
          markerId: const MarkerId('pickup'),
          position: _pickupLatLng!,
          infoWindow: InfoWindow(title: _pickupAddress),
        ),
      if (_driverLatLng != null)
        Marker(
          markerId: const MarkerId('driver'),
          position: _driverLatLng!,
          infoWindow: InfoWindow(
            title: _driverName,
            snippet: _etaMinutes == null ? 'Live location' : 'ETA ${_etaMinutes!} min',
          ),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueCyan),
        ),
    };

    final freshness = _driverUpdatedAt == null
        ? 'Waiting for first live location update...'
        : 'Updated ${DateTime.now().difference(_driverUpdatedAt!).inSeconds}s ago';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Booster Tracker'),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFC9D8FF), Color(0xFFE9EEFF)],
          ),
        ),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 24),
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(color: const Color(0xFFE4E8F5)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x1F1E3A8A),
                      blurRadius: 24,
                      offset: Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 17,
                          backgroundColor: const Color(0xFFEFF3FF),
                          child: Text(
                            _driverName.isEmpty ? 'P' : _driverName.characters.first.toUpperCase(),
                            style: const TextStyle(
                              color: Color(0xFF3558D9),
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'boosstter',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Color(0xFF3558D9),
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        Container(
                          width: 38,
                          height: 38,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: const Color(0xFFF5F7FF),
                            border: Border.all(color: const Color(0xFF95ACFF), width: 2),
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            _etaMinutes == null ? '--' : '${_etaMinutes!}',
                            style: const TextStyle(
                              color: Color(0xFF1E3A8A),
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: _statusPillColor().withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          _statusPillText(),
                          style: TextStyle(
                            color: _statusPillColor(),
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE3FFF3),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _statusTitle(),
                            style: const TextStyle(
                              color: Color(0xFF0F172A),
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _statusSubtitle(),
                            style: const TextStyle(
                              color: Color(0xFF334155),
                              fontSize: 14,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 330,
                      child: Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(22),
                            child: GoogleMap(
                              initialCameraPosition: CameraPosition(
                                target: _pickupLatLng ?? const LatLng(37.7749, -122.4194),
                                zoom: 13,
                              ),
                              markers: markers,
                              myLocationEnabled: false,
                              myLocationButtonEnabled: false,
                            ),
                          ),
                          Positioned(
                            top: 12,
                            left: 12,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(999),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Color(0x26000000),
                                    blurRadius: 12,
                                    offset: Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                child: Row(
                                  children: const [
                                    Icon(Icons.my_location_rounded, color: Color(0xFF2563EB), size: 18),
                                    SizedBox(width: 6),
                                    Text(
                                      'Localize',
                                      style: TextStyle(
                                        color: Color(0xFF0F172A),
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFFFFF),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFFE4E8F5)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _driverName,
                            style: const TextStyle(
                              color: Color(0xFF0F172A),
                              fontSize: 32,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _driverPhone.isNotEmpty ? _driverPhone : (_driverEmail.isNotEmpty ? _driverEmail : 'Provider assigned'),
                            style: const TextStyle(
                              color: Color(0xFF64748B),
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: _TrackerMetricTile(
                                  label: 'ETA',
                                  value: _etaMinutes == null ? '--' : '${_etaMinutes!} min',
                                  icon: Icons.schedule_rounded,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _TrackerMetricTile(
                                  label: 'Distance',
                                  value: _distanceKm == null ? '--' : '${_distanceKm!.toStringAsFixed(1)} km',
                                  icon: Icons.route_rounded,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              const Icon(Icons.location_on_outlined, color: Color(0xFF3B82F6), size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _pickupAddress,
                                  style: const TextStyle(
                                    color: Color(0xFF334155),
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                            decoration: BoxDecoration(
                              color: _isTrackingConnected
                                  ? const Color(0xFFEFF6FF)
                                  : const Color(0xFFFFF7ED),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              _isTrackingConnected ? freshness : 'Live GPS reconnecting...',
                              style: TextStyle(
                                color: _isTrackingConnected
                                    ? const Color(0xFF1D4ED8)
                                    : const Color(0xFFB45309),
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: () {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Live map is centered on your active request.'),
                                  ),
                                );
                              },
                              icon: const Icon(Icons.place_rounded),
                              label: const Text('Locate Booster On The Map'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: MainBottomNavBar(
        currentTab: MainTab.orders,
        onTabSelected: _onTabSelected,
      ),
    );
  }
}

class _TrackerMetricTile extends StatelessWidget {
  const _TrackerMetricTile({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

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
          Row(
            children: [
              Icon(icon, size: 14, color: const Color(0xFF22D3EE)),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: Color(0xFF8A8A9A),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
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