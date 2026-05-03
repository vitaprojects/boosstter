import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'app_shell.dart';
import 'boost_service_options.dart';
import 'customer_requests_tab_screen.dart';
import 'customer_screen.dart';
import 'driver_screen.dart';
import 'orders_landing_screen.dart';
import 'provider_status_screen.dart';
import 'profile_screen.dart';

class HomeScreen extends StatefulWidget {
  final List<String>? selectedBoostTypes;

  const HomeScreen({this.selectedBoostTypes, super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const List<_MainTabVisual> _tabVisuals = <_MainTabVisual>[
    _MainTabVisual(
      label: 'Home',
      icon: Icons.home_outlined,
      activeIcon: Icons.home,
      color: Color(0xFF5500FF),
    ),
    _MainTabVisual(
      label: 'Offer',
      icon: Icons.tune_outlined,
      activeIcon: Icons.tune,
      color: Color(0xFFEA3DFF),
    ),
    _MainTabVisual(
      label: 'Orders NEW',
      icon: Icons.radar_outlined,
      activeIcon: Icons.radar,
      color: Color(0xFF00E5FF),
    ),
    _MainTabVisual(
      label: 'Profile',
      icon: Icons.person_outline,
      activeIcon: Icons.person,
      color: Color(0xFFFFD60A),
    ),
  ];

  int _selectedTabIndex = 0;
  int _requestTabVersion = 0;

  void _onMainTabSelected(int index) {
    if (index == 0) {
      setState(() {
        _selectedTabIndex = 0;
        _requestTabVersion++;
      });
      return;
    }

    if (_selectedTabIndex == index) {
      return;
    }
    setState(() {
      _selectedTabIndex = index;
    });
  }

  @override
  void initState() {
    super.initState();
    _saveBoostTypes();
  }

  List<Widget> _buildTabScreens() {
    return <Widget>[
      _MainServiceHub(
        key: ValueKey<String>('request-$_requestTabVersion'),
      ),
      const ProviderStatusScreen(showBottomNav: false),
      const OrdersLandingScreen(showBottomNav: false),
      const ProfileScreen(showBottomNav: false),
    ];
  }

  Future<void> _saveBoostTypes() async {
    if (widget.selectedBoostTypes == null || widget.selectedBoostTypes!.isEmpty) {
      return;
    }
    
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update({
        'boostTypes': widget.selectedBoostTypes,
      });
    } catch (_) {
      // Silently fail
    }
  }

  Widget _buildNavIcon(_MainTabVisual tab, bool isSelected) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: tab.color.withValues(alpha: isSelected ? 0.22 : 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: tab.color.withValues(alpha: isSelected ? 0.65 : 0.2),
          width: 1.2,
        ),
      ),
      child: Icon(
        isSelected ? tab.activeIcon : tab.icon,
        color: isSelected ? tab.color : const Color(0xFF8A8A9A),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: IndexedStack(
        index: _selectedTabIndex,
        children: _buildTabScreens(),
      ),
      bottomNavigationBar: MediaQuery.removePadding(
        context: context,
        removeBottom: true,
        child: BottomNavigationBar(
          type: BottomNavigationBarType.fixed,
          selectedItemColor: const Color(0xFF5500FF),
          unselectedItemColor: const Color(0xFFAAAAAA),
          backgroundColor: Colors.white,
          currentIndex: _selectedTabIndex,
          onTap: _onMainTabSelected,
          items: List<BottomNavigationBarItem>.generate(_tabVisuals.length, (index) {
            final tab = _tabVisuals[index];
            return BottomNavigationBarItem(
              icon: _buildNavIcon(tab, false),
              activeIcon: _buildNavIcon(tab, true),
              label: tab.label,
            );
          }),
        ),
      ),
    );
  }
}

class _MainTabVisual {
  const _MainTabVisual({
    required this.label,
    required this.icon,
    required this.activeIcon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final IconData activeIcon;
  final Color color;
}

class _MainServiceHub extends StatelessWidget {
  const _MainServiceHub({super.key});

  void _openNeedBoost(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const CustomerScreen(
          initialServiceType: serviceTypeBoost,
          showBottomNav: true,
        ),
      ),
    );
  }

  void _openNeedTow(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const CustomerScreen(
          initialServiceType: serviceTypeTow,
          showBottomNav: true,
        ),
      ),
    );
  }

  void _openOfferService(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const ProviderStatusScreen(showBottomNav: true),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BoosterPageBackground(
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'How would you like to use Booster?',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'Choose a service to continue to the detailed flow.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF8A8A9A),
                    ),
              ),
              const SizedBox(height: 18),
              _ServiceChoiceCard(
                title: 'Get a Battery Boost',
                subtitle:
                    'Request roadside jump-start help and get matched with nearby providers.',
                icon: Icons.bolt,
                accent: const Color(0xFF5500FF),
                cta: 'Request a Boost',
                onTap: () => _openNeedBoost(context),
              ),
              const SizedBox(height: 12),
              _ServiceChoiceCard(
                title: 'Get a Tow',
                subtitle:
                    'Request towing assistance and share your pickup details for dispatch.',
                icon: Icons.local_shipping,
                accent: const Color(0xFF0EA5E9),
                cta: 'Request a Tow',
                onTap: () => _openNeedTow(context),
              ),
              const SizedBox(height: 12),
              _ServiceChoiceCard(
                title: 'Provide Boost or Tow Services',
                subtitle:
                    'Set up your provider profile, go available, and receive nearby job requests.',
                icon: Icons.support_agent,
                accent: const Color(0xFF16A34A),
                cta: 'Set Up Provider Profile',
                onTap: () => _openOfferService(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ServiceChoiceCard extends StatelessWidget {
  const _ServiceChoiceCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accent,
    required this.cta,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color accent;
  final String cta;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return BoosterSurfaceCard(
      padding: const EdgeInsets.all(16),
      borderColor: accent.withValues(alpha: 0.25),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF8A8A9A),
                ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: onTap,
              style: ElevatedButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.arrow_forward),
              label: Text(cta),
            ),
          ),
        ],
      ),
    );
  }
}
