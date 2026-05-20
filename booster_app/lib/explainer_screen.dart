import 'package:flutter/material.dart';

class ExplainerScreen extends StatelessWidget {
  const ExplainerScreen({required this.onProceed, super.key});

  final VoidCallback onProceed;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FB),
      body: Stack(
        children: [
          const Positioned(
            top: -140,
            left: -100,
            child: _SoftBlob(size: 280, color: Color(0x245500FF)),
          ),
          const Positioned(
            top: 120,
            right: -120,
            child: _SoftBlob(size: 260, color: Color(0x2606B6D4)),
          ),
          const Positioned(
            bottom: -130,
            left: -80,
            child: _SoftBlob(size: 240, color: Color(0x22F59E0B)),
          ),
          SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                    children: [
                      const _HeroCard(),
                      const SizedBox(height: 16),
                      Text(
                        'What can Boosstter do?',
                        style: Theme.of(
                          context,
                        ).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: const Color(0xFF111827),
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Row(
                        children: [
                          Expanded(
                            child: _ServiceMiniCard(
                              icon: Icons.battery_charging_full,
                              title: 'Boost',
                              body: 'Dead battery help nearby.',
                              color: Color(0xFF5500FF),
                            ),
                          ),
                          SizedBox(width: 10),
                          Expanded(
                            child: _ServiceMiniCard(
                              icon: Icons.local_shipping_outlined,
                              title: 'Tow',
                              body: 'Tow dispatch for your vehicle.',
                              color: Color(0xFF0284C7),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      const _ServiceMiniCard(
                        icon: Icons.build_circle_outlined,
                        title: 'Mobile mechanic',
                        body: 'On-site support for common roadside issues.',
                        color: Color(0xFF16A34A),
                        horizontal: true,
                      ),
                      const SizedBox(height: 18),
                      _ExplainerCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'How it works',
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w900),
                            ),
                            const SizedBox(height: 14),
                            const _StepRow(
                              index: 1,
                              title: 'Tell us what you need',
                              text:
                                  'Choose boost, tow, or mobile mechanic service.',
                            ),
                            const _StepRow(
                              index: 2,
                              title: 'Confirm vehicle location',
                              text: 'Use GPS or enter a different address.',
                            ),
                            const _StepRow(
                              index: 3,
                              title: 'Match with a provider',
                              text:
                                  'See nearby providers, ETA, distance, and pricing.',
                            ),
                            const _StepRow(
                              index: 4,
                              title: 'Pay after acceptance',
                              text:
                                  'Messaging and calling unlock after payment confirmation.',
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      const _AudienceCard(),
                      const SizedBox(height: 16),
                      const _TrustStrip(),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    boxShadow: [
                      BoxShadow(
                        color: Color(0x14000000),
                        blurRadius: 18,
                        offset: Offset(0, -4),
                      ),
                    ],
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: onProceed,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF5500FF),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      icon: const Icon(Icons.arrow_forward_rounded),
                      label: const Text(
                        'Get started',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
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
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        gradient: const LinearGradient(
          colors: [Color(0xFF5500FF), Color(0xFF8B5CF6), Color(0xFF06B6D4)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x335500FF),
            blurRadius: 28,
            offset: Offset(0, 14),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned(
            right: -16,
            top: -12,
            child: Icon(
              Icons.electric_bolt,
              color: Colors.white.withValues(alpha: 0.16),
              size: 132,
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Text(
                  'Roadside help made simple',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Need help on the road? Boosstter gets you moving.',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 34,
                  height: 1.03,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.8,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Request a battery boost, tow, or mobile mechanic and connect with nearby providers in minutes.',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 16,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 22),
              const Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _HeroPill(icon: Icons.schedule, text: 'Fast ETA'),
                  _HeroPill(
                    icon: Icons.payments_outlined,
                    text: 'Pay securely',
                  ),
                  _HeroPill(
                    icon: Icons.chat_bubble_outline,
                    text: 'Message provider',
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroPill extends StatelessWidget {
  const _HeroPill({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 16),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _ExplainerCard extends StatelessWidget {
  const _ExplainerCard({
    required this.child,
    this.borderColor = const Color(0xFFE4E5ED),
  });

  final Widget child;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: borderColor),
        boxShadow: const [
          BoxShadow(
            color: Color(0x11000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _ServiceMiniCard extends StatelessWidget {
  const _ServiceMiniCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.color,
    this.horizontal = false,
  });

  final IconData icon;
  final String title;
  final String body;
  final Color color;
  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    final iconBox = Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(icon, color: color),
    );
    final textBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: Color(0xFF111827),
            fontSize: 16,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          body,
          style: const TextStyle(
            color: Color(0xFF64748B),
            height: 1.28,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );

    return _ExplainerCard(
      borderColor: color.withValues(alpha: 0.18),
      child:
          horizontal
              ? Row(
                children: [
                  iconBox,
                  const SizedBox(width: 12),
                  Expanded(child: textBlock),
                ],
              )
              : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [iconBox, const SizedBox(height: 12), textBlock],
              ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.index,
    required this.title,
    required this.text,
  });

  final int index;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [Color(0xFF5500FF), Color(0xFF0EA5E9)],
              ),
            ),
            child: Text(
              '$index',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  text,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF64748B),
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AudienceCard extends StatelessWidget {
  const _AudienceCard();

  @override
  Widget build(BuildContext context) {
    return _ExplainerCard(
      borderColor: const Color(0xFFEDE9FE),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'For customers and providers',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 12),
          const _AudienceRow(
            icon: Icons.person_pin_circle_outlined,
            title: 'Need help?',
            body:
                'Choose your service, confirm vehicle location, and track progress.',
            color: Color(0xFF5500FF),
          ),
          SizedBox(height: 10),
          const _AudienceRow(
            icon: Icons.handyman_outlined,
            title: 'Provide help?',
            body:
                'Go available, set pricing, accept jobs, message customers, and get reviewed.',
            color: Color(0xFF0EA5E9),
          ),
        ],
      ),
    );
  }
}

class _AudienceRow extends StatelessWidget {
  const _AudienceRow({
    required this.icon,
    required this.title,
    required this.body,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String body;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: color),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF111827),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                body,
                style: const TextStyle(
                  color: Color(0xFF64748B),
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TrustStrip extends StatelessWidget {
  const _TrustStrip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(22),
      ),
      child: const Row(
        children: [
          Icon(Icons.verified_user_outlined, color: Color(0xFF22D3EE)),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Secure payment, clear pricing, reviews after service, and support at each step.',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SoftBlob extends StatelessWidget {
  const _SoftBlob({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: [
            BoxShadow(color: color, blurRadius: 80, spreadRadius: 10),
          ],
        ),
      ),
    );
  }
}
