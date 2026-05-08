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

    final lockup = Image.asset(
      'assets/branding/brand_lockup.png',
      width: compact ? size * 2.0 : size * 3.2,
      fit: BoxFit.contain,
    );

    if (compact) {
      return lockup;
    }

    return lockup;
  }
}
