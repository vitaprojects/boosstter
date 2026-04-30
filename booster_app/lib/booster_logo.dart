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
    final wordmarkColor = Colors.white;
    final taglineColor = Colors.grey[300] ?? Colors.white70;

    final mark = ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.28),
      child: SizedBox(
        width: size,
        height: size,
        child: Image.asset(
          'assets/app_icon_source.png',
          fit: BoxFit.cover,
          errorBuilder:
              (_, _, _) => Container(
                color: const Color(0xFF101A33),
                alignment: Alignment.center,
                child: Icon(
                  Icons.flash_on,
                  color: Colors.white,
                  size: size * 0.5,
                ),
              ),
        ),
      ),
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
            color: wordmarkColor,
          ),
        ),
        Text(
          'Fast roadside energy',
          style: TextStyle(
            fontSize: compact ? size * 0.11 : size * 0.13,
            fontWeight: FontWeight.w500,
            color: taglineColor,
          ),
        ),
      ],
    );

    if (compact) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [mark, SizedBox(height: size * 0.16), wordmark],
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [mark, SizedBox(width: size * 0.18), wordmark],
    );
  }
}
