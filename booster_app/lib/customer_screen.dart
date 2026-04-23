import 'package:flutter/material.dart';
import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geocoding/geocoding.dart';
import 'login_screen.dart';
import 'paywall_screen.dart';
import 'stripe_payment_service.dart';

class CustomerScreen extends StatefulWidget {
  const CustomerScreen({super.key});

  @override
  State<CustomerScreen> createState() => _CustomerScreenState();
}

class _CustomerScreenState extends State<CustomerScreen> {
  Position? _currentPosition;
  bool _isLoading = true;
  bool _hasLocationPermission = false;
  bool _isSearchingBoosters = false;
  GoogleMapController? _mapController;

  String? _pickupAddress;
  LatLng? _pickupLatLng;
  String? _vehicleType;
  String? _plugType;
  final List<_NearbyBooster> _nearbyBoosters = <_NearbyBooster>[];

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _requestWatchSub;
  String? _activeRequestId;
  String? _activeRequestStatus;
  String? _activeDriverId;

  bool get _isWaitingForBooster {
    return _activeRequestStatus == 'pending' ||
        _activeRequestStatus == 'awaiting_payment' ||
        _activeRequestStatus == 'paid' ||
        _activeRequestStatus == 'accepted' ||
        _activeRequestStatus == 'en_route';
  }

  @override
  void initState() {
    super.initState();
    _getCurrentLocation();
    _watchLatestRequest();
  }

  @override
  void dispose() {
    _requestWatchSub?.cancel();
    super.dispose();
  }

  Future<void> _getCurrentLocation() async {
    try {
      LocationPermission permission = await Geolocator.requestPermission();
      
      if (permission == LocationPermission.denied || 
          permission == LocationPermission.deniedForever) {
        // Use default location if permission denied
        setState(() {
          _hasLocationPermission = false;
          _currentPosition = Position(
            latitude: 37.7749, // Default to San Francisco
            longitude: -122.4194,
            timestamp: DateTime.now(),
            accuracy: 0,
            altitude: 0,
            heading: 0,
            speed: 0,
            speedAccuracy: 0,
            altitudeAccuracy: 0,
            headingAccuracy: 0,
          );
          _isLoading = false;
          _updateMarkers();
        });
        return;
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      setState(() {
        _hasLocationPermission = true;
        _currentPosition = position;
        _isLoading = false;
      });

      // Move camera to current position
      if (_mapController != null && _currentPosition != null) {
        _mapController!.animateCamera(
          CameraUpdate.newLatLng(
            LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
          ),
        );
      }

      // Location updated successfully
    } catch (e) {
      // Use default location on error
      setState(() {
        _hasLocationPermission = false;
        _currentPosition = Position(
          latitude: 37.7749,
          longitude: -122.4194,
          timestamp: DateTime.now(),
          accuracy: 0,
          altitude: 0,
          heading: 0,
          speed: 0,
          speedAccuracy: 0,
          altitudeAccuracy: 0,
          headingAccuracy: 0,
        );
        _isLoading = false;
        _updateMarkers();
      });
    }
  }

  Future<bool> _ensureSubscribed() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return false;
    }

    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();

    if (!mounted) return false;

    if (!userDoc.exists) {
      _showErrorSnackBar('User profile not found', Icons.person_off);
      return false;
    }

