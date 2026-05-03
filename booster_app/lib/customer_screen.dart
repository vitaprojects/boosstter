import 'package:flutter/material.dart';
import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:geocoding/geocoding.dart';
import 'app_shell.dart';
import 'login_screen.dart';
import 'stripe_payment_service.dart';
import 'boost_service_options.dart';
import 'offline_retry_queue.dart';
import 'request_lifecycle.dart';
import 'home_screen.dart';
import 'provider_status_screen.dart';
import 'customer_requests_tab_screen.dart';
import 'profile_screen.dart';
import 'main_bottom_nav.dart';
import 'customer_order_tracker_screen.dart';
import 'subscription_required_screen.dart';
import 'region_policy.dart';
import 'orders_landing_screen.dart';

enum _CustomerStep { vehicle, location, request, boosters }

enum _LocationSelectionTab { current, map }

enum _SearchAgainAction { searchAgain, cancelRequest, later }

class _SubscriptionCharge {
  const _SubscriptionCharge({
    required this.region,
    required this.baseAmountCents,
    required this.taxAmountCents,
  });

  final SupportedRegion region;
  final int baseAmountCents;
  final int taxAmountCents;

  int get totalAmountCents => baseAmountCents + taxAmountCents;
}

class CustomerScreen extends StatefulWidget {
  const CustomerScreen({
    this.initialServiceType = serviceTypeBoost,
    this.showBottomNav = true,
    super.key,
  });

  final String initialServiceType;
  final bool showBottomNav;

  @override
  State<CustomerScreen> createState() => _CustomerScreenState();
}

class _CustomerScreenState extends State<CustomerScreen> {
  static const int _yearlySubscriptionBaseCents = 1000;

  Position? _currentPosition;
  bool _isLoading = true;
  bool _hasLocationPermission = false;
  bool _isSearchingBoosters = false;
  bool _isResolvingLocation = false;
  GoogleMapController? _mapController;
  GoogleMapController? _locationPickerMapController;
  final TextEditingController _mapAddressController = TextEditingController();

  String? _pickupAddress;
  LatLng? _pickupLatLng;
  LatLng? _detectedCurrentLatLng;
  String? _detectedCurrentAddress;
  LatLng? _locationPickerLatLng;
  String? _locationPickerAddress;
  String _serviceType = serviceTypeBoost;
  String? _vehicleType;
  String? _plugType;
  String? _towType;
  final List<_NearbyBooster> _nearbyBoosters = <_NearbyBooster>[];
  _CustomerStep _currentStep = _CustomerStep.vehicle;
  _LocationSelectionTab _locationSelectionTab = _LocationSelectionTab.current;

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _requestWatchSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _driverWatchSub;
  String? _activeRequestId;
  String? _activeRequestStatus;
  String? _activeRequestServiceType;
  String? _activeDriverId;
  double? _activeDriverDistanceKm;
  int? _activeDriverEtaMinutes;
  LatLng? _activeDriverLatLng;
  DateTime? _activeDriverLastUpdatedAt;
  bool _isDriverTrackingConnected = false;
  DateTime? _activeRequestCreatedAt;
  DateTime? _activeRequestStatusUpdatedAt;
  late final Timer _statusTicker;
  Timer? _requestWatchRetryTimer;
  Timer? _driverWatchRetryTimer;
  DateTime? _searchAgainPromptCooldownUntil;
  bool _isSearchAgainDialogOpen = false;
  bool _isRedispatching = false;

  static const LatLng _defaultMapCenter = LatLng(37.7749, -122.4194);

  bool get _isWaitingForBooster {
    return _activeRequestStatus == 'pending' ||
        _activeRequestStatus == 'searching' ||
        _activeRequestStatus == 'awaiting_payment' ||
        _activeRequestStatus == 'paid' ||
        _activeRequestStatus == 'accepted' ||
        _activeRequestStatus == 'en_route' ||
        _activeRequestStatus == 'arrived';
  }

