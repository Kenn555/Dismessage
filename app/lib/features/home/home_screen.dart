import 'dart:async';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config.dart';
import '../../services/connection_service.dart';
import '../../services/contacts_service.dart';
import '../../services/id_privacy.dart';
import '../../theme/app_theme.dart';
import '../../widgets/contact_avatar.dart';
import '../../widgets/contact_dialog.dart';
import '../../widgets/dismessage_logo.dart';
import '../chat/chat_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.connection,
    required this.settings,
    required this.contacts,
    this.privacy,
  });

  final ConnectionService connection;
  final ServerSettings settings;
  final ContactsService contacts;

  /// Which IDs are shown in full (masked by default).
  final IdPrivacy? privacy;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _peerController = TextEditingController();
  late final StreamSubscription<ConnectionEvent> _events;
  String? _peerError;

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
    _contacts.addListener(_watchContacts);
    _watchContacts();
  }

  /// Follows whether each saved contact is online.
  void _watchContacts() =>
      _connection.watchPresence(_contacts.contacts.map((c) => c.id));

  @override
  void dispose() {
    _contacts.removeListener(_watchContacts);
    _events.cancel();
    _peerController.dispose();
    super.dispose();
  }

  void _onEvent(ConnectionEvent event) {
    if (!mounted) return;
    switch (event) {
      case IncomingRequestEvent(:final from):
        _showIncomingRequest(from);
      case SessionStartedEvent(:final session):
        Navigator.of(context).popUntil((route) => route.isFirst);
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ChatScreen(
              session: session,
              connection: _connection,
              contacts: _contacts,
              privacy: _privacy,
            ),
          ),
        );
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
      case ServerErrorEvent(:final message):
        _snack(message);
    }
  }

  void _snack(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _showIncomingRequest(String from) async {
    final accepted = await showDialog<bool>(
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
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Refuser'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Accepter'),
            ),
          ],
        );
      },
    );
    _incomingDialogs.remove(from);
    // null: the requester withdrew, nothing to answer.
    if (accepted == true) _connection.accept(from);
    if (accepted == false) _connection.reject(from);
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
    _connection.requestChat(peer);
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
            Text(
              'Dismessage',
              style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
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
          IconButton(
            key: const Key('server-settings'),
            tooltip: 'Serveur',
            icon: const Icon(Icons.tune_rounded),
            onPressed: _editServer,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListenableBuilder(
                    listenable: _connection,
                    builder: (context, _) =>
                        _ConnectionBanner(connection: _connection),
                  ),
                  ListenableBuilder(
                    listenable: Listenable.merge([_connection, _privacy]),
                    builder: (context, _) => _IdCard(
                      id: _connection.myId,
                      privacy: _privacy,
                      onCopy: _copyId,
                      onRegenerate: _regenerate,
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
                              FilteringTextInputFormatter.allow(
                                RegExp(r'[0-9 \-]'),
                              ),
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
                                      SizedBox(
                                        width: double.infinity,
                                        child: current,
                                      ),
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
                                        icon: const Icon(
                                          Icons.arrow_forward_rounded,
                                        ),
                                        label: const Text('Se connecter'),
                                        onPressed:
                                            _connection.status ==
                                                ServerStatus.online
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
                  const SizedBox(height: 32),
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
                    listenable: Listenable.merge([
                      _contacts,
                      _connection,
                      _privacy,
                    ]),
                    builder: (context, _) => _ContactList(
                      contacts: _contacts.contacts,
                      displayId: _privacy.contact,
                      isOnline: _connection.isOnline,
                      canConnect:
                          _connection.status == ServerStatus.online &&
                          _connection.pendingRequest == null,
                      onConnect: (c) => _connection.requestChat(c.id),
                      onRename: _renameContact,
                      onRemove: _removeContact,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
  final VoidCallback onRegenerate;

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
              'Partagez-le pour que l’on puisse vous joindre.',
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
  });

  final List<Contact> contacts;

  /// A contact's ID as displayed (masked unless revealed).
  final String Function(String id) displayId;

  /// Presence of a contact; null while unknown.
  final bool? Function(String id) isOnline;
  final bool canConnect;
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
              leading: _PresenceAvatar(
                contact: contact,
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
              enabled: canConnect,
              onTap: () => onConnect(contact),
              trailing: PopupMenuButton<String>(
                key: ValueKey('contact-menu-${contact.id}'),
                tooltip: 'Options',
                icon: const Icon(Icons.more_vert_rounded),
                onSelected: (action) =>
                    action == 'rename' ? onRename(contact) : onRemove(contact),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('Renommer')),
                  PopupMenuItem(value: 'remove', child: Text('Supprimer')),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Contact avatar with a green (online) or grey (offline) dot; no dot
/// while the presence is unknown.
class _PresenceAvatar extends StatelessWidget {
  const _PresenceAvatar({required this.contact, required this.online});

  final Contact contact;
  final bool? online;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final online = this.online;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ContactAvatar(id: contact.id, name: contact.name),
        if (online != null)
          Positioned(
            right: -1,
            bottom: -1,
            child: Semantics(
              label: online ? 'En ligne' : 'Hors ligne',
              child: Container(
                key: ValueKey(
                  'presence-${contact.id}-${online ? 'on' : 'off'}',
                ),
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: online ? AppTheme.online : scheme.outline,
                  border: Border.all(color: scheme.surface, width: 2.5),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

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
