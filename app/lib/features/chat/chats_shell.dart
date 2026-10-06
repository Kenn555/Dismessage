import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/material.dart';

import '../../services/chat_session.dart';
import '../../services/connection_service.dart';
import '../../services/contacts_service.dart';
import '../../services/id_privacy.dart';
import '../../theme/app_theme.dart';
import '../../widgets/presence_avatar.dart';
import '../../widgets/session_tile.dart';
import 'chat_screen.dart';

/// Builds the screen of one conversation (tests inject fake hardware).
typedef ChatScreenBuilder =
    Widget Function(ChatSession session, {required bool active});

/// Every open conversation, the active one on screen.
///
/// From [kWideLayoutWidth], a sidebar lists them (name, presence, unread);
/// below, from two conversations, round avatars float on the left,
/// vertically centered. Each conversation stays built: switching keeps what
/// is typed, the scroll position and the reply in progress.
class ChatsShell extends StatefulWidget {
  const ChatsShell({
    super.key,
    required this.connection,
    required this.contacts,
    this.privacy,
    this.buildChat,
  });

  /// Name of this route, to find it in the navigator.
  static const routeName = 'chats';

  final ConnectionService connection;
  final ContactsService contacts;
  final IdPrivacy? privacy;
  final ChatScreenBuilder? buildChat;

  @override
  State<ChatsShell> createState() => _ChatsShellState();
}

class _ChatsShellState extends State<ChatsShell> {
  ConnectionService get _connection => widget.connection;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _connection.addListener(_onConnection);
  }

  @override
  void dispose() {
    _connection.removeListener(_onConnection);
    super.dispose();
  }

  /// No conversation left: back to the home screen.
  void _onConnection() {
    if (_closing || _connection.sessions.isNotEmpty || !mounted) return;
    _closing = true;
    final route = ModalRoute.of(context);
    if (route == null) return;
    if (route.isCurrent) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).removeRoute(route);
    }
  }

  String? _name(ChatSession session) =>
      widget.contacts.byId(session.peer)?.name;

  Widget _chat(ChatSession session, bool active) {
    final build = widget.buildChat;
    if (build != null) return build(session, active: active);
    return ChatScreen(
      session: session,
      connection: _connection,
      contacts: widget.contacts,
      privacy: widget.privacy,
      active: active,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Back home: the conversations stay open.
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _connection.activate(null);
      },
      child: ListenableBuilder(
        listenable: _connection,
        builder: (context, _) {
          final sessions = _connection.sessions;
          if (sessions.isEmpty) return const Scaffold();
          final active = _connection.active ?? sessions.last;
          final chats = IndexedStack(
            index: sessions.indexOf(active).clamp(0, sessions.length - 1),
            children: [
              for (final session in sessions)
                ExcludeFocus(
                  key: ValueKey(session.sid),
                  excluding: session != active,
                  child: TickerMode(
                    enabled: session == active,
                    child: _chat(session, session == active),
                  ),
                ),
            ],
          );
          // Unread counts, presence and typing change without the
          // connection.
          Widget list(Widget Function() build) => ListenableBuilder(
            listenable: Listenable.merge([widget.contacts, ...sessions]),
            builder: (context, _) => build(),
          );
          return LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= kWideLayoutWidth) {
                return Row(
                  children: [
                    SizedBox(
                      width: 280,
                      child: list(
                        () => _Sidebar(
                          sessions: sessions,
                          active: active,
                          name: _name,
                          onOpen: _connection.activate,
                          onClose: _connection.closeSession,
                          onNew: () => Navigator.of(context).maybePop(),
                        ),
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: chats),
                  ],
                );
              }
              return Stack(
                children: [
                  Positioned.fill(child: chats),
                  if (sessions.length >= 2)
                    Positioned(
                      left: 6,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: list(
                          () => _SessionRail(
                            sessions: sessions,
                            active: active,
                            name: _name,
                            onOpen: _connection.activate,
                            onClose: _connection.closeSession,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// Wide screens: the open conversations, by name.
class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.sessions,
    required this.active,
    required this.name,
    required this.onOpen,
    required this.onClose,
    required this.onNew,
  });

  final List<ChatSession> sessions;
  final ChatSession active;
  final String? Function(ChatSession) name;
  final void Function(ChatSession) onOpen;
  final void Function(ChatSession) onClose;
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      key: const Key('chats-sidebar'),
      color: theme.colorScheme.surfaceContainerLow,
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 16, 8),
              child: Text('Conversations', style: theme.textTheme.titleLarge),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: FilledButton.tonalIcon(
                key: const Key('sidebar-new'),
                icon: const Icon(Icons.add_comment_outlined),
                label: const Text('Nouvelle conversation'),
                onPressed: onNew,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
                children: [
                  for (final session in sessions)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: SessionTile(
                        session: session,
                        name: name(session),
                        selected: session == active,
                        onTap: () => onOpen(session),
                        onClose: () => onClose(session),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Narrow screens: a floating column of avatars on the left.
class _SessionRail extends StatelessWidget {
  const _SessionRail({
    required this.sessions,
    required this.active,
    required this.name,
    required this.onOpen,
    required this.onClose,
  });

  final List<ChatSession> sessions;
  final ChatSession active;
  final String? Function(ChatSession) name;
  final void Function(ChatSession) onOpen;
  final void Function(ChatSession) onClose;

  Future<void> _confirmClose(BuildContext context, ChatSession session) async {
    final label = name(session) ?? DismessageId.format(session.peer);
    final close = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('rail-close'),
              leading: const Icon(Icons.logout_rounded),
              title: Text('Fermer la conversation avec $label'),
              onTap: () => Navigator.pop(context, true),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (close ?? false) onClose(session);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: const Key('chats-rail'),
      elevation: 6,
      shape: const StadiumBorder(),
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.92),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final session in sessions)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Tooltip(
                    message: name(session) ?? DismessageId.format(session.peer),
                    child: InkWell(
                      key: ValueKey('rail-${session.peer}'),
                      customBorder: const CircleBorder(),
                      onTap: () => onOpen(session),
                      onLongPress: () => _confirmClose(context, session),
                      child: PresenceAvatar(
                        id: session.peer,
                        name: name(session),
                        online: !session.peerLeft,
                        unread: session.unread,
                        selected: session == active,
                        keyPrefix: 'rail-presence',
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
