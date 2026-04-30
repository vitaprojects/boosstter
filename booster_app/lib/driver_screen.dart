import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:geolocator/geolocator.dart';
import 'app_shell.dart';
import 'login_screen.dart';
import 'boost_service_options.dart';
import 'offline_retry_queue.dart';
import 'request_lifecycle.dart';
import 'new_order_notification_screen.dart';
import 'order_details_screen.dart';
import 'route_metrics_service.dart';
import 'home_screen.dart';
import 'customer_screen.dart';
import 'profile_screen.dart';
import 'provider_status_screen.dart';
import 'main_bottom_nav.dart';
import 'subscription_access.dart';

const String _serviceTypeBoost = serviceTypeBoost;
const String _serviceTypeTow = serviceTypeTow;
const String _regularVehicleType = regularVehicleType;
const String _electricVehicleType = electricVehicleType;
const List<String> _plugTypes = boostPlugTypes;
const List<String> _towTypes = towServiceTypes;

class DriverScreen extends StatefulWidget {
  const DriverScreen({
    this.showBottomNav = true,
    super.key,
  });

  final bool showBottomNav;

  @override
  State<DriverScreen> createState() => _DriverScreenState();
}

class _DriverScreenState extends State<DriverScreen> {
  bool _isAvailable = false;
  Timer? _locationTimer;
  Position? _currentPosition;
  final Set<String> _offeredServiceTypes = <String>{_serviceTypeBoost};
  String? _offeredVehicleType;
  String? _offeredPlugType;
  final Set<String> _offeredTowTypes = <String>{};

  // Active job state
  String? _activeRequestId;
  String? _activeRequestStatus;
  String? _activePickupAddress;
  double? _activePickupLat;
  double? _activePickupLng;
  String? _activeServiceType;
  String? _activeVehicleType;
  String? _activePlugType;
  String? _activeTowType;
  StreamSubscription<QuerySnapshot>? _activeJobSub;
  StreamSubscription<String>? _tokenRefreshSub;
  
  // Incoming orders state
  StreamSubscription<QuerySnapshot>? _incomingOrdersSub;
  final Set<String> _shownOrderNotifications = <String>{};
  final Map<String, RouteMetrics?> _routeMetricsByRequest =
      <String, RouteMetrics?>{};
  final Set<String> _routeMetricsInFlight = <String>{};

  bool get _hasActiveJob =>
      _activeRequestId != null &&
      _activeRequestStatus != null &&
      _activeRequestStatus != 'completed' &&
      _activeRequestStatus != 'cancelled';

  @override
  void initState() {
    super.initState();
    _loadDriverData();
    _registerPushToken();
  }

  @override
  void dispose() {
    _locationTimer?.cancel();
    _activeJobSub?.cancel();
    _tokenRefreshSub?.cancel();
    _incomingOrdersSub?.cancel();
    super.dispose();
  }

