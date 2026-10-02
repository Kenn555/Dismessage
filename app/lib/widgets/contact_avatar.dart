import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Round avatar with a stable color per ID: initial of the contact name,
/// or a generic icon for an unknown peer.
class ContactAvatar extends StatelessWidget {
  const ContactAvatar({
    super.key,
    required this.id,
    this.name,
    this.radius = 22,
  });

  final String id;
  final String? name;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final color = AppTheme.avatarColor(id, Theme.of(context).colorScheme);
    final name = this.name;
    return CircleAvatar(
      radius: radius,
      backgroundColor: color.withValues(alpha: 0.15),
      foregroundColor: color,
      child: name == null || name.isEmpty
          ? Icon(Icons.person_rounded, size: radius)
          : Text(
              name.characters.first.toUpperCase(),
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: radius * 0.8,
              ),
            ),
    );
  }
}
