import 'package:flutter/material.dart';

class BoosterPageBackground extends StatelessWidget {
  const BoosterPageBackground({
    required this.child,
    super.key,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF2F2F7),
      child: child,
    );
  }
}

class BoosterSurfaceCard extends StatelessWidget {
  const BoosterSurfaceCard({
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.margin,
    this.borderColor,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: borderColor ?? const Color(0xFFE0E0E8),
        ),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      child: child,
    );
  }
}

class _Blob extends StatelessWidget {
  const _Blob({required this.size, required this.color});

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
            BoxShadow(color: color, blurRadius: 90, spreadRadius: 14),
          ],
        ),
      ),
    );
  }
}