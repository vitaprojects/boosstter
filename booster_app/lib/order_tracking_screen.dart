import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'app_shell.dart';
import 'request_lifecycle.dart';

/// Order Tracking Screen
/// Shows after booster accepts an order
/// - Displays map with route to customer's location
/// - Shows current distance and navigation
/// - Allows marking order as arrived
/// - Allows completing the order after arrival
class OrderTrackingScreen extends StatefulWidget {
  final String requestId;
  final String customerId;
  final String pickupAddress;
  final double pickupLatitude;
  final double pickupLongitude;
  final String vehicleType;
  final String plugType;

  const OrderTrackingScreen({
    required this.requestId,
    required this.customerId,
    required this.pickupAddress,
    required this.pickupLatitude,
    required this.pickupLongitude,
    required this.vehicleType,
    required this.plugType,
    super.key,
  });

  @override
  State<OrderTrackingScreen> createState() => _OrderTrackingScreenState();
}

class _OrderTrackingScreenState extends State<OrderTrackingScreen> {
  GoogleMapController? _mapController;
  Position? _currentPosition;
  Timer? _locationUpdateTimer;
  double _distanceKm = 0.0;
  String _currentStatus = 'accepted';
  bool _isUpdatingStatus = false;
  late StreamSubscription<Position> _positionStream;

  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};

  @override
  void initState() {
    super.initState();
    _startLocationTracking();
    _watchOrderStatus();
  }

  @override
  void dispose() {
    _locationUpdateTimer?.cancel();
    _mapController?.dispose();
    _positionStream.cancel();
    super.dispose();
  }

  void _startLocationTracking() {
    // Get initial position
    _updateCurrentLocation();

    // Stream location updates every 5 seconds
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10, // Update every 10 meters
      ),
    ).listen((Position position) {
      if (mounted) {
        setState(() {
          _currentPosition = position;
          _updateMapView();
          _uploadLocation();
        });
      }
    });
  }

  Future<void> _updateCurrentLocation() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      if (mounted) {
        setState(() {
          _currentPosition = position;
          _updateMapView();
          _uploadLocation();
        });
      }
    } catch (e) {
      debugPrint('Error getting position: $e');
    }
  }

  void _updateMapView() {
    if (_currentPosition == null || _mapController == null) return;

    final currentLoc =
        LatLng(_currentPosition!.latitude, _currentPosition!.longitude);
    final pickupLoc = LatLng(widget.pickupLatitude, widget.pickupLongitude);

    // Calculate distance
    _distanceKm = Geolocator.distanceBetween(
          _currentPosition!.latitude,
          _currentPosition!.longitude,
          widget.pickupLatitude,
          widget.pickupLongitude,
        ) /
        1000;

    // Update markers
    _markers.clear();
    _markers.add(
      Marker(
        markerId: const MarkerId('booster'),
        position: currentLoc,
        infoWindow: const InfoWindow(title: 'Your Location'),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
      ),
    );

    _markers.add(
      Marker(
        markerId: const MarkerId('customer'),
        position: pickupLoc,
        infoWindow: InfoWindow(title: widget.pickupAddress),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
      ),
    );

    // Update polyline (route)
    _polylines.clear();
    _polylines.add(
      Polyline(
        polylineId: const PolylineId('route'),
        color: const Color(0xFF14B8A6),
        width: 4,
        points: [currentLoc, pickupLoc],
      ),
    );

    setState(() {});

    // Animate camera to show both markers
    _mapController?.animateCamera(
      CameraUpdate.newLatLngBounds(_calculateBounds(currentLoc, pickupLoc), 100),
    );
  }

  LatLngBounds _calculateBounds(LatLng loc1, LatLng loc2) {
    final southWest = LatLng(
      loc1.latitude < loc2.latitude ? loc1.latitude : loc2.latitude,
      loc1.longitude < loc2.longitude ? loc1.longitude : loc2.longitude,
    );
    final northEast = LatLng(
      loc1.latitude > loc2.latitude ? loc1.latitude : loc2.latitude,
      loc1.longitude > loc2.longitude ? loc1.longitude : loc2.longitude,
    );
    return LatLngBounds(southwest: southWest, northeast: northEast);
  }

  Future<void> _uploadLocation() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null || _currentPosition == null) return;

      await FirebaseFirestore.instance.collection('requests').doc(widget.requestId).set(
        {
          'boosterLatitude': _currentPosition!.latitude,
          'boosterLongitude': _currentPosition!.longitude,
          'boosterLocationUpdatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    } catch (e) {
      debugPrint('Error uploading location: $e');
    }
  }

  void _watchOrderStatus() {
    FirebaseFirestore.instance
        .collection('requests')
        .doc(widget.requestId)
        .snapshots()
        .listen((doc) {
      if (!mounted) return;
      if (!doc.exists) return;

      final data = doc.data() ?? {};
      final status = data['status'] ?? 'accepted';

      setState(() {
        _currentStatus = status;
      });

      // If order was cancelled or completed by customer, go back
      if (status == 'cancelled' || status == 'completed') {
        Navigator.of(context).pop();
      }
    });
  }

  Future<void> _markAsArrived() async {
    if (_isUpdatingStatus) return;

    setState(() => _isUpdatingStatus = true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final requestRef =
          FirebaseFirestore.instance.collection('requests').doc(widget.requestId);

      await FirebaseFirestore.instance.runTransaction((txn) async {
        final snap = await txn.get(requestRef);
        if (!snap.exists) {
          throw Exception('Boost request not found.');
        }

        final data = snap.data() ?? <String, dynamic>{};
        final currentStatus = data['status'] ?? 'accepted';

        if (!canTransitionRequestStatus(
          requestStatusFromString(currentStatus),
          RequestStatus.arrived,
        )) {
          throw Exception('Cannot mark arrived in status: $currentStatus');
        }

        txn.update(requestRef, {
          'status': 'arrived',
          'arrivedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✓ Marked as arrived!'),
            backgroundColor: Color(0xFF14B8A6),
            duration: Duration(seconds: 2),
          ),
        );
        setState(() => _isUpdatingStatus = false);
      }
    } catch (e) {
      debugPrint('Error marking arrived: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
        setState(() => _isUpdatingStatus = false);
      }
    }
  }

  Future<void> _completeOrder() async {
    if (_isUpdatingStatus) return;

    setState(() => _isUpdatingStatus = true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final requestRef =
          FirebaseFirestore.instance.collection('requests').doc(widget.requestId);

      await FirebaseFirestore.instance.runTransaction((txn) async {
        final snap = await txn.get(requestRef);
        if (!snap.exists) {
          throw Exception('Boost request not found.');
        }

        final data = snap.data() ?? <String, dynamic>{};
        final currentStatus = data['status'] ?? 'arrived';

        if (!canTransitionRequestStatus(
          requestStatusFromString(currentStatus),
          RequestStatus.completed,
        )) {
          throw Exception('Cannot complete in status: $currentStatus');
        }

        txn.update(requestRef, {
          'status': 'completed',
          'completedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });

      if (mounted) {
        // Show completion dialog
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => _CompletionDialog(
            onClose: () {
              Navigator.of(context).pop(); // Close dialog
              Navigator.of(context).pop(); // Go back to driver screen
            },
          ),
        );
      }
    } catch (e) {
      debugPrint('Error completing order: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
        setState(() => _isUpdatingStatus = false);
      }
    }
  }

  bool get _isArrivedOrBeyond {
    return _currentStatus == 'arrived' ||
        _currentStatus == 'paid' ||
        _currentStatus == 'completed';
  }

  @override
  Widget build(BuildContext context) {
    final initialCameraPos = CameraPosition(
      target: LatLng(widget.pickupLatitude, widget.pickupLongitude),
      zoom: 15,
    );

    return PopScope(
      canPop: _currentStatus == 'completed',
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) {
          return;
        }
        // Confirm before leaving if order is not completed
        if (_currentStatus != 'completed') {
          final shouldLeave = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Leave Order?'),
              content:
                  const Text('Are you sure you want to leave this order?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Leave'),
                ),
              ],
            ),
          );
          if (shouldLeave == true && context.mounted) {
            Navigator.of(context).pop();
          }
        }
      },
      child: Scaffold(
        body: BoosterPageBackground(
          child: Stack(
            children: [
              // Map
              GoogleMap(
                initialCameraPosition: initialCameraPos,
                onMapCreated: (controller) {
                  _mapController = controller;
                  _updateMapView();
                },
                markers: _markers,
                polylines: _polylines,
                myLocationEnabled: true,
                myLocationButtonEnabled: true,
                zoomControlsEnabled: true,
              ),
              // Top info card
              Positioned(
                top: 16,
                left: 16,
                right: 16,
                child: SafeArea(
                  child: BoosterSurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Order in Progress',
                          style: TextStyle(
                            color: Color(0xFF14B8A6),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          widget.pickupAddress,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Distance',
                                  style: TextStyle(
                                    color: Colors.grey,
                                    fontSize: 11,
                                  ),
                                ),
                                Text(
                                  '${_distanceKm.toStringAsFixed(2)} km',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Status',
                                  style: TextStyle(
                                    color: Colors.grey,
                                    fontSize: 11,
                                  ),
                                ),
                                Text(
                                  _currentStatus.replaceAll('_', ' ').toUpperCase(),
                                  style: const TextStyle(
                                    color: Color(0xFF14B8A6),
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Bottom action card
              Positioned(
                bottom: 16,
                left: 16,
                right: 16,
                child: SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_currentStatus == 'accepted' || _currentStatus == 'en_route')
                        BoosterSurfaceCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                'You\'re on your way! Target location ahead',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Material(
                                color: const Color(0xFF14B8A6),
                                borderRadius: BorderRadius.circular(12),
                                child: InkWell(
                                  onTap:
                                      _isUpdatingStatus ? null : _markAsArrived,
                                  borderRadius: BorderRadius.circular(12),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 14,
                                    ),
                                    child: _isUpdatingStatus
                                        ? const SizedBox(
                                            height: 20,
                                            width: 20,
                                            child:
                                                CircularProgressIndicator(
                                              strokeWidth: 2,
                                              valueColor:
                                                  AlwaysStoppedAnimation<Color>(
                                                Colors.white,
                                              ),
                                            ),
                                          )
                                        : const Text(
                                            'I have Arrived!',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16,
                                            ),
                                          ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (_isArrivedOrBeyond)
                        BoosterSurfaceCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                'Great! Help the customer and mark order complete.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: const Color(0xFF8A8A9A),
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Material(
                                color: const Color(0xFF14B8A6),
                                borderRadius: BorderRadius.circular(12),
                                child: InkWell(
                                  onTap: _isUpdatingStatus ? null : _completeOrder,
                                  borderRadius: BorderRadius.circular(12),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 14,
                                    ),
                                    child: _isUpdatingStatus
                                        ? const SizedBox(
                                            height: 20,
                                            width: 20,
                                            child:
                                                CircularProgressIndicator(
                                              strokeWidth: 2,
                                              valueColor:
                                                  AlwaysStoppedAnimation<Color>(
                                                Colors.white,
                                              ),
                                            ),
                                          )
                                        : const Text(
                                            'Order Complete ✓',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16,
                                            ),
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
            ],
          ),
        ),
      ),
    );
  }
}

/// Dialog shown when order is successfully completed
class _CompletionDialog extends StatelessWidget {
  final VoidCallback onClose;

  const _CompletionDialog({required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: BoosterSurfaceCard(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.check_circle_outline,
              size: 60,
              color: Color(0xFF14B8A6),
            ),
            const SizedBox(height: 16),
            const Text(
              'Order Complete! 🎉',
              style: TextStyle(

                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Great work! The order has been completed successfully.',
              style: TextStyle(
                color: Colors.grey,
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            Material(
              color: const Color(0xFF14B8A6),
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                onTap: onClose,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: const Text(
                    'Continue',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
