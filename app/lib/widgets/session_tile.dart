import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/material.dart';

import '../services/chat_session.dart';
import '../theme/app_theme.dart';
import 'presence_avatar.dart';

/// An open conversation: who, live or ended, typing, unread bubbles.
class SessionTile extends StatelessWidget {
  const SessionTile({
    super.key,
    required this.session,
    this.name,
    this.selected = false,
    required this.onTap,
    required this.onClose,
  });

  final ChatSession session;

  /// Saved contact name; an unknown peer is shown by full ID.
  final String? name;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final live = !session.peerLeft;
    final typing = live && session.remoteDraft.isNotEmpty;
    final unread = session.unread;
    return ListTile(
      key: ValueKey('session-${session.peer}'),
      selected: selected,
      selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.45),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      contentPadding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
      leading: PresenceAvatar(
        id: session.peer,
        name: name,
        online: live,
        radius: 20,
        keyPrefix: 'session-presence',
      ),
      title: Text(
        name ?? DismessageId.format(session.peer),
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: unread > 0 ? FontWeight.w800 : null,
        ),
      ),
      subtitle: Text(
        typing
            ? 'écrit…'
            : live
            ? 'En direct'
            : 'Déconnecté',
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: typing ? scheme.primary : scheme.onSurfaceVariant,
          fontStyle: typing ? FontStyle.italic : null,
        ),
      ),
      onTap: onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (unread > 0)
            UnreadBadge(
              key: ValueKey('session-unread-${session.peer}'),
              count: unread,
            ),
          IconButton(
            key: ValueKey('session-close-${session.peer}'),
            tooltip: 'Fermer la conversation',
            icon: const Icon(Icons.close_rounded, size: 20),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}
