import 'package:flutter/material.dart';

class BoosterLogo extends StatelessWidget {
  const BoosterLogo({
    super.key,
    this.size = 72,
    this.showWordmark = true,
    this.compact = false,
  });

  final double size;
  final bool showWordmark;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final mark = SizedBox(
      width: size,
      height: size,
      child: Image.asset(
        'assets/branding/booster_mark.png',
        fit: BoxFit.cover,
      ),
    );

    if (!showWordmark) {
      return mark;
    }

    final tagline = Text(
      'GET BOOSTED',
      style: TextStyle(
        fontSize: compact ? size * 0.2 : size * 0.23,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.2,
        color: onSurface.withValues(alpha: 0.9),
      ),
    );

    if (compact) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          mark,
          SizedBox(height: size * 0.12),
          tagline,
        ],
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        mark,
        SizedBox(width: size * 0.18),
        tagline,
      ],
    );
  }
}
