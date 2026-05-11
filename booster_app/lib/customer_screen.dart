import 'package:flutter/material.dart';
import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geocoding/geocoding.dart';
import 'package:flutter/services.dart';
import 'login_screen.dart';
import 'paywall_screen.dart';
import 'review_screen.dart';
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
  final List<String> _boostRetryQueue = <String>[];
  int _boostRetryQueueIndex = 0;
  bool _searchTimeoutPersistedForCurrentCycle = false;

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _requestWatchSub;
  String? _activeRequestId;
  String? _activeRequestStatus;
  String? _activeDriverId;
  String? _activeServiceType;
  String? _providerEtaSummary;

  // Step 4 tracking
  String? _providerDisplayName;
  double? _providerDistanceKm;
  int? _providerEtaMinutes;
  double? _providerLat;
  double? _providerLng;
  bool _showTrackingMap = false;
  bool _isCompletingJob = false;
  bool _noProvidersFound = false;

  // Search timeout tracking (30 minutes = 1800 seconds)
  DateTime? _searchStartTime;
  Timer? _searchTimeoutTimer;
  Timer? _searchCountdownTicker;
  bool _searchTimedOut = false;
  int _resendAttempts = 0;
  int _searchRemainingSeconds = 30 * 60;
  bool _shareDialogShownForCurrentTimeout = false;
  bool get _isWaitingForBooster {
    return _activeRequestStatus == 'pending' ||
        _activeRequestStatus == 'paid' ||
      _activeRequestStatus == 'expired' ||
        _activeRequestStatus == 'accepted' ||
        _activeRequestStatus == 'en_route';
  }

  bool get _isSearchWindowStatus {
    return _activeRequestStatus == 'pending' || _activeRequestStatus == 'paid';
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
    _searchTimeoutTimer?.cancel();
    _searchCountdownTicker?.cancel();
    super.dispose();
  }

  String _formatCountdown(int totalSeconds) {
    final clamped = totalSeconds < 0 ? 0 : totalSeconds;
    final minutes = (clamped ~/ 60).toString().padLeft(2, '0');
    final seconds = (clamped % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  void _startSearchCycleCountdown({DateTime? startedAt}) {
    final start = startedAt ?? DateTime.now();
    final elapsed = DateTime.now().difference(start).inSeconds;
    final remaining = (30 * 60) - elapsed;

    _searchTimeoutTimer?.cancel();
    _searchCountdownTicker?.cancel();

    if (!mounted) {
      return;
    }

    if (remaining <= 0) {
      setState(() {
        _searchStartTime = start;
        _searchRemainingSeconds = 0;
        _searchTimedOut = true;
      });
      return;
    }

    setState(() {
      _searchStartTime = start;
      _searchRemainingSeconds = remaining;
      _searchTimedOut = false;
      _searchTimeoutPersistedForCurrentCycle = false;
    });

    _searchTimeoutTimer = Timer(Duration(seconds: remaining), () {
      if (!mounted) return;
      _handleSearchCycleTimeout();
    });

    _searchCountdownTicker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final updatedRemaining = (30 * 60) - DateTime.now().difference(start).inSeconds;
      if (updatedRemaining <= 0) {
        timer.cancel();
        _handleSearchCycleTimeout();
      } else {
        setState(() {
          _searchRemainingSeconds = updatedRemaining;
        });
      }
    });
  }

  void _stopSearchCycleCountdown({bool clearStartTime = false}) {
    _searchTimeoutTimer?.cancel();
    _searchCountdownTicker?.cancel();
    if (!mounted) return;
    setState(() {
      if (clearStartTime) {
        _searchStartTime = null;
      }
      _searchRemainingSeconds = 30 * 60;
      _searchTimedOut = false;
      _searchTimeoutPersistedForCurrentCycle = false;
    });
  }

  void _handleSearchCycleTimeout() {
    if (!mounted) return;
    final shouldPersist = !_searchTimeoutPersistedForCurrentCycle;
    setState(() {
      _searchRemainingSeconds = 0;
      _searchTimedOut = true;
      _searchTimeoutPersistedForCurrentCycle = true;
    });

    if (shouldPersist) {
      _persistSearchTimeout();
      _trackBoostFlowEvent(
        'search_cycle_timeout',
        details: <String, dynamic>{
          'resendAttempts': _resendAttempts,
          'activeStatus': _activeRequestStatus,
        },
      );
    }
  }

  Future<void> _persistSearchTimeout() async {
    final requestId = _activeRequestId;
    if (requestId == null) {
      return;
    }
    try {
      await FirebaseFirestore.instance.collection('requests').doc(requestId).update({
        'status': 'expired',
        'expiredAt': FieldValue.serverTimestamp(),
        'searchCycleTimedOutAt': FieldValue.serverTimestamp(),
        'searchTimeoutCount': FieldValue.increment(1),
        'lastSearchCycleResult': 'timeout',
        'resendAttempts': _resendAttempts,
      });
    } catch (_) {
      // Keep UI flow going even if analytics/state persistence fails.
    }
  }

  void _rebuildBoostRetryQueue({String? rotateAfterDriverId}) {
    final ids = _nearbyBoosters.map((b) => b.userId).toList();
    if (ids.isEmpty) {
      _boostRetryQueue
        ..clear();
      _boostRetryQueueIndex = 0;
      return;
    }

    if (rotateAfterDriverId != null) {
      final currentIndex = ids.indexOf(rotateAfterDriverId);
      if (currentIndex >= 0) {
        final rotated = <String>[];
        for (var i = 1; i <= ids.length; i++) {
          rotated.add(ids[(currentIndex + i) % ids.length]);
        }
        _boostRetryQueue
          ..clear()
          ..addAll(rotated);
        _boostRetryQueueIndex = 0;
        return;
      }
    }

    _boostRetryQueue
      ..clear()
      ..addAll(ids);
    _boostRetryQueueIndex = 0;
  }

  String? _nextBoostProviderFromQueue() {
    if (_boostRetryQueue.isEmpty) {
      return null;
    }
    final providerId = _boostRetryQueue[_boostRetryQueueIndex % _boostRetryQueue.length];
    _boostRetryQueueIndex = (_boostRetryQueueIndex + 1) % _boostRetryQueue.length;
    return providerId;
  }

  Future<void> _trackBoostFlowEvent(
    String eventName, {
    Map<String, dynamic>? details,
  }) async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) {
      return;
    }
    try {
      await FirebaseFirestore.instance.collection('analytics_events').add({
        'eventName': eventName,
        'userId': userId,
        'requestId': _activeRequestId,
        'serviceType': _serviceType,
        'activeStatus': _activeRequestStatus,
        'resendAttempts': _resendAttempts,
        'flowStep': _flowStep,
        'details': details ?? <String, dynamic>{},
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // Ignore analytics write failures.
    }
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
        if (preferred == _serviceTypeTow || preferred == _serviceTypeMechanic) {
          _serviceType = preferred!;
        } else {
          _serviceType = _serviceTypeBoost;
        }
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

    final data = userDoc.data() ?? <String, dynamic>{};
    final bool isSubscribed = data['yearlySubscriptionPaid'] == true || data['isSubscribed'] == true;
    if (isSubscribed) {
      return true;
    }

    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => PaywallScreen(
          isFirstTimer: true,
          pickupAddress: _pickupAddress,
        ),
      ),
    );

    return result == true;
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

  String _serviceLabel(String serviceType) {
    switch (serviceType) {
      case _serviceTypeTow:
        return 'Tow Assistance';
      case _serviceTypeMechanic:
        return 'Mobile Mechanic';
      default:
        return 'Battery Boost';
    }
  }

  Future<bool> _hasConcurrentActiveRequest(String customerId) async {
    final activeSnapshot = await FirebaseFirestore.instance
        .collection('requests')
        .where('customerId', isEqualTo: customerId)
      .where('status', whereIn: ['pending', 'awaiting_payment', 'paid', 'expired', 'accepted', 'en_route'])
        .limit(1)
        .get();

    if (activeSnapshot.docs.isEmpty) {
      return false;
    }

    if (!mounted) {
      return true;
    }

    final activeData = activeSnapshot.docs.first.data();
    final activeServiceType = activeData['serviceType']?.toString() ?? _serviceTypeBoost;
    final activeLabel = _serviceLabel(activeServiceType);
    _showErrorSnackBar(
      'You already have an active $activeLabel request. Complete it before starting another service.',
      Icons.block,
    );
    return true;
  }

  Future<void> _confirmTowPaymentAndPlaceRequest() async {
    if (_selectedTowReason == null || _selectedTowReason!.isEmpty) {
      _showErrorSnackBar(
        _serviceType == _serviceTypeMechanic
            ? 'Select an issue type before requesting'
            : 'Select a tow reason before requesting',
        Icons.list_alt,
      );
      return;
    }

    if (_pickupLatLng == null || _pickupAddress == null) {
      _showErrorSnackBar('Please save your pickup location first', Icons.place);
      return;
    }

    if (_nearbyBoosters.isEmpty) {
      _showErrorSnackBar(
        _serviceType == _serviceTypeMechanic
            ? 'No mobile mechanics found nearby yet'
            : 'No tow providers found nearby yet',
        Icons.search_off,
      );
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return;
    }

    if (await _hasConcurrentActiveRequest(user.uid)) {
      return;
    }

    final pricing = await _computeTowPricing();
    if (!mounted) return;

    final proceed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _TowPaymentConfirmScreen(
          pricing: pricing,
          serviceLabel: _serviceType == _serviceTypeMechanic
              ? 'Mobile mechanic service'
              : 'Tow service',
        ),
      ),
    );

    if (proceed != true || !mounted) {
      return;
    }

    if (await _hasConcurrentActiveRequest(user.uid)) {
      return;
    }

    final nearestProvider = _nearbyBoosters.first;

    try {
      final requestRef = await FirebaseFirestore.instance.collection('requests').add({
        'customerId': user.uid,
        'driverId': nearestProvider.userId,
        'serviceType': _serviceType,
        'status': 'paid',
        'paidAt': FieldValue.serverTimestamp(),
        'paymentProvider': 'in_app',
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
        _activeRequestStatus = 'paid';
        _activeDriverId = nearestProvider.userId;
        _activeServiceType = _serviceType;
        _towStep = 4;
        _flowStep = 4;
        _shareDialogShownForCurrentTimeout = false;
      });
      _startSearchCycleCountdown();

      _showSuccessSnackBar(
        _serviceType == _serviceTypeMechanic
        ? 'Payment confirmed. Mobile mechanic request sent to nearest provider.'
        : 'Payment confirmed. Tow request sent to nearest provider.',
      );
    } catch (_) {
      if (!mounted) return;
      _showErrorSnackBar(
        _serviceType == _serviceTypeMechanic
            ? 'Could not place mobile mechanic request. Please try again.'
            : 'Could not place tow request. Please try again.',
        Icons.cloud_off,
      );
    }
  }

  Future<void> _confirmBoostAndRequest() async {
    if (_pickupLatLng == null || _pickupAddress == null) {
      _showErrorSnackBar('No location set', Icons.place);
      return;
    }
    if (_isSearchingBoosters) return;

    // Check subscription status and show paywall
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    if (await _hasConcurrentActiveRequest(user.uid)) {
      return;
    }

    final userDoc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
    if (!mounted) return;
    final data = userDoc.data() ?? <String, dynamic>{};
    final isFirstTimer = !(data['yearlySubscriptionPaid'] == true);

    final proceed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PaywallScreen(
          isFirstTimer: isFirstTimer,
          pickupAddress: _pickupAddress,
        ),
      ),
    );
    if (proceed != true || !mounted) return;

    // Now search and place request
    setState(() {
      _isSearchingBoosters = true;
      _flowStep = 4;
      _noProvidersFound = false;
      _shareDialogShownForCurrentTimeout = false;
      _resendAttempts = 0;
    });
    _boostRetryQueue
      ..clear();
    _boostRetryQueueIndex = 0;
    _startSearchCycleCountdown();
    await _searchNearbyBoosters();
    if (!mounted) return;

    if (_nearbyBoosters.isEmpty) {
      setState(() => _noProvidersFound = true);
      await _trackBoostFlowEvent(
        'initial_search_no_providers',
        details: <String, dynamic>{
          'pickupAddress': _pickupAddress,
        },
      );
      return;
    }

    _rebuildBoostRetryQueue();
    final providerId = _nextBoostProviderFromQueue() ?? _nearbyBoosters.first.userId;
    await _requestBoost(providerId);
  }

  Future<void> _requestBoost(String driverId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    if (await _hasConcurrentActiveRequest(user.uid)) {
      return;
    }

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
        'status': 'paid',
        'paidAt': FieldValue.serverTimestamp(),
        'paymentAmount': boostPaymentTotalCadCents,
        'paymentCurrency': 'cad',
        'paymentProvider': 'in_app',
        'pickupAddress': _pickupAddress,
        'pickupLatitude': _pickupLatLng!.latitude,
        'pickupLongitude': _pickupLatLng!.longitude,
        'vehicleType': _vehicleType,
        'towVehicleType': _serviceType == _serviceTypeTow ? _vehicleType : null,
        'plugType': _plugType,
        'dispatchMode': 'retry_queue',
        'resendAttempts': _resendAttempts,
        'searchTimeoutCount': 0,
        'attemptedDriverIds': FieldValue.arrayUnion([driverId]),
        'lastDispatchedDriverId': driverId,
        'lastDispatchedAt': FieldValue.serverTimestamp(),
        'timestamp': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        setState(() {
          _activeRequestId = docRef.id;
          _activeRequestStatus = 'paid';
          _activeDriverId = driverId;
          _activeServiceType = _serviceTypeBoost;
          _flowStep = 4;
          _shareDialogShownForCurrentTimeout = false;
        });
        _startSearchCycleCountdown();
        _showSuccessSnackBar(
          'Payment confirmed. Request sent and waiting for provider acceptance.',
        );
        await _trackBoostFlowEvent(
          'boost_request_dispatched',
          details: <String, dynamic>{
            'driverId': driverId,
            'queueSize': _boostRetryQueue.length,
            'pickupAddress': _pickupAddress,
          },
        );
      }
    } catch (e) {
      if (mounted) {
        _showErrorSnackBar(
          'Failed to send request. Please try again',
          Icons.cloud_off,
        );
        await _trackBoostFlowEvent(
          'boost_request_dispatch_failed',
          details: <String, dynamic>{
            'driverId': driverId,
          },
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
        await _trackBoostFlowEvent('provider_search_completed', details: <String, dynamic>{
          'providerCount': 0,
        });
      } else {
        _showSuccessSnackBar('${boosters.length} boosters found nearby');
        await _trackBoostFlowEvent('provider_search_completed', details: <String, dynamic>{
          'providerCount': boosters.length,
        });
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
        _stopSearchCycleCountdown(clearStartTime: true);
        setState(() {
          _activeRequestId = null;
          _activeRequestStatus = null;
          _activeDriverId = null;
          _activeServiceType = null;
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
      final paidAtTimestamp = data['paidAt'] as Timestamp?;
      final createdTimestamp = data['timestamp'] as Timestamp?;
      final cycleStart = (paidAtTimestamp ?? createdTimestamp)?.toDate();

      setState(() {
        _activeRequestId = doc.id;
        _activeRequestStatus = newStatus;
        _activeDriverId = data['driverId']?.toString();
        _activeServiceType = data['serviceType']?.toString();
        // Keep the screen service context aligned with the active request.
        if (_activeServiceType == _serviceTypeBoost ||
            _activeServiceType == _serviceTypeTow ||
            _activeServiceType == _serviceTypeMechanic) {
          _serviceType = _activeServiceType!;
        }
        _pickupAddress = _pickupAddress ?? requestPickupAddress;
        if (_pickupLatLng == null && requestPickupLat != null && requestPickupLng != null) {
          _pickupLatLng = LatLng(requestPickupLat, requestPickupLng);
        }
        if (newStatus == 'pending' ||
            newStatus == 'paid' ||
            newStatus == 'expired' ||
            newStatus == 'accepted' ||
            newStatus == 'en_route') {
          _flowStep = 4;
        }
      });

      if (newStatus == 'pending' || newStatus == 'paid') {
        _startSearchCycleCountdown(startedAt: cycleStart);
      } else {
        _stopSearchCycleCountdown(clearStartTime: true);
      }

      if ((newStatus == 'accepted' || newStatus == 'en_route') &&
          prevStatus != newStatus &&
          _activeDriverId != null) {
        setState(() {
          _isSearchingBoosters = false;
          _resendAttempts = 0;
        });
        _notifyProviderEta(_activeDriverId!);
      }

      // Trigger review prompt when job completes
      if (prevStatus != 'completed' && newStatus == 'completed') {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _promptReview(doc.id);
        });
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
      final name = (data?['displayName'] as String?) ??
          (data?['name'] as String?) ??
          'Your Provider';

      if (lat == null || lng == null || (lat == 0.0 && lng == 0.0)) {
        if (!mounted) return;
        setState(() {
          _providerDisplayName = name;
          _providerEtaSummary = '$name is heading to your location.';
        });
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
          '$name is heading to you • ETA $etaMinutes min • ${distanceKm.toStringAsFixed(1)} km (${distanceMi.toStringAsFixed(1)} mi)';
      if (!mounted) return;
      setState(() {
        _providerDisplayName = name;
        _providerDistanceKm = distanceKm;
        _providerEtaMinutes = etaMinutes;
        _providerLat = lat;
        _providerLng = lng;
        _providerEtaSummary = summary;
      });
      _showSuccessSnackBar(summary);
    } catch (_) {
      if (!mounted) return;
      _showSuccessSnackBar('Provider accepted and is heading to your location.');
    }
  }

  Future<void> _markJobComplete() async {
    if (_activeRequestId == null || _isCompletingJob) return;
    setState(() => _isCompletingJob = true);
    try {
      await FirebaseFirestore.instance
          .collection('requests')
          .doc(_activeRequestId)
          .update({
        'status': 'completed',
        'completedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (mounted) {
        _showErrorSnackBar('Could not mark complete. Try again.', Icons.error);
      }
    } finally {
      if (mounted) setState(() => _isCompletingJob = false);
    }
  }

  Future<void> _resendActiveBoostRequest() async {
    final requestId = _activeRequestId;
    if (requestId == null) {
      _showErrorSnackBar('No active request to resend.', Icons.info_outline);
      return;
    }

    setState(() {
      _isSearchingBoosters = true;
      _searchTimedOut = false;
      _resendAttempts++;
      _shareDialogShownForCurrentTimeout = false;
    });
    _startSearchCycleCountdown();

    await _searchNearbyBoosters();
    if (!mounted) return;

    if (_nearbyBoosters.isEmpty) {
      setState(() {
        _isSearchingBoosters = false;
      });
      _showErrorSnackBar('No providers available to resend right now.', Icons.search_off);
      await _trackBoostFlowEvent('resend_search_no_providers');
      return;
    }

    _rebuildBoostRetryQueue(rotateAfterDriverId: _activeDriverId);
    final targetProviderId = _nextBoostProviderFromQueue();
    if (targetProviderId == null) {
      setState(() {
        _isSearchingBoosters = false;
      });
      _showErrorSnackBar('No providers available to resend right now.', Icons.search_off);
      await _trackBoostFlowEvent('resend_queue_empty');
      return;
    }

    try {
      await FirebaseFirestore.instance.collection('requests').doc(requestId).update({
        'driverId': targetProviderId,
        'status': 'paid',
        'paidAt': FieldValue.serverTimestamp(),
        'resentAt': FieldValue.serverTimestamp(),
        'resendAttempts': _resendAttempts,
        'lastSearchCycleResult': 'resent',
        'attemptedDriverIds': FieldValue.arrayUnion([targetProviderId]),
        'lastDispatchedDriverId': targetProviderId,
        'lastDispatchedAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      setState(() {
        _activeDriverId = targetProviderId;
        _activeRequestStatus = 'paid';
        _isSearchingBoosters = true;
      });
      _showSuccessSnackBar('Request resent to a nearby provider.');
      await _trackBoostFlowEvent(
        'request_resent',
        details: <String, dynamic>{
          'driverId': targetProviderId,
          'queueSize': _boostRetryQueue.length,
        },
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isSearchingBoosters = false;
      });
      _showErrorSnackBar('Could not resend request. Please try again.', Icons.cloud_off);
      await _trackBoostFlowEvent('request_resend_failed');
    }
  }

  Future<void> _cancelActiveBoostRequest() async {
    final requestId = _activeRequestId;

    _stopSearchCycleCountdown(clearStartTime: true);

    try {
      if (requestId != null) {
        await FirebaseFirestore.instance.collection('requests').doc(requestId).update({
          'status': 'cancelled',
          'cancelledAt': FieldValue.serverTimestamp(),
          'cancelledBy': 'customer',
        });
      }

      if (!mounted) return;
      setState(() {
        _isSearchingBoosters = false;
        _searchTimedOut = false;
        _resendAttempts = 0;
        _shareDialogShownForCurrentTimeout = false;
        _flowStep = 1;
        _activeRequestId = null;
        _activeRequestStatus = null;
        _activeDriverId = null;
        _activeServiceType = null;
        _providerEtaSummary = null;
        _providerDisplayName = null;
        _providerDistanceKm = null;
        _providerEtaMinutes = null;
        _providerLat = null;
        _providerLng = null;
        _boostRetryQueue.clear();
        _boostRetryQueueIndex = 0;
      });
      _showSuccessSnackBar('Request cancelled. You can start a new boost request.');
      await _trackBoostFlowEvent('request_cancelled_by_customer');
    } catch (_) {
      if (!mounted) return;
      _showErrorSnackBar('Could not cancel request. Please try again.', Icons.cloud_off);
      await _trackBoostFlowEvent('request_cancel_failed');
    }
  }

  Future<void> _promptReview(String requestId) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReviewScreen(
          requestId: requestId,
          providerName: _providerDisplayName ?? 'Your Provider',
          isCustomerReviewing: true,
        ),
      ),
    );
    if (!mounted) return;
    // Reset flow after review
    setState(() {
      _flowStep = 1;
      _activeRequestId = null;
      _activeRequestStatus = null;
      _activeDriverId = null;
      _activeServiceType = null;
      _providerEtaSummary = null;
      _providerDisplayName = null;
      _providerDistanceKm = null;
      _providerEtaMinutes = null;
      _providerLat = null;
      _providerLng = null;
      _noProvidersFound = false;
      _isSearchingBoosters = false;
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
    final hasActiveOrder = _activeRequestId != null ||
        _activeRequestStatus == 'paid' ||
      _activeRequestStatus == 'expired' ||
        _activeRequestStatus == 'accepted' ||
        _activeRequestStatus == 'en_route' ||
        _activeRequestStatus == 'completed';
    
    // Only show tracking screen if active request matches selected service type
    final showActiveOrderTracking = hasActiveOrder && 
        (_activeServiceType == _serviceType);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _serviceType == _serviceTypeTow
            ? 'Tow Assistance'
            : _serviceType == _serviceTypeMechanic
              ? 'Mobile Mechanic Assistance'
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
      body: showActiveOrderTracking
          ? _buildBoostStep4(context)
          : (_serviceType == _serviceTypeTow || _serviceType == _serviceTypeMechanic)
              ? _buildTowFlow(context)
              : _buildBoostFlow(context),
    );
  }

  Widget _buildBoostFlow(BuildContext context) {
    final hasActiveBoostRequest = _activeRequestId != null ||
        _isWaitingForBooster ||
        _activeRequestStatus == 'paid' ||
      _activeRequestStatus == 'expired' ||
        _activeRequestStatus == 'accepted' ||
        _activeRequestStatus == 'en_route' ||
        _activeRequestStatus == 'completed';

    // ── Step 4: Tracking ──────────────────────────────────────────────────
    if (_flowStep == 4 || hasActiveBoostRequest) {
      return _buildBoostStep4(context);
    }

    // ── Step 3: Review & Pay ──────────────────────────────────────────────
    if (_flowStep == 3) {
      final vehicleLabel = _selectedBoostVehicleType == _electricVehicleType
          ? 'Electric Car Boost${_selectedBoostPlugType != null ? ' (${_selectedBoostPlugType})' : ''}'
          : 'Regular Car Boost';
      final priceDisplay =
          '\$${(boostPaymentTotalCadCents / 100).toStringAsFixed(2)}';

      return Container(
        color: const Color(0xFFF3F3F7),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
            children: [
              // Step header
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: const Color(0xFFE1E2EA)),
                  boxShadow: const [
                    BoxShadow(color: Color(0x11000000), blurRadius: 10, offset: Offset(0, 2)),
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
                          child: const Text(
                            '3',
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
                                'Request Battery Boost',
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Review your request including location address before requesting.',
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
                    _StepProgressRow(activeStep: 3, totalSteps: 4),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              // Current Selection card
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFFE1E2EA)),
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
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Icon(Icons.directions_car, color: Color(0xFF2BC8E8)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(vehicleLabel,
                              style: Theme.of(context).textTheme.bodyLarge),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        const Icon(Icons.place, color: Color(0xFF6366F1)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(_pickupAddress ?? '',
                              style: Theme.of(context).textTheme.bodyLarge),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              // Ready to Request card
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFFE1E2EA)),
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
                      'We will search for battery boost providers currently available near your saved location.',
                      style: Theme.of(context)
                          .textTheme
                          .bodyLarge
                          ?.copyWith(color: const Color(0xFF666A7A)),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _isSearchingBoosters || _isWaitingForBooster
                            ? null
                            : _confirmBoostAndRequest,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF5500FF),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(22),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 18),
                        ),
                        child: _isSearchingBoosters
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                          : FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              'Request & Pay $priceDisplay',
                              maxLines: 1,
                              style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w700),
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
      );
    }

    // Steps 1 & 2: vehicle selection page
    final hasActiveOtherRequest = _activeRequestId != null && 
        _activeServiceType != _serviceTypeBoost;
    
    return Container(
              color: const Color(0xFFF3F3F7),
              child: SafeArea(
                child: Column(
                  children: [
                    if (hasActiveOtherRequest)
                      Container(
                        margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEF3C7),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFFCD34D)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.info_outline, color: Color(0xFFA16207), size: 20),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Complete your active request before starting a new service.',
                                style: const TextStyle(
                                  color: Color(0xFF854D0E),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
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
                                  child: const Text('Request Now'),
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
            );
  }
  // ── Step 4: live tracking, searching, no-provider, completion ─────────────
  Widget _buildBoostStep4(BuildContext context) {
    final status = _activeRequestStatus ?? 'pending';
    final activeService = _activeServiceType ?? _serviceType;
    final isTowOrder = activeService == _serviceTypeTow;
    final isMechanicOrder = activeService == _serviceTypeMechanic;
    final hasProviderAccepted = _activeDriverId != null &&
      (status == 'accepted' || status == 'en_route' || status == 'completed');
    final isWaitingForAcceptance =
      status == 'pending' || status == 'paid' || status == 'expired' || _isSearchingBoosters;
    final isCompleted = status == 'completed';
    final showCountdown = (_isSearchWindowStatus || _isSearchingBoosters) && !_searchTimedOut;

    // ── No providers found ───────────────────────────────────────────────────
    if (_noProvidersFound) {
      return Container(
        color: const Color(0xFFF3F3F7),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 88, height: 88,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFEDD5),
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: const Icon(Icons.search_off, color: Color(0xFFEA580C), size: 44),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'No Providers Nearby',
                    style: Theme.of(context).textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w800),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    "We couldn't find a battery boost provider near you right now. "
                    'Help grow our network — share the app with friends who could become providers!',
                    style: Theme.of(context).textTheme.bodyLarge
                        ?.copyWith(color: const Color(0xFF666A7A)),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.share),
                      label: const Text('Share Boosstter with Friends',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      onPressed: () {
                        const txt =
                            '🔋 Need a battery boost? Try Boosstter — the on-demand battery boost app!\n\n'
                            'Download on the App Store or Google Play:\nhttps://boosstter.app/download';
                        Clipboard.setData(const ClipboardData(text: txt));
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('Share text copied! Paste it anywhere to share.'),
                          behavior: SnackBarBehavior.floating,
                        ));
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF5500FF),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextButton(
                    onPressed: () => setState(() {
                      _flowStep = 3;
                      _noProvidersFound = false;
                      _isSearchingBoosters = false;
                    }),
                    child: const Text('Try Again'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // ── Searching animation ──────────────────────────────────────────────────
    if (isWaitingForAcceptance && !hasProviderAccepted) {
            // Second timeout cycle - prompt app sharing after resend cycle also times out.
            if (_searchTimedOut && _resendAttempts >= 1 && !_shareDialogShownForCurrentTimeout) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                setState(() {
                  _shareDialogShownForCurrentTimeout = true;
                });
                showDialog(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('No Providers Available'),
                    content: const Text(
                      'We could not find available providers after searching twice. '
                      'Help grow our network by sharing Boosstter with friends and family!',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Not Now'),
                      ),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.share),
                        label: const Text('Share App'),
                        onPressed: () {
                          Navigator.pop(ctx);
                          const txt =
                              'Need a battery boost? Try Boosstter - the on-demand battery boost app!\n\n'
                              'Download on the App Store or Google Play:\nhttps://boosstter.app/download';
                          Clipboard.setData(const ClipboardData(text: txt));
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content: Text('Share text copied! Paste it anywhere to share.'),
                            behavior: SnackBarBehavior.floating,
                          ));
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF5500FF),
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                );
              });
            }

            // Timeout state with Resend & Cancel buttons
            if (_searchTimedOut) {
              return Container(
                color: const Color(0xFFF3F3F7),
                child: SafeArea(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 88, height: 88,
                            decoration: BoxDecoration(
                              color: const Color(0xFFEDE9FE),
                              borderRadius: BorderRadius.circular(28),
                            ),
                            child: const Icon(Icons.schedule, color: Color(0xFF5500FF), size: 44),
                          ),
                          const SizedBox(height: 24),
                          Text(
                            'Search Still Running…',
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w800),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            _resendAttempts == 0
                                ? 'The 30-minute search cycle ended without a provider response. You can resend or cancel this request.'
                                : 'The resent cycle ended too. You can resend again or cancel this request.',
                            style: Theme.of(context).textTheme.bodyLarge
                                ?.copyWith(color: const Color(0xFF666A7A)),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'Countdown: ${_formatCountdown(_searchRemainingSeconds)}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                          const SizedBox(height: 32),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              icon: const Icon(Icons.refresh),
                              label: const Text('Resend Request',
                                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                              onPressed: _resendActiveBoostRequest,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF5500FF),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton(
                              onPressed: _cancelActiveBoostRequest,
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                side: const BorderSide(color: Color(0xFFCCCCCC)),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                              ),
                              child: const Text('Cancel Request',
                                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF5500FF))),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }

            // Normal searching state - keep searching
      return Container(
        color: const Color(0xFFF3F3F7),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _PulseRing(
                    child: Container(
                      width: 80, height: 80,
                      decoration: BoxDecoration(
                        color: const Color(0xFF5500FF),
                        borderRadius: BorderRadius.circular(26),
                      ),
                      child: const Icon(Icons.battery_charging_full, color: Colors.white, size: 40),
                    ),
                  ),
                  const SizedBox(height: 32),
                  Text(
                    'Searching Nearby Providers…',
                    style: Theme.of(context).textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w800),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    "Hang tight — we're finding a certified battery boost provider in your area.",
                    style: Theme.of(context).textTheme.bodyLarge
                      ?.copyWith(color: const Color(0xFF0EA5E9), fontWeight: FontWeight.w600),
                    textAlign: TextAlign.center,
                  ),
                  if (showCountdown) ...[
                    const SizedBox(height: 10),
                    Text(
                      'Time remaining in this cycle: ${_formatCountdown(_searchRemainingSeconds)}',
                      style: const TextStyle(
                        color: Color(0xFF0F172A),
                        fontWeight: FontWeight.w700,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 28),
                  const CircularProgressIndicator(color: Color(0xFF5500FF)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // ── Provider accepted / tracking / completed ─────────────────────────────
    return Scaffold(
      backgroundColor: const Color(0xFFF3F3F7),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(
          _showTrackingMap
              ? (isTowOrder
                  ? 'Tow Tracking Map'
                  : isMechanicOrder
                      ? 'Mechanic Tracking Map'
                      : 'Provider Tracking Map')
              : 'Requests',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: _showTrackingMap
          ? (_pickupLatLng == null
              ? const Center(child: Text('Location unavailable'))
              : GoogleMap(
                  initialCameraPosition: CameraPosition(target: _pickupLatLng!, zoom: 14),
                  onMapCreated: (c) => _mapController = c,
                  markers: {
                    Marker(
                      markerId: const MarkerId('customer'),
                      position: _pickupLatLng!,
                      infoWindow: const InfoWindow(title: 'Your Location'),
                      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
                    ),
                    if (_providerLat != null && _providerLng != null)
                      Marker(
                        markerId: const MarkerId('provider'),
                        position: LatLng(_providerLat!, _providerLng!),
                        infoWindow: InfoWindow(
                            title: _providerDisplayName ??
                            (isTowOrder
                              ? 'Tow Operator'
                              : isMechanicOrder
                                ? 'Mobile Mechanic'
                                : 'Provider')),
                        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
                      ),
                  },
                  myLocationEnabled: true,
                  myLocationButtonEnabled: true,
                ))
          : ListView(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 24),
              children: [
                _StepProgressRow(activeStep: 4, totalSteps: 4),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFE1E2EA)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Transaction',
                          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                      const SizedBox(height: 8),
                      Text('Request ID: ${_activeRequestId ?? 'Pending'}',
                          style: const TextStyle(color: Color(0xFF4B5563))),
                      const SizedBox(height: 4),
                          Text(
                            'Service: ${isTowOrder ? 'Tow Assistance' : isMechanicOrder ? 'Mobile Mechanic' : 'Battery Boost'}',
                          style: const TextStyle(color: Color(0xFF4B5563))),
                      const SizedBox(height: 4),
                        Text('Status: ${_statusLabel(status, serviceType: activeService)}',
                          style: const TextStyle(color: Color(0xFF4B5563))),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: _statusColor(status).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _statusColor(status).withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    children: [
                      Icon(_statusIcon(status), color: _statusColor(status), size: 22),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(_statusLabel(status, serviceType: activeService),
                            style: TextStyle(
                                color: _statusColor(status),
                                fontWeight: FontWeight.w700,
                                fontSize: 15)),
                      ),
                    ],
                  ),
                ),
                if (showCountdown) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFBFDBFE)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.timer, size: 20, color: Color(0xFF1D4ED8)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '30-minute cycle remaining: ${_formatCountdown(_searchRemainingSeconds)}',
                            style: const TextStyle(
                              color: Color(0xFF1E3A8A),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                _RequestStatusFlow(
                  currentStatus: status,
                  serviceType: activeService,
                ),
                const SizedBox(height: 16),
                if (_providerDisplayName != null)
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0xFFE1E2EA)),
                      boxShadow: const [
                        BoxShadow(color: Color(0x0D000000), blurRadius: 10, offset: Offset(0, 2))
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                color: const Color(0xFFEDE9FE),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: const Icon(Icons.person, color: Color(0xFF5500FF), size: 28),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(_providerDisplayName!,
                                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                                      Text(
                                        isTowOrder
                                          ? 'Verified Tow Operator'
                                          : isMechanicOrder
                                            ? 'Verified Mobile Mechanic'
                                            : 'Certified Battery Boost Provider',
                                      style: TextStyle(color: Colors.grey[600], fontSize: 13)),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (_providerDistanceKm != null) ...[
                          const SizedBox(height: 16),
                          const Divider(height: 1),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                  child: _InfoTile(
                                icon: Icons.straighten,
                                label: 'Distance',
                                value: '${_providerDistanceKm!.toStringAsFixed(1)} km  /  '
                                    '${(_providerDistanceKm! * 0.621371).toStringAsFixed(1)} mi',
                              )),
                              const SizedBox(width: 12),
                              Expanded(
                                  child: _InfoTile(
                                icon: Icons.schedule,
                                label: 'ETA',
                                value: '${_providerEtaMinutes ?? '–'} min',
                              )),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFE1E2EA)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.place, color: Color(0xFF6366F1)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(_pickupAddress ?? 'Your Location',
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                if ((status == 'accepted' || status == 'en_route') && !isCompleted)
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: _isCompletingJob
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.check_circle_outline),
                      label: const Text('Mark Job as Complete',
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                      onPressed: _isCompletingJob ? null : _markJobComplete,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF5500FF),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                    ),
                  ),
                if (isCompleted)
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: const Color(0xFFDCFCE7),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      children: [
                        const Icon(Icons.check_circle, color: Color(0xFF16A34A), size: 48),
                        const SizedBox(height: 12),
                        Text(
                            isTowOrder
                                ? 'Tow Complete!'
                                : isMechanicOrder
                                    ? 'Mechanic Service Complete!'
                                    : 'Boost Complete!',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF15803D))),
                        const SizedBox(height: 6),
                        Text(
                          isTowOrder
                            ? 'Your tow order is complete. Thanks for using Boosstter!'
                            : isMechanicOrder
                                ? 'Your mobile mechanic service is complete. Thanks for using Boosstter!'
                            : 'Your battery has been boosted. Thanks for using Boosstter!',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Color(0xFF166534))),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: () => _promptReview(_activeRequestId ?? ''),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF16A34A),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: const Text('Leave a Review'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _showTrackingMap ? 1 : 0,
        onDestinationSelected: (index) {
          setState(() => _showTrackingMap = index == 1);
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.receipt_long_outlined), label: 'Requests'),
          NavigationDestination(icon: Icon(Icons.map_outlined), label: 'Tracking Map'),
        ],
      ),
    );
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'accepted':
      case 'en_route':
        return const Color(0xFF0EA5E9);
      case 'paid':
        return const Color(0xFFF59E0B);
      case 'completed':
        return const Color(0xFF16A34A);
      case 'awaiting_payment':
        return const Color(0xFFEA580C);
      default:
        return Colors.grey;
    }
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'accepted':
        return Icons.handshake_outlined;
      case 'en_route':
        return Icons.drive_eta;
      case 'paid':
        return Icons.check_circle_outline;
      case 'completed':
        return Icons.check_circle;
      case 'awaiting_payment':
        return Icons.payment;
      default:
        return Icons.hourglass_top;
    }
  }

  String _statusLabel(String status, {String? serviceType}) {
    final isTow = serviceType == _serviceTypeTow;
    final isMechanic = serviceType == _serviceTypeMechanic;
    switch (status) {
      case 'pending':
        return 'Searching for providers…';
      case 'awaiting_payment':
        return 'Payment Required';
      case 'paid':
        return 'Payment Received – Waiting for Provider Acceptance';
      case 'expired':
        return 'Request Expired – Resend or Cancel';
      case 'accepted':
        return isTow
            ? 'Tow Operator Accepted – On the Way'
            : isMechanic
                ? 'Mechanic Accepted – On the Way'
                : 'Provider Accepted – On the Way';
      case 'en_route':
        return isTow
            ? 'Tow Operator En Route to You'
            : isMechanic
                ? 'Mechanic En Route to You'
                : 'Provider En Route to You';
      case 'completed':
        return isTow
            ? 'Tow Completed Successfully'
            : isMechanic
                ? 'Mechanic Service Completed Successfully'
                : 'Boost Completed Successfully';
      default:
        return status;
    }
  }

  Widget _buildTowFlow(BuildContext context) {
    final isMechanic = _serviceType == _serviceTypeMechanic;
    final selectedTowVehicle = _resolvedTowVehicle ?? _towVehicleOptions.first;
    final estimatedTowAmount = _estimateTowPrice(selectedTowVehicle);
    final stepOneTitle = isMechanic ? 'Choose Service Type' : 'Choose Tow Type';
    final stepThreeTitle = isMechanic ? 'Request Mobile Mechanic' : 'Request Tow';
    final submittedTitle = isMechanic ? 'Mechanic Request Submitted' : 'Tow Request Submitted';
    final reasons = isMechanic ? _mechanicReasons : _towReasons;
    final hasActiveOtherRequest = _activeRequestId != null && 
        _activeServiceType != _serviceType;

    return Container(
      color: const Color(0xFFF3F3F7),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
          children: [
            if (hasActiveOtherRequest)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF3C7),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFFCD34D)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, color: Color(0xFFA16207), size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Complete your active request before starting a new service.',
                        style: const TextStyle(
                          color: Color(0xFF854D0E),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
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
                              'Step ${_towStep.clamp(1, 4)} of 4',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelLarge
                                  ?.copyWith(
                                    color: const Color(0xFF0E90AC),
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _towStep == 1
                                ? stepOneTitle
                                : _towStep == 2
                                  ? 'Set Your Location'
                                  : _towStep == 3
                                    ? stepThreeTitle
                                    : submittedTitle,
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _towStep == 1
                                  ? (isMechanic
                                      ? 'Pick the mechanic service that matches your issue before we search.'
                                      : 'Pick the tow service that matches your vehicle before we search.')
                                : _towStep == 2
                                  ? 'Save your current location or enter a different address.'
                                  : _towStep == 3
                                    ? (isMechanic
                                        ? 'Review your mobile mechanic request and start finding nearby available providers.'
                                        : 'Review your tow request and start finding nearby available providers.')
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
                isMechanic ? 'Select Your Vehicle / Issue Type' : 'Select Your Vehicle Type',
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
                            _towDetectedLocationAddress != null
                                ? Text(
                                    _towDetectedLocationAddress!,
                                    style: Theme.of(context).textTheme.bodyLarge,
                                  )
                                : const Row(
                                    children: [
                                      SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      ),
                                      SizedBox(width: 10),
                                      Text('Detecting current location...'),
                                    ],
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
                                ? 'Use Current Location'
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
                              _vehicleType ?? _resolvedTowVehicle ?? (isMechanic ? 'Service vehicle' : 'Tow vehicle'),
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
                        isMechanic
                            ? 'We will search for mobile mechanics currently available near your saved location.'
                            : 'We will search for tow providers currently available near your saved location.',
                        style: Theme.of(context)
                            .textTheme
                            .bodyLarge
                            ?.copyWith(color: const Color(0xFF6D7182)),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        value: _selectedTowReason,
                        items: reasons
                            .map((reason) => DropdownMenuItem<String>(
                                  value: reason,
                                  child: Text(reason),
                                ))
                            .toList(),
                        onChanged: (value) {
                          setState(() => _selectedTowReason = value);
                        },
                        decoration: const InputDecoration(
                          hintText: 'Reason for service',
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
                            '${isMechanic ? 'Request Mobile Mechanic' : 'Request Tow'} • Pay \$${_estimateTowPrice(_vehicleType ?? _resolvedTowVehicle ?? _towVehicleOptions.first)}',
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
                      ? (isMechanic
                        ? 'No nearby mobile mechanics found yet. Update location and try again.'
                        : 'No nearby tow providers found yet. Update location and try again.')
                      : '${_nearbyBoosters.length} nearby ${isMechanic ? 'mobile mechanics' : 'tow providers'} found. Nearest ETA ${_nearbyBoosters.first.etaMinutes} min.',
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
          ? 'Payment confirmed — waiting for provider acceptance'
                : needsPayment
                    ? 'Booster accepted — payment required'
                    : 'Waiting for booster to accept';

    final String subtitle = isDone
        ? 'Your request is complete. Thank you!'
        : isEnRoute
            ? 'Booster is en route to your location'
            : isPaid
          ? 'Your paid order is in the provider queue.'
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
  const _TowPaymentConfirmScreen({required this.pricing, required this.serviceLabel});

  final _TowPricing pricing;
  final String serviceLabel;

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
                  _PaymentLine(label: serviceLabel, value: '\$${_toCad(pricing.serviceCents)}'),
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

// ── Pulse ring animation for searching state ───────────────────────────────
class _PulseRing extends StatefulWidget {
  const _PulseRing({required this.child});
  final Widget child;

  @override
  State<_PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<_PulseRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400))
      ..repeat();
    _scale = Tween<double>(begin: 1.0, end: 2.0).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _opacity = Tween<double>(begin: 0.5, end: 0.0).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        AnimatedBuilder(
          animation: _ctrl,
          builder: (_, __) => Transform.scale(
            scale: _scale.value,
            child: Container(
              width: 80, height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF5500FF).withValues(alpha: _opacity.value * 0.25),
                border: Border.all(
                  color: const Color(0xFF5500FF).withValues(alpha: _opacity.value),
                  width: 2,
                ),
              ),
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

// ── Info tile (label + value) card ─────────────────────────────────────────
class _InfoTile extends StatelessWidget {
  const _InfoTile({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F3F7),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: const Color(0xFF5500FF)),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        fontSize: 11, color: Colors.grey, fontWeight: FontWeight.w500)),
                Text(value,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RequestStatusFlow extends StatelessWidget {
  const _RequestStatusFlow({
    required this.currentStatus,
    required this.serviceType,
  });

  final String currentStatus;
  final String serviceType;

  static const List<String> _orderedStatuses = <String>[
    'paid',
    'accepted',
    'en_route',
    'completed',
  ];

  int _currentIndex() {
    if (currentStatus == 'pending' || currentStatus == 'awaiting_payment') {
      return 0;
    }
    final idx = _orderedStatuses.indexOf(currentStatus);
    return idx < 0 ? 0 : idx;
  }

  String _labelFor(String status) {
    final isTow = serviceType == _serviceTypeTow;
    final isMechanic = serviceType == _serviceTypeMechanic;
    switch (status) {
      case 'paid':
        return 'Payment Confirmed';
      case 'accepted':
        return isTow
            ? 'Tow Operator Accepted'
            : isMechanic
                ? 'Mechanic Accepted'
                : 'Provider Accepted';
      case 'en_route':
        return isTow
            ? 'Tow Operator En Route'
            : isMechanic
                ? 'Mechanic En Route'
                : 'Provider En Route';
      case 'completed':
        return isTow
            ? 'Tow Completed'
            : isMechanic
                ? 'Mechanic Service Completed'
                : 'Boost Completed';
      default:
        return status;
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeIndex = _currentIndex();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE1E2EA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Tracking Flow',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
          const SizedBox(height: 10),
          ...List<Widget>.generate(_orderedStatuses.length, (index) {
            final status = _orderedStatuses[index];
            final reached = index <= activeIndex;
            final isCurrent = _orderedStatuses[activeIndex] == status;
            return Padding(
              padding: EdgeInsets.only(bottom: index == _orderedStatuses.length - 1 ? 0 : 10),
              child: Row(
                children: [
                  Icon(
                    reached ? Icons.check_circle : Icons.radio_button_unchecked,
                    size: 20,
                    color: reached ? const Color(0xFF16A34A) : const Color(0xFF9CA3AF),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _labelFor(status),
                      style: TextStyle(
                        fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                        color: reached ? const Color(0xFF0F172A) : const Color(0xFF6B7280),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
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
const String _serviceTypeMechanic = 'mobile_mechanic';
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

const List<String> _mechanicReasons = <String>[
  'Engine check / warning light',
  'Battery / alternator diagnosis',
  'Brake issue inspection',
  'Overheating issue',
  'Starter / ignition problem',
  'Fluid leak check',
  'Other mechanical issue',
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