    final bool isSubscribed = userDoc['isSubscribed'] ?? false;
    if (isSubscribed) {
      return true;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const PaywallScreen()),
    );

    return false;
  }

  Future<void> _openPickupSelector() async {
    final selection = await showModalBottomSheet<_PickupSelection>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const _PickupSelectorSheet(),
    );

    if (selection == null || !mounted) {
      return;
    }

    setState(() {
      _pickupAddress = selection.address;
      _pickupLatLng = selection.latLng;
      _vehicleType = selection.vehicleType;
      _plugType = selection.plugType;
      _nearbyBoosters.clear();
    });

    _showSuccessSnackBar('Pickup saved. Searching nearby boosters...');
    await _searchNearbyBoosters();
  }

  Future<void> _requestBoost(String driverId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    if (_isWaitingForBooster) {
      _showErrorSnackBar(
        'You already have an active invite. Please wait for booster response.',
        Icons.hourglass_bottom,
      );
      return;
    }

    if (_pickupLatLng == null || _pickupAddress == null) {
      _showErrorSnackBar('Please save a pickup location first', Icons.place);
      return;
    }

    if (_vehicleType == null) {
      _showErrorSnackBar('Choose Regular or Electric before inviting a booster', Icons.ev_station);
      return;
    }

    final subscribed = await _ensureSubscribed();
    if (!subscribed || !mounted) {
      return;
    }

    try {
      final docRef = await FirebaseFirestore.instance.collection('requests').add({
        'customerId': user.uid,
        'driverId': driverId,
        'status': 'pending',
        'pickupAddress': _pickupAddress,
        'pickupLatitude': _pickupLatLng!.latitude,
        'pickupLongitude': _pickupLatLng!.longitude,
        'vehicleType': _vehicleType,
        'plugType': _plugType,
        'timestamp': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        setState(() {
          _activeRequestId = docRef.id;
          _activeRequestStatus = 'pending';
          _activeDriverId = driverId;
        });
        _showSuccessSnackBar(
          'Invite sent. Waiting for booster confirmation.',
        );
      }
    } catch (e) {
      if (mounted) {
        _showErrorSnackBar(
          'Failed to send request. Please try again',
          Icons.cloud_off,
        );
      }
    }
  }

  Future<void> _searchNearbyBoosters() async {
    if (_pickupLatLng == null) {
      _showErrorSnackBar('Set a pickup location first', Icons.place);
      return;
    }

    setState(() => _isSearchingBoosters = true);

    try {
      final currentUserId = FirebaseAuth.instance.currentUser?.uid;
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .where('role', isEqualTo: 'driver')
          .where('isAvailable', isEqualTo: true)
          .get();

      final boosters = <_NearbyBooster>[];
      for (final doc in snapshot.docs) {
        if (doc.id == currentUserId) continue;

        final data = doc.data();
        final latitude = (data['latitude'] as num?)?.toDouble() ?? 0.0;
        final longitude = (data['longitude'] as num?)?.toDouble() ?? 0.0;
        final email = (data['email'] ?? 'Booster') as String;

        if (latitude == 0.0 && longitude == 0.0) {
          continue;
        }

        final distanceMeters = Geolocator.distanceBetween(
          _pickupLatLng!.latitude,
          _pickupLatLng!.longitude,
          latitude,
          longitude,
        );

        final distanceKm = distanceMeters / 1000.0;
        final etaMinutes = ((distanceKm / 40.0) * 60.0).ceil().clamp(1, 240);

        boosters.add(
          _NearbyBooster(
            userId: doc.id,
            displayName: email,
            latitude: latitude,
            longitude: longitude,
            distanceKm: distanceKm,
            etaMinutes: etaMinutes,
          ),
        );
      }

      boosters.sort((a, b) => a.distanceKm.compareTo(b.distanceKm));

      if (!mounted) return;
      setState(() {
        _nearbyBoosters
          ..clear()
          ..addAll(boosters);
      });

      if (boosters.isEmpty) {
        _showErrorSnackBar(
          'No available boosters found nearby right now',
          Icons.search_off,
        );
      } else {
        _showSuccessSnackBar('${boosters.length} boosters found nearby');
      }
    } catch (_) {
      if (mounted) {
        _showErrorSnackBar(
          'Could not search boosters. Please try again',
          Icons.cloud_off,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSearchingBoosters = false);
      }
    }
  }

  void _updateMarkers() {
    if (!mounted) return;
    setState(() {});
  }

  void _watchLatestRequest() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return;
    }

    _requestWatchSub?.cancel();
    _requestWatchSub = FirebaseFirestore.instance
        .collection('requests')
        .where('customerId', isEqualTo: user.uid)
        .orderBy('timestamp', descending: true)
        .limit(1)
        .snapshots()
        .listen((snapshot) {
      if (!mounted) {
        return;
      }

      if (snapshot.docs.isEmpty) {
        setState(() {
          _activeRequestId = null;
          _activeRequestStatus = null;
          _activeDriverId = null;
        });
        return;
      }

      final doc = snapshot.docs.first;
      final data = doc.data();
      final newStatus = (data['status'] ?? 'pending').toString();
      final prevStatus = _activeRequestStatus;

      setState(() {
        _activeRequestId = doc.id;
        _activeRequestStatus = newStatus;
        _activeDriverId = data['driverId']?.toString();
      });

      // Auto-show payment sheet when booster accepts (fires once)
      if (prevStatus != 'awaiting_payment' && newStatus == 'awaiting_payment') {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showPaymentSheet(doc.id);
        });
      }
    });
  }

  Future<void> _showPaymentSheet(String requestId) async {
    final result = await showModalBottomSheet<BoostPaymentResult>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      builder: (_) => _PaymentSheet(requestId: requestId),
    );

    if (!mounted) return;

    if (result != null) {
      try {
        await FirebaseFirestore.instance
            .collection('requests')
            .doc(requestId)
            .update({
          'status': 'paid',
          'paidAt': FieldValue.serverTimestamp(),
          'paymentAmount': result.amount,
          'paymentCurrency': result.currency,
          'paymentIntentId': result.paymentIntentId,
          'paymentProvider': 'stripe',
        });
        if (mounted) {
          _showSuccessSnackBar('Payment successful! Booster is heading your way.');
        }
      } catch (e) {
        if (mounted) {
          _showErrorSnackBar('Payment update failed. Please try again.', Icons.error);
        }
      }
    } else {
      _showErrorSnackBar('Payment cancelled. Booster is still waiting.', Icons.info);
    }
  }

  void _recenterMap() {
    final focus = _pickupLatLng ??
        (_currentPosition == null
            ? null
            : LatLng(_currentPosition!.latitude, _currentPosition!.longitude));

    if (_mapController != null && focus != null) {
      _mapController!.animateCamera(
        CameraUpdate.newLatLng(
          focus,
        ),
      );
    }
  }

  void _showErrorSnackBar(String message, IconData icon) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(icon, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: Colors.red[700],
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _showSuccessSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: Colors.green[700],
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Booster'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              if (context.mounted) {
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (context) => const LoginScreen()),
                  (route) => false,
                );
              }
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Getting your location...'),
                ],
              ),
            )
          : Column(
              children: [
                Expanded(
                  flex: 5,
                  child: GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: LatLng(
                        _currentPosition!.latitude,
                        _currentPosition!.longitude,
                      ),
                      zoom: 14,
                    ),
                    markers: _buildMarkers(),
                    onMapCreated: (controller) {
                      _mapController = controller;
                    },
                    myLocationEnabled: _hasLocationPermission,
                    myLocationButtonEnabled: _hasLocationPermission,
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                    decoration: BoxDecoration(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      border: const Border(
                        top: BorderSide(color: Colors.white10),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _openPickupSelector,
                                icon: const Icon(Icons.place),
                                label: const Text('Set Pickup'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: _isSearchingBoosters
                                    ? null
                                    : _searchNearbyBoosters,
                                icon: _isSearchingBoosters
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.search),
                                label: const Text('Search'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        if (_pickupAddress != null)
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E1E1E),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white10),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.pin_drop,
                                  color: Color(0xFF6366F1),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _pickupAddress!,
                                    style:
                                        Theme.of(context).textTheme.bodyMedium,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (_vehicleType != null) ...[
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E1E1E),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white10),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  _vehicleType == _electricVehicleType
                                      ? Icons.ev_station
                                      : Icons.directions_car,
                                  color: const Color(0xFF22D3EE),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _vehicleType == _electricVehicleType
                                        ? 'Electric vehicle${_plugType == null ? '' : ' • $_plugType'}'
                                        : 'Regular vehicle',
                                    style: Theme.of(context).textTheme.bodyMedium,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 10),
                        if (_activeRequestId != null)
                          _RequestStatusCard(
                            status: _activeRequestStatus ?? 'pending',
                            driverId: _activeDriverId,
                            onPayNow: _activeRequestStatus == 'awaiting_payment'
                                ? () => _showPaymentSheet(_activeRequestId!)
                                : null,
                          ),
                        if (_activeRequestId != null) const SizedBox(height: 10),
                        Text(
                          'Nearby Boosters',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: _nearbyBoosters.isEmpty
                              ? Center(
                                  child: Text(
                                    _pickupAddress == null
                                        ? 'Set pickup and search to find boosters'
                                        : 'No boosters found yet',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(color: Colors.grey[400]),
                                  ),
                                )
                              : ListView.builder(
                                  itemCount: _nearbyBoosters.length,
                                  itemBuilder: (context, index) {
                                    final booster = _nearbyBoosters[index];
                                    return Card(
                                      margin: const EdgeInsets.only(bottom: 8),
                                      child: ListTile(
                                        leading: const Icon(
                                          Icons.directions_car,
                                          color: Color(0xFF6366F1),
                                        ),
                                        title: Text(booster.displayName),
                                        subtitle: Text(
                                          '${booster.distanceKm.toStringAsFixed(2)} km • ETA ${booster.etaMinutes} min',
                                        ),
                                        trailing: ElevatedButton(
                                          onPressed: _isWaitingForBooster
                                              ? null
                                              : () => _requestBoost(booster.userId),
                                          child: const Text('Send Invite'),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
      floatingActionButton: _isLoading
          ? null
          : FloatingActionButton(
              onPressed: _recenterMap,
              tooltip: 'Recenter Map',
              child: const Icon(Icons.my_location),
            ),
    );
  }

  Set<Marker> _buildMarkers() {
    final markers = <Marker>{};

    if (_currentPosition != null) {
      markers.add(
        Marker(
          markerId: const MarkerId('current_location'),
          position: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
          infoWindow: const InfoWindow(title: 'Your current location'),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
        ),
      );
    }

    if (_pickupLatLng != null) {
      markers.add(
        Marker(
          markerId: const MarkerId('pickup_location'),
          position: _pickupLatLng!,
          infoWindow: InfoWindow(title: _pickupAddress ?? 'Pickup location'),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
        ),
      );
    }

    for (final booster in _nearbyBoosters) {
      markers.add(
        Marker(
          markerId: MarkerId('booster_${booster.userId}'),
          position: LatLng(booster.latitude, booster.longitude),
          infoWindow: InfoWindow(
            title: booster.displayName,
            snippet:
                '${booster.distanceKm.toStringAsFixed(2)} km • ETA ${booster.etaMinutes} min',
          ),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        ),
      );
    }

    return markers;
  }
}

class _RequestStatusCard extends StatelessWidget {
  const _RequestStatusCard({required this.status, required this.driverId, this.onPayNow});

  final String status;
  final String? driverId;
  final VoidCallback? onPayNow;

  @override
  Widget build(BuildContext context) {
    final n = status.toLowerCase();
    final isPending = n == 'pending';
    final needsPayment = n == 'awaiting_payment';
    final isPaid = n == 'paid';
    final isEnRoute = n == 'accepted' || n == 'en_route';
    final isDone = n == 'completed';

    final Color tone = isDone
        ? Colors.green
        : isEnRoute || isPaid
            ? const Color(0xFF06B6D4)
            : needsPayment
                ? const Color(0xFFF59E0B)
                : isPending
                    ? Colors.orange
                    : Colors.grey;

    final IconData icon = isDone
        ? Icons.check_circle
        : isEnRoute || isPaid
            ? Icons.directions_car
            : needsPayment
                ? Icons.payment
                : Icons.hourglass_bottom;

    final String title = isDone
        ? 'Boost Completed'
        : isEnRoute
            ? 'Booster is on the way'
            : isPaid
                ? 'Payment confirmed — booster heading over'
                : needsPayment
                    ? 'Booster accepted — payment required'
                    : 'Waiting for booster to accept';

    final String subtitle = isDone
        ? 'Your request is complete. Thank you!'
        : isEnRoute
            ? 'Booster is en route to your location'
            : isPaid
                ? 'Sit tight, help is on the way!'
                : needsPayment
                    ? 'Tap "Pay Now" to confirm and dispatch the booster'
                    : 'Invite sent. Please wait for confirmation.';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tone.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: tone),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Colors.grey[300]),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (needsPayment && onPayNow != null) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onPayNow,
                icon: const Icon(Icons.payment, size: 18),
                label: const Text('Pay Now — \$25.00',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFF59E0B),
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PaymentSheet extends StatefulWidget {
  const _PaymentSheet({required this.requestId});

  final String requestId;

  @override
  State<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<_PaymentSheet> {
  bool _isProcessing = false;
  String? _error;

  Future<void> _processPayment() async {
    setState(() => _isProcessing = true);

    try {
      final result = await StripePaymentService.instance.payForBoostRequest(
        requestId: widget.requestId,
        amountInCents: boostPaymentTotalCadCents,
      );

      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _error = null;
      });
      Navigator.of(context).pop(result);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _error = error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);

    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1E293B),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: mediaQuery.size.height * 0.9,
          ),
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              24,
              20,
              24,
              mediaQuery.viewInsets.bottom + 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
          // Handle bar
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[600],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.payment, color: Color(0xFFF59E0B)),
              ),
              const SizedBox(width: 14),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Complete Payment',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold)),
                  Text('Booster is waiting for your confirmation',
                      style: TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 24),
          // Summary
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                _SummaryRow(label: 'Boost Service', value: '\$20.00'),
                const SizedBox(height: 8),
                _SummaryRow(label: 'Service Fee', value: '\$3.50'),
                const SizedBox(height: 8),
                _SummaryRow(label: 'Tax', value: '\$1.50'),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Divider(color: Colors.white12),
                ),
                _SummaryRow(
                    label: 'Total',
                    value: '\$25.00',
                    bold: true,
                    valueColor: const Color(0xFFF59E0B)),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white10),
            ),
            child: const Row(
              children: [
                Icon(Icons.lock, color: Color(0xFF22D3EE), size: 18),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Secure Stripe checkout. Card entry happens in Stripe PaymentSheet.',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isProcessing ? null : _processPayment,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFF59E0B),
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: _isProcessing
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.black),
                    )
                  : const Text('Continue to Stripe \$25.00',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 13),
            ),
          ],
          const SizedBox(height: 10),
          Center(
            child: TextButton(
              onPressed: _isProcessing
                  ? null
                  : () => Navigator.of(context).pop(false),
              child: const Text('Cancel',
                  style: TextStyle(color: Colors.grey)),
            ),
          ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow(
      {required this.label,
      required this.value,
      this.bold = false,
      this.valueColor});
  final String label;
  final String value;
  final bool bold;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: TextStyle(
                color: bold ? Colors.white : Colors.grey[400],
                fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                fontSize: bold ? 15 : 13)),
        Text(value,
            style: TextStyle(
                color: valueColor ?? (bold ? Colors.white : Colors.white70),
                fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                fontSize: bold ? 16 : 13)),
      ],
    );
  }
}

