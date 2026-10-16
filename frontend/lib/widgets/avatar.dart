import 'package:flutter/material.dart';

/// A creator's avatar. Accounts have no profile picture, so it is the first
/// letter of the name on a colour picked from the creator's id: stable
/// across pages, distinct between creators.
class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.name,
    required this.seed,
    this.size = 36,
  });

  final String name;

  /// Usually the user id.
  final String seed;
  final double size;

  static const _palette = [
    Color(0xFFEF6C00),
    Color(0xFF00897B),
    Color(0xFF5E35B1),
    Color(0xFF3949AB),
    Color(0xFFC2185B),
    Color(0xFF7CB342),
    Color(0xFF0288D1),
    Color(0xFF6D4C41),
  ];

  @override
  Widget build(BuildContext context) {
    final letter = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    final colour = _palette[seed.hashCode.abs() % _palette.length];
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
        child: Text(
          letter,
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.45,
            fontWeight: FontWeight.w500,
            height: 1,
          ),
        ),
      ),
    );
  }
}
