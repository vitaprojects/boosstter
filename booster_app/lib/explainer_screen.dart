import 'package:flutter/material.dart';

class ExplainerScreen extends StatelessWidget {
  const ExplainerScreen({
    required this.onProceed,
    super.key,
  });

  final VoidCallback onProceed;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Container(
          color: const Color(0xFFF3F3F6),
          child: Stack(
            children: [
              Positioned(
                left: -80,
                top: 140,
                child: _SoftBlob(
                  size: 220,
                  color: const Color(0xFF5500FF).withValues(alpha: 0.08),
                ),
              ),
              Positioned(
                right: -40,
                bottom: 180,
                child: _SoftBlob(
                  size: 200,
                  color: const Color(0xFF00B8F0).withValues(alpha: 0.08),
                ),
              ),
              ListView(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
                children: [
                  Text(
                    'Welcome to Booster',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 16),
                  _ExplainerCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Dead battery? Flat tire? Need a tow?',
                          style:
                              Theme.of(context).textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Get help nearby or earn money helping someone on the road.',
                          style:
                              Theme.of(context).textTheme.bodyLarge?.copyWith(
                                    color: const Color(0xFF6F7282),
                                    fontWeight: FontWeight.w500,
                                  ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  _ExplainerCard(
                    borderColor: const Color(0xFFBCECF4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'How It Works',
                          style:
                              Theme.of(context).textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Need a Boost or Tow?',
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Stuck with a dead battery? Car won\'t start? Need a tow fast? Open the app and request help in minutes.',
                          style:
                              Theme.of(context).textTheme.bodyLarge?.copyWith(
                                    color: const Color(0xFF5F6272),
                                  ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'A nearby helper can come give you a jump-start or provide towing assistance if available. You can request help for yourself, a friend, a family member, or anyone stranded on the road.',
                          style:
                              Theme.of(context).textTheme.bodyLarge?.copyWith(
                                    color: const Color(0xFF5F6272),
                                  ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'No long waits. No stressful searching. Just quick local help when you need it most.',
                          style:
                              Theme.of(context).textTheme.bodyLarge?.copyWith(
                                    color: const Color(0xFF5F6272),
                                  ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  _ExplainerCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Here\'s how it works:',
                          style:
                              Theme.of(context).textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                        const SizedBox(height: 14),
                        const _StepRow(index: 1, text: 'Open the app'),
                        const _StepRow(index: 2, text: 'Get a Boost Or Tow service'),
                        const _StepRow(index: 3, text: 'Share your location'),
                        const _StepRow(
                          index: 4,
                          text: 'Get matched with a nearby helper',
                        ),
                        const _StepRow(index: 5, text: 'Track their arrival'),
                        const _StepRow(index: 6, text: 'Get back on the road'),
                        const SizedBox(height: 14),
                        Text(
                          'Simple. Fast. Stress-free.',
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    color: const Color(0xFF0F766E),
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  ElevatedButton.icon(
                    onPressed: onProceed,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF5500FF),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: const Icon(Icons.arrow_forward),
                    label: const Text('Proceed to Main Screen'),
                  ),
                ],
              ),
            ],
          ),
        ),
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

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.index,
    required this.text,
  });

  final int index;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
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
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SoftBlob extends StatelessWidget {
  const _SoftBlob({
    required this.size,
    required this.color,
  });

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
            BoxShadow(
              color: color,
              blurRadius: 80,
              spreadRadius: 10,
            ),
          ],
        ),
      ),
    );
  }
}