class _NearbyBooster {
  const _NearbyBooster({
    required this.userId,
    required this.displayName,
    required this.latitude,
    required this.longitude,
    required this.distanceKm,
    required this.etaMinutes,
  });

  final String userId;
  final String displayName;
  final double latitude;
  final double longitude;
  final double distanceKm;
  final int etaMinutes;
}

class _PickupSelection {
  const _PickupSelection({
    required this.address,
    required this.latLng,
    required this.vehicleType,
    this.plugType,
  });

  final String address;
  final LatLng latLng;
  final String vehicleType;
  final String? plugType;
}

class _PickupSelectorSheet extends StatefulWidget {
  const _PickupSelectorSheet();

  @override
  State<_PickupSelectorSheet> createState() => _PickupSelectorSheetState();
}

class _PickupSelectorSheetState extends State<_PickupSelectorSheet> {
  final TextEditingController _addressController = TextEditingController();
  bool _isSaving = false;
  String? _error;
  String _selectedVehicleType = _regularVehicleType;
  String? _selectedPlugType = _plugTypes.first;

  @override
  void dispose() {
    _addressController.dispose();
    super.dispose();
  }

  Future<void> _saveAddressSearch() async {
    final input = _addressController.text.trim();
    if (input.isEmpty) {
      setState(() => _error = 'Enter an address');
      return;
    }

    if (!_isVehicleSelectionValid()) {
      setState(() => _error = 'Select your EV plug type to continue');
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });

