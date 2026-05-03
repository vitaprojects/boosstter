import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'app_shell.dart';
import 'boost_service_options.dart';
import 'orders_landing_screen.dart';
import 'home_screen.dart';
import 'customer_screen.dart';
import 'profile_screen.dart';
import 'main_bottom_nav.dart';
import 'subscription_access.dart';

class ProviderStatusScreen extends StatefulWidget {
  const ProviderStatusScreen({
    this.showBottomNav = true,
    super.key,
  });

  final bool showBottomNav;

  @override
  State<ProviderStatusScreen> createState() => _ProviderStatusScreenState();
}

class _ProviderStatusScreenState extends State<ProviderStatusScreen> {
  static const List<String> _plugTypes = boostPlugTypes;
  static const List<String> _towTypes = towServiceTypes;

  bool _isLoading = true;
  bool _isSaving = false;
  bool _isAvailable = false;
  final Set<String> _offeredServiceTypes = <String>{};
  String? _offeredVehicleType;
  String? _offeredPlugType;
  final Set<String> _offeredTowTypes = <String>{};

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
      return;
    }

    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
      final data = doc.data() ?? <String, dynamic>{};

      if (!mounted) return;
      setState(() {
        _isAvailable = data['isAvailable'] == true;
        _offeredServiceTypes
          ..clear()
          ..addAll(
            ((data['offeredServiceTypes'] as List?)
                        ?.map((item) => item.toString())
                        .where((item) => item.isNotEmpty)
                        .toList(growable: false)) ??
                    const <String>[serviceTypeBoost],
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
        if (_offeredServiceTypes.contains(serviceTypeBoost) && _offeredVehicleType == null) {
          _offeredVehicleType = regularVehicleType;
        }
        if (_offeredVehicleType == electricVehicleType) {
          _offeredPlugType ??= _plugTypes.first;
        }
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not load your provider settings.')),
      );
    }
  }

  Future<void> _saveProviderProfile({Position? positionOverride}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final payload = <String, dynamic>{
      'userId': user.uid,
      'email': user.email,
      'role': 'driver',
      'isAvailable': _isAvailable,
      'offeredServiceTypes': _offeredServiceTypes.toList(growable: false),
      'offeredVehicleType': _offeredServiceTypes.contains(serviceTypeBoost)
          ? _offeredVehicleType
          : null,
      'offeredPlugType': _offeredServiceTypes.contains(serviceTypeBoost) &&
              _offeredVehicleType == electricVehicleType
          ? _offeredPlugType
          : null,
      'offeredTowTypes': _offeredServiceTypes.contains(serviceTypeTow)
          ? _offeredTowTypes.toList(growable: false)
          : const <String>[],
      'updatedAt': FieldValue.serverTimestamp(),
    };

    if (positionOverride != null) {
      payload['latitude'] = positionOverride.latitude;
      payload['longitude'] = positionOverride.longitude;
      payload['locationUpdatedAt'] = FieldValue.serverTimestamp();
    }

    await FirebaseFirestore.instance.collection('users').doc(user.uid).set(
          payload,
          SetOptions(merge: true),
        );
  }

  bool _serviceSelectionIsValid() {
    if (_offeredServiceTypes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose at least one offered service type.')),
      );
      return false;
    }

    if (_offeredServiceTypes.contains(serviceTypeBoost) && _offeredVehicleType == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose your boost type.')),
      );
      return false;
    }

    if (_offeredServiceTypes.contains(serviceTypeBoost) &&
        _offeredVehicleType == electricVehicleType &&
        _offeredPlugType == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select your EV connector type.')),
      );
      return false;
    }

    if (_offeredServiceTypes.contains(serviceTypeTow) && _offeredTowTypes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose at least one tow type.')),
      );
      return false;
    }

    return true;
  }

  Future<void> _toggleAvailability(bool value) async {
    if (_isSaving) return;

    if (value) {
      final canProceed = await ensureSubscribedForAction(
        context,
        purpose: 'provide_service',
      );
      if (!canProceed) {
        return;
      }
    }

    if (value && !_serviceSelectionIsValid()) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      Position? position;
      if (value) {
        final permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Location permission is required to go available.')),
            );
          }
          return;
        }
        position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        );
      }

      setState(() => _isAvailable = value);
      await _saveProviderProfile(positionOverride: position);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(value ? 'You are now available.' : 'You are now offline.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update availability. Try again.')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _saveSettingsAfterChange() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      await _saveProviderProfile();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save provider settings.')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _toggleServiceType(String serviceType, bool selected) async {
    setState(() {
      if (selected) {
        _offeredServiceTypes.add(serviceType);
        if (serviceType == serviceTypeBoost) {
          _offeredVehicleType ??= regularVehicleType;
        }
        if (serviceType == serviceTypeTow && _offeredTowTypes.isEmpty) {
          _offeredTowTypes.add(towTypeCar);
        }
      } else {
        _offeredServiceTypes.remove(serviceType);
      }
    });
    await _saveSettingsAfterChange();
  }

  Future<void> _selectBoostVehicleType(String type) async {
    setState(() {
      _offeredVehicleType = type;
      if (type == regularVehicleType) {
        _offeredPlugType = null;
      } else {
        _offeredPlugType ??= _plugTypes.first;
      }
    });
    await _saveSettingsAfterChange();
  }

  Future<void> _selectPlugType(String plugType) async {
    setState(() => _offeredPlugType = plugType);
    await _saveSettingsAfterChange();
  }

  Future<void> _toggleTowType(String towType, bool selected) async {
    setState(() {
      if (selected) {
        _offeredTowTypes.add(towType);
      } else {
        _offeredTowTypes.remove(towType);
      }
    });
    await _saveSettingsAfterChange();
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
    if (tab == MainTab.provider) return;

    final Widget destination;
    switch (tab) {
      case MainTab.home:
        destination = const HomeScreen();
        break;
      case MainTab.request:
        destination = const CustomerScreen();
        break;
      case MainTab.provider:
        return;
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
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new),
          onPressed: _handleBack,
        ),
        title: const Text('Service Status'),
      ),
      body: BoosterPageBackground(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  BoosterSurfaceCard(
                    borderColor: _isAvailable
                        ? const Color(0xFF22C55E).withValues(alpha: 0.45)
                        : const Color(0xFFEEEEF0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.tune, color: Color(0xFF22D3EE)),
                            const SizedBox(width: 10),
                            Text(
                              'Offer Services',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Need a Boost or Need a Tow is temporary. This section controls what services you offer to others at any time.',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Colors.grey[300],
                              ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _isAvailable ? 'Available for jobs' : 'Offline for jobs',
                                style: TextStyle(
                                  color: _isAvailable
                                      ? const Color(0xFF22C55E)
                                      : Colors.grey[400],
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Switch(
                              value: _isAvailable,
                              onChanged: _isSaving ? null : _toggleAvailability,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  BoosterSurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Service Types',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            FilterChip(
                              label: const Text('Boost Service'),
                              selected: _offeredServiceTypes.contains(serviceTypeBoost),
                              onSelected: _isSaving
                                  ? null
                                  : (value) => _toggleServiceType(serviceTypeBoost, value),
                            ),
                            FilterChip(
                              label: const Text('Tow Service'),
                              selected: _offeredServiceTypes.contains(serviceTypeTow),
                              onSelected: _isSaving
                                  ? null
                                  : (value) => _toggleServiceType(serviceTypeTow, value),
                            ),
                          ],
                        ),
                        if (_offeredServiceTypes.contains(serviceTypeBoost)) ...[
                          const SizedBox(height: 16),
                          Text(
                            'Boost Type',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              ChoiceChip(
                                label: const Text('Regular (Cable)'),
                                selected: _offeredVehicleType == regularVehicleType,
                                onSelected: _isSaving
                                    ? null
                                    : (_) => _selectBoostVehicleType(regularVehicleType),
                              ),
                              ChoiceChip(
                                label: const Text('Electric (Machine)'),
                                selected: _offeredVehicleType == electricVehicleType,
                                onSelected: _isSaving
                                    ? null
                                    : (_) => _selectBoostVehicleType(electricVehicleType),
                              ),
                            ],
                          ),
                          if (_offeredVehicleType == electricVehicleType) ...[
                            const SizedBox(height: 12),
                            DropdownButtonFormField<String>(
                              value: _offeredPlugType,
                              dropdownColor: Colors.white,
                              decoration: const InputDecoration(
                                labelText: 'EV connector type',
                                filled: true,
                                fillColor: Color(0xFFF2F2F7),
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
                                  .toList(growable: false),
                              onChanged: _isSaving
                                  ? null
                                  : (value) {
                                      if (value != null) {
                                        _selectPlugType(value);
                                      }
                                    },
                            ),
                          ],
                        ],
                        if (_offeredServiceTypes.contains(serviceTypeTow)) ...[
                          const SizedBox(height: 16),
                          Text(
                            'Tow Types',
                            style: Theme.of(context).textTheme.titleSmall,
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
                                    onSelected: _isSaving
                                        ? null
                                        : (value) => _toggleTowType(towType, value),
                                  ),
                                )
                                .toList(growable: false),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const OrdersLandingScreen(),
                          ),
                        );
                      },
                      icon: const Icon(Icons.notifications_active_outlined),
                      label: const Text('Open Orders Page'),
                    ),
                  ),
                  if (_isSaving) ...[
                    const SizedBox(height: 12),
                    const Center(child: CircularProgressIndicator()),
                  ],
                ],
              ),
      ),
      bottomNavigationBar: widget.showBottomNav
          ? MainBottomNavBar(
              currentTab: MainTab.provider,
              onTabSelected: _onTabSelected,
            )
          : null,
    );
  }
}