  @override
  void initState() {
    super.initState();
    _serviceType = widget.initialServiceType;
    _statusTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
        _maybePromptSearchAgain();
      }
    });
    _getCurrentLocation();
    _watchLatestRequest();
  }

  @override
  void dispose() {
    _statusTicker.cancel();
    _requestWatchRetryTimer?.cancel();
    _driverWatchRetryTimer?.cancel();
    _requestWatchSub?.cancel();
    _driverWatchSub?.cancel();
    _mapController?.dispose();
    _locationPickerMapController?.dispose();
    _mapAddressController.dispose();
    super.dispose();
  }

  DateTime? _toDateTime(dynamic value) {
    if (value is Timestamp) {
      return value.toDate();
    }
    if (value is DateTime) {
      return value;
    }
    return null;
  }

  Future<_SubscriptionCharge?> _subscriptionChargeIfRequired(String userId) async {
    final snapshot = await FirebaseFirestore.instance.collection('users').doc(userId).get();
    final data = snapshot.data() ?? <String, dynamic>{};

    final regionCode = data['regionCode']?.toString();
    final matchedRegion = findSupportedRegion(regionCode);
    if (regionCode != null && matchedRegion == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Booster is currently available only in Canada, United States, United Kingdom, and Nigeria.',
            ),
          ),
        );
      }
      return null;
    }

    if (data['isSubscribed'] == true) {
      return const _SubscriptionCharge(
        region: defaultSupportedRegion,
        baseAmountCents: 0,
        taxAmountCents: 0,
      );
    }

    final region = resolveSupportedRegion(regionCode);
    final taxCents = taxAmountForRegion(_yearlySubscriptionBaseCents, region);

    return _SubscriptionCharge(
      region: region,
      baseAmountCents: _yearlySubscriptionBaseCents,
      taxAmountCents: taxCents,
    );
  }

  Future<bool> _confirmYearlySubscriptionAddOn(
    _SubscriptionCharge charge, {
    required int serviceTotalAmountCents,
  }) async {
    if (!mounted) {
      return false;
    }

    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SubscriptionRequiredScreen(
          subscriptionBaseAmountCents: charge.baseAmountCents,
          subscriptionTaxAmountCents: charge.taxAmountCents,
          subscriptionCurrencyCode: charge.region.currencyCode,
          serviceTotalAmountCents: serviceTotalAmountCents,
        ),
      ),
    );

    return result == true;
  }

  void _scheduleRequestWatchRetry() {
    _requestWatchRetryTimer?.cancel();
    _requestWatchRetryTimer = Timer(const Duration(seconds: 3), _watchLatestRequest);
  }

  void _scheduleDriverWatchRetry(String? driverId) {
    _driverWatchRetryTimer?.cancel();
    if (driverId == null) return;
    _driverWatchRetryTimer =
        Timer(const Duration(seconds: 3), () => _watchActiveDriverLocation(driverId));
  }

  bool _isRetryableSyncError(Object error) {
    if (error is FirebaseException) {
      return error.code == 'unavailable' ||
          error.code == 'network-request-failed' ||
          error.code == 'deadline-exceeded';
    }
    final message = error.toString().toLowerCase();
    return message.contains('network') ||
        message.contains('unavailable') ||
        message.contains('timed out') ||
        message.contains('failed host lookup');
  }

  Future<void> _transitionRequestStatus({
    required String requestId,
    required RequestStatus to,
    Map<String, dynamic>? extra,
  }) async {
    Future<void> runTransition() async {
      final requestRef = FirebaseFirestore.instance.collection('requests').doc(requestId);
      await FirebaseFirestore.instance.runTransaction((txn) async {
        final snap = await txn.get(requestRef);
        if (!snap.exists) {
          throw Exception('Boost request not found.');
        }
        final data = snap.data() ?? <String, dynamic>{};
        final from = requestStatusFromString((data['status'] ?? '').toString());
        if (!canTransitionRequestStatus(from, to)) {
          throw Exception('Invalid request status transition: ${from.value} -> ${to.value}');
        }

        final patch = <String, dynamic>{
          ...buildStatusTransitionPatch(to: to),
        };
        if (extra != null) {
          patch.addAll(extra);
        }
        txn.update(requestRef, patch);
      });
    }

    try {
      await runTransition();
    } catch (error) {
      if (_isRetryableSyncError(error)) {
        OfflineRetryQueue.instance.enqueue(
          key: 'request-transition-$requestId-${to.value}',
          action: runTransition,
        );
        throw Exception('Offline: action queued and will retry automatically.');
      }
      rethrow;
    }
  }

  Future<String> _resolveAddress(
    double latitude,
    double longitude, {
    required String fallbackLabel,
  }) async {
    var address =
        '$fallbackLabel (${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)})';

    try {
      final places = await placemarkFromCoordinates(latitude, longitude);
      if (places.isNotEmpty) {
        final p = places.first;
        final formatted = [
          if ((p.street ?? '').isNotEmpty) p.street,
          if ((p.locality ?? '').isNotEmpty) p.locality,
          if ((p.administrativeArea ?? '').isNotEmpty) p.administrativeArea,
        ].whereType<String>().join(', ');
        if (formatted.isNotEmpty) {
          address = formatted;
        }
      }
    } catch (_) {
      // Keep fallback text if reverse-geocoding fails.
    }

    return address;
  }

  void _selectVehicleType(String vehicleType) {
    setState(() {
      _vehicleType = vehicleType;
      _plugType = vehicleType == _electricVehicleType ? _plugType : null;
    });
  }

  void _selectPlugType(String plugType) {
    setState(() => _plugType = plugType);
  }

  void _selectTowType(String towType) {
    setState(() => _towType = towType);
  }

  int get _serviceBaseAmountCents {
    if (_serviceType == serviceTypeTow) {
      return towBaseAmountForType(_towType ?? towTypeCar);
    }
    return boostServiceBaseCadCents;
  }

  int get _serviceTaxAmountCents {
    if (_serviceType == serviceTypeTow) {
      return taxAmountForBase(_serviceBaseAmountCents);
    }
    return boostServiceTaxCadCents;
  }

  int get _serviceTotalAmountCents => _serviceBaseAmountCents + _serviceTaxAmountCents;

  String get _serviceSummaryLabel {
    if (_serviceType == serviceTypeTow) {
      return towTypeLabel(_towType ?? towTypeCar);
    }
    if (_vehicleType == _electricVehicleType) {
      return 'Electric Car Boost';
    }
    return 'Regular Car Boost';
  }

  bool _vehicleSelectionIsValid() {
    if (_serviceType == serviceTypeTow) {
      if (_towType == null) {
        _showErrorSnackBar('Choose tow type to continue', Icons.local_shipping);
        return false;
      }
      return true;
    }

    if (_vehicleType == null) {
      _showErrorSnackBar('Choose Regular Car Boost or Electric Car Boost', Icons.ev_station);
      return false;
    }

    if (_vehicleType == _electricVehicleType && _plugType == null) {
      _showErrorSnackBar('Choose your electric plug type to continue', Icons.electrical_services);
      return false;
    }

    return true;
  }

  void _continueToLocationStep() {
    if (!_vehicleSelectionIsValid()) {
      return;
    }

    setState(() => _currentStep = _CustomerStep.location);
    if (_locationSelectionTab == _LocationSelectionTab.current) {
      _prepareCurrentLocationPreview();
    }
  }

  Future<void> _prepareCurrentLocationPreview() async {
    if (_currentPosition == null || _isResolvingLocation) {
      return;
    }

    setState(() => _isResolvingLocation = true);
    final latLng = LatLng(
      _currentPosition!.latitude,
      _currentPosition!.longitude,
    );
    final address = await _resolveAddress(
      latLng.latitude,
      latLng.longitude,
      fallbackLabel: 'Current location',
    );

    if (!mounted) return;
    setState(() {
      _detectedCurrentLatLng = latLng;
      _detectedCurrentAddress = address;
      _isResolvingLocation = false;
    });
  }

  Future<void> _saveDetectedCurrentLocation() async {
    if (_detectedCurrentLatLng == null || _detectedCurrentAddress == null) {
      await _prepareCurrentLocationPreview();
    }

    if (_detectedCurrentLatLng == null || _detectedCurrentAddress == null) {
      if (mounted) {
        _showErrorSnackBar('Could not detect your current location', Icons.my_location);
      }
      return;
    }

    setState(() {
      _pickupLatLng = _detectedCurrentLatLng;
      _pickupAddress = _detectedCurrentAddress;
      _nearbyBoosters.clear();
      _currentStep = _CustomerStep.request;
    });
  }

  Future<void> _selectLocationFromMap(LatLng latLng) async {
    setState(() {
      _locationPickerLatLng = latLng;
      _locationPickerAddress =
          'Selected location (${latLng.latitude.toStringAsFixed(5)}, ${latLng.longitude.toStringAsFixed(5)})';
    });

    final address = await _resolveAddress(
      latLng.latitude,
      latLng.longitude,
      fallbackLabel: 'Selected location',
    );

    if (!mounted) return;
    setState(() => _locationPickerAddress = address);
  }

  Future<void> _searchAddressOnMap() async {
    FocusManager.instance.primaryFocus?.unfocus();

    final input = _mapAddressController.text.trim();
    if (input.isEmpty) {
      _showErrorSnackBar('Enter an address to search on the map', Icons.search);
      return;
    }

    setState(() => _isResolvingLocation = true);
    try {
      final locations = await locationFromAddress(input);
      if (locations.isEmpty) {
        _showErrorSnackBar('Address not found', Icons.search_off);
        return;
      }

      final picked = LatLng(locations.first.latitude, locations.first.longitude);
      await _locationPickerMapController?.animateCamera(
        CameraUpdate.newLatLng(picked),
      );
      await _selectLocationFromMap(picked);
    } catch (_) {
      if (mounted) {
        _showErrorSnackBar('Could not search this address', Icons.cloud_off);
      }
    } finally {
      if (mounted) {
        setState(() => _isResolvingLocation = false);
      }
    }
  }

  void _saveMapLocation() {
    if (_locationPickerLatLng == null || _locationPickerAddress == null) {
      _showErrorSnackBar('Search or tap on the map to choose a location', Icons.place);
      return;
    }

    setState(() {
      _pickupLatLng = _locationPickerLatLng;
      _pickupAddress = _locationPickerAddress;
      _nearbyBoosters.clear();
      _currentStep = _CustomerStep.request;
    });
  }

  void _goBackOneStep() {
    switch (_currentStep) {
      case _CustomerStep.vehicle:
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        } else {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const HomeScreen()),
          );
        }
        break;
      case _CustomerStep.location:
        setState(() => _currentStep = _CustomerStep.vehicle);
        break;
      case _CustomerStep.request:
        setState(() => _currentStep = _CustomerStep.location);
        break;
      case _CustomerStep.boosters:
        setState(() => _currentStep = _CustomerStep.request);
        break;
    }
  }

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

  void _openActiveRequestTracker() {
    if (_activeRequestId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No active request to track.')),
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CustomerOrderTrackerScreen(requestId: _activeRequestId!),
      ),
    );
  }

  Position _defaultPosition() {
    return Position(
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
  }

  void _setFallbackLocation({required bool hasPermission}) {
    if (!mounted) return;
    setState(() {
      _hasLocationPermission = hasPermission;
      _currentPosition = _defaultPosition();
      _isLoading = false;
    });
  }

  Future<void> _getCurrentLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled().timeout(
        const Duration(seconds: 5),
      );
      if (!serviceEnabled) {
        _setFallbackLocation(hasPermission: false);
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission().timeout(
        const Duration(seconds: 5),
      );
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission().timeout(
          const Duration(seconds: 8),
        );
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _setFallbackLocation(hasPermission: false);
        return;
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      ).timeout(const Duration(seconds: 12));

      if (!mounted) return;
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
      _setFallbackLocation(hasPermission: false);
    }
  }

  Future<List<_NearbyBooster>> _findNearbyBoosters() async {
    if (_pickupLatLng == null) {
      return const <_NearbyBooster>[];
    }

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
      final offeredServiceTypes = (data['offeredServiceTypes'] as List?)
              ?.map((item) => item.toString())
              .toSet() ??
          <String>{serviceTypeBoost};
      final offeredVehicleType = data['offeredVehicleType']?.toString();
      final offeredTowTypes = (data['offeredTowTypes'] as List?)
              ?.map((item) => item.toString())
              .toSet() ??
          <String>{};
      final latitude = (data['latitude'] as num?)?.toDouble() ?? 0.0;
      final longitude = (data['longitude'] as num?)?.toDouble() ?? 0.0;
      final email = (data['email'] ?? 'Provider') as String;

      if (!offeredServiceTypes.contains(_serviceType)) {
        continue;
      }

      if (_serviceType == serviceTypeBoost) {
        if (offeredVehicleType != _vehicleType) {
          continue;
        }
      } else {
        if (_towType == null || !offeredTowTypes.contains(_towType)) {
          continue;
        }
      }

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
    return boosters;
  }

  Future<void> _requestBoosterAndPay() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final subscriptionCharge = await _subscriptionChargeIfRequired(user.uid);
    if (subscriptionCharge == null) {
      return;
    }

    final requiresSubscriptionCharge = subscriptionCharge.totalAmountCents > 0;
    final approved = await _confirmYearlySubscriptionAddOn(
      subscriptionCharge,
      serviceTotalAmountCents: _serviceTotalAmountCents,
    );
    if (!approved) {
      return;
    }

    if (_isWaitingForBooster) {
      _showErrorSnackBar(
        'You already have an active invite. Please wait for provider response.',
        Icons.hourglass_bottom,
      );
      return;
    }

    if (_pickupLatLng == null || _pickupAddress == null) {
      _showErrorSnackBar('Please save a pickup location first', Icons.place);
      return;
    }

    if (_serviceType == serviceTypeBoost) {
      if (_vehicleType == null) {
        _showErrorSnackBar(
          'Choose Regular or Electric before inviting a provider',
          Icons.ev_station,
        );
        return;
      }

      if (_vehicleType == _electricVehicleType && _plugType == null) {
        _showErrorSnackBar(
          'Choose your electric plug type before inviting a provider',
          Icons.electrical_services,
        );
        return;
      }
    } else if (_towType == null) {
      _showErrorSnackBar('Choose tow type before inviting a provider', Icons.local_shipping);
      return;
    }

    if (!mounted) {
      return;
    }

    try {
      final docRef = FirebaseFirestore.instance.collection('requests').doc();
      final requestBaseAmountCents = _serviceBaseAmountCents + subscriptionCharge.baseAmountCents;
      final requestTaxAmountCents = _serviceTaxAmountCents + subscriptionCharge.taxAmountCents;
      final requestTotalAmountCents = requestBaseAmountCents + requestTaxAmountCents;

      if (!mounted) return;

      final paymentResult = await showModalBottomSheet<BoostPaymentResult>(
        context: context,
        isScrollControlled: true,
        isDismissible: false,
        enableDrag: false,
        builder: (_) => _PaymentSheet(
          requestId: docRef.id,
          requestSeedData: <String, dynamic>{
            'customerId': user.uid,
            'driverId': null,
            'status': 'awaiting_payment',
            'statusUpdatedAt': FieldValue.serverTimestamp(),
            'awaiting_paymentAt': FieldValue.serverTimestamp(),
            'pickupAddress': _pickupAddress,
            'pickupLatitude': _pickupLatLng!.latitude,
            'pickupLongitude': _pickupLatLng!.longitude,
            'serviceType': _serviceType,
            'vehicleType': _serviceType == serviceTypeBoost ? _vehicleType : null,
            'plugType': _serviceType == serviceTypeBoost ? _plugType : null,
            'towType': _serviceType == serviceTypeTow ? _towType : null,
            'serviceBaseAmount': _serviceBaseAmountCents,
            'serviceTaxAmount': _serviceTaxAmountCents,
            'subscriptionBaseAmount': subscriptionCharge.baseAmountCents,
            'subscriptionTaxAmount': subscriptionCharge.taxAmountCents,
            'notifiedDriverIds': const <String>[],
            'notifiedBoostersPreview': const <Map<String, dynamic>>[],
            'timestamp': FieldValue.serverTimestamp(),
          },
          serviceLabel: _serviceSummaryLabel,
          totalAmountCents: requestTotalAmountCents,
          baseAmountCents: _serviceBaseAmountCents,
          taxAmountCents: _serviceTaxAmountCents,
          subscriptionBaseAmountCents: subscriptionCharge.baseAmountCents,
          subscriptionTaxAmountCents: subscriptionCharge.taxAmountCents,
          subscriptionCurrencyCode: subscriptionCharge.region.currencyCode,
        ),
      );

      if (!mounted) return;

      if (paymentResult == null) {
        final requestSnap = await FirebaseFirestore.instance
            .collection('requests')
            .doc(docRef.id)
            .get();
        if (requestSnap.exists) {
          await _transitionRequestStatus(
            requestId: docRef.id,
            to: RequestStatus.cancelled,
          );
        }
        _showErrorSnackBar('Payment cancelled. Request was not dispatched.', Icons.info);
        return;
      }

      if (requiresSubscriptionCharge) {
        await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
          'isSubscribed': true,
          'subscriptionPlan': 'yearly',
          'subscriptionBaseAmountCents': subscriptionCharge.baseAmountCents,
          'subscriptionTaxAmountCents': subscriptionCharge.taxAmountCents,
          'subscriptionTotalAmountCents': subscriptionCharge.totalAmountCents,
          'subscriptionCurrency': subscriptionCharge.region.currencyCode,
          'subscriptionRegionCode': subscriptionCharge.region.code,
          'subscriptionPurpose': 'request_service',
          'subscriptionStartedAt': FieldValue.serverTimestamp(),
          'subscriptionExpiresAt': Timestamp.fromDate(
            DateTime.now().add(const Duration(days: 365)),
          ),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }

      if (mounted) {
        setState(() => _isSearchingBoosters = true);
      }

      final boosters = await _findNearbyBoosters();
      final topMatches = boosters.take(20).toList(growable: false);

      await _transitionRequestStatus(
        requestId: docRef.id,
        to: RequestStatus.paid,
        extra: {
          'paymentAmount': paymentResult.amount,
          'baseAmount': requestBaseAmountCents,
          'taxAmount': requestTaxAmountCents,
          'serviceBaseAmount': _serviceBaseAmountCents,
          'serviceTaxAmount': _serviceTaxAmountCents,
          'subscriptionBaseAmount': subscriptionCharge.baseAmountCents,
          'subscriptionTaxAmount': subscriptionCharge.taxAmountCents,
          'paymentCurrency': paymentResult.currency,
          'paymentIntentId': paymentResult.paymentIntentId,
          'paymentProvider': paymentResult.paymentProvider,
          'notifiedDriverIds': topMatches.map((b) => b.userId).toList(growable: false),
          'notifiedBoostersPreview': topMatches
              .map(
                (b) => {
                  'driverId': b.userId,
                  'distanceKm': b.distanceKm,
                  'etaMinutes': b.etaMinutes,
                },
              )
              .toList(growable: false),
        },
      );

      final callable = FirebaseFunctions.instanceFor(region: 'northamerica-northeast1')
          .httpsCallable('dispatchBoosterNotifications');
      final dispatchResponse = await callable.call(<String, dynamic>{
        'requestId': docRef.id,
      });
      final responseData =
          Map<String, dynamic>.from(dispatchResponse.data as Map<dynamic, dynamic>);
      final notifiedCount = (responseData['notifiedCount'] as num?)?.toInt() ?? 0;

      if (mounted) {
        setState(() {
          _activeRequestId = docRef.id;
          _activeRequestStatus = notifiedCount > 0 ? 'searching' : 'no_boosters_available';
          _activeDriverId = null;
          _activeRequestCreatedAt = DateTime.now();
          _activeRequestStatusUpdatedAt = DateTime.now();
          _nearbyBoosters
            ..clear()
            ..addAll(boosters);
        });
        _showSuccessSnackBar(
          notifiedCount > 0
              ? 'Payment confirmed. Notified $notifiedCount nearby providers first.'
              : 'Payment confirmed. No providers were notified yet.',
        );

        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => CustomerOrderTrackerScreen(requestId: docRef.id),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        if (e.toString().toLowerCase().contains('queued')) {
          _showErrorSnackBar(
            'No connection. Your request update is queued and will retry automatically.',
            Icons.wifi_off,
          );
          return;
        }
          _showErrorSnackBar(
            'Failed to request service. Please try again',
            Icons.cloud_off,
          );
      }
    } finally {
      if (mounted) {
        setState(() => _isSearchingBoosters = false);
      }
    }
  }

  void _watchLatestRequest() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return;
    }

    _requestWatchSub?.cancel();
    _requestWatchRetryTimer?.cancel();
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
          _activeRequestServiceType = null;
          _activeDriverId = null;
          _activeDriverDistanceKm = null;
          _activeDriverEtaMinutes = null;
          _activeDriverLatLng = null;
          _activeDriverLastUpdatedAt = null;
          _isDriverTrackingConnected = false;
          _activeRequestCreatedAt = null;
          _activeRequestStatusUpdatedAt = null;
          _searchAgainPromptCooldownUntil = null;
          _isSearchAgainDialogOpen = false;
        });
        return;
      }

      final doc = snapshot.docs.first;
      final data = doc.data();
      final previousRequestId = _activeRequestId;
      final newStatus = (data['status'] ?? 'pending').toString();
      final prevStatus = _activeRequestStatus;
      final newDriverId = data['driverId']?.toString();
      final newServiceType = (data['serviceType'] ?? serviceTypeBoost).toString();

      setState(() {
        _activeRequestId = doc.id;
        _activeRequestStatus = newStatus;
        _activeRequestServiceType = newServiceType;
        _activeDriverId = newDriverId;
        _activeRequestCreatedAt = _toDateTime(data['timestamp']);
        _activeRequestStatusUpdatedAt =
            _toDateTime(data['statusUpdatedAt']) ?? _toDateTime(data['timestamp']);
        if (previousRequestId != doc.id) {
          _searchAgainPromptCooldownUntil = null;
          _isSearchAgainDialogOpen = false;
        }
      });

      _watchActiveDriverLocation(newDriverId);

      if ((prevStatus == 'pending' || prevStatus == 'paid' || prevStatus == 'searching') &&
          (newStatus == 'accepted' || newStatus == 'en_route')) {
        _showProviderAcceptedFlash();
      } else if (newStatus == 'arrived' && prevStatus != 'arrived') {
        _showSuccessSnackBar('Provider has arrived at your location.');
      } else if (newStatus == 'completed' && prevStatus != 'completed') {
        _showSuccessSnackBar('Service request completed.');
      } else if (newStatus == 'cancelled' && prevStatus != 'cancelled') {
        _showErrorSnackBar('This request was cancelled.', Icons.info);
      } else if (newStatus == 'no_boosters_available' &&
          prevStatus != 'no_boosters_available') {
        _showErrorSnackBar('No providers are available nearby right now.', Icons.search_off);
      }

      _maybePromptSearchAgain();
    }, onError: (_) {
      if (!mounted) return;
      setState(() => _isDriverTrackingConnected = false);
      _scheduleRequestWatchRetry();
    }, onDone: _scheduleRequestWatchRetry);
  }

  void _watchActiveDriverLocation(String? driverId) {
    _driverWatchSub?.cancel();
    _driverWatchRetryTimer?.cancel();
    if (driverId == null || _pickupLatLng == null) {
      if (mounted) {
        setState(() {
          _activeDriverDistanceKm = null;
          _activeDriverEtaMinutes = null;
          _activeDriverLatLng = null;
          _activeDriverLastUpdatedAt = null;
          _isDriverTrackingConnected = false;
        });
      }
      return;
    }

    if (mounted) {
      setState(() => _isDriverTrackingConnected = true);
    }

    _driverWatchSub = FirebaseFirestore.instance
        .collection('users')
        .doc(driverId)
        .snapshots()
        .listen((doc) {
      if (!mounted || !doc.exists || _pickupLatLng == null) return;
      final data = doc.data() ?? <String, dynamic>{};
      final lat = (data['latitude'] as num?)?.toDouble();
      final lng = (data['longitude'] as num?)?.toDouble();
      if (lat == null || lng == null) return;

      final latestLatLng = LatLng(lat, lng);
      final previousLatLng = _activeDriverLatLng;
      final lastUpdatedAt =
          _toDateTime(data['locationUpdatedAt']) ?? _toDateTime(data['updatedAt']);

      final meters = Geolocator.distanceBetween(
        lat,
        lng,
        _pickupLatLng!.latitude,
        _pickupLatLng!.longitude,
      );
      final km = meters / 1000.0;
      final etaMinutes = ((km / 40.0) * 60.0).ceil().clamp(1, 240);

      setState(() {
        _isDriverTrackingConnected = true;
        _activeDriverDistanceKm = km;
        _activeDriverEtaMinutes = etaMinutes;
        _activeDriverLatLng = latestLatLng;
        _activeDriverLastUpdatedAt = lastUpdatedAt;
      });

      if (_mapController != null) {
        final movedMeters = previousLatLng == null
            ? double.infinity
            : Geolocator.distanceBetween(
                previousLatLng.latitude,
                previousLatLng.longitude,
                latestLatLng.latitude,
                latestLatLng.longitude,
              );
        if (movedMeters >= 80) {
          _mapController!.animateCamera(CameraUpdate.newLatLng(latestLatLng));
        }
      }
    }, onError: (_) {
      if (!mounted) return;
      setState(() => _isDriverTrackingConnected = false);
      _scheduleDriverWatchRetry(driverId);
    }, onDone: () {
      if (!mounted) return;
      setState(() => _isDriverTrackingConnected = false);
      _scheduleDriverWatchRetry(driverId);
    });
  }

  Future<void> _showPaymentSheet(String requestId) async {
    final approved = await _confirmYearlySubscriptionAddOn(
      const _SubscriptionCharge(
        region: defaultSupportedRegion,
        baseAmountCents: 0,
        taxAmountCents: 0,
      ),
      serviceTotalAmountCents: _serviceTotalAmountCents,
    );
    if (!approved) {
      return;
    }

    final result = await showModalBottomSheet<BoostPaymentResult>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      builder: (_) => _PaymentSheet(
        requestId: requestId,
        serviceLabel: _serviceSummaryLabel,
        totalAmountCents: _serviceTotalAmountCents,
        baseAmountCents: _serviceBaseAmountCents,
        taxAmountCents: _serviceTaxAmountCents,
      ),
    );

    if (!mounted) return;

    if (result != null) {
      try {
        await _transitionRequestStatus(
          requestId: requestId,
          to: RequestStatus.paid,
          extra: {
            'paymentAmount': result.amount,
            'paymentCurrency': result.currency,
            'paymentIntentId': result.paymentIntentId,
            'paymentProvider': result.paymentProvider,
          },
        );
        if (mounted) {
          _showSuccessSnackBar(
            result.paymentProvider == 'stripe'
                ? 'Payment successful!'
                : 'Payment confirmed in ${result.paymentProvider} mode.',
          );
        }
      } catch (e) {
        if (mounted) {
          if (e.toString().toLowerCase().contains('queued')) {
            _showErrorSnackBar(
              'No connection. Payment status update is queued and will retry automatically.',
              Icons.wifi_off,
            );
            return;
          }
          _showErrorSnackBar('Payment update failed. Please try again.', Icons.error);
        }
      }
    } else {
      _showErrorSnackBar('Payment cancelled. Request was not dispatched.', Icons.info);
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

  void _showProviderAcceptedFlash() {
    if (!mounted || _activeRequestId == null) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          'Provider accepted your request. Open live tracker to view ETA and distance.',
        ),
        duration: const Duration(seconds: 6),
        backgroundColor: const Color(0xFF14B8A6),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        margin: const EdgeInsets.all(16),
        action: SnackBarAction(
          label: 'View Live Tracker',
          textColor: Colors.white,
          onPressed: _openActiveRequestTracker,
        ),
      ),
    );
  }

  bool _shouldPromptSearchAgainForStatus(String? status) {
    return status == 'paid' ||
        status == 'pending' ||
        status == 'searching' ||
        status == 'no_boosters_available';
  }

  Duration? _activeRequestAge() {
    final createdAt = _activeRequestCreatedAt;
    if (createdAt == null) return null;
    return DateTime.now().difference(createdAt);
  }

  Future<void> _searchAgainForActiveRequest() async {
    final requestId = _activeRequestId;
    if (requestId == null || _isRedispatching) {
      return;
    }

    setState(() => _isRedispatching = true);
    try {
      final callable = FirebaseFunctions.instanceFor(region: 'northamerica-northeast1')
          .httpsCallable('dispatchBoosterNotifications');
      final dispatchResponse = await callable.call(<String, dynamic>{
        'requestId': requestId,
      });
      final responseData =
          Map<String, dynamic>.from(dispatchResponse.data as Map<dynamic, dynamic>);
      final notifiedCount = (responseData['notifiedCount'] as num?)?.toInt() ?? 0;

      if (!mounted) {
        return;
      }

      setState(() {
        _activeRequestStatus = notifiedCount > 0 ? 'searching' : 'no_boosters_available';
        _activeRequestStatusUpdatedAt = DateTime.now();
        _searchAgainPromptCooldownUntil = null;
      });

      _showSuccessSnackBar(
        notifiedCount > 0
            ? 'Searching again now. Notified $notifiedCount nearby providers.'
            : 'Search attempted again. No providers available yet.',
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      _showErrorSnackBar('Could not search again right now. Please retry.', Icons.search_off);
    } finally {
      if (mounted) {
        setState(() => _isRedispatching = false);
      }
    }
  }

  Future<void> _cancelActiveRequestFromPrompt() async {
    final requestId = _activeRequestId;
    if (requestId == null) {
      return;
    }

    try {
      await _transitionRequestStatus(
        requestId: requestId,
        to: RequestStatus.cancelled,
      );
      if (mounted) {
        _showErrorSnackBar('Request cancelled. You can create a new one anytime.', Icons.info);
      }
    } catch (_) {
      if (mounted) {
        _showErrorSnackBar('Unable to cancel request right now.', Icons.error_outline);
      }
    }
  }

  Future<void> _maybePromptSearchAgain() async {
    if (!mounted || _isSearchAgainDialogOpen) {
      return;
    }

    if (_activeRequestServiceType != serviceTypeBoost) {
      return;
    }

    if (!_shouldPromptSearchAgainForStatus(_activeRequestStatus)) {
      return;
    }

    final age = _activeRequestAge();
    if (age == null || age.inMinutes < 30) {
      return;
    }

    final cooldownUntil = _searchAgainPromptCooldownUntil;
    if (cooldownUntil != null && DateTime.now().isBefore(cooldownUntil)) {
      return;
    }

    _isSearchAgainDialogOpen = true;
    final action = await showDialog<_SearchAgainAction>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Still Looking For A Booster'),
          content: const Text(
            'No provider has accepted within 30 minutes. Would you like to search again, or cancel this request?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(_SearchAgainAction.later),
              child: const Text('Later'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(_SearchAgainAction.cancelRequest),
              child: const Text('Cancel Request'),
            ),
            ElevatedButton(
              onPressed: _isRedispatching
                  ? null
                  : () => Navigator.of(dialogContext).pop(_SearchAgainAction.searchAgain),
              child: const Text('Search Again'),
            ),
          ],
        );
      },
    );

    _isSearchAgainDialogOpen = false;
    if (!mounted) {
      return;
    }

    if (action == _SearchAgainAction.searchAgain) {
      await _searchAgainForActiveRequest();
      return;
    }

    if (action == _SearchAgainAction.cancelRequest) {
      await _cancelActiveRequestFromPrompt();
      return;
    }

    setState(() {
      _searchAgainPromptCooldownUntil = DateTime.now().add(const Duration(minutes: 2));
    });
  }

  int _currentStepNumber() {
    switch (_currentStep) {
      case _CustomerStep.vehicle:
        return 1;
      case _CustomerStep.location:
        return 2;
      case _CustomerStep.request:
        return 3;
      case _CustomerStep.boosters:
        return 4;
    }
  }

  String _currentStepTitle() {
    switch (_currentStep) {
      case _CustomerStep.vehicle:
        return _serviceType == serviceTypeTow ? 'Choose Tow Type' : 'Choose Your Battery Boost Type';
      case _CustomerStep.location:
        return 'Set Your Location';
      case _CustomerStep.request:
        return _serviceType == serviceTypeTow ? 'Request Tow' : 'Request Battery Boost';
      case _CustomerStep.boosters:
        return _serviceType == serviceTypeTow
            ? 'Available Tow Providers'
            : 'Available Battery Boost Providers';
    }
  }

  String _currentStepSubtitle() {
    switch (_currentStep) {
      case _CustomerStep.vehicle:
        return _serviceType == serviceTypeTow
            ? 'Pick the tow service that matches your vehicle before we search.'
            : 'Pick the exact kind of roadside help you need before we search.';
      case _CustomerStep.location:
        return 'Save your current location or enter a different address.';
      case _CustomerStep.request:
        return _serviceType == serviceTypeTow
            ? 'Review your tow request and start finding nearby available providers.'
            : 'Review your request including location address before requesting.';
      case _CustomerStep.boosters:
        return _serviceType == serviceTypeTow
            ? 'Reach out to one of the available tow providers below.'
            : 'Reach out to one of the available battery boost providers below.';
    }
  }

  Widget _buildStepIntro() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Color(0xFFE0E0E8)),
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFF22D3EE).withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Center(
                  child: Text(
                    '${_currentStepNumber()}',
                    style: const TextStyle(
                      color: Color(0xFF0891B2),
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _currentStepTitle(),
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _currentStepSubtitle(),
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(color: Colors.grey[700]),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: List.generate(4, (index) {
              final stepIndex = index + 1;
              final isComplete = stepIndex < _currentStepNumber();
              final isActive = stepIndex == _currentStepNumber();
              return Expanded(
                child: Container(
                  height: 6,
                  margin: EdgeInsets.only(right: index == 3 ? 0 : 8),
                  decoration: BoxDecoration(
                    color: isComplete || isActive
                        ? (isActive
                            ? const Color(0xFF22D3EE)
                            : const Color(0xFF6366F1))
                        : const Color(0xFFE8E8EE),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectionSummary() {
    if (_vehicleType == null && _pickupAddress == null) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE0E0E8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Current Selection', style: Theme.of(context).textTheme.titleSmall),
          if (_vehicleType != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  _serviceType == serviceTypeTow
                      ? Icons.local_shipping
                      : (_vehicleType == _electricVehicleType
                          ? Icons.ev_station
                          : Icons.directions_car),
                  color: const Color(0xFF22D3EE),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _serviceSummaryLabel,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ],
          if (_pickupAddress != null) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.place, color: Color(0xFF6366F1)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _pickupAddress!,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildVehicleStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_serviceType == serviceTypeTow)
          _TowTypeSelector(
            selectedTowType: _towType,
            onTowTypeChanged: _selectTowType,
          )
        else
          _VehicleTypeSelector(
            selectedVehicleType: _vehicleType,
            onVehicleTypeChanged: _selectVehicleType,
          ),
        if (_serviceType == serviceTypeBoost && _vehicleType == _electricVehicleType) ...[
          const SizedBox(height: 14),
          _PlugTypeSelector(
            selectedPlugType: _plugType,
            onPlugTypeChanged: _selectPlugType,
          ),
        ],
        const SizedBox(height: 18),
        ElevatedButton(
          onPressed: _continueToLocationStep,
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
          child: const Text('Continue'),
        ),
      ],
    );
  }

  Widget _buildCurrentLocationTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE0E0E8)),
          ),
          child: _isResolvingLocation && _detectedCurrentAddress == null
              ? const Row(
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 12),
                    Expanded(child: Text('Detecting your current location...')),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.my_location, color: Color(0xFF22D3EE)),
                        SizedBox(width: 10),
                        Text('Detected Location'),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _detectedCurrentAddress ?? 'Tap this tab to detect your current location.',
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(color: Colors.grey[700]),
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 14),
        ElevatedButton.icon(
          onPressed: _isResolvingLocation ? null : _saveDetectedCurrentLocation,
          icon: const Icon(Icons.check_circle_outline),
          label: const Text('Save Current Location'),
        ),
      ],
    );
  }

  Widget _buildMapLocationTab() {
    final initialTarget = _locationPickerLatLng ??
        _pickupLatLng ??
        (_currentPosition == null
            ? _defaultMapCenter
            : LatLng(_currentPosition!.latitude, _currentPosition!.longitude));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _mapAddressController,
          decoration: const InputDecoration(
            labelText: 'Enter address',
            prefixIcon: Icon(Icons.search),
          ),
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _searchAddressOnMap(),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 260,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: GoogleMap(
              initialCameraPosition: CameraPosition(target: initialTarget, zoom: 14),
              onMapCreated: (controller) {
                _locationPickerMapController = controller;
              },
              onTap: _selectLocationFromMap,
              markers: _locationPickerLatLng == null
                  ? const <Marker>{}
                  : <Marker>{
                      Marker(
                        markerId: const MarkerId('location_picker'),
                        position: _locationPickerLatLng!,
                        infoWindow: InfoWindow(
                          title: _locationPickerAddress ?? 'Selected location',
                        ),
                      ),
                    },
              myLocationEnabled: _hasLocationPermission,
              myLocationButtonEnabled: _hasLocationPermission,
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (_locationPickerAddress != null)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF2F2F7),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE0E0E8)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.pin_drop, color: Color(0xFF6366F1)),
                const SizedBox(width: 10),
                Expanded(child: Text(_locationPickerAddress!)),
              ],
            ),
          ),
        if (_locationPickerAddress != null) const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _isResolvingLocation ? null : _searchAddressOnMap,
                child: _isResolvingLocation
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Find on Map'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                onPressed: _isResolvingLocation ? null : _saveMapLocation,
                child: const Text('Save Location'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildLocationStep() {
    final screenHeight = MediaQuery.of(context).size.height;
    final tabContentHeight = (screenHeight * 0.56).clamp(420.0, 560.0);

    return DefaultTabController(
      length: 2,
      child: Builder(
        builder: (context) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFF2F2F7),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFFE0E0E8)),
                ),
                child: TabBar(
                  labelPadding: const EdgeInsets.symmetric(horizontal: 8),
                  onTap: (index) {
                    final tab = index == 0
                        ? _LocationSelectionTab.current
                        : _LocationSelectionTab.map;
                    setState(() => _locationSelectionTab = tab);
                    if (tab == _LocationSelectionTab.current) {
                      _prepareCurrentLocationPreview();
                    }
                  },
                  tabs: const [
                    Tab(text: 'Current Location'),
                    Tab(text: 'Enter a Different Address'),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: tabContentHeight,
                child: TabBarView(
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: _buildCurrentLocationTab(),
                    ),
                    SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: 24),
                      child: _buildMapLocationTab(),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildRequestStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSelectionSummary(),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFE0E0E8)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Ready to Request?', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 10),
              Text(
                _serviceType == serviceTypeTow
                    ? 'We will search for tow providers currently available near your saved location.'
                  : 'We will search for battery boost providers currently available near your saved location.',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: Colors.grey[300]),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                    onPressed: _isSearchingBoosters ? null : _requestBoosterAndPay,
                  icon: _isSearchingBoosters
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.payment),
                  label: Text(
                    'Request ${_serviceType == serviceTypeTow ? 'Tow' : 'Battery Boost'} • Pay \$${(_serviceTotalAmountCents / 100).toStringAsFixed(2)}',
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBoostersStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 220,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: GoogleMap(
              initialCameraPosition: CameraPosition(
                target: _pickupLatLng ??
                    (_currentPosition == null
                        ? _defaultMapCenter
                        : LatLng(_currentPosition!.latitude, _currentPosition!.longitude)),
                zoom: 12,
              ),
              markers: _buildMarkers(),
              onMapCreated: (controller) {
                _mapController = controller;
              },
              myLocationEnabled: _hasLocationPermission,
              myLocationButtonEnabled: _hasLocationPermission,
            ),
          ),
        ),
        const SizedBox(height: 16),
        _buildSelectionSummary(),
        const SizedBox(height: 16),
        if (_nearbyBoosters.isEmpty)
          BoosterSurfaceCard(
            padding: const EdgeInsets.all(18),
            child: Column(
              children: [
                const Icon(Icons.search_off, size: 36, color: Color(0xFF22D3EE)),
                const SizedBox(height: 12),
                Text(
                  _serviceType == serviceTypeTow
                      ? 'No tow providers available right now'
                      : 'No battery boost providers available right now',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'Try again in a moment or adjust the location and search again.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: Colors.grey[400]),
                ),
              ],
            ),
          )
        else
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _nearbyBoosters.length,
            itemBuilder: (context, index) {
              final booster = _nearbyBoosters[index];
              return BoosterSurfaceCard(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: const Color(0xFF6366F1).withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Icon(Icons.directions_car, color: Color(0xFF818CF8)),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(booster.displayName, style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 4),
                          Text(
                            '${booster.distanceKm.toStringAsFixed(2)} km away • ETA ${booster.etaMinutes} min',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: Colors.grey[400]),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    ElevatedButton(
                      onPressed: _isWaitingForBooster ? null : _requestBoosterAndPay,
                      child: const Text('Request'),
                    ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _buildCurrentStepContent() {
    switch (_currentStep) {
      case _CustomerStep.vehicle:
        return _buildVehicleStep();
      case _CustomerStep.location:
        return _buildLocationStep();
      case _CustomerStep.request:
        return _buildRequestStep();
      case _CustomerStep.boosters:
        return _buildBoostersStep();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new),
          onPressed: _goBackOneStep,
        ),
        title: Text(_serviceType == serviceTypeTow ? 'Tow Assistance' : 'Battery Boost Assistance'),
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
          ? const BoosterPageBackground(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Getting your location...'),
                  ],
                ),
              ),
            )
          : BoosterPageBackground(
              child: SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildStepIntro(),
                        if (_activeRequestId != null &&
                          _activeRequestStatus != 'awaiting_payment' &&
                          _currentStep != _CustomerStep.vehicle &&
                          _currentStep != _CustomerStep.location &&
                          _currentStep != _CustomerStep.request) ...[
                        const SizedBox(height: 16),
                        _RequestStatusCard(
                          status: _activeRequestStatus ?? 'pending',
                          showBoostTimer: _activeRequestServiceType == serviceTypeBoost,
                          driverId: _activeDriverId,
                          driverDistanceKm: _activeDriverDistanceKm,
                          driverEtaMinutes: _activeDriverEtaMinutes,
                          driverLastUpdatedAt: _activeDriverLastUpdatedAt,
                          isTrackingConnected: _isDriverTrackingConnected,
                          requestCreatedAt: _activeRequestCreatedAt,
                          statusUpdatedAt: _activeRequestStatusUpdatedAt,
                          now: DateTime.now(),
                          onOpenTracker: _openActiveRequestTracker,
                          onPayNow: _activeRequestStatus == 'awaiting_payment'
                              ? () => _showPaymentSheet(_activeRequestId!)
                              : null,
                        ),
                      ],
                      const SizedBox(height: 16),
                      _buildCurrentStepContent(),
                    ],
                  ),
                ),
              ),
            ),
      bottomNavigationBar: widget.showBottomNav
          ? MainBottomNavBar(
              currentTab: MainTab.request,
              onTabSelected: _onTabSelected,
            )
          : null,
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

    if (_activeDriverLatLng != null) {
      markers.add(
        Marker(
          markerId: const MarkerId('active_driver'),
          position: _activeDriverLatLng!,
          infoWindow: InfoWindow(
            title: 'Provider location',
            snippet: _activeDriverDistanceKm != null && _activeDriverEtaMinutes != null
                ? '${_activeDriverDistanceKm!.toStringAsFixed(1)} km • ETA ${_activeDriverEtaMinutes!} min'
                : 'Live location update',
          ),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueCyan),
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
  const _RequestStatusCard({
    required this.status,
    required this.showBoostTimer,
    required this.driverId,
    required this.driverDistanceKm,
    required this.driverEtaMinutes,
    required this.driverLastUpdatedAt,
    required this.isTrackingConnected,
    required this.requestCreatedAt,
    required this.statusUpdatedAt,
    required this.now,
    this.onOpenTracker,
    this.onPayNow,
  });

  final String status;
  final bool showBoostTimer;
  final String? driverId;
  final double? driverDistanceKm;
  final int? driverEtaMinutes;
  final DateTime? driverLastUpdatedAt;
  final bool isTrackingConnected;
  final DateTime? requestCreatedAt;
  final DateTime? statusUpdatedAt;
  final DateTime now;
  final VoidCallback? onOpenTracker;
  final VoidCallback? onPayNow;

  String _formatElapsed(DateTime? from, DateTime now) {
    if (from == null) return 'just now';
    final diff = now.difference(from);
    if (diff.inMinutes < 1) {
      return '${diff.inSeconds.clamp(0, 59)}s ago';
    }
    if (diff.inHours < 1) {
      return '${diff.inMinutes}m ago';
    }
    return '${diff.inHours}h ago';
  }

  Duration _countdownFromRequest(DateTime? requestCreatedAt, DateTime now) {
    if (requestCreatedAt == null) {
      return Duration.zero;
    }
    final deadline = requestCreatedAt.add(const Duration(minutes: 20));
    final remaining = deadline.difference(now);
    return remaining.isNegative ? Duration.zero : remaining;
  }

  String _formatCountdown(Duration remaining) {
    final minutes = remaining.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = remaining.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final n = status.toLowerCase();
    final isPending = n == 'pending';
    final needsPayment = n == 'awaiting_payment';
    final isPaid = n == 'paid';
    final isSearching = n == 'searching';
    final isEnRoute = n == 'accepted' || n == 'en_route';
    final isArrived = n == 'arrived';
    final isDone = n == 'completed';
    final isCancelled = n == 'cancelled';
    final noBoosters = n == 'no_boosters_available';
    final showActiveTimer = showBoostTimer && (isPending || isSearching || isPaid || noBoosters);
    final timerRemaining = _countdownFromRequest(requestCreatedAt, now);

    final Color tone = isDone
        ? Colors.green
        : isArrived
            ? const Color(0xFF14B8A6)
        : isEnRoute || isPaid
            ? const Color(0xFF06B6D4)
          : isCancelled
            ? const Color(0xFFEF4444)
          : noBoosters
            ? const Color(0xFFFB7185)
          : isSearching
            ? const Color(0xFF6366F1)
            : needsPayment
                ? const Color(0xFFF59E0B)
                : isPending
                    ? Colors.orange
                    : Colors.grey;

    final IconData icon = isDone
        ? Icons.check_circle
        : isArrived
            ? Icons.place
        : isEnRoute || isPaid
            ? Icons.directions_car
          : isCancelled
            ? Icons.cancel
          : noBoosters
            ? Icons.search_off
          : isSearching
            ? Icons.notifications_active
            : needsPayment
                ? Icons.payment
                : Icons.hourglass_bottom;

    final String title = isDone
        ? 'Boost Completed'
        : isArrived
            ? 'Provider has arrived'
        : isEnRoute
            ? 'Provider is on the way'
            : isPaid
            ? 'Payment confirmed — notifying nearby providers'
            : isCancelled
              ? 'Request cancelled'
            : noBoosters
              ? 'No providers available'
            : isSearching
              ? 'Searching nearby providers'
                : needsPayment
                    ? 'Payment required to dispatch request'
                    : 'Waiting for provider to accept';

    final String subtitle = isDone
        ? 'Your request is complete. Thank you!'
        : isArrived
            ? 'Provider reached your pickup point.'
        : isEnRoute
          ? (driverDistanceKm != null && driverEtaMinutes != null
            ? 'Provider is ${driverDistanceKm!.toStringAsFixed(1)} km away • ETA ${driverEtaMinutes!} min'
            : 'Provider is en route to your location')
            : isPaid
            ? 'Hold tight while we notify available providers nearest first.'
            : isCancelled
              ? 'The request is no longer active.'
            : noBoosters
              ? 'Try again shortly or update your pickup location.'
            : isSearching
              ? 'Pinging available providers in your area...'
                : needsPayment
                    ? 'Tap "Pay Now" to confirm and dispatch your request'
                    : 'Invite sent. Please wait for confirmation.';

    final canOpenTracker = !isCancelled && !isDone && !noBoosters;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: canOpenTracker ? onOpenTracker : null,
        child: Container(
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
                    const SizedBox(height: 2),
                    Text(
                      'Status updated ${_formatElapsed(statusUpdatedAt, now)} • Requested ${_formatElapsed(requestCreatedAt, now)}',
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: Colors.grey[400]),
                    ),
                    if (showActiveTimer) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A1A2E),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.timer, color: Colors.white, size: 16),
                            const SizedBox(width: 8),
                            Text(
                              '${_formatCountdown(timerRemaining)} / 20:00',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (isEnRoute || isArrived) ...[
                      const SizedBox(height: 2),
                      Text(
                        !isTrackingConnected
                            ? 'Live tracking reconnecting...'
                            : driverLastUpdatedAt == null
                                ? 'Waiting for live GPS update...'
                                : now.difference(driverLastUpdatedAt!).inSeconds > 45
                                    ? 'Latest driver GPS is stale (${_formatElapsed(driverLastUpdatedAt, now)}).'
                                    : 'Driver GPS updated ${_formatElapsed(driverLastUpdatedAt, now)}',
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(
                              color: !isTrackingConnected
                                  ? const Color(0xFFF59E0B)
                                  : (driverLastUpdatedAt != null &&
                                          now.difference(driverLastUpdatedAt!).inSeconds > 45)
                                      ? const Color(0xFFF59E0B)
                                      : Colors.grey[400],
                            ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (needsPayment && onPayNow != null) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: onPayNow,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFF59E0B),
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    Icon(Icons.payment, size: 18),
                    SizedBox(width: 8),
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          'Pay Now',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (canOpenTracker && onOpenTracker != null) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onOpenTracker,
                icon: const Icon(Icons.map_outlined),
                label: const Text('Open Live Tracker'),
              ),
            ),
          ],
        ],
      ),
        ),
      ),
    );
  }
}