    try {
      final locations = await locationFromAddress(input);
      if (locations.isEmpty) {
        setState(() => _error = 'Address not found');
        return;
      }

      final selected = locations.first;
      if (!mounted) return;
      Navigator.of(context).pop(
        _PickupSelection(
          address: input,
          latLng: LatLng(selected.latitude, selected.longitude),
          vehicleType: _selectedVehicleType,
          plugType: _selectedVehicleType == _electricVehicleType
              ? _selectedPlugType
              : null,
        ),
      );
    } catch (_) {
      setState(() => _error = 'Could not resolve address');
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _saveCurrentLocation() async {
    if (!_isVehicleSelectionValid()) {
      setState(() => _error = 'Select your EV plug type to continue');
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });

    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        setState(() => _error = 'Location permission denied');
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      String displayAddress =
          'Current location (${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)})';
      try {
        final places = await placemarkFromCoordinates(
          position.latitude,
          position.longitude,
        );
        if (places.isNotEmpty) {
          final p = places.first;
          displayAddress = [
            if ((p.street ?? '').isNotEmpty) p.street,
            if ((p.locality ?? '').isNotEmpty) p.locality,
            if ((p.administrativeArea ?? '').isNotEmpty)
              p.administrativeArea,
          ].whereType<String>().join(', ');
        }
      } catch (_) {
        // Keep coordinate fallback address.
      }

      if (!mounted) return;
      Navigator.of(context).pop(
        _PickupSelection(
          address: displayAddress,
          latLng: LatLng(position.latitude, position.longitude),
          vehicleType: _selectedVehicleType,
          plugType: _selectedVehicleType == _electricVehicleType
              ? _selectedPlugType
              : null,
        ),
      );
    } catch (_) {
      setState(() => _error = 'Could not access current location');
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  bool _isVehicleSelectionValid() {
    if (_selectedVehicleType == _regularVehicleType) {
      return true;
    }
    return _selectedPlugType != null;
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);

    return DefaultTabController(
      length: 2,
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: mediaQuery.size.height * 0.92,
          ),
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              16,
              12,
              16,
              16 + mediaQuery.viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
            Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[600],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            Text('Set Pickup Location', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 14),
            _VehicleTypeSelector(
              selectedVehicleType: _selectedVehicleType,
              selectedPlugType: _selectedPlugType,
              onVehicleTypeChanged: (vehicleType) {
                setState(() {
                  _selectedVehicleType = vehicleType;
                  if (vehicleType == _regularVehicleType) {
                    _selectedPlugType = null;
                  } else {
                    _selectedPlugType ??= _plugTypes.first;
                  }
                  _error = null;
                });
              },
              onPlugTypeChanged: (plugType) {
                setState(() {
                  _selectedPlugType = plugType;
                  _error = null;
                });
              },
            ),
            const SizedBox(height: 12),
            const TabBar(
              tabs: [
                Tab(text: 'Enter Address'),
                Tab(text: 'Use Current Location'),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 240,
              child: TabBarView(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _addressController,
                        decoration: const InputDecoration(
                          labelText: 'Address',
                          prefixIcon: Icon(Icons.search),
                        ),
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _saveAddressSearch(),
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed: _isSaving ? null : _saveAddressSearch,
                        child: _isSaving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Save Pickup'),
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 6),
                      Text(
                        'Use your current GPS location as pickup address.',
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(color: Colors.grey[400]),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: _isSaving ? null : _saveCurrentLocation,
                        icon: const Icon(Icons.my_location),
                        label: _isSaving
                            ? const Text('Saving...')
                            : const Text('Save Current Location'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

const String _regularVehicleType = 'regular';
const String _electricVehicleType = 'electric';
const List<String> _plugTypes = <String>[
  'J1772 Type 1',
  'Type 2',
  'CHAdeMO',
  'CCS Combo',
  'Tesla / NACS',
];

class _VehicleTypeSelector extends StatelessWidget {
  const _VehicleTypeSelector({
    required this.selectedVehicleType,
    required this.selectedPlugType,
    required this.onVehicleTypeChanged,
    required this.onPlugTypeChanged,
  });

  final String selectedVehicleType;
  final String? selectedPlugType;
  final ValueChanged<String> onVehicleTypeChanged;
  final ValueChanged<String> onPlugTypeChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Vehicle Type', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _VehicleTypeCard(
                title: 'Regular',
                subtitle: 'Any car can boost it',
                icon: Icons.directions_car_filled,
                selected: selectedVehicleType == _regularVehicleType,
                onTap: () => onVehicleTypeChanged(_regularVehicleType),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _VehicleTypeCard(
                title: 'Electric',
                subtitle: 'Choose your plug type',
                icon: Icons.ev_station,
                selected: selectedVehicleType == _electricVehicleType,
                onTap: () => onVehicleTypeChanged(_electricVehicleType),
              ),
            ),
          ],
        ),
        if (selectedVehicleType == _electricVehicleType) ...[
          const SizedBox(height: 14),
          Text('Select Plug Type', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: _plugTypes.map((plugType) {
              return _PlugTypeCard(
                plugType: plugType,
                selected: selectedPlugType == plugType,
                onTap: () => onPlugTypeChanged(plugType),
              );
            }).toList(),
          ),
        ],
      ],
    );
  }
}