  Future<void> _registerPushToken() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      await FirebaseMessaging.instance.requestPermission();
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null && token.isNotEmpty) {
        await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
          'fcmToken': token,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }

      _tokenRefreshSub = FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
        if (newToken.isEmpty) return;
        await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
          'fcmToken': newToken,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      });
    } catch (_) {
      // Keep app functional even if push permission/token fails.
    }
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
      setState(() {
        _isAvailable = data['isAvailable'] == true;
        _offeredServiceTypes
          ..clear()
          ..addAll(
            ((data['offeredServiceTypes'] as List?)
                        ?.map((item) => item.toString())
                        .where((item) => item.isNotEmpty)
                        .toList(growable: false)) ??
                    const <String>[_serviceTypeBoost],
          );
        _offeredVehicleType = data['offeredVehicleType']?.toString();
        _offeredPlugType = data['offeredPlugType']?.toString();
        _offeredTowTypes
          ..clear()
          ..addAll(
            ((data['offeredTowTypes'] as List?)
                        ?.map((item) => item.toString())
                        .where((item) => item.isNotEmpty)
                        .toList(growable: false)) ??
                    const <String>[],
          );
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
        .where('status', whereIn: ['accepted', 'en_route', 'arrived', 'paid'])
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
              _activeServiceType = null;
              _activeVehicleType = null;
              _activePlugType = null;
              _activeTowType = null;
            });
            // Start watching for new incoming orders once active job is cleared
            _watchIncomingOrders();
          } else {
            final doc = snap.docs.first;
            final data = doc.data();
            setState(() {
              _activeRequestId = doc.id;
              _activeRequestStatus = data['status'];
              _activePickupAddress = data['pickupAddress'];
              _activePickupLat = (data['pickupLatitude'] as num?)?.toDouble();
              _activePickupLng = (data['pickupLongitude'] as num?)?.toDouble();
              _activeServiceType = data['serviceType']?.toString() ?? _serviceTypeBoost;
              _activeVehicleType = data['vehicleType']?.toString();
              _activePlugType = data['plugType']?.toString();
              _activeTowType = data['towType']?.toString();
            });
            // Stop watching for new orders while there's an active job
            _incomingOrdersSub?.cancel();
          }
        });
  }

  void _watchIncomingOrders() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || !_isAvailable) return;

    _incomingOrdersSub?.cancel();
    // Simplified query: just filter by notifiedDriverIds to avoid composite index requirement
    // Additional filtering (status, driverId) done client-side
    _incomingOrdersSub = FirebaseFirestore.instance
        .collection('requests')
        .where('notifiedDriverIds', arrayContains: user.uid)
        .orderBy('timestamp', descending: true)
        .limit(20) // Limit to recent orders for performance
        .snapshots()
        .listen((snap) {
          if (!mounted) return;
          
          for (final doc in snap.docs) {
            final data = doc.data();
            
            // Client-side filtering: only show if still pending and not assigned
            final status = data['status']?.toString() ?? '';
            final driverId = data['driverId']?.toString() ?? '';
            
            if (status != 'pending' || driverId.isNotEmpty) {
              continue; // Skip if already accepted or not pending
            }
            
            final requestId = doc.id;
            
            // Only show notification once per order
            if (_shownOrderNotifications.contains(requestId)) {
              continue;
            }
            
            _shownOrderNotifications.add(requestId);
            
            final serviceType = data['serviceType']?.toString() ?? _serviceTypeBoost;
            final vehicleType = data['vehicleType']?.toString() ?? 'regular';
            final plugType = data['plugType']?.toString() ?? '';
            final towType = data['towType']?.toString() ?? '';
            final serviceLabel = serviceType == _serviceTypeTow
                ? 'Tow • ${towTypeLabel(towType)}'
                : 'Boost • ${vehicleType == _electricVehicleType ? 'Electric${plugType.isEmpty ? '' : ' • $plugType'}' : 'Regular'}';

            _showOrderNotificationModal(
              requestId: requestId,
              customerId: data['customerId']?.toString() ?? '',
              pickupAddress: data['pickupAddress']?.toString() ?? 'Pickup location',
              pickupLatitude: (data['pickupLatitude'] as num?)?.toDouble() ?? 0.0,
              pickupLongitude: (data['pickupLongitude'] as num?)?.toDouble() ?? 0.0,
              compensationAmount: (data['compensationAmount'] as num?)?.toDouble() ?? 0.0,
              vehicleType: serviceLabel,
              plugType: '',
            );
          }
        }, onError: (error) {
          // Safe error handling
          debugPrint('Error watching incoming orders: $error');
        });
  }

  void _showOrderNotificationModal({
    required String requestId,
    required String customerId,
    required String pickupAddress,
    required double pickupLatitude,
    required double pickupLongitude,
    required double compensationAmount,
    required String vehicleType,
    required String plugType,
  }) {
    showModalBottomSheet(
      context: context,
      isDismissible: true,
      enableDrag: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => NewOrderNotificationScreen(
        requestId: requestId,
        customerId: customerId,
        pickupAddress: pickupAddress,
        pickupLatitude: pickupLatitude,
        pickupLongitude: pickupLongitude,
        compensationAmount: compensationAmount,
        vehicleType: vehicleType,
        plugType: plugType,
      ),
    ).then((_) {
      // Clean up notification tracking when modal is closed
      _shownOrderNotifications.remove(requestId);
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
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'userId': user.uid,
        'email': user.email,
        'role': 'driver',
        'isAvailable': _isAvailable,
        'latitude': _currentPosition!.latitude,
        'longitude': _currentPosition!.longitude,
        'offeredServiceTypes': _offeredServiceTypes.toList(growable: false),
        'offeredVehicleType': _offeredVehicleType,
        'offeredPlugType': _offeredVehicleType == _electricVehicleType
            ? _offeredPlugType
            : null,
        'offeredTowTypes': _offeredTowTypes.toList(growable: false),
        'locationUpdatedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }
  }

  bool _serviceSelectionIsValid() {
    if (_offeredServiceTypes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose at least one service type (Boost or Tow)')),
      );
      return false;
    }

    if (_offeredServiceTypes.contains(_serviceTypeBoost) && _offeredVehicleType == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose your boost type to go online')),
      );
      return false;
    }

    if (_offeredServiceTypes.contains(_serviceTypeBoost) &&
        _offeredVehicleType == _electricVehicleType &&
        _offeredPlugType == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select your EV connector type to go online')),
      );
      return false;
    }

    if (_offeredServiceTypes.contains(_serviceTypeTow) && _offeredTowTypes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose at least one tow service type to go online')),
      );
      return false;
    }

    return true;
  }

  Future<void> _saveDriverServiceProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
      'userId': user.uid,
      'email': user.email,
      'role': 'driver',
      'offeredServiceTypes': _offeredServiceTypes.toList(growable: false),
      'offeredVehicleType': _offeredVehicleType,
      'offeredPlugType': _offeredVehicleType == _electricVehicleType
          ? _offeredPlugType
          : null,
      'offeredTowTypes': _offeredTowTypes.toList(growable: false),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> _selectOfferedVehicleType(String vehicleType) async {
    setState(() {
      _offeredVehicleType = vehicleType;
      if (vehicleType == _regularVehicleType) {
        _offeredPlugType = null;
      } else {
        _offeredPlugType ??= _plugTypes.first;
      }
    });
    await _saveDriverServiceProfile();
    if (_isAvailable) {
      await _pushLocationToFirestore();
    }
  }

  Future<void> _selectOfferedPlugType(String plugType) async {
    setState(() => _offeredPlugType = plugType);
    await _saveDriverServiceProfile();
    if (_isAvailable) {
      await _pushLocationToFirestore();
    }
  }

  Future<void> _toggleOfferedServiceType(String serviceType, bool selected) async {
    setState(() {
      if (selected) {
        _offeredServiceTypes.add(serviceType);
      } else {
        _offeredServiceTypes.remove(serviceType);
      }
    });
    await _saveDriverServiceProfile();
  }

  Future<void> _toggleTowType(String towType, bool selected) async {
    setState(() {
      if (selected) {
        _offeredTowTypes.add(towType);
      } else {
        _offeredTowTypes.remove(towType);
      }
    });
    await _saveDriverServiceProfile();
  }

  Future<void> _toggleAvailability(bool value) async {
    if (value) {
      final canProceed = await ensureSubscribedForAction(
        context,
        purpose: 'provide_service',
      );
      if (!canProceed) {
        return;
      }

      if (!_serviceSelectionIsValid()) {
        return;
      }
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
      await _saveDriverServiceProfile();
      _startLocationUpdates();
      _watchIncomingOrders(); // Start listening for new orders
      await _updateLocation(); // immediate first push
    } else {
      setState(() => _isAvailable = false);
      _stopLocationUpdates();
      _incomingOrdersSub?.cancel(); // Stop listening for new orders
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .set({
          'isAvailable': false,
          'offeredServiceTypes': _offeredServiceTypes.toList(growable: false),
          'offeredVehicleType': _offeredVehicleType,
          'offeredPlugType': _offeredVehicleType == _electricVehicleType
              ? _offeredPlugType
              : null,
          'offeredTowTypes': _offeredTowTypes.toList(growable: false),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(value ? 'You are now Available' : 'You are now Offline')),
      );
    }
  }

  Future<bool> _acceptRequest(String requestId) async {
    final canProceed = await ensureSubscribedForAction(
      context,
      purpose: 'provide_service',
    );
    if (!canProceed) return false;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    try {
      await FirebaseFirestore.instance.runTransaction((txn) async {
        final ref = FirebaseFirestore.instance.collection('requests').doc(requestId);
        final snap = await txn.get(ref);
        if (!snap.exists) {
          throw Exception('Request not found');
        }

        final data = snap.data() ?? <String, dynamic>{};
        final status = requestStatusFromString((data['status'] ?? '').toString());
        final assignedDriverId = data['driverId']?.toString();
        final notifiedDrivers = (data['notifiedDriverIds'] as List?)
                ?.map((item) => item.toString())
                .toList(growable: false) ??
            const <String>[];

        if (!canTransitionRequestStatus(status, RequestStatus.accepted) ||
            (assignedDriverId != null && assignedDriverId.isNotEmpty)) {
          throw Exception('This request is no longer available.');
        }
        if (!notifiedDrivers.contains(user.uid)) {
          throw Exception('You are not eligible for this request anymore.');
        }

        txn.update(ref, {
          ...buildStatusTransitionPatch(to: RequestStatus.accepted),
          'driverId': user.uid,
          'driverEmail': user.email ?? '',
        });
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Order accepted.')),
        );
      }
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to accept: $e')),
        );
      }
      return false;
    }
  }

  Future<void> _updateJobStatus(String status) async {
    if (_activeRequestId == null) return;

    bool isRetryableSyncError(Object error) {
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

    try {
      final nextStatus = requestStatusFromString(status);
      final requestRef =
          FirebaseFirestore.instance.collection('requests').doc(_activeRequestId);

      Future<void> runUpdate() async {
        await FirebaseFirestore.instance.runTransaction((txn) async {
          final snap = await txn.get(requestRef);
          if (!snap.exists) {
            throw Exception('Request no longer exists.');
          }

          final data = snap.data() ?? <String, dynamic>{};
          final current = requestStatusFromString((data['status'] ?? '').toString());
          if (!canTransitionRequestStatus(current, nextStatus)) {
            throw Exception('Invalid status change: ${current.value} -> ${nextStatus.value}');
          }

          txn.update(requestRef, buildStatusTransitionPatch(to: nextStatus));
        });
      }

      await runUpdate();
    } catch (e) {
      if (mounted) {
        if (isRetryableSyncError(e)) {
          final nextStatus = requestStatusFromString(status);
          final requestId = _activeRequestId!;
          OfflineRetryQueue.instance.enqueue(
            key: 'driver-status-$requestId-${nextStatus.value}',
            action: () async {
              final requestRef =
                  FirebaseFirestore.instance.collection('requests').doc(requestId);
              await FirebaseFirestore.instance.runTransaction((txn) async {
                final snap = await txn.get(requestRef);
                if (!snap.exists) return;
                final data = snap.data() ?? <String, dynamic>{};
                final current =
                    requestStatusFromString((data['status'] ?? '').toString());
                if (!canTransitionRequestStatus(current, nextStatus)) {
                  return;
                }
                txn.update(requestRef, buildStatusTransitionPatch(to: nextStatus));
              });
            },
          );
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No connection. Status update queued and will retry.'),
            ),
          );
          return;
        }
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Update failed: $e')));
      }
    }
  }

  void _handleBack() {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  void _onTabSelected(MainTab tab) {
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

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new),
          onPressed: _handleBack,
        ),
        title: const Text('Order Console'),
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
      body: BoosterPageBackground(
        child: ListView(
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
                _isAvailable ? 'Order Board' : 'Go Available to Load Orders',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              if (_isAvailable)
                Text(
                  'Newest orders first. Tap any order to view details.',
                  style: TextStyle(
                    color: Colors.grey[400],
                    fontSize: 13,
                  ),
                ),
              if (_isAvailable) const SizedBox(height: 12),
              if (_isAvailable) _buildIncomingRequestsList(),
            ],
          ],
        ),
      ),
      bottomNavigationBar: widget.showBottomNav
          ? MainBottomNavBar(
              currentTab: MainTab.orders,
              onTabSelected: _onTabSelected,
            )
          : null,
    );
  }

  Widget _buildAvailabilityCard() {
    return BoosterSurfaceCard(
      padding: const EdgeInsets.all(20),
      borderColor: _isAvailable
          ? const Color(0xFF22C55E).withValues(alpha: 0.5)
          : Colors.grey.withValues(alpha: 0.2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
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
                            _isAvailable ? 'Available for Requests' : 'Currently Offline',
                            style: TextStyle(
                              color: _isAvailable ? const Color(0xFF22C55E) : Colors.grey[400],
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          if (_isAvailable && _currentPosition != null)
                            Text(
                              'Location updating every 5s while you stay online',
                              style: TextStyle(color: Colors.grey[500], fontSize: 12),
                            )
                          else
                            Text(
                              'Choose services you offer, then toggle online',
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
                const SizedBox(height: 18),
                Text(
                  'Services you offer',
                  style: TextStyle(
                    color: Colors.grey[300],
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilterChip(
                      label: const Text('Boost Service'),
                      selected: _offeredServiceTypes.contains(_serviceTypeBoost),
                      onSelected: (selected) => _toggleOfferedServiceType(_serviceTypeBoost, selected),
                      selectedColor: const Color(0xFF6366F1).withValues(alpha: 0.25),
                      labelStyle: TextStyle(
                        color: _offeredServiceTypes.contains(_serviceTypeBoost)
                            ? Colors.white
                            : Colors.grey[300],
                      ),
                    ),
                    FilterChip(
                      label: const Text('Tow Service'),
                      selected: _offeredServiceTypes.contains(_serviceTypeTow),
                      onSelected: (selected) => _toggleOfferedServiceType(_serviceTypeTow, selected),
                      selectedColor: const Color(0xFFF59E0B).withValues(alpha: 0.25),
                      labelStyle: TextStyle(
                        color: _offeredServiceTypes.contains(_serviceTypeTow)
                            ? Colors.white
                            : Colors.grey[300],
                      ),
                    ),
                  ],
                ),
                if (_offeredServiceTypes.contains(_serviceTypeBoost)) ...[
                  const SizedBox(height: 14),
                  Text(
                    'Boost type',
                    style: TextStyle(
                      color: Colors.grey[300],
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      ChoiceChip(
                        label: const Text('Regular'),
                        selected: _offeredVehicleType == _regularVehicleType,
                        onSelected: (_) => _selectOfferedVehicleType(_regularVehicleType),
                        selectedColor: const Color(0xFF6366F1).withValues(alpha: 0.25),
                        labelStyle: TextStyle(
                          color: _offeredVehicleType == _regularVehicleType
                              ? Colors.white
                              : Colors.grey[300],
                        ),
                      ),
                      ChoiceChip(
                        label: const Text('Electric'),
                        selected: _offeredVehicleType == _electricVehicleType,
                        onSelected: (_) => _selectOfferedVehicleType(_electricVehicleType),
                        selectedColor: const Color(0xFF22D3EE).withValues(alpha: 0.25),
                        labelStyle: TextStyle(
                          color: _offeredVehicleType == _electricVehicleType
                              ? Colors.white
                              : Colors.grey[300],
                        ),
                      ),
                    ],
                  ),
                  if (_offeredVehicleType == _electricVehicleType) ...[
                    const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                      value: _offeredPlugType,
                      dropdownColor: Colors.white,
                      decoration: InputDecoration(
                        labelText: 'EV connector type',
                        labelStyle: TextStyle(color: Colors.grey[600]),
                        filled: true,
                        fillColor: const Color(0xFFF2F2F7),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      items: _plugTypes
                          .map(
                            (plugType) => DropdownMenuItem<String>(
                              value: plugType,
                              child: Text(
                                plugType,
                                style: const TextStyle(color: Color(0xFF1A1A2E)),
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value != null) {
                          _selectOfferedPlugType(value);
                        }
                      },
                    ),
                  ],
                ],
                if (_offeredServiceTypes.contains(_serviceTypeTow)) ...[
                  const SizedBox(height: 14),
                  Text(
                    'Tow types',
                    style: TextStyle(
                      color: Colors.grey[300],
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: _towTypes
                        .map(
                          (towType) => FilterChip(
                            label: Text(towTypeLabel(towType)),
                            selected: _offeredTowTypes.contains(towType),
                            onSelected: (selected) => _toggleTowType(towType, selected),
                            selectedColor: const Color(0xFFF59E0B).withValues(alpha: 0.25),
                            labelStyle: TextStyle(
                              color: _offeredTowTypes.contains(towType)
                                  ? Colors.white
                                  : Colors.grey[300],
                            ),
                          ),
                        )
                        .toList(growable: false),
                  ),
                ],
              ],
            ),
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
        statusLabel = _activeServiceType == _serviceTypeTow ? 'New Tow Request' : 'New Boost Request';
        actionLabel = 'Accept Request';
        nextStatus = 'accepted';
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
        statusIcon = Icons.near_me;
        statusLabel = 'En Route to Customer';
        actionLabel = 'Mark Arrived';
        nextStatus = 'arrived';
        break;
      case 'arrived':
        statusColor = const Color(0xFF14B8A6);
        statusIcon = Icons.place;
        statusLabel = 'Arrived at Pickup';
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

    return BoosterSurfaceCard(
      padding: EdgeInsets.zero,
      borderColor: statusColor.withValues(alpha: 0.4),
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
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
                if (_activeServiceType == _serviceTypeTow && _activeTowType != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.local_shipping, color: Color(0xFFF59E0B), size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          towTypeLabel(_activeTowType!),
                          style: const TextStyle(
                            color: const Color(0xFF8A8A9A),
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (_activeServiceType != _serviceTypeTow && _activeVehicleType != null) ...[
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
                            color: const Color(0xFF8A8A9A),
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
                if (status == 'pending') ...[
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
                      Text('Accept this request to start heading over.',
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
          .where('notifiedDriverIds', arrayContains: user.uid)
          .orderBy('timestamp', descending: true)
          .limit(20)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Text('Error: ${snapshot.error}',
              style: const TextStyle(color: Colors.red));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final docs = snapshot.data!.docs
            .where((doc) {
              final data = doc.data() as Map<String, dynamic>;
              final status = data['status']?.toString() ?? '';
              final driverId = data['driverId']?.toString() ?? '';
              return status == 'pending' && driverId.isEmpty;
            })
            .toList(growable: false);
          _primeRouteMetrics(docs);
        if (docs.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(32),
            alignment: Alignment.center,
            child: Column(
              children: [
                Icon(Icons.inbox_outlined, color: Colors.grey[600], size: 48),
                const SizedBox(height: 12),
                Text(
                  'No live orders yet. New requests will appear here first.',
                  style: TextStyle(color: Colors.grey[500], fontSize: 15),
                ),
              ],
            ),
          );
        }
        return Column(
          children: docs.map((doc) {
            final data = doc.data() as Map<String, dynamic>;
            final address = data['pickupAddress']?.toString() ?? 'Unknown location';
            final ts = data['timestamp'] as Timestamp?;
            final timeAgo = ts != null
                ? _formatTimeAgo(ts.toDate())
                : '';
            final pickupLatitude = (data['pickupLatitude'] as num?)?.toDouble();
            final pickupLongitude = (data['pickupLongitude'] as num?)?.toDouble();
            final routeMetrics = _routeMetricsByRequest[doc.id];
            final fallbackDistanceKm = _distanceToRequestKm(
              pickupLatitude: pickupLatitude,
              pickupLongitude: pickupLongitude,
            );
            final fallbackEtaMinutes = _estimateEtaMinutes(fallbackDistanceKm);
            return _OrderBoardCard(
              customerId: data['customerId']?.toString() ?? '',
              serviceLabel: _buildOrderServiceLabel(data),
              address: address,
              postedLabel: timeAgo,
              distanceLabel: _formatDistanceLabel(
                routeMetrics?.distanceKm ?? fallbackDistanceKm,
                hasRoute: routeMetrics != null,
                isLoading: _routeMetricsInFlight.contains(doc.id),
              ),
              etaLabel: _formatEtaLabel(
                routeMetrics?.etaMinutes ?? fallbackEtaMinutes,
                hasRoute: routeMetrics != null,
                isLoading: _routeMetricsInFlight.contains(doc.id),
              ),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => OrderDetailsScreen(
                      customerId: data['customerId']?.toString() ?? '',
                      serviceLabel: _buildOrderServiceLabel(data),
                      pickupAddress: address,
                      postedLabel: timeAgo,
                      distanceLabel: _formatDistanceLabel(
                        routeMetrics?.distanceKm ?? fallbackDistanceKm,
                        hasRoute: routeMetrics != null,
                        isLoading: _routeMetricsInFlight.contains(doc.id),
                      ),
                      etaLabel: _formatEtaLabel(
                        routeMetrics?.etaMinutes ?? fallbackEtaMinutes,
                        hasRoute: routeMetrics != null,
                        isLoading: _routeMetricsInFlight.contains(doc.id),
                      ),
                      onAcceptOrder: () => _acceptRequest(doc.id),
                    ),
                  ),
                );
              },
            );
          }).toList(growable: false),
        );
      },
    );
  }

  void _primeRouteMetrics(List<QueryDocumentSnapshot> docs) {
    if (_currentPosition == null) {
      return;
    }

    for (final doc in docs) {
      if (_routeMetricsByRequest.containsKey(doc.id) ||
          _routeMetricsInFlight.contains(doc.id)) {
        continue;
      }

      final data = doc.data() as Map<String, dynamic>;
      final pickupLatitude = (data['pickupLatitude'] as num?)?.toDouble();
      final pickupLongitude = (data['pickupLongitude'] as num?)?.toDouble();
      if (pickupLatitude == null || pickupLongitude == null) {
        continue;
      }

      _routeMetricsInFlight.add(doc.id);
      RouteMetricsService.instance
          .getDrivingRouteMetrics(
            originLatitude: _currentPosition!.latitude,
            originLongitude: _currentPosition!.longitude,
            destinationLatitude: pickupLatitude,
            destinationLongitude: pickupLongitude,
          )
          .then((metrics) {
            if (!mounted) {
              return;
            }
            setState(() {
              _routeMetricsByRequest[doc.id] = metrics;
              _routeMetricsInFlight.remove(doc.id);
            });
          });
    }
  }

  double? _distanceToRequestKm({
    required double? pickupLatitude,
    required double? pickupLongitude,
  }) {
    if (_currentPosition == null || pickupLatitude == null || pickupLongitude == null) {
      return null;
    }
    return Geolocator.distanceBetween(
          _currentPosition!.latitude,
          _currentPosition!.longitude,
          pickupLatitude,
          pickupLongitude,
        ) /
        1000;
  }

  int? _estimateEtaMinutes(double? distanceKm) {
    if (distanceKm == null) return null;
    final etaMinutes = ((distanceKm / 35) * 60).ceil();
    return etaMinutes < 2 ? 2 : etaMinutes;
  }

  String _formatDistanceLabel(
    double? distanceKm, {
    required bool hasRoute,
    required bool isLoading,
  }) {
    if (distanceKm == null) {
      return isLoading ? 'Loading route...' : 'Distance unavailable';
    }
    if (hasRoute) {
      return '${distanceKm.toStringAsFixed(1)} km route';
    }
    return '${distanceKm.toStringAsFixed(1)} km';
  }

  String _formatEtaLabel(
    int? etaMinutes, {
    required bool hasRoute,
    required bool isLoading,
  }) {
    if (etaMinutes == null) {
      return isLoading ? 'Loading ETA...' : 'ETA unavailable';
    }
    if (hasRoute) {
      return '$etaMinutes min route ETA';
    }
    return '$etaMinutes min est.';
  }

  String _buildOrderServiceLabel(Map<String, dynamic> data) {
    final serviceType = data['serviceType']?.toString() ?? _serviceTypeBoost;
    if (serviceType == _serviceTypeTow) {
      final towType = data['towType']?.toString();
      return towType == null || towType.isEmpty
          ? 'Tow Service'
          : 'Tow • ${towTypeLabel(towType)}';
    }

    final vehicleType = data['vehicleType']?.toString();
    final plugType = data['plugType']?.toString();
    if (vehicleType == _electricVehicleType) {
      return plugType == null || plugType.isEmpty
          ? 'Boost • Electric'
          : 'Boost • Electric • $plugType';
    }
    return 'Boost • Regular';
  }

  String _formatTimeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${diff.inHours}h ago';
  }
}

class _OrderBoardCard extends StatelessWidget {
  const _OrderBoardCard({
    required this.customerId,
    required this.serviceLabel,
    required this.address,
    required this.postedLabel,
    required this.distanceLabel,
    required this.etaLabel,
    required this.onTap,
  });

  final String customerId;
  final String serviceLabel;
  final String address;
  final String postedLabel;
  final String distanceLabel;
  final String etaLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _loadCustomerName(customerId),
      builder: (context, snapshot) {
        final customerName = snapshot.data ?? 'Customer';
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(14),
              child: Ink(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: const Color(0xFF14B8A6).withValues(alpha: 0.40),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.assignment_outlined,
                            color: Color(0xFF22D3EE), size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            customerName,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        if (postedLabel.isNotEmpty)
                          Text(
                            postedLabel,
                            style: TextStyle(
                              color: Colors.grey[500],
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      serviceLabel,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      address,
                      style: const TextStyle(color: Color(0xFF8A8A9A), fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        _OrderMetaChip(
                          icon: Icons.near_me_outlined,
                          label: distanceLabel,
                          color: const Color(0xFF22D3EE),
                        ),
                        const SizedBox(width: 8),
                        _OrderMetaChip(
                          icon: Icons.schedule,
                          label: etaLabel,
                          color: const Color(0xFFF59E0B),
                        ),
                        const Spacer(),
                        const Icon(Icons.chevron_right, color: const Color(0xFFBBBBBB)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _OrderMetaChip extends StatelessWidget {
  const _OrderMetaChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

Future<String> _loadCustomerName(String customerId) async {
  if (customerId.isEmpty) return 'Customer';

  try {
    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(customerId)
        .get();
    final data = snapshot.data() ?? <String, dynamic>{};
    final fullName = data['fullName']?.toString().trim() ?? '';
    if (fullName.isNotEmpty) return fullName;
    final displayName = data['displayName']?.toString().trim() ?? '';
    if (displayName.isNotEmpty) return displayName;
    final email = data['email']?.toString().trim() ?? '';
    if (email.isNotEmpty) return email;
  } catch (_) {
    return 'Customer';
  }

  return 'Customer';
}