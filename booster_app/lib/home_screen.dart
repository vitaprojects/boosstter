import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'login_screen.dart';
import 'customer_screen.dart';
import 'driver_screen.dart';
import 'explainer_screen.dart';
import 'project_flow_checkpoint.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isSelecting = false;
  int _selectedTabIndex = 0;

  static const List<_MainTabVisual> _tabs = <_MainTabVisual>[
    _MainTabVisual(
      label: 'Home',
      icon: Icons.home_outlined,
      activeIcon: Icons.home,
      color: Color(0xFF5500FF),
    ),
    _MainTabVisual(
      label: 'Requests',
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
    _MainTabVisual(
      label: 'Explainer',
      icon: Icons.info_outline,
      activeIcon: Icons.info,
      color: Color(0xFF16A34A),
    ),
  ];

  Future<void> _openNeedBoost() async {
    await _startCustomerService('boost');
  }

  Future<void> _openNeedTow() async {
    await _startCustomerService('tow');
  }

  Future<void> _openNeedMechanic() async {
    await _startCustomerService('mobile_mechanic');
  }

  Future<void> _startCustomerService(String serviceType) async {
    await _setRoleForCurrentUser('customer', serviceType: serviceType);
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CustomerScreen()),
    );
  }

  Future<void> _openRequestsTab() async {
    await _setRoleForCurrentUser('driver');
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const DriverScreen()),
    );
  }

  Future<void> _setRoleForCurrentUser(
    String role, {
    String? serviceType,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() => _isSelecting = true);
    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set(
        {
          'userId': user.uid,
          'email': user.email,
          'role': role,
          'preferredServiceType': serviceType,
          'isAvailable': false,
          'latitude': 0.0,
          'longitude': 0.0,
          'isSubscribed': false,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not sync account mode. Continuing anyway.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSelecting = false);
    }
  }

  Widget _buildNavIcon(_MainTabVisual tab, bool isSelected) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: tab.color.withValues(alpha: isSelected ? 0.2 : 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: tab.color.withValues(alpha: isSelected ? 0.6 : 0.2),
          width: 1.2,
        ),
      ),
      child: Icon(
        isSelected ? tab.activeIcon : tab.icon,
        color: isSelected ? tab.color : const Color(0xFF8A8A9A),
      ),
    );
  }

  void _onMainTabSelected(int index) {
    if (index == 4) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (explainerContext) => ExplainerScreen(
            onProceed: () {
              Navigator.of(explainerContext).pop();
            },
          ),
        ),
      );
      return;
    }

    if (_selectedTabIndex == index) {
      return;
    }
    setState(() => _selectedTabIndex = index);
  }

  Widget _buildBody() {
    switch (_selectedTabIndex) {
      case 0:
        return _MainServiceHub(
          isSelecting: _isSelecting,
          onOpenBoost: _openNeedBoost,
          onOpenTow: _openNeedTow,
          onOpenMechanic: _openNeedMechanic,
          onOpenExplainer: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (explainerContext) => ExplainerScreen(
                  onProceed: () {
                    Navigator.of(explainerContext).pop();
                  },
                ),
              ),
            );
          },
        );
      case 1:
        return _RequestsTab(onOpenDriverMode: _openRequestsTab);
      case 2:
        return const _InfoTab(
          title: 'Orders NEW',
          subtitle: 'Order tracking UI will be restored next. Current build keeps this tab visible to match your prior layout.',
          icon: Icons.radar,
          accent: Color(0xFF00E5FF),
        );
      case 3:
        return _ProfileTab(
          onLogout: () async {
            await FirebaseAuth.instance.signOut();
            if (!mounted) return;
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => const LoginScreen()),
              (route) => false,
            );
          },
        );
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _buildBody(),
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
          items: List<BottomNavigationBarItem>.generate(_tabs.length, (index) {
            final tab = _tabs[index];
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
  const _MainServiceHub({
    required this.isSelecting,
    required this.onOpenBoost,
    required this.onOpenTow,
    required this.onOpenMechanic,
    required this.onOpenExplainer,
  });

  final bool isSelecting;
  final VoidCallback onOpenBoost;
  final VoidCallback onOpenTow;
  final VoidCallback onOpenMechanic;
  final VoidCallback onOpenExplainer;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        color: const Color(0xFFF3F3F6),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onOpenExplainer,
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF0F766E),
                ),
                icon: const Icon(Icons.chevron_left),
                label: const Text('Back to Explainer'),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'How would you like to use Booster?',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'Choose a service to continue to the detailed flow.',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: const Color(0xFF8A8A9A),
                  ),
            ),
            const SizedBox(height: 14),
            _ServiceChoiceCard(
              title: 'Get a Battery Boost',
              subtitle:
                  'Request roadside jump-start help and get matched with nearby providers.',
              icon: Icons.bolt,
              accent: const Color(0xFF5500FF),
              cta: 'Request a Boost',
              onTap: isSelecting ? null : onOpenBoost,
            ),
            const SizedBox(height: 12),
            _ServiceChoiceCard(
              title: 'Get a Tow',
              subtitle:
                  'Request towing assistance and share your pickup details for dispatch.',
              icon: Icons.local_shipping,
              accent: const Color(0xFF0EA5E9),
              cta: 'Request a Tow',
              onTap: isSelecting ? null : onOpenTow,
            ),
            const SizedBox(height: 12),
            _ServiceChoiceCard(
              title: 'Get a Mobile Mechanic',
              subtitle:
                  'Request on-site auto mechanic help and share your vehicle details for dispatch.',
              icon: Icons.handyman,
              accent: const Color(0xFF0F766E),
              cta: 'Request a Mechanic',
              onTap: isSelecting ? null : onOpenMechanic,
            ),
            if (isSelecting) ...[
              const SizedBox(height: 18),
              const Center(child: CircularProgressIndicator()),
            ],
          ],
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
    this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color accent;
  final String cta;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: accent),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
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
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
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