class _VehicleTypeCard extends StatelessWidget {
  const _VehicleTypeCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF6366F1).withValues(alpha: 0.14)
              : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? const Color(0xFF6366F1) : Colors.white12,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: selected ? const Color(0xFF6366F1) : Colors.grey[400]),
            const SizedBox(height: 10),
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.grey[400]),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlugTypeCard extends StatelessWidget {
  const _PlugTypeCard({
    required this.plugType,
    required this.selected,
    required this.onTap,
  });

  final String plugType;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 164,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF22D3EE).withValues(alpha: 0.12)
              : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? const Color(0xFF22D3EE) : Colors.white12,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _PlugTypeIllustration(label: plugType),
            const SizedBox(height: 10),
            Text(
              plugType,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              _plugTypeDescription(plugType),
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.grey[400]),
            ),
          ],
        ),
      ),
    );
  }

  String _plugTypeDescription(String value) {
    switch (value) {
      case 'J1772 Type 1':
        return 'Common AC connector in North America';
      case 'Type 2':
        return 'Common AC connector in Europe';
      case 'CHAdeMO':
        return 'DC fast charging standard';
      case 'CCS Combo':
        return 'Combined AC/DC fast charging';
      case 'Tesla / NACS':
        return 'Tesla and NACS-compatible connector';
      default:
        return 'Select the plug that matches your car';
    }
  }
}

