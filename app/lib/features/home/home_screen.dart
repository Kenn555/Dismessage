import 'dart:async';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config.dart';
import '../../services/background_mode.dart';
import '../../services/chat_session.dart';
import '../../services/connection_service.dart';
import '../../services/contacts_service.dart';
import '../../services/id_privacy.dart';
import '../../services/link_opener.dart' show OpenLink;
import '../../theme/app_theme.dart';
import '../../widgets/contact_dialog.dart';
import '../../widgets/dismessage_logo.dart';
import '../../widgets/presence_avatar.dart';
import '../../widgets/session_tile.dart';
import '../chat/chats_shell.dart';
import 'about_dialog.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.connection,
    required this.settings,
    required this.contacts,
    this.privacy,
    this.background,
    this.buildChat,
    this.openLink,
  });

  final ConnectionService connection;
  final ServerSettings settings;
  final ContactsService contacts;

  /// Which IDs are shown in full (masked by default).
  final IdPrivacy? privacy;

  /// Android background mode; no settings button when null or unsupported.
  final BackgroundMode? background;

  /// Builds a conversation screen (tests inject fake hardware).
  final ChatScreenBuilder? buildChat;

  /// Opens the GitHub link of "À propos" (tests inject a fake).
  final OpenLink? openLink;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _peerController = TextEditingController();
  late final StreamSubscription<ConnectionEvent> _events;
  String? _peerError;

  /// Whether the conversations route is on the stack.
  bool _shellOpen = false;

  /// Open incoming-request dialogs, by requester ID.
  final Map<String, BuildContext> _incomingDialogs = {};

  ConnectionService get _connection => widget.connection;
  ContactsService get _contacts => widget.contacts;
  late final IdPrivacy _privacy = widget.privacy ?? IdPrivacy();

  /// Contact name when saved, formatted ID otherwise.
  String _label(String id) => _contacts.label(id);

  @override
  void initState() {
    super.initState();
    _events = _connection.events.listen(_onEvent);
    _connection.addListener(_showActive);
    _contacts.addListener(_watchContacts);
    _watchContacts();
  }

  /// One path to the conversations: a new session, a tap on a notification,
  /// an open conversation or a contact already in one all activate it.
  void _showActive() {
    if (_shellOpen || !mounted || _connection.active == null) return;
    _shellOpen = true;
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            settings: const RouteSettings(name: ChatsShell.routeName),
            builder: (_) => ChatsShell(
              connection: _connection,
              contacts: _contacts,
              privacy: _privacy,
              buildChat: widget.buildChat,
            ),
          ),
        )
        .whenComplete(() => _shellOpen = false);
  }

  /// Talks to [peer]: the open conversation if any, a request otherwise.
  void _reach(String peer) {
    final live = _connection.liveSessionWith(peer);
    if (live != null) {
      _connection.activate(live);
    } else {
      _connection.requestChat(peer);
    }
  }

  /// Follows whether each saved contact is online.
  void _watchContacts() =>
      _connection.watchPresence(_contacts.contacts.map((c) => c.id));

  @override
  void dispose() {
    _contacts.removeListener(_watchContacts);
    _connection.removeListener(_showActive);
    _events.cancel();
    _peerController.dispose();
    super.dispose();
  }

  void _onEvent(ConnectionEvent event) {
    if (!mounted) return;
    switch (event) {
      case IncomingRequestEvent(:final from):
        _showIncomingRequest(from);
      case SessionStartedEvent():
        // Already shown: the new session is the active one.
        break;
      case PeerOfflineEvent(:final peer):
        _snack('${_label(peer)} est hors ligne.');
      case RequestRejectedEvent(:final peer):
        _snack('${_label(peer)} a refusé la conversation.');
      case RequestTimedOutEvent(:final peer):
        _snack("${_label(peer)} n'a pas répondu.");
      case RequestCancelledEvent(:final from):
        final dialog = _incomingDialogs.remove(from);
        if (dialog != null && dialog.mounted) {
          Navigator.of(dialog).pop();
          _snack('${_label(from)} a annulé sa demande.');
        }
      case IncomingRequestAnsweredEvent(:final from):
        // Answered from the notification: the dialog has nothing left to do.
        final dialog = _incomingDialogs.remove(from);
        if (dialog != null && dialog.mounted) Navigator.of(dialog).pop();
      case EncryptionFailedEvent(:final peer):
        _snack(
          'Chiffrement impossible avec ${_label(peer)} : '
          'conversation fermée, rien n’a été envoyé.',
        );
      case ServerErrorEvent(:final message):
        _snack(message);
    }
  }

  void _snack(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _showIncomingRequest(String from) async {
    final answer = await showDialog<_RequestAnswer>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        _incomingDialogs[from] = context;
        return AlertDialog(
          title: const Text('Demande de conversation'),
          content: Text(
            _contacts.byId(from) == null
                ? '${DismessageId.format(from)} veut discuter avec vous.'
                : '${_label(from)} (${_privacy.contact(from)}) '
                      'veut discuter avec vous.',
          ),
          actions: [
            TextButton(
              key: const Key('request-block'),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: () => Navigator.pop(context, _RequestAnswer.block),
              child: const Text('Bloquer'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, _RequestAnswer.reject),
              child: const Text('Refuser'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, _RequestAnswer.accept),
              child: const Text('Accepter'),
            ),
          ],
        );
      },
    );
    _incomingDialogs.remove(from);
    // null: the requester withdrew, nothing to answer.
    switch (answer) {
      case _RequestAnswer.accept:
        _connection.accept(from);
      case _RequestAnswer.reject:
        _connection.reject(from);
      case _RequestAnswer.block:
        _connection.reject(from);
        await _block(from);
      case null:
        break;
    }
  }

  void _connect() {
    final peer = DismessageId.parse(_peerController.text);
    if (peer == null) {
      setState(() => _peerError = 'ID invalide (9 chiffres)');
      return;
    }
    if (peer == _connection.myId) {
      setState(() => _peerError = "C'est votre propre ID");
      return;
    }
    setState(() => _peerError = null);
    _reach(peer);
  }

  Future<void> _addContact() async {
    final draft = await showContactDialog(context);
    if (draft == null) return;
    if (draft.id == _connection.myId) {
      _snack("C'est votre propre ID");
      return;
    }
    await _contacts.save(draft.id, draft.name);
  }

  Future<void> _renameContact(Contact contact) async {
    final draft = await showContactDialog(
      context,
      id: contact.id,
      name: contact.name,
    );
    if (draft != null) await _contacts.save(draft.id, draft.name);
  }

  Future<void> _removeContact(Contact contact) async {
    await _contacts.remove(contact.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${contact.name} supprimé des contacts.'),
        action: SnackBarAction(
          label: 'Annuler',
          onPressed: () => _contacts.save(contact.id, contact.name),
        ),
      ),
    );
  }

  Future<void> _regenerate() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Générer un nouvel ID ?'),
        content: const Text(
          "L'ancien ID ne permettra plus de vous joindre. Cette action est définitive.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Générer'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await _connection.regenerateId();
  }

  /// Background mode (Android), who can ask for a conversation, blocked IDs.
  Future<void> _showSettings() async {
    final background = widget.background;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([?background, _contacts]),
          builder: (context, _) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (background != null && background.supported)
                  SwitchListTile(
                    key: const Key('background-switch'),
                    secondary: const Icon(Icons.notifications_active_outlined),
                    title: const Text('Rester joignable en arrière-plan'),
                    subtitle: const Text(
                      'Démarre avec le téléphone et garde Dismessage connecté, '
                      'même fermé, pour être prévenu des messages et des '
                      'demandes. Une notification discrète l’indique.',
                    ),
                    value: background.enabled,
                    onChanged: background.setEnabled,
                  ),
                SwitchListTile(
                  key: const Key('contacts-only-switch'),
                  secondary: const Icon(Icons.shield_outlined),
                  title: const Text('Seuls mes contacts peuvent me joindre'),
                  subtitle: const Text(
                    'Les demandes des autres sont ignorées, sans notification. '
                    'Ils ne savent pas que vous les avez écartés.',
                  ),
                  value: _contacts.contactsOnly,
                  onChanged: _contacts.setContactsOnly,
                ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                    'IDs bloqués',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                if (_contacts.blocked.isEmpty)
                  const ListTile(
                    key: Key('no-blocked'),
                    leading: Icon(Icons.block_rounded),
                    title: Text('Aucun ID bloqué'),
                    subtitle: Text(
                      'Bloquez quelqu’un depuis sa demande, un contact ou '
                      'une conversation : ses demandes seront ignorées.',
                    ),
                  ),
                for (final id in _contacts.blocked)
                  ListTile(
                    leading: const Icon(Icons.block_rounded),
                    title: Text(_label(id)),
                    subtitle: _contacts.byId(id) == null
                        ? null
                        : Text(_privacy.contact(id)),
                    trailing: TextButton(
                      key: ValueKey('unblock-$id'),
                      onPressed: () => _contacts.unblock(id),
                      child: const Text('Débloquer'),
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Blocks [id]: its requests are ignored from now on (undo offered).
  Future<void> _block(String id) async {
    await _contacts.block(id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${_label(id)} est bloqué.'),
        action: SnackBarAction(
          label: 'Annuler',
          onPressed: () => _contacts.unblock(id),
        ),
      ),
    );
  }

  Future<void> _toggleBlock(Contact contact) => _contacts.isBlocked(contact.id)
      ? _contacts.unblock(contact.id)
      : _block(contact.id);

  Future<void> _editServer() async {
    final uri = await showDialog<Uri>(
      context: context,
      builder: (_) => _ServerDialog(initial: _connection.serverUri),
    );
    if (uri == null) return;
    await widget.settings.save(uri);
    await _connection.setServerUri(uri);
  }

  void _copyId(String formatted) {
    Clipboard.setData(ClipboardData(text: formatted));
    _snack('ID copié');
  }

  /// Settings (Android), server and about: icons, or a "⋮" menu on a small
  /// phone, where three icons do not fit beside the title.
  List<Widget> _headerButtons(BuildContext context) {
    final buttons = [
      (
        key: const Key('settings'),
        label: 'Réglages',
        icon: Icons.settings_outlined,
        action: _showSettings,
      ),
      (
        key: const Key('server-settings'),
        label: 'Serveur',
        icon: Icons.tune_rounded,
        action: _editServer,
      ),
      (
        key: const Key('about'),
        label: 'À propos',
        icon: Icons.info_outline_rounded,
        action: () =>
            AboutDismessageDialog.show(context, openLink: widget.openLink),
      ),
    ];
    if (MediaQuery.sizeOf(context).width >= kCompactHeaderWidth) {
      return [
        for (final b in buttons)
          IconButton(
            key: b.key,
            tooltip: b.label,
            icon: Icon(b.icon),
            onPressed: b.action,
          ),
      ];
    }
    return [
      PopupMenuButton<VoidCallback>(
        key: const Key('header-menu'),
        tooltip: 'Plus',
        icon: const Icon(Icons.more_vert_rounded),
        onSelected: (action) => action(),
        itemBuilder: (_) => [
          for (final b in buttons)
            PopupMenuItem(
              key: b.key,
              value: b.action,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(b.icon),
                title: Text(b.label),
              ),
            ),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DismessageLogo(size: 30),
            SizedBox(width: 12),
            // Shortened rather than overflowing on a very small screen.
            Flexible(
              child: Text(
                'Dismessage',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                ),
              ),
            ),
          ],
        ),
        actions: [
          ListenableBuilder(
            listenable: _connection,
            builder: (context, _) => _StatusChip(status: _connection.status),
          ),
          const SizedBox(width: 4),
          ..._headerButtons(context),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= kWideLayoutWidth;
            final banner = ListenableBuilder(
              listenable: _connection,
              builder: (context, _) =>
                  _ConnectionBanner(connection: _connection),
            );
            if (!wide) {
              return Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        banner,
                        ..._conversationColumn(),
                        const SizedBox(height: 32),
                        ..._contactsColumn(),
                      ],
                    ),
                  ),
                ),
              );
            }
            // Each column scrolls on its own: a long contact list does not
            // push my ID out of sight.
            Widget column(Key key, List<Widget> children) => Expanded(
              child: SingleChildScrollView(
                key: key,
                padding: const EdgeInsets.fromLTRB(10, 16, 10, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            );
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1040),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                        child: banner,
                      ),
                      Expanded(
                        child: Row(
                          key: const Key('home-two-columns'),
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            column(
                              const Key('home-left-column'),
                              _conversationColumn(),
                            ),
                            const SizedBox(width: 12),
                            column(
                              const Key('home-right-column'),
                              _contactsColumn(),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// Open conversations (if any), my ID, then the form to reach someone.
  List<Widget> _conversationColumn() => [
    _OpenSessions(
      connection: _connection,
      contacts: _contacts,
      onOpen: _connection.activate,
    ),
    ListenableBuilder(
      listenable: Listenable.merge([_connection, _privacy]),
      builder: (context, _) => _IdCard(
        id: _connection.myId,
        privacy: _privacy,
        onCopy: _copyId,
        // The relay gives the new ID: only while connected.
        onRegenerate: _connection.status == ServerStatus.online
            ? _regenerate
            : null,
      ),
    ),
    const SizedBox(height: 32),
    const _SectionTitle(
      title: 'Nouvelle conversation',
      subtitle: "Entrez l'ID de la personne à joindre.",
    ),
    const SizedBox(height: 12),
    Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('peer-id'),
              controller: _peerController,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9 \-]')),
              ],
              style: const TextStyle(
                fontFeatures: [FontFeature.tabularFigures()],
                letterSpacing: 1,
              ),
              decoration: InputDecoration(
                labelText: "ID de l'interlocuteur",
                hintText: '123 456 789',
                prefixIcon: const Icon(Icons.tag_rounded),
                errorText: _peerError,
              ),
              onSubmitted: (_) => _connect(),
            ),
            const SizedBox(height: 12),
            ListenableBuilder(
              listenable: _connection,
              builder: (context, _) {
                final pending = _connection.pendingRequest;
                return AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  // Full width (the default centers the child).
                  layoutBuilder: (current, previous) => Stack(
                    children: [
                      ...previous,
                      if (current != null)
                        SizedBox(width: double.infinity, child: current),
                    ],
                  ),
                  child: pending != null
                      ? _PendingRequestCard(
                          key: ValueKey(pending),
                          peerLabel: _label(pending),
                          onCancel: _connection.cancelRequest,
                        )
                      : FilledButton.icon(
                          key: const Key('connect'),
                          icon: const Icon(Icons.arrow_forward_rounded),
                          label: const Text('Se connecter'),
                          onPressed: _connection.status == ServerStatus.online
                              ? _connect
                              : null,
                        ),
                );
              },
            ),
          ],
        ),
      ),
    ),
  ];

  /// Saved contacts, with their presence.
  List<Widget> _contactsColumn() => [
    Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        const Expanded(
          child: _SectionTitle(
            title: 'Contacts',
            subtitle: 'Sur cet appareil uniquement.',
          ),
        ),
        ListenableBuilder(
          listenable: _privacy,
          builder: (context, _) => IconButton(
            key: const Key('reveal-contact-ids'),
            tooltip: _privacy.showContacts
                ? 'Masquer les ID'
                : 'Afficher les ID',
            icon: Icon(
              _privacy.showContacts
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
            ),
            onPressed: _privacy.toggleContacts,
          ),
        ),
        TextButton.icon(
          key: const Key('add-contact'),
          icon: const Icon(Icons.person_add_alt_1_rounded),
          label: const Text('Ajouter'),
          onPressed: _addContact,
        ),
      ],
    ),
    const SizedBox(height: 12),
    ListenableBuilder(
      listenable: Listenable.merge([_contacts, _connection, _privacy]),
      builder: (context, _) => _ContactList(
        contacts: _contacts.contacts,
        displayId: _privacy.contact,
        isOnline: _connection.isOnline,
        canConnect: (id) =>
            _connection.liveSessionWith(id) != null ||
            (_connection.status == ServerStatus.online &&
                _connection.pendingRequest == null),
        onConnect: (c) => _reach(c.id),
        onRename: _renameContact,
        onRemove: _removeContact,
        isBlocked: _contacts.isBlocked,
        onToggleBlock: _toggleBlock,
      ),
    ),
  ];
}

