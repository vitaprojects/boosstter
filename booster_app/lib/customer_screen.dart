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
  int _flowStep = 1;
  GoogleMapController? _mapController;

  String _serviceType = _serviceTypeBoost;

  String? _pickupAddress;
  LatLng? _pickupLatLng;
  String? _vehicleType;
  String? _plugType;
  String? _selectedBoostVehicleType;
  String? _selectedBoostPlugType;
  String? _selectedTowVehicle;
  bool _showTowManualVehicle = false;
  final TextEditingController _towManualVehicleController = TextEditingController();
  String? _towDetectedLocationAddress;
  LatLng? _towDetectedLocationLatLng;
  int _towStep = 1;
  int _towLocationTabIndex = 0;
  final TextEditingController _towManualAddressController = TextEditingController();
  String? _selectedTowReason;
  final TextEditingController _towNotesController = TextEditingController();
  final List<_NearbyBooster> _nearbyBoosters = <_NearbyBooster>[];

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _requestWatchSub;
  String? _activeRequestId;
  String? _activeRequestStatus;
  String? _activeDriverId;
  String? _providerEtaSummary;

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
    _loadPreferredServiceType();
    _getCurrentLocation();
    _watchLatestRequest();
  }

  @override
  void dispose() {
    _requestWatchSub?.cancel();
    _towManualVehicleController.dispose();
    _towManualAddressController.dispose();
    _towNotesController.dispose();
    super.dispose();
  }

  Future<void> _loadPreferredServiceType() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return;
    }

    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final preferred = userDoc.data()?['preferredServiceType']?.toString();
      if (!mounted) return;
      setState(() {
        _serviceType = preferred == _serviceTypeTow ? _serviceTypeTow : _serviceTypeBoost;
      });
    } catch (_) {
      // Default to boost flow when profile service preference cannot be read.
    }
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
      await _updateTowDetectedLocation(position.latitude, position.longitude);

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
      await _updateTowDetectedLocation(37.7749, -122.4194);
    }
  }

  Future<void> _updateTowDetectedLocation(double latitude, double longitude) async {
    var address =
        'Current location (${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)})';

    try {
      final places = await placemarkFromCoordinates(latitude, longitude);
      if (places.isNotEmpty) {
        final p = places.first;
        final parts = <String>[
          if ((p.street ?? '').isNotEmpty) p.street!,
          if ((p.locality ?? '').isNotEmpty) p.locality!,
          if ((p.administrativeArea ?? '').isNotEmpty) p.administrativeArea!,
        ];
        if (parts.isNotEmpty) {
          address = parts.join(', ');
        }
      }
    } catch (_) {
      // Keep coordinate fallback.
    }

    if (!mounted) return;
    setState(() {
      _towDetectedLocationAddress = address;
      _towDetectedLocationLatLng = LatLng(latitude, longitude);
    });
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

  Future<void> _openPickupSelector({
    required String vehicleType,
    String? plugType,
  }) async {
    final selection = await showModalBottomSheet<_PickupSelection>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _PickupSelectorSheet(
        initialVehicleType: vehicleType,
        initialPlugType: plugType,
        lockVehicleSelection: true,
      ),
    );

    if (selection == null || !mounted) {
      return;
    }

    setState(() {
      _pickupAddress = selection.address;
      _pickupLatLng = selection.latLng;
      _vehicleType = selection.vehicleType;
      _plugType = selection.plugType;
      _flowStep = 2;
      _nearbyBoosters.clear();
    });

    _showSuccessSnackBar('Pickup saved. Searching nearby boosters...');
    await _searchNearbyBoosters();
  }

  bool get _isBoostSelectionValid {
    if (_selectedBoostVehicleType == null) {
      return false;
    }

    if (_selectedBoostVehicleType == _electricVehicleType &&
        _selectedBoostPlugType == null) {
      return false;
    }

    return true;
  }

  Future<void> _continueBoostFlow() async {
    if (_selectedBoostVehicleType == null) {
      _showErrorSnackBar('Choose Regular or Electric to continue', Icons.ev_station);
      return;
    }

    if (_selectedBoostVehicleType == _electricVehicleType &&
        _selectedBoostPlugType == null) {
      _showErrorSnackBar('Select your EV plug type to continue', Icons.power);
      return;
    }

    await _openPickupSelector(
      vehicleType: _selectedBoostVehicleType!,
      plugType: _selectedBoostVehicleType == _electricVehicleType
          ? _selectedBoostPlugType
          : null,
    );
  }

  String? get _resolvedTowVehicle {
    final manual = _towManualVehicleController.text.trim();
    if (_showTowManualVehicle && manual.isNotEmpty) {
      return manual;
    }
    return _selectedTowVehicle;
  }

  Future<void> _continueTowStepOne() async {
    final selectedVehicle = _resolvedTowVehicle;
    if (selectedVehicle == null || selectedVehicle.isEmpty) {
      _showErrorSnackBar('Select a vehicle type or enter it manually', Icons.directions_car);
      return;
    }

    setState(() {
      _selectedTowVehicle = selectedVehicle;
      _towStep = 2;
      _flowStep = 2;
    });

    if (_currentPosition != null) {
      await _updateTowDetectedLocation(
        _currentPosition!.latitude,
        _currentPosition!.longitude,
      );
    }
  }

  Future<void> _saveTowCurrentLocation() async {
    if (_towDetectedLocationLatLng == null || _towDetectedLocationAddress == null) {
      _showErrorSnackBar('Current location is not ready yet. Try again in a moment.', Icons.my_location);
      return;
    }

    setState(() {
      _pickupAddress = _towDetectedLocationAddress;
      _pickupLatLng = _towDetectedLocationLatLng;
      _vehicleType = _resolvedTowVehicle;
      _plugType = null;
      _towStep = 3;
      _flowStep = 3;
    });

    _showSuccessSnackBar('Current location saved. Searching nearby tow providers...');
    await _searchNearbyBoosters();
  }

  Future<void> _saveTowManualAddress() async {
    final input = _towManualAddressController.text.trim();
    if (input.isEmpty) {
      _showErrorSnackBar('Enter an address to continue', Icons.search);
      return;
    }

    try {
      final locations = await locationFromAddress(input);
      if (locations.isEmpty) {
        _showErrorSnackBar('Address not found', Icons.search_off);
        return;
      }

      final selected = locations.first;
      if (!mounted) return;
      setState(() {
        _pickupAddress = input;
        _pickupLatLng = LatLng(selected.latitude, selected.longitude);
        _vehicleType = _resolvedTowVehicle;
        _plugType = null;
        _towStep = 3;
        _flowStep = 3;
      });

      _showSuccessSnackBar('Address saved. Searching nearby tow providers...');
      await _searchNearbyBoosters();
    } catch (_) {
      _showErrorSnackBar('Could not resolve address', Icons.cloud_off);
    }
  }

  Future<_TowPricing> _computeTowPricing() async {
    final user = FirebaseAuth.instance.currentUser;
    var applyFirstUseYearlySubscription = false;

    if (user != null) {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final data = userDoc.data() ?? <String, dynamic>{};
      final hasUsedServiceBefore = data['hasUsedServiceBefore'] == true;
      final yearlySubscriptionPaid = data['yearlySubscriptionPaid'] == true;
      applyFirstUseYearlySubscription = !hasUsedServiceBefore && !yearlySubscriptionPaid;
    }

    final isCanadianAddress = (_pickupAddress ?? '').toLowerCase().contains('canada') ||
        (_pickupAddress ?? '').toLowerCase().contains('ontario');
    final taxCents = isCanadianAddress
        ? (_towBaseCadCents * _canadianTaxRate).round()
        : 0;
    final subscriptionCents =
        applyFirstUseYearlySubscription ? _firstUseYearlySubscriptionCadCents : 0;

    return _TowPricing(
      serviceCents: _towBaseCadCents,
      taxCents: taxCents,
      subscriptionCents: subscriptionCents,
      totalCents: _towBaseCadCents + taxCents + subscriptionCents,
    );
  }

  Future<void> _confirmTowPaymentAndPlaceRequest() async {
    if (_selectedTowReason == null || _selectedTowReason!.isEmpty) {
      _showErrorSnackBar('Select a tow reason before requesting', Icons.list_alt);
      return;
    }

    if (_pickupLatLng == null || _pickupAddress == null) {
      _showErrorSnackBar('Please save your pickup location first', Icons.place);
      return;
    }

    if (_nearbyBoosters.isEmpty) {
      _showErrorSnackBar('No tow providers found nearby yet', Icons.search_off);
      return;
    }

    final pricing = await _computeTowPricing();
    if (!mounted) return;

    final proceed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _TowPaymentConfirmScreen(pricing: pricing),
      ),
    );

    if (proceed != true || !mounted) {
      return;
    }

    final nearestProvider = _nearbyBoosters.first;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return;
    }

    try {
      final requestRef = await FirebaseFirestore.instance.collection('requests').add({
        'customerId': user.uid,
        'driverId': nearestProvider.userId,
        'serviceType': _serviceTypeTow,
        'status': 'pending',
        'pickupAddress': _pickupAddress,
        'pickupLatitude': _pickupLatLng!.latitude,
        'pickupLongitude': _pickupLatLng!.longitude,
        'vehicleType': _vehicleType,
        'towVehicleType': _vehicleType,
        'towReason': _selectedTowReason,
        'towNotes': _towNotesController.text.trim().isEmpty
            ? null
            : _towNotesController.text.trim(),
        'serviceChargeCents': pricing.serviceCents,
        'subscriptionChargeCents': pricing.subscriptionCents,
        'taxCents': pricing.taxCents,
        'totalChargeCents': pricing.totalCents,
        'currency': 'cad',
        'timestamp': FieldValue.serverTimestamp(),
      });

      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'hasUsedServiceBefore': true,
        'isSubscribed': pricing.subscriptionCents > 0 ? true : FieldValue.delete(),
        'yearlySubscriptionPaid': pricing.subscriptionCents > 0 ? true : FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (!mounted) return;
      setState(() {
        _activeRequestId = requestRef.id;
        _activeRequestStatus = 'pending';
        _activeDriverId = nearestProvider.userId;
        _towStep = 4;
        _flowStep = 4;
      });

      _showSuccessSnackBar(
        'Tow request sent to nearest provider. Waiting for acceptance...',
      );
    } catch (_) {
      if (!mounted) return;
      _showErrorSnackBar('Could not place tow request. Please try again.', Icons.cloud_off);
    }
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
      _showErrorSnackBar(
        _serviceType == _serviceTypeTow
            ? 'Choose your tow vehicle before requesting help'
            : 'Choose Regular or Electric before inviting a booster',
        Icons.ev_station,
      );
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
        'serviceType': _serviceType,
        'status': 'pending',
        'pickupAddress': _pickupAddress,
        'pickupLatitude': _pickupLatLng!.latitude,
        'pickupLongitude': _pickupLatLng!.longitude,
        'vehicleType': _vehicleType,
        'towVehicleType': _serviceType == _serviceTypeTow ? _vehicleType : null,
        'plugType': _plugType,
        'timestamp': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        setState(() {
          _activeRequestId = docRef.id;
          _activeRequestStatus = 'pending';
          _activeDriverId = driverId;
          _flowStep = 4;
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

    setState(() {
      _isSearchingBoosters = true;
      if (_flowStep < 3) {
        _flowStep = 3;
      }
    });

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
        if (_flowStep < 3) {
          _flowStep = 3;
        }
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
      final requestPickupAddress = data['pickupAddress']?.toString();
      final requestPickupLat = (data['pickupLatitude'] as num?)?.toDouble();
      final requestPickupLng = (data['pickupLongitude'] as num?)?.toDouble();

      setState(() {
        _activeRequestId = doc.id;
        _activeRequestStatus = newStatus;
        _activeDriverId = data['driverId']?.toString();
        _pickupAddress = _pickupAddress ?? requestPickupAddress;
        if (_pickupLatLng == null && requestPickupLat != null && requestPickupLng != null) {
          _pickupLatLng = LatLng(requestPickupLat, requestPickupLng);
        }
        if (newStatus == 'pending' || newStatus == 'awaiting_payment' || newStatus == 'paid' || newStatus == 'accepted' || newStatus == 'en_route') {
          _flowStep = 4;
        }
      });

      // Auto-show payment sheet when booster accepts (fires once)
      if (prevStatus != 'awaiting_payment' && newStatus == 'awaiting_payment') {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showPaymentSheet(doc.id);
        });
      }

      if ((newStatus == 'accepted' || newStatus == 'en_route') &&
          prevStatus != newStatus &&
          _activeDriverId != null) {
        _notifyProviderEta(_activeDriverId!);
      }
    });
  }

  Future<void> _notifyProviderEta(String driverId) async {
    if (_pickupLatLng == null) {
      return;
    }

    try {
      final providerDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(driverId)
          .get();

      if (!mounted || !providerDoc.exists) {
        return;
      }

      final data = providerDoc.data();
      final lat = (data?['latitude'] as num?)?.toDouble();
      final lng = (data?['longitude'] as num?)?.toDouble();
      if (lat == null || lng == null || (lat == 0.0 && lng == 0.0)) {
        _showSuccessSnackBar('Provider accepted and is heading to your location.');
        return;
      }

      final distanceMeters = Geolocator.distanceBetween(
        _pickupLatLng!.latitude,
        _pickupLatLng!.longitude,
        lat,
        lng,
      );
      final distanceKm = distanceMeters / 1000.0;
      final distanceMi = distanceKm * 0.621371;
      final etaMinutes = ((distanceKm / 40.0) * 60.0).ceil().clamp(1, 240);

      final summary =
          'Provider is heading to you • ETA $etaMinutes min • ${distanceKm.toStringAsFixed(1)} km (${distanceMi.toStringAsFixed(1)} mi)';
      if (!mounted) return;
      setState(() {
        _providerEtaSummary = summary;
      });
      _showSuccessSnackBar(summary);
    } catch (_) {
      if (!mounted) return;
      _showSuccessSnackBar('Provider accepted and is heading to your location.');
    }
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
        title: Text(
          _serviceType == _serviceTypeTow
              ? 'Tow Assistance'
              : 'Battery Boost Assistance',
        ),
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
      body: _serviceType == _serviceTypeTow
          ? _buildTowFlow(context)
          : Container(
              color: const Color(0xFFF3F3F7),
              child: SafeArea(
                child: Column(
                  children: [
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
                        children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: const Color(0xFFE1E2EA)),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x11000000),
                            blurRadius: 10,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 56,
                                height: 56,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFCCEFF8),
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  '${_flowStep.clamp(1, 4)}',
                                  style: TextStyle(
                                    color: Color(0xFF0E90AC),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 34,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Choose Your Battery Boost Type',
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineSmall
                                          ?.copyWith(fontWeight: FontWeight.w700),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Pick the exact kind of roadside help you need before we search.',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyLarge
                                          ?.copyWith(color: const Color(0xFF666A7A)),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          _StepProgressRow(activeStep: _flowStep.clamp(1, 4), totalSteps: 4),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Vehicle Type',
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _BoostTypeCard(
                            title: 'Regular Car Boost',
                            subtitle: 'Best for standard gas or hybrid vehicles',
                            icon: Icons.directions_car,
                            selected: _selectedBoostVehicleType == _regularVehicleType,
                            selectedColor: const Color(0xFF6366F1),
                            onTap: () {
                              setState(() {
                                _selectedBoostVehicleType = _regularVehicleType;
                                _selectedBoostPlugType = null;
                              });
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _BoostTypeCard(
                            title: 'Electric Car Boost',
                            subtitle: 'Best for EV roadside battery support',
                            icon: Icons.ev_station,
                            selected: _selectedBoostVehicleType == _electricVehicleType,
                            selectedColor: const Color(0xFF22D3EE),
                            onTap: () {
                              setState(() {
                                _selectedBoostVehicleType = _electricVehicleType;
                                _selectedBoostPlugType ??= _plugTypes.first;
                              });
                            },
                          ),
                        ),
                      ],
                    ),
                    if (_selectedBoostVehicleType == _electricVehicleType) ...[
                      const SizedBox(height: 16),
                      Text(
                        'EV Plug Type',
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 220,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: _plugTypes.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 10),
                          itemBuilder: (context, index) {
                            final plugType = _plugTypes[index];
                            return _PlugTypeCard(
                              plugType: plugType,
                              selected: _selectedBoostPlugType == plugType,
                              onTap: () => setState(() {
                                _selectedBoostPlugType = plugType;
                              }),
                            );
                          },
                        ),
                      ),
                    ],
                    if (_pickupAddress != null) ...[
                      const SizedBox(height: 18),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFFDCE8F8)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Pickup Location Confirmed',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                const Icon(Icons.pin_drop, color: Color(0xFF0EA5E9)),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _pickupAddress!,
                                    style: Theme.of(context).textTheme.bodyLarge,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: () => _openPickupSelector(
                                      vehicleType: _selectedBoostVehicleType ?? _regularVehicleType,
                                      plugType: _selectedBoostPlugType,
                                    ),
                                    icon: const Icon(Icons.edit_location_alt),
                                    label: const Text('Change Location'),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: _isSearchingBoosters ? null : _searchNearbyBoosters,
                                    icon: _isSearchingBoosters
                                        ? const SizedBox(
                                            width: 14,
                                            height: 14,
                                            child: CircularProgressIndicator(strokeWidth: 2),
                                          )
                                        : const Icon(Icons.search),
                                    label: const Text('Search Providers'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Text(
                      'Nearby Service Providers',
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    if (_pickupAddress == null)
                      Text(
                        'Choose boost type and continue to set location first.',
                        style: Theme.of(context)
                            .textTheme
                            .bodyLarge
                            ?.copyWith(color: const Color(0xFF737687)),
                      )
                    else if (_isSearchingBoosters)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 10),
                        child: LinearProgressIndicator(),
                      )
                    else if (_nearbyBoosters.isEmpty)
                      Text(
                        'No providers found nearby yet. Tap Search Providers to refresh.',
                        style: Theme.of(context)
                            .textTheme
                            .bodyLarge
                            ?.copyWith(color: const Color(0xFF737687)),
                      )
                    else
                      Column(
                        children: _nearbyBoosters.map((booster) {
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: const Color(0xFFE2E4ED)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.directions_car, color: Color(0xFF6366F1)),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        booster.displayName,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall
                                            ?.copyWith(fontWeight: FontWeight.w700),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${booster.distanceKm.toStringAsFixed(1)} km • ETA ${booster.etaMinutes} min',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(color: const Color(0xFF6D7182)),
                                      ),
                                    ],
                                  ),
                                ),
                                ElevatedButton(
                                  onPressed: _isWaitingForBooster
                                      ? null
                                      : () => _requestBoost(booster.userId),
                                  child: const Text('Request'),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                    if (_activeRequestId != null) ...[
                      const SizedBox(height: 14),
                      _RequestStatusCard(
                        status: _activeRequestStatus ?? 'pending',
                        driverId: _activeDriverId,
                        onPayNow: _activeRequestStatus == 'awaiting_payment'
                            ? () => _showPaymentSheet(_activeRequestId!)
                            : null,
                      ),
                    ],
                    if (_providerEtaSummary != null) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0EA5E9).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF0EA5E9).withValues(alpha: 0.5)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.local_shipping, color: Color(0xFF0EA5E9)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _providerEtaSummary!,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 6, 18, 12),
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed:
                              _isBoostSelectionValid ? _continueBoostFlow : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF5500FF),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(22),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 18),
                          ),
                          child: const Text(
                            'Continue',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildTowFlow(BuildContext context) {
    final selectedTowVehicle = _resolvedTowVehicle ?? _towVehicleOptions.first;
    final estimatedTowAmount = _estimateTowPrice(selectedTowVehicle);

    return Container(
      color: const Color(0xFFF3F3F7),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: const Color(0xFFE1E2EA)),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x11000000),
                    blurRadius: 10,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: const Color(0xFFCCEFF8),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '${_towStep.clamp(1, 4)}',
                          style: const TextStyle(
                            color: Color(0xFF0E90AC),
                            fontWeight: FontWeight.w700,
                            fontSize: 34,
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _towStep == 1
                                ? 'Choose Tow Type'
                                : _towStep == 2
                                  ? 'Set Your Location'
                                  : _towStep == 3
                                    ? 'Request Tow'
                                    : 'Tow Request Submitted',
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _towStep == 1
                                  ? 'Pick the tow service that matches your vehicle before we search.'
                                : _towStep == 2
                                  ? 'Save your current location or enter a different address.'
                                  : _towStep == 3
                                    ? 'Review your tow request and start finding nearby available providers.'
                                    : 'Waiting for provider acceptance and dispatch updates.',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyLarge
                                  ?.copyWith(color: const Color(0xFF666A7A)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _StepProgressRow(activeStep: _towStep.clamp(1, 4), totalSteps: 4),
                ],
              ),
            ),
            const SizedBox(height: 18),
            if (_towStep == 1) ...[
              Text(
                'Select Your Vehicle Type',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _showTowManualVehicle ? null : _selectedTowVehicle,
                items: _towVehicleOptions
                    .map((v) => DropdownMenuItem<String>(value: v, child: Text(v)))
                    .toList(),
                onChanged: _showTowManualVehicle
                    ? null
                    : (value) {
                        setState(() {
                          _selectedTowVehicle = value;
                        });
                      },
                decoration: const InputDecoration(
                  hintText: 'Choose vehicle',
                ),
              ),
              const SizedBox(height: 10),
              TextButton.icon(
                onPressed: () {
                  setState(() {
                    _showTowManualVehicle = !_showTowManualVehicle;
                    if (_showTowManualVehicle) {
                      _selectedTowVehicle = null;
                    }
                  });
                },
                icon: const Icon(Icons.edit_note),
                label: Text(
                  _showTowManualVehicle
                      ? 'Use dropdown instead'
                      : 'Car not listed? Enter vehicle manually',
                ),
              ),
              if (_showTowManualVehicle) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _towManualVehicleController,
                  decoration: const InputDecoration(
                    labelText: 'Enter vehicle manually',
                    hintText: 'Example: 2020 Ford F-150',
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Text(
                'Selected: $selectedTowVehicle • Estimated total \$$estimatedTowAmount (incl. tax)',
                style: Theme.of(context)
                    .textTheme
                    .bodyLarge
                    ?.copyWith(color: const Color(0xFF6D7182)),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _continueTowStepOne,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF5500FF),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(22),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 18),
                  ),
                  child: const Text(
                    'Continue',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ] else ...[
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFFD6D7E0)),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            onPressed: () => setState(() => _towLocationTabIndex = 0),
                            child: Text(
                              'Current Location',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: _towLocationTabIndex == 0
                                    ? const Color(0xFF5500FF)
                                    : const Color(0xFF222638),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: TextButton(
                            onPressed: () => setState(() => _towLocationTabIndex = 1),
                            child: Text(
                              'Enter a Different Address',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: _towLocationTabIndex == 1
                                    ? const Color(0xFF5500FF)
                                    : const Color(0xFF222638),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    Container(
                      height: 3,
                      margin: const EdgeInsets.symmetric(horizontal: 14),
                      child: Row(
                        children: [
                          Expanded(
                            child: Container(
                              decoration: BoxDecoration(
                                color: _towLocationTabIndex == 0
                                    ? const Color(0xFF5500FF)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Container(
                              decoration: BoxDecoration(
                                color: _towLocationTabIndex == 1
                                    ? const Color(0xFF5500FF)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_towLocationTabIndex == 0)
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 14),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF7F7FA),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFFD6D7E0)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.my_location, color: Color(0xFF2BC8E8)),
                                SizedBox(width: 8),
                                Text('Detected Location', style: TextStyle(fontWeight: FontWeight.w700)),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _towDetectedLocationAddress ?? 'Detecting current location...',
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                          ],
                        ),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: TextField(
                          controller: _towManualAddressController,
                          decoration: const InputDecoration(
                            labelText: 'Enter address',
                            prefixIcon: Icon(Icons.search),
                          ),
                        ),
                      ),
                    const SizedBox(height: 14),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _towLocationTabIndex == 0
                              ? _saveTowCurrentLocation
                              : _saveTowManualAddress,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF5500FF),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          child: Text(
                            _towLocationTabIndex == 0
                                ? 'Save Current Location'
                                : 'Save Address',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_pickupAddress != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFD6D7E0)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Current Selection',
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          const Icon(Icons.place, color: Color(0xFF6366F1)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _pickupAddress!,
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Icon(Icons.directions_car, color: Color(0xFF6366F1)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _vehicleType ?? _resolvedTowVehicle ?? 'Tow vehicle',
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFD6D7E0)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Ready to Request?',
                        style: Theme.of(context)
                            .textTheme
                            .headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'We will search for tow providers currently available near your saved location.',
                        style: Theme.of(context)
                            .textTheme
                            .bodyLarge
                            ?.copyWith(color: const Color(0xFF6D7182)),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        value: _selectedTowReason,
                        items: _towReasons
                            .map((reason) => DropdownMenuItem<String>(
                                  value: reason,
                                  child: Text(reason),
                                ))
                            .toList(),
                        onChanged: (value) {
                          setState(() => _selectedTowReason = value);
                        },
                        decoration: const InputDecoration(
                          hintText: 'Reason for tow',
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _towNotesController,
                        minLines: 2,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          hintText: 'Extra notes (optional)',
                          prefixIcon: Icon(Icons.sticky_note_2_outlined),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _confirmTowPaymentAndPlaceRequest,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF5500FF),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          child: Text(
                            'Request Tow • Pay \$${_estimateTowPrice(_vehicleType ?? _resolvedTowVehicle ?? _towVehicleOptions.first)}',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                if (_isSearchingBoosters)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: LinearProgressIndicator(),
                  )
                else
                  Text(
                    _nearbyBoosters.isEmpty
                        ? 'No nearby tow providers found yet. Update location and try again.'
                        : '${_nearbyBoosters.length} nearby tow providers found. Nearest ETA ${_nearbyBoosters.first.etaMinutes} min.',
                    style: Theme.of(context)
                        .textTheme
                        .bodyLarge
                        ?.copyWith(color: const Color(0xFF6D7182)),
                  ),
              ],
              if (_activeRequestId != null) ...[
                const SizedBox(height: 12),
                _RequestStatusCard(
                  status: _activeRequestStatus ?? 'pending',
                  driverId: _activeDriverId,
                  onPayNow: _activeRequestStatus == 'awaiting_payment'
                      ? () => _showPaymentSheet(_activeRequestId!)
                      : null,
                ),
              ],
              if (_providerEtaSummary != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0EA5E9).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF0EA5E9).withValues(alpha: 0.5)),
                  ),
                  child: Text(_providerEtaSummary!, style: Theme.of(context).textTheme.bodyMedium),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  String _estimateTowPrice(String vehicleTypeLabel) {
    final normalized = vehicleTypeLabel.toLowerCase();
    if (normalized.contains('pickup') || normalized.contains('van')) {
      return '282.50';
    }
    if (normalized.contains('suv')) {
      return '209.05';
    }
    return '152.55';
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

class _TowPricing {
  const _TowPricing({
    required this.serviceCents,
    required this.taxCents,
    required this.subscriptionCents,
    required this.totalCents,
  });

  final int serviceCents;
  final int taxCents;
  final int subscriptionCents;
  final int totalCents;
}

class _TowPaymentConfirmScreen extends StatelessWidget {
  const _TowPaymentConfirmScreen({required this.pricing});

  final _TowPricing pricing;

  String _toCad(int cents) => (cents / 100).toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Confirm Payment'),
      ),
      body: Container(
        color: const Color(0xFFF3F3F7),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFE1E2EA)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Service Payment',
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Review your service charge below before confirming payment.',
                    style: Theme.of(context)
                        .textTheme
                        .bodyLarge
                        ?.copyWith(color: const Color(0xFF6D7182)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFE1E2EA)),
              ),
              child: Column(
                children: [
                  _PaymentLine(label: 'Tow service', value: '\$${_toCad(pricing.serviceCents)}'),
                  if (pricing.subscriptionCents > 0)
                    _PaymentLine(
                      label: 'Yearly subscription (first-time user)',
                      value: '\$${_toCad(pricing.subscriptionCents)}',
                    ),
                  _PaymentLine(label: 'Tax', value: '\$${_toCad(pricing.taxCents)}'),
                  const Divider(height: 24),
                  _PaymentLine(
                    label: 'Service Total',
                    value: '\$${_toCad(pricing.totalCents)}',
                    bold: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF5500FF),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: const Text(
                'Continue to Payment',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(false),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF5500FF),
                side: const BorderSide(color: Colors.black54),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: const Text(
                'Cancel',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PaymentLine extends StatelessWidget {
  const _PaymentLine({
    required this.label,
    required this.value,
    this.bold = false,
  });

  final String label;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: bold ? const Color(0xFF1F2233) : const Color(0xFF6D7182),
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                ),
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: const Color(0xFF1F2233),
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
                ),
          ),
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

class _StepProgressRow extends StatelessWidget {
  const _StepProgressRow({
    required this.activeStep,
    required this.totalSteps,
  });

  final int activeStep;
  final int totalSteps;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List<Widget>.generate(totalSteps, (index) {
        final isActive = index < activeStep;
        return Expanded(
          child: Container(
            height: 10,
            margin: EdgeInsets.only(right: index == totalSteps - 1 ? 0 : 10),
            decoration: BoxDecoration(
              color: isActive ? const Color(0xFF2BC8E8) : const Color(0xFFE3E3EB),
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
      }),
    );
  }
}

class _BoostTypeCard extends StatelessWidget {
  const _BoostTypeCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.selected,
    required this.selectedColor,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool selected;
  final Color selectedColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? selectedColor.withValues(alpha: 0.14) : Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: selected ? selectedColor.withValues(alpha: 0.9) : const Color(0xFFD6D7E0),
            width: selected ? 2 : 1.3,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: selectedColor.withValues(alpha: 0.16),
                    blurRadius: 22,
                    spreadRadius: 3,
                  ),
                ]
              : const [],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: selectedColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(icon, color: const Color(0xFF6B7280), size: 33),
                ),
                const Spacer(),
                if (selected)
                  Icon(Icons.check_circle, color: selectedColor, size: 34),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(color: const Color(0xFF666A7A)),
            ),
          ],
        ),
      ),
    );
  }
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
  const _PickupSelectorSheet({
    required this.initialVehicleType,
    this.initialPlugType,
    this.lockVehicleSelection = false,
  });

  final String initialVehicleType;
  final String? initialPlugType;
  final bool lockVehicleSelection;

  @override
  State<_PickupSelectorSheet> createState() => _PickupSelectorSheetState();
}