class _PlugTypeIllustration extends StatelessWidget {
  const _PlugTypeIllustration({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 96,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: <Color>[Color(0xFF0F172A), Color(0xFF1E293B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Stack(
        children: [
          Positioned(
            right: 8,
            top: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                _plugBadge(label),
                style: const TextStyle(
                  color: Color(0xFFBFDBFE),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: CustomPaint(
              painter: _PlugFacePainter(label: label),
            ),
          ),
        ],
      ),
    );
  }

  String _plugBadge(String value) {
    switch (value) {
      case 'J1772 Type 1':
        return 'TYPE 1';
      case 'Type 2':
        return 'TYPE 2';
      case 'CHAdeMO':
        return 'DC';
      case 'CCS Combo':
        return 'CCS';
      case 'Tesla / NACS':
        return 'NACS';
      default:
        return 'EV';
    }
  }
}

class _PlugFacePainter extends CustomPainter {
  const _PlugFacePainter({required this.label});

  final String label;

  @override
  void paint(Canvas canvas, Size size) {
    final cablePaint = Paint()
      ..color = const Color(0xFF22D3EE)
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;

    final bodyPaint = Paint()..color = const Color(0xFFE2E8F0);
    final shellPaint = Paint()..color = const Color(0xFFCBD5E1);
    final pinPaint = Paint()..color = const Color(0xFF0F172A);
    final accentPaint = Paint()..color = const Color(0xFF38BDF8).withValues(alpha: 0.22);

    final cableStart = Offset(size.width * 0.16, size.height * 0.55);
    final cableMid = Offset(size.width * 0.34, size.height * 0.55);
    final socketCenter = Offset(size.width * 0.62, size.height * 0.54);

    canvas.drawLine(cableStart, cableMid, cablePaint);
    canvas.drawCircle(cableStart, 7, accentPaint);

    final bodyRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: socketCenter,
        width: size.width * 0.34,
        height: size.height * 0.58,
      ),
      const Radius.circular(18),
    );
    canvas.drawRRect(bodyRect, shellPaint);

    final faceRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(socketCenter.dx + 3, socketCenter.dy),
        width: size.width * 0.26,
        height: size.height * 0.46,
      ),
      const Radius.circular(16),
    );
    canvas.drawRRect(faceRect, bodyPaint);