/// The conversations still open, to go back to them.
class _OpenSessions extends StatelessWidget {
  const _OpenSessions({
    required this.connection,
    required this.contacts,
    required this.onOpen,
  });

  final ConnectionService connection;
  final ContactsService contacts;
  final void Function(ChatSession) onOpen;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: connection,
      builder: (context, _) {
        final sessions = connection.sessions;
        if (sessions.isEmpty) return const SizedBox.shrink();
        return ListenableBuilder(
          listenable: Listenable.merge([contacts, ...sessions]),
          builder: (context, _) => Column(
            key: const Key('open-sessions'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _SectionTitle(
                title: 'Conversations en cours',
                subtitle: 'Touchez pour reprendre.',
              ),
              const SizedBox(height: 12),
              Card(
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    children: [
                      for (final session in sessions)
                        SessionTile(
                          session: session,
                          name: contacts.byId(session.peer)?.name,
                          onTap: () => onOpen(session),
                          onClose: () => connection.closeSession(session),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        );
      },
    );
  }
}

/// Hero card: my ID, on the brand gradient.
class _IdCard extends StatelessWidget {
  const _IdCard({
    required this.id,
    required this.privacy,
    required this.onCopy,
    required this.onRegenerate,
  });

  final String? id;
  final IdPrivacy privacy;
  final void Function(String formatted) onCopy;
  final VoidCallback? onRegenerate;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final id = this.id;
    // Copy always gives the full ID; the display may be masked.
    final formatted = id == null ? '— — —' : DismessageId.format(id);
    final shown = id == null ? formatted : privacy.mine(id);
    const onBrand = Colors.white;
    final muted = Colors.white.withValues(alpha: 0.78);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: AppTheme.brandGradient,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: AppTheme.brand.withValues(alpha: 0.25),
            blurRadius: 24,
            spreadRadius: -4,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'VOTRE ID',
              style: text.labelMedium?.copyWith(
                color: muted,
                letterSpacing: 1.6,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Flexible(
                  child: SelectableText(
                    shown,
                    key: const Key('my-id'),
                    style: text.displaySmall?.copyWith(
                      color: onBrand,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      letterSpacing: 2,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  key: const Key('reveal-my-id'),
                  tooltip: privacy.showMine ? 'Masquer l’ID' : 'Afficher l’ID',
                  color: onBrand,
                  icon: Icon(
                    privacy.showMine
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                  onPressed: id == null ? null : privacy.toggleMine,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              id == null
                  // First launch: the relay gives the ID.
                  ? 'Votre ID vous sera attribué dès la connexion au serveur.'
                  : 'Partagez-le pour que l’on puisse vous joindre.',
              key: const Key('my-id-hint'),
              style: text.bodyMedium?.copyWith(color: muted),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: onBrand,
                    foregroundColor: AppTheme.brand,
                    minimumSize: const Size(0, 42),
                  ),
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('Copier'),
                  onPressed: id == null ? null : () => onCopy(formatted),
                ),
                TextButton.icon(
                  key: const Key('regenerate-id'),
                  style: TextButton.styleFrom(
                    foregroundColor: onBrand,
                    minimumSize: const Size(0, 42),
                  ),
                  icon: const Icon(Icons.autorenew_rounded, size: 18),
                  label: const Text('Générer un nouvel ID'),
                  onPressed: onRegenerate,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleLarge),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Saved contacts: tap to start a conversation.
class _ContactList extends StatelessWidget {
  const _ContactList({
    required this.contacts,
    required this.displayId,
    required this.isOnline,
    required this.canConnect,
    required this.onConnect,
    required this.onRename,
    required this.onRemove,
    required this.isBlocked,
    required this.onToggleBlock,
  });

  final List<Contact> contacts;
  final bool Function(String id) isBlocked;
  final void Function(Contact) onToggleBlock;

  /// A contact's ID as displayed (masked unless revealed).
  final String Function(String id) displayId;

  /// Presence of a contact; null while unknown.
  final bool? Function(String id) isOnline;

  /// Whether tapping the contact does something (open conversation, or a
  /// request can be sent).
  final bool Function(String id) canConnect;
  final void Function(Contact) onConnect;
  final void Function(Contact) onRename;
  final void Function(Contact) onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (contacts.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: scheme.primaryContainer,
                foregroundColor: scheme.onPrimaryContainer,
                child: const Icon(Icons.people_alt_outlined),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  'Aucun contact. Enregistrez quelqu’un pour le retrouver '
                  'ici sans retaper son ID.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (final (index, contact) in contacts.indexed) ...[
            if (index > 0) const Divider(indent: 72),
            ListTile(
              key: ValueKey('contact-${contact.id}'),
              contentPadding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
              leading: PresenceAvatar(
                id: contact.id,
                name: contact.name,
                online: isOnline(contact.id),
              ),
              title: Text(contact.name, style: theme.textTheme.titleMedium),
              subtitle: Text(
                [
                  displayId(contact.id),
                  switch (isOnline(contact.id)) {
                    true => 'En ligne',
                    false => 'Hors ligne',
                    null => null,
                  },
                ].nonNulls.join(' · '),
                key: ValueKey('contact-status-${contact.id}'),
                style: const TextStyle(
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              enabled: canConnect(contact.id),
              onTap: () => onConnect(contact),
              trailing: PopupMenuButton<String>(
                key: ValueKey('contact-menu-${contact.id}'),
                tooltip: 'Options',
                icon: const Icon(Icons.more_vert_rounded),
                onSelected: (action) => switch (action) {
                  'rename' => onRename(contact),
                  'block' => onToggleBlock(contact),
                  _ => onRemove(contact),
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'rename', child: Text('Renommer')),
                  PopupMenuItem(
                    value: 'block',
                    child: Text(
                      isBlocked(contact.id) ? 'Débloquer' : 'Bloquer',
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'remove',
                    child: Text('Supprimer'),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

enum _RequestAnswer { accept, reject, block }

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final ServerStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      ServerStatus.online => ('En ligne', AppTheme.online),
      ServerStatus.connecting => ('Connexion…', const Color(0xFFF59E0B)),
      ServerStatus.offline => ('Hors ligne', const Color(0xFFEF4444)),
    };
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      // Neutral pill: tinted backgrounds clash with the brand surface.
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 6),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _ServerDialog extends StatefulWidget {
  const _ServerDialog({required this.initial});

  final Uri initial;

  @override
  State<_ServerDialog> createState() => _ServerDialogState();
}

class _ServerDialogState extends State<_ServerDialog> {
  late final _controller = TextEditingController(
    text: widget.initial.toString(),
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final uri = ServerAddress.parse(_controller.text);
    if (uri == null) {
      setState(() => _error = 'Adresse invalide');
      return;
    }
    Navigator.pop(context, uri);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Adresse du serveur'),
      content: TextField(
        key: const Key('server-address'),
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.url,
        decoration: InputDecoration(
          hintText: 'https://xxxx-8080.euw.devtunnels.ms',
          helperText: 'Collez le lien du tunnel ou une adresse ws(s)://',
          errorText: _error,
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          key: const Key('server-save'),
          onPressed: _submit,
          child: const Text('Se connecter'),
        ),
      ],
    );
  }
}

/// Shown while waiting for the peer to accept: spinner, countdown, cancel.
class _PendingRequestCard extends StatelessWidget {
  const _PendingRequestCard({
    super.key,
    required this.peerLabel,
    required this.onCancel,
  });

  /// Contact name or formatted ID.
  final String peerLabel;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('pending-request'),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
            child: Row(
              children: [
                const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Demande envoyée à $peerLabel',
                        style: theme.textTheme.titleSmall,
                      ),
                      Text(
                        'En attente de sa réponse…',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                TextButton(
                  key: const Key('cancel-request'),
                  onPressed: onCancel,
                  child: const Text('Annuler'),
                ),
              ],
            ),
          ),
          // Time left before the request expires.
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 1, end: 0),
            duration: const Duration(seconds: kConnectRequestTimeoutSeconds),
            builder: (context, value, _) =>
                LinearProgressIndicator(value: value, minHeight: 3),
          ),
        ],
      ),
    );
  }
}

/// Explains why we are not online yet, so a remote friend can report it.
class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({required this.connection});

  final ConnectionService connection;

  @override
  Widget build(BuildContext context) {
    final status = connection.status;
    final error = connection.lastError;
    if (status == ServerStatus.online ||
        (status == ServerStatus.connecting && connection.failures == 0)) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final connecting = status == ServerStatus.connecting;
    final attempt = connection.failures + (connecting ? 1 : 0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        key: const Key('connection-banner'),
        color: theme.colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: connecting
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : Icon(
                        Icons.cloud_off,
                        color: theme.colorScheme.onErrorContainer,
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DefaultTextStyle.merge(
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        connecting
                            ? 'Connexion en cours… (tentative $attempt)'
                            : 'Serveur injoignable (tentative $attempt)',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                      if (error != null) Text(error),
                      SelectableText(
                        'Serveur : ${connection.serverUri}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (!connecting)
                TextButton(
                  key: const Key('retry-now'),
                  onPressed: connection.retryNow,
                  child: const Text('Réessayer'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