class _PickupSelectorSheetState extends State<_PickupSelectorSheet> {
  final TextEditingController _addressController = TextEditingController();
  bool _isSaving = false;
  String? _error;
  bool _isLoadingCurrentLocationPreview = false;
  String? _currentLocationPreviewAddress;
  late String _selectedVehicleType;
  String? _selectedPlugType;

  @override
  void initState() {
    super.initState();
    _selectedVehicleType = widget.initialVehicleType;
    _selectedPlugType = widget.initialVehicleType == _electricVehicleType
        ? (widget.initialPlugType ?? _plugTypes.first)
        : null;
    _loadCurrentLocationPreview();
  }

  Future<void> _loadCurrentLocationPreview() async {
    setState(() {
      _isLoadingCurrentLocationPreview = true;
    });

    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (!mounted) return;
        setState(() {
          _isLoadingCurrentLocationPreview = false;
          _currentLocationPreviewAddress =
              'Location permission is off. Enable it to auto-detect your address.';
        });
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      var displayAddress =
          'Current location (${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)})';
      try {
        final places = await placemarkFromCoordinates(
          position.latitude,
          position.longitude,
        );
        if (places.isNotEmpty) {
          final p = places.first;
          final parts = <String>[
            if ((p.street ?? '').isNotEmpty) p.street!,
            if ((p.locality ?? '').isNotEmpty) p.locality!,
            if ((p.administrativeArea ?? '').isNotEmpty) p.administrativeArea!,
          ];
          if (parts.isNotEmpty) {
            displayAddress = parts.join(', ');
          }
        }
      } catch (_) {
        // Keep coordinate fallback.
      }

      if (!mounted) return;
      setState(() {
        _isLoadingCurrentLocationPreview = false;
        _currentLocationPreviewAddress = displayAddress;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoadingCurrentLocationPreview = false;
        _currentLocationPreviewAddress =
            'Could not detect your address yet. You can still tap Save Current Location.';
      });
    }
  }

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
            if (!widget.lockVehicleSelection)
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
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF7F7FA),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFD6D7E0)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.my_location, color: Color(0xFF2BC8E8)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _isLoadingCurrentLocationPreview
                                    ? 'Detecting your current address...'
                                    : (_currentLocationPreviewAddress ??
                                        'Use your current GPS location as pickup address.'),
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(color: const Color(0xFF6D7182)),
                              ),
                            ),
                          ],
                        ),
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

const String _serviceTypeBoost = 'boost';
const String _serviceTypeTow = 'tow';
const int _towBaseCadCents = 2000;
const int _firstUseYearlySubscriptionCadCents = 900;
const double _canadianTaxRate = 0.13;

const String _regularVehicleType = 'regular';
const String _electricVehicleType = 'electric';
const List<String> _towVehicleOptions = <String>[
  'Car Tow',
  'SUV Tow',
  'Pickup / Van Tow',
  'Motorcycle Tow',
  'Light Truck Tow',
];

const List<String> _towReasons = <String>[
  'Mechanical breakdown',
  'Flat tire',
  'Accident',
  'Out of fuel',
  'Vehicle won\'t start',
  'Vehicle stuck',
  'Other',
];
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