    for (final pin in _pinLayout(size, socketCenter)) {
      canvas.drawCircle(pin.$1, pin.$2, pinPaint);
    }

    final capPaint = Paint()..color = const Color(0xFF0F172A).withValues(alpha: 0.12);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width * 0.43, size.height * 0.33, 12, size.height * 0.16),
        const Radius.circular(6),
      ),
      capPaint,
    );
  }

  List<(Offset, double)> _pinLayout(Size size, Offset center) {
    switch (label) {
      case 'J1772 Type 1':
        return <(Offset, double)>[
          (Offset(center.dx - 10, center.dy - 10), 4),
          (Offset(center.dx + 5, center.dy - 10), 4),
          (Offset(center.dx - 15, center.dy + 8), 4),
          (Offset(center.dx, center.dy + 8), 5),
          (Offset(center.dx + 15, center.dy + 8), 4),
        ];
      case 'Type 2':
        return <(Offset, double)>[
          (Offset(center.dx - 12, center.dy - 12), 4),
          (Offset(center.dx, center.dy - 14), 4),
          (Offset(center.dx + 12, center.dy - 12), 4),
          (Offset(center.dx - 16, center.dy + 1), 4),
          (Offset(center.dx, center.dy), 5),
          (Offset(center.dx + 16, center.dy + 1), 4),
          (Offset(center.dx, center.dy + 15), 4),
        ];
      case 'CHAdeMO':
        return <(Offset, double)>[
          (Offset(center.dx - 7, center.dy), 9),
          (Offset(center.dx + 11, center.dy - 1), 7),
        ];
      case 'CCS Combo':
        return <(Offset, double)>[
          (Offset(center.dx - 12, center.dy - 13), 4),
          (Offset(center.dx, center.dy - 15), 4),
          (Offset(center.dx + 12, center.dy - 13), 4),
          (Offset(center.dx - 16, center.dy + 1), 4),
          (Offset(center.dx, center.dy), 5),
          (Offset(center.dx + 16, center.dy + 1), 4),
          (Offset(center.dx - 10, center.dy + 18), 8),
          (Offset(center.dx + 10, center.dy + 18), 8),
        ];
      case 'Tesla / NACS':
        return <(Offset, double)>[
          (Offset(center.dx - 10, center.dy - 8), 4),
          (Offset(center.dx + 5, center.dy - 8), 4),
          (Offset(center.dx - 13, center.dy + 7), 4),
          (Offset(center.dx + 8, center.dy + 7), 4),
          (Offset(center.dx - 2, center.dy + 19), 6),
        ];
      default:
        return <(Offset, double)>[(center, 5)];
    }
  }

  @override
  bool shouldRepaint(covariant _PlugFacePainter oldDelegate) {
    return oldDelegate.label != label;
  }
}