class _PaymentSheet extends StatefulWidget {
  const _PaymentSheet({
    required this.requestId,
    required this.serviceLabel,
    required this.totalAmountCents,
    required this.baseAmountCents,
    required this.taxAmountCents,
    this.subscriptionBaseAmountCents = 0,
    this.subscriptionTaxAmountCents = 0,
    this.subscriptionCurrencyCode = 'CAD',
    this.requestSeedData,
  });

  final String requestId;
  final String serviceLabel;
  final int totalAmountCents;
  final int baseAmountCents;
  final int taxAmountCents;
  final int subscriptionBaseAmountCents;
  final int subscriptionTaxAmountCents;
  final String subscriptionCurrencyCode;
  final Map<String, dynamic>? requestSeedData;

  @override
  State<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<_PaymentSheet> {
  bool _isProcessing = false;
  String? _error;

  StripePaymentService get _paymentService => StripePaymentService.instance;

  Future<void> _processPayment() async {
    setState(() => _isProcessing = true);

    try {
      if (widget.requestSeedData != null) {
        await FirebaseFirestore.instance
            .collection('requests')
            .doc(widget.requestId)
            .set(widget.requestSeedData!);
      }

      final result = await StripePaymentService.instance.payForBoostRequest(
        requestId: widget.requestId,
        amountInCents: widget.totalAmountCents,
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
          color: Colors.white,
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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      'Complete Payment',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'Provider is waiting for your confirmation',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          // Summary
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFF2F2F7),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                _SummaryRow(
                  label: widget.serviceLabel,
                  value: '\$${(widget.baseAmountCents / 100).toStringAsFixed(2)}',
                ),
                const SizedBox(height: 8),
                _SummaryRow(
                  label: 'Service Tax',
                  value: '\$${(widget.taxAmountCents / 100).toStringAsFixed(2)}',
                ),
                if (widget.subscriptionBaseAmountCents > 0) ...[
                  const SizedBox(height: 8),
                  _SummaryRow(
                    label: 'Yearly Subscription',
                    value:
                        '\$${(widget.subscriptionBaseAmountCents / 100).toStringAsFixed(2)}',
                  ),
                  const SizedBox(height: 8),
                  _SummaryRow(
                    label: 'Subscription Tax',
                    value:
                        '\$${(widget.subscriptionTaxAmountCents / 100).toStringAsFixed(2)}',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'First service checkout includes yearly subscription (${widget.subscriptionCurrencyCode}).',
                    style: const TextStyle(
                      color: Color(0xFF8A8A9A),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Divider(color: Color(0xFFE0E0E8)),
                ),
                _SummaryRow(
                    label: 'Total',
                    value: '\$${(widget.totalAmountCents / 100).toStringAsFixed(2)}',
                    bold: true,
                    valueColor: const Color(0xFFF59E0B)),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFF2F2F7),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE0E0E8)),
            ),
            child: Row(
              children: [
                Icon(
                  _paymentService.paymentMode == BoostPaymentMode.stripe
                      ? Icons.lock
                      : Icons.science,
                  color: const Color(0xFF22D3EE),
                  size: 18,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _paymentService.paymentInfoText,
                    style: const TextStyle(color: Color(0xFF8A8A9A), fontSize: 13),
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
                    : Text(
                        '${_paymentService.checkoutButtonLabel} \$${(widget.totalAmountCents / 100).toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
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
                  : () => Navigator.of(context).pop(),
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
                color: bold ? const Color(0xFF1A1A2E) : Colors.grey[600],
                fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                fontSize: bold ? 15 : 13)),
        Text(value,
            style: TextStyle(
                color: valueColor ?? (bold ? const Color(0xFF1A1A2E) : const Color(0xFF8A8A9A)),
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

const String _regularVehicleType = regularVehicleType;
const String _electricVehicleType = electricVehicleType;
const List<String> _plugTypes = boostPlugTypes;
const List<String> _towTypes = towServiceTypes;

class _PlugTypeSelector extends StatelessWidget {
  const _PlugTypeSelector({
    required this.selectedPlugType,
    required this.onPlugTypeChanged,
  });

  final String? selectedPlugType;
  final ValueChanged<String> onPlugTypeChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('EV Plug Type', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: _plugTypes
                .map(
                  (plugType) => Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: _PlugTypeCard(
                      plugType: plugType,
                      selected: selectedPlugType == plugType,
                      onTap: () => onPlugTypeChanged(plugType),
                    ),
                  ),
                )
                .toList(growable: false),
          ),
        ),
      ],
    );
  }
}

class _TowTypeSelector extends StatelessWidget {
  const _TowTypeSelector({
    required this.selectedTowType,
    required this.onTowTypeChanged,
  });

