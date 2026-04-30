import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'app_shell.dart';
import 'request_lifecycle.dart';
import 'order_tracking_screen.dart';

/// New Order Notification Screen
/// Shows when a booster receives a new order with:
/// - Location and distance to customer
/// - Compensation/payout amount
/// - Accept/Decline buttons
class NewOrderNotificationScreen extends StatefulWidget {
  final String requestId;
  final String customerId;
  final String pickupAddress;
  final double pickupLatitude;
  final double pickupLongitude;
  final double compensationAmount;
  final String vehicleType;
  final String plugType;
  final double? distanceKm;

  const NewOrderNotificationScreen({
    required this.requestId,
    required this.customerId,
    required this.pickupAddress,
    required this.pickupLatitude,
    required this.pickupLongitude,
    required this.compensationAmount,
    required this.vehicleType,
    required this.plugType,
    this.distanceKm,
    super.key,
  });

  @override
  State<NewOrderNotificationScreen> createState() =>
      _NewOrderNotificationScreenState();
}

class _NewOrderNotificationScreenState extends State<NewOrderNotificationScreen>
    with SingleTickerProviderStateMixin {
  bool _isAccepting = false;
  bool _isDeclining = false;
  late AnimationController _slideController;
  late Animation<Offset> _slideAnimation;
  Position? _boosterPosition;

  @override
  void initState() {
    super.initState();
    _slideController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _slideController, curve: Curves.easeOut));

    _slideController.forward();
    _getCurrentLocation();
  }

  @override
  void dispose() {
    _slideController.dispose();
    super.dispose();
  }

  Future<void> _getCurrentLocation() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      if (mounted) {
        setState(() {
          _boosterPosition = position;
        });
      }
    } catch (e) {
      debugPrint('Error getting booster position: $e');
    }
  }

  double _calculateDistance(Position from) {
    return Geolocator.distanceBetween(
          from.latitude,
          from.longitude,
          widget.pickupLatitude,
          widget.pickupLongitude,
        ) /
        1000; // Convert to km
  }

  Future<void> _acceptOrder() async {
    if (_isAccepting) return;
    
    setState(() => _isAccepting = true);

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
        final currentStatus = data['status'] ?? 'pending';

        // Verify status can transition to accepted
        if (!canTransitionRequestStatus(
          requestStatusFromString(currentStatus),
          RequestStatus.accepted,
        )) {
          throw Exception('Cannot accept order in status: $currentStatus');
        }

        txn.update(requestRef, {
          'driverId': user.uid,
          'status': 'accepted',
          'acceptedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });

      if (mounted) {
        // Close notification and go to tracking screen
        Navigator.of(context).pop();
        
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (context) => OrderTrackingScreen(
              requestId: widget.requestId,
              customerId: widget.customerId,
              pickupAddress: widget.pickupAddress,
              pickupLatitude: widget.pickupLatitude,
              pickupLongitude: widget.pickupLongitude,
              vehicleType: widget.vehicleType,
              plugType: widget.plugType,
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error accepting order: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error accepting order: $e'),
            backgroundColor: Colors.red,
          ),
        );
        setState(() => _isAccepting = false);
      }
    }
  }

  Future<void> _declineOrder() async {
    if (_isDeclining) return;
    
    setState(() => _isDeclining = true);

    try {
      // Just close the notification - request stays in pool for other boosters
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      debugPrint('Error declining order: $e');
      if (mounted) {
        setState(() => _isDeclining = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final distance = _boosterPosition != null
        ? _calculateDistance(_boosterPosition!)
        : widget.distanceKm ?? 0.0;

    return SlideTransition(
      position: _slideAnimation,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            // Semi-transparent background
            GestureDetector(
              onTap: _declineOrder,
              child: Container(
                color: Colors.black.withValues(alpha: 0.5),
              ),
            ),
            // Main notification card
            Align(
              alignment: Alignment.bottomCenter,
              child: SingleChildScrollView(
                child: BoosterSurfaceCard(
                  margin: const EdgeInsets.all(16),
                  borderColor: const Color(0xFF14B8A6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header with close button
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'New Service Order! 🚀',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          GestureDetector(
                            onTap: _declineOrder,
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.grey[200],
                              ),
                              child: const Icon(
                                Icons.close,
                                color: Color(0xFF8A8A9A),
                                size: 20,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      // Location info
                      _InfoRow(
                        icon: Icons.location_on,
                        label: 'Location',
                        value: widget.pickupAddress,
                        isMultiline: true,
                      ),
                      const SizedBox(height: 12),
                      // Distance info
                      _InfoRow(
                        icon: Icons.directions_car,
                        label: 'Distance',
                        value: '${distance.toStringAsFixed(1)} km away',
                      ),
                      const SizedBox(height: 12),
                      // Service type info
                      _InfoRow(
                        icon: Icons.build,
                        label: 'Service',
                        value: widget.plugType.isEmpty
                            ? widget.vehicleType
                            : '${widget.vehicleType} - ${widget.plugType}',
                      ),
                      const SizedBox(height: 16),
                      // Compensation highlight
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF14B8A6), Color(0xFF0D9488)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Your Compensation',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              '\$${widget.compensationAmount.toStringAsFixed(2)}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      // Action buttons
                      Row(
                        children: [
                          // Decline button
                          Expanded(
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: _isDeclining ? null : _declineOrder,
                                borderRadius: BorderRadius.circular(12),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  decoration: BoxDecoration(
                                    border: Border.all(color: Colors.grey[600]!),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: _isDeclining
                                      ? const SizedBox(
                                          height: 20,
                                          width: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            valueColor:
                                                AlwaysStoppedAnimation<Color>(
                                              Colors.grey,
                                            ),
                                          ),
                                        )
                                      : const Text(
                                          'Decline',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: Colors.grey,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          // Accept button
                          Expanded(
                            child: Material(
                              color: const Color(0xFF14B8A6),
                              borderRadius: BorderRadius.circular(12),
                              child: InkWell(
                                onTap: _isAccepting ? null : _acceptOrder,
                                borderRadius: BorderRadius.circular(12),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  child: _isAccepting
                                      ? const SizedBox(
                                          height: 20,
                                          width: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            valueColor:
                                                AlwaysStoppedAnimation<Color>(
                                              Colors.white,
                                            ),
                                          ),
                                        )
                                      : const Text(
                                          'Accept Order',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
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

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool isMultiline;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.isMultiline = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment:
          isMultiline ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        Icon(
          icon,
          color: const Color(0xFF14B8A6),
          size: 24,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: Colors.grey,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: isMultiline ? 2 : 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
