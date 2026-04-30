import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'app_shell.dart';
import 'login_screen.dart';
import 'home_screen.dart';
import 'customer_screen.dart';
import 'provider_status_screen.dart';
import 'driver_screen.dart';
import 'main_bottom_nav.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({
    this.showBottomNav = true,
    super.key,
  });

  final bool showBottomNav;

  void _handleBack(BuildContext context) {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  void _onTabSelected(BuildContext context, MainTab tab) {
    if (tab == MainTab.profile) return;

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
        destination = const DriverScreen();
        break;
      case MainTab.profile:
        return;
    }

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => destination),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new),
            onPressed: () => _handleBack(context),
          ),
          title: const Text('Profile'),
        ),
        body: BoosterPageBackground(
          child: Center(
            child: FilledButton(
              onPressed: () {
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                  (route) => false,
                );
              },
              child: const Text('Go to Login'),
            ),
          ),
        ),
        bottomNavigationBar: showBottomNav
            ? MainBottomNavBar(
                currentTab: MainTab.profile,
                onTabSelected: (tab) => _onTabSelected(context, tab),
              )
            : null,
      );
    }

    final userDocStream = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .snapshots();

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new),
          onPressed: () => _handleBack(context),
        ),
        title: const Text('Profile'),
      ),
      body: BoosterPageBackground(
        child: SafeArea(
          child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: userDocStream,
            builder: (context, snapshot) {
              final userData = snapshot.data?.data() ?? <String, dynamic>{};
              final role = (userData['role'] ?? 'Not set').toString();
              final fullName = (userData['fullName'] ?? '').toString().trim();
              final address = (userData['address'] ?? '').toString().trim();
              final phone = (userData['phone'] ?? '').toString().trim();
              final isVerified = userData['isVerified'] == true;
              final isSubscribed = userData['isSubscribed'] == true;
              final boostTypes = (userData['boostTypes'] is List)
                  ? (userData['boostTypes'] as List)
                      .map((item) => item.toString())
                      .where((item) => item.isNotEmpty)
                      .toList(growable: false)
                  : const <String>[];

              final missingProfileItems = <String>[
                if (fullName.isEmpty) 'Full name',
                if (address.isEmpty) 'Address',
                if (phone.isEmpty) 'Phone number',
                if (role.toLowerCase() != 'customer' && role.toLowerCase() != 'driver')
                  'Account role',
                if (!isVerified) 'Verification',
              ];
              final totalProfileChecks = 5;
              final completedChecks = totalProfileChecks - missingProfileItems.length;

              return ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Center(
                    child: CircleAvatar(
                      radius: 42,
                      backgroundColor: const Color(0xFF2EC4B6).withValues(alpha: 0.2),
                      child: Text(
                        _initialForEmail(user.email),
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Text(
                      user.email ?? 'No email',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _ProfileTile(label: 'User ID', value: user.uid),
                  _ProfileTile(
                    label: 'Full Name',
                    value: fullName.isEmpty ? 'Not set' : fullName,
                  ),
                  _ProfileTile(
                    label: 'Phone',
                    value: phone.isEmpty ? 'Not set' : phone,
                  ),
                  _ProfileTile(label: 'Role', value: role),
                  _ProfileTile(
                    label: 'Verification',
                    value: isVerified ? 'Verified' : 'Pending',
                  ),
                  _ProfileTile(
                    label: 'Subscription',
                    value: isSubscribed ? 'Active' : 'Inactive',
                  ),
                  const SizedBox(height: 16),
                  BoosterSurfaceCard(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Profile Completeness',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '$completedChecks of $totalProfileChecks checks complete',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: Colors.grey[300]),
                        ),
                        const SizedBox(height: 10),
                        LinearProgressIndicator(
                          value: completedChecks / totalProfileChecks,
                          minHeight: 8,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        if (missingProfileItems.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(
                            'Missing: ${missingProfileItems.join(', ')}',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: const Color(0xFFF59E0B)),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  BoosterSurfaceCard(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Boost Types', style: Theme.of(context).textTheme.titleSmall),
                        const SizedBox(height: 10),
                        if (boostTypes.isEmpty)
                          Text(
                            'No boost types selected.',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: Colors.grey[300]),
                          )
                        else
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: boostTypes
                                .map(
                                  (type) => Chip(
                                    label: Text(type),
                                    side: const BorderSide(color: const Color(0xFFCCCCCC)),
                                    backgroundColor:
                                        const Color(0xFF2EC4B6).withValues(alpha: 0.15),
                                  ),
                                )
                                .toList(growable: false),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.logout),
                    label: const Text('Sign Out'),
                    onPressed: () async {
                      await FirebaseAuth.instance.signOut();
                      if (!context.mounted) return;
                      Navigator.of(context).pushAndRemoveUntil(
                        MaterialPageRoute(builder: (_) => const LoginScreen()),
                        (route) => false,
                      );
                    },
                  ),
                ],
              );
            },
          ),
        ),
      ),
      bottomNavigationBar: showBottomNav
          ? MainBottomNavBar(
              currentTab: MainTab.profile,
              onTabSelected: (tab) => _onTabSelected(context, tab),
            )
          : null,
    );
  }

  String _initialForEmail(String? email) {
    if (email == null || email.trim().isEmpty) return 'P';
    return email.trim().substring(0, 1).toUpperCase();
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: BoosterSurfaceCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(color: Colors.grey[300]),
            ),
            const SizedBox(height: 4),
            Text(value, style: Theme.of(context).textTheme.bodyLarge),
          ],
        ),
      ),
    );
  }
}