  final String? selectedTowType;
  final ValueChanged<String> onTowTypeChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Tow Service Type', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: _towTypes.map((towType) {
            final selected = selectedTowType == towType;
            return ChoiceChip(
              label: Text(towTypeLabel(towType)),
              selected: selected,
              selectedColor: const Color(0xFFF59E0B).withValues(alpha: 0.28),
              labelStyle: TextStyle(
                color: selected ? const Color(0xFF1A1A2E) : Colors.grey[700],
              ),
              onSelected: (_) => onTowTypeChanged(towType),
            );
          }).toList(growable: false),
        ),
        const SizedBox(height: 10),
        Text(
          'Tow pricing starts at \$135.00 for car tow and \$250.00 for pickup/van tow, plus tax.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey[700]),
        ),
      ],
    );
  }
}

class _VehicleTypeSelector extends StatelessWidget {
  const _VehicleTypeSelector({
    required this.selectedVehicleType,
    required this.onVehicleTypeChanged,
  });

  final String? selectedVehicleType;
  final ValueChanged<String> onVehicleTypeChanged;

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
                title: 'Regular Car Boost',
                subtitle: 'Best for standard gas or hybrid vehicles',
                icon: Icons.directions_car_filled,
                selected: selectedVehicleType == _regularVehicleType,
                accentColor: const Color(0xFF6366F1),
                onTap: () => onVehicleTypeChanged(_regularVehicleType),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _VehicleTypeCard(
                title: 'Electric Car Boost',
                subtitle: 'Best for EV roadside battery support',
                icon: Icons.ev_station,
                selected: selectedVehicleType == _electricVehicleType,
                accentColor: const Color(0xFF22D3EE),
                onTap: () => onVehicleTypeChanged(_electricVehicleType),
              ),
            ),
          ],
        ),
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
    required this.accentColor,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool selected;
  final Color accentColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        constraints: const BoxConstraints(minHeight: 170),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: selected
                ? <Color>[
                    accentColor.withValues(alpha: 0.10),
                    Colors.white,
                  ]
                : <Color>[
                    Colors.white,
                    const Color(0xFFF2F2F7),
                  ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? accentColor : const Color(0xFFE0E0E8),
            width: selected ? 1.6 : 1,
          ),
          boxShadow: selected
              ? <BoxShadow>[
                  BoxShadow(
                    color: accentColor.withValues(alpha: 0.18),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: selected ? 0.18 : 0.10),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: selected ? accentColor : Colors.grey[700]),
                ),
                const Spacer(),
                if (selected)
                  Icon(Icons.check_circle, color: accentColor),
              ],
            ),
            const SizedBox(height: 14),
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              subtitle,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.grey[700]),
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
            color: selected ? const Color(0xFF22D3EE) : const Color(0xFFE8E8EE),
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
                  ?.copyWith(color: Colors.grey[700]),
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE0E0E8)),
      ),
      child: Stack(
        children: [
          Positioned(
            right: 8,
            top: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF5500FF).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                _plugBadge(label),
                style: const TextStyle(
                  color: Color(0xFF5500FF),
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
    final pinPaint = Paint()..color = const Color(0xFF1A1A2E);
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

    final capPaint = Paint()..color = const Color(0xFF1A1A2E).withValues(alpha: 0.12);
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