class _RequestsTab extends StatelessWidget {
  const _RequestsTab({required this.onOpenDriverMode});

  final VoidCallback onOpenDriverMode;

  @override
  Widget build(BuildContext context) {
    return _InfoTab(
      title: 'Requests',
      subtitle:
          'Turn on provider mode to receive nearby jobs. This keeps the legacy tab flow visible while we restore full request queue UI.',
      icon: Icons.tune,
      accent: const Color(0xFFEA3DFF),
      actionLabel: 'Open Provider Mode',
      onAction: onOpenDriverMode,
    );
  }
}

class _ProfileTab extends StatelessWidget {
  const _ProfileTab({required this.onLogout});

  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return _InfoTab(
      title: 'Profile',
      subtitle:
          'Account profile restoration is next. You can sign out from here while we rebuild the rest of the previous profile surface.',
      icon: Icons.person,
      accent: const Color(0xFFFFD60A),
      actionLabel: 'Sign out',
      onAction: onLogout,
      secondaryActionLabel: 'Flow Checkpoint',
      onSecondaryAction: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const FlowCheckpointScreen()),
        );
      },
    );
  }
}

class _InfoTab extends StatelessWidget {
  const _InfoTab({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accent,
    this.actionLabel,
    this.onAction,
    this.secondaryActionLabel,
    this.onSecondaryAction,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color accent;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? secondaryActionLabel;
  final VoidCallback? onSecondaryAction;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        color: const Color(0xFFF3F3F6),
        padding: const EdgeInsets.all(18),
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 520),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: accent.withValues(alpha: 0.2)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: accent, size: 28),
                const SizedBox(height: 12),
                Text(
                  title,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: const Color(0xFF6F7282),
                      ),
                ),
                if (actionLabel != null && onAction != null) ...[
                  const SizedBox(height: 18),
                  ElevatedButton(
                    onPressed: onAction,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: Colors.white,
                    ),
                    child: Text(actionLabel!),
                  ),
                ],
                if (secondaryActionLabel != null && onSecondaryAction != null) ...[
                  const SizedBox(height: 10),
                  OutlinedButton(
                    onPressed: onSecondaryAction,
                    child: Text(secondaryActionLabel!),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class FlowCheckpointScreen extends StatelessWidget {
  const FlowCheckpointScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Flow Checkpoint')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _CheckpointCard(
              title: 'Checkpoint Version',
              child: Text(
                ProjectFlowCheckpoint.version,
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            _CheckpointCard(
              title: 'Completed Flows',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: ProjectFlowCheckpoint.completedFlows
                    .map((item) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text('- $item'),
                        ))
                    .toList(),
              ),
            ),
            _CheckpointCard(
              title: 'EV Plug Types',
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: ProjectFlowCheckpoint.evPlugTypes
                    .map((item) => Chip(label: Text(item)))
                    .toList(),
              ),
            ),
            _CheckpointCard(
              title: 'Tow Reasons',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: ProjectFlowCheckpoint.towReasons
                    .map((item) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text('- $item'),
                        ))
                    .toList(),
              ),
            ),
            _CheckpointCard(
              title: 'Pricing Rule',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(ProjectFlowCheckpoint.pricingRule),
                  const SizedBox(height: 8),
                  Text(
                    'Tow service: \$${(ProjectFlowCheckpoint.towServiceCadCents / 100).toStringAsFixed(2)}',
                  ),
                  Text(
                    'First-use yearly subscription: \$${(ProjectFlowCheckpoint.firstUseYearlySubscriptionCadCents / 100).toStringAsFixed(2)}',
                  ),
                  Text(
                    'Canadian tax rate: ${(ProjectFlowCheckpoint.canadianTaxRate * 100).toStringAsFixed(0)}%',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CheckpointCard extends StatelessWidget {
  const _CheckpointCard({
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E4ED)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}
