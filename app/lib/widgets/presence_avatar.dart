import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'contact_avatar.dart';

/// [ContactAvatar] with a green (online) or grey (offline) dot, no dot while
/// the presence is unknown, and the number of unread bubbles.
class PresenceAvatar extends StatelessWidget {
  const PresenceAvatar({
    super.key,
    required this.id,
    this.name,
    required this.online,
    this.radius = 22,
    this.unread = 0,
    this.selected = false,
    this.keyPrefix = 'presence',
  });

  final String id;
  final String? name;
  final bool? online;
  final double radius;
  final int unread;

  /// Ring in the brand color: the conversation on screen.
  final bool selected;

  /// Prefix of the dot's key (`<prefix>-<id>-on` / `-off`), for tests.
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final online = this.online;
    final dot = (radius * 0.64).clamp(10.0, 14.0);
    Widget avatar = ContactAvatar(id: id, name: name, radius: radius);
    if (selected) {
      avatar = Container(
        padding: const EdgeInsets.all(2.5),
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: AppTheme.brandGradient,
        ),
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.surface,
          ),
          child: avatar,
        ),
      );
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        avatar,
        if (online != null)
          Positioned(
            right: -1,
            bottom: -1,
            child: Semantics(
              label: online ? 'En ligne' : 'Hors ligne',
              child: Container(
                key: ValueKey('$keyPrefix-$id-${online ? 'on' : 'off'}'),
                width: dot,
                height: dot,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: online ? AppTheme.online : scheme.outline,
                  border: Border.all(color: scheme.surface, width: 2.5),
                ),
              ),
            ),
          ),
        if (unread > 0)
          Positioned(
            right: -4,
            top: -4,
            child: UnreadBadge(key: ValueKey('unread-$id'), count: unread),
          ),
      ],
    );
  }
}

/// Number of unread bubbles ("99+" beyond).
class UnreadBadge extends StatelessWidget {
  const UnreadBadge({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) =>
      Badge(label: Text(count > 99 ? '99+' : '$count'));
}
