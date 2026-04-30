import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'app_shell.dart';

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
  String _driverName = 'Booster';
  String _driverEmail = '';
  String _driverPhone = '';
  LatLng? _driverLatLng;
  DateTime? _driverUpdatedAt;
  int? _etaMinutes;
  double? _distanceKm;
  bool _isTrackingConnected = false;

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
        _driverName = 'Booster';
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
        _driverName = fullName.isNotEmpty ? fullName : (email.isNotEmpty ? email : 'Booster');
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
        return 'Booster is on the way';
      case 'arrived':
        return 'Booster has arrived';
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
      return 'Booster accepted your order and is heading to your location.';
    }
    if (_status == 'pending' || _status == 'searching' || _status == 'paid') {
      return 'Your request is active and being matched with nearby providers.';
    }
    if (_status == 'arrived') {
      return 'Your booster reached the pickup location.';
    }
    if (_status == 'completed') {
      return 'This service request is complete.';
    }
    if (_status == 'no_boosters_available') {
      return 'Try adjusting pickup location and requesting again.';
    }
    return 'Tracking is active.';
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Order Tracker'),
      ),
      body: BoosterPageBackground(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            BoosterSurfaceCard(
              borderColor: const Color(0xFF22D3EE).withValues(alpha: 0.4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _statusTitle(),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _statusSubtitle(),
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            BoosterSurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Booster info',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text('Name: $_driverName', style: const TextStyle(color: const Color(0xFF8A8A9A))),
                  if (_driverEmail.isNotEmpty)
                    Text('Email: $_driverEmail', style: const TextStyle(color: const Color(0xFF8A8A9A))),
                  if (_driverPhone.isNotEmpty)
                    Text('Phone: $_driverPhone', style: const TextStyle(color: const Color(0xFF8A8A9A))),
                  const SizedBox(height: 8),
                  Text(
                    !_isTrackingConnected
                        ? 'Live GPS reconnecting...'
                        : _driverUpdatedAt == null
                            ? 'Waiting for first live location update...'
                            : 'Location updated ${DateTime.now().difference(_driverUpdatedAt!).inSeconds}s ago',
                    style: TextStyle(
                      color: _isTrackingConnected ? Colors.grey[600] : const Color(0xFFF59E0B),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 260,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: _pickupLatLng ?? const LatLng(37.7749, -122.4194),
                    zoom: 12,
                  ),
                  markers: markers,
                  myLocationEnabled: false,
                  myLocationButtonEnabled: false,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}