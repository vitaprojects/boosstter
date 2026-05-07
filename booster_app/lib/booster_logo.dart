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
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final subtitleColor = onSurface.withValues(alpha: 0.7);

    final mark = SizedBox(
      width: size,
      height: size,
      child: Image.asset('assets/branding/booster_mark.png'),
    );

    if (!showWordmark) {
      return mark;
    }

    final wordmark = Column(
      crossAxisAlignment:
          compact ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Booster',
          style: TextStyle(
            fontSize: compact ? size * 0.24 : size * 0.28,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
            color: onSurface,
          ),
        ),
        Text(
          'Fast roadside energy',
          style: TextStyle(
            fontSize: compact ? size * 0.11 : size * 0.13,
            fontWeight: FontWeight.w500,
            color: subtitleColor,
          ),
        ),
      ],
    );

    if (compact) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          mark,
          SizedBox(height: size * 0.16),
          wordmark,
        ],
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        mark,
        SizedBox(width: size * 0.18),
        wordmark,
      ],
    );
  }
}
