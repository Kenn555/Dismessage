import 'dart:async';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config.dart';
import '../../services/connection_service.dart';
import '../../services/contacts_service.dart';
import '../../widgets/contact_dialog.dart';
import '../chat/chat_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.connection,
    required this.settings,
    required this.contacts,
  });

  final ConnectionService connection;
  final ServerSettings settings;
  final ContactsService contacts;

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

  /// Contact name when saved, formatted ID otherwise.
  String _label(String id) => _contacts.label(id);

  @override
  void initState() {
    super.initState();
    _events = _connection.events.listen(_onEvent);
  }

  @override
  void dispose() {
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
                : '${_label(from)} (${DismessageId.format(from)}) '
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dismessage'),
        actions: [
          ListenableBuilder(
            listenable: _connection,
            builder: (context, _) => _StatusChip(status: _connection.status),
          ),
          IconButton(
            key: const Key('server-settings'),
            tooltip: 'Serveur',
            icon: const Icon(Icons.dns_outlined),
            onPressed: _editServer,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListenableBuilder(
                  listenable: _connection,
                  builder: (context, _) =>
                      _ConnectionBanner(connection: _connection),
                ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: ListenableBuilder(
                      listenable: _connection,
                      builder: (context, _) {
                        final id = _connection.myId;
                        final formatted = id == null
                            ? '— — —'
                            : DismessageId.format(id);
                        return Column(
                          children: [
                            Text(
                              'Votre ID',
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            SelectableText(
                              formatted,
                              key: const Key('my-id'),
                              style: theme.textTheme.displaySmall?.copyWith(
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                                letterSpacing: 2,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              alignment: WrapAlignment.center,
                              children: [
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.copy),
                                  label: const Text('Copier'),
                                  onPressed: id == null
                                      ? null
                                      : () {
                                          Clipboard.setData(
                                            ClipboardData(text: formatted),
                                          );
                                          _snack('ID copié');
                                        },
                                ),
                                TextButton.icon(
                                  key: const Key('regenerate-id'),
                                  icon: const Icon(Icons.autorenew),
                                  label: const Text('Générer un nouvel ID'),
                                  onPressed: _regenerate,
                                ),
                              ],
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                Text("Joindre quelqu'un", style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('peer-id'),
                  controller: _peerController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9 \-]')),
                  ],
                  decoration: InputDecoration(
                    labelText: "ID de l'interlocuteur",
                    hintText: '123 456 789',
                    errorText: _peerError,
                    border: const OutlineInputBorder(),
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
                      child: pending != null
                          ? _PendingRequestCard(
                              key: ValueKey(pending),
                              peerLabel: _label(pending),
                              onCancel: _connection.cancelRequest,
                            )
                          : FilledButton.icon(
                              key: const Key('connect'),
                              icon: const Icon(Icons.chat_bubble_outline),
                              label: const Text('Se connecter'),
                              onPressed:
                                  _connection.status == ServerStatus.online
                                  ? _connect
                                  : null,
                            ),
                    );
                  },
                ),
                const SizedBox(height: 32),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Contacts',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    TextButton.icon(
                      key: const Key('add-contact'),
                      icon: const Icon(Icons.person_add_alt),
                      label: const Text('Ajouter'),
                      onPressed: _addContact,
                    ),
                  ],
                ),
                ListenableBuilder(
                  listenable: Listenable.merge([_contacts, _connection]),
                  builder: (context, _) => _ContactList(
                    contacts: _contacts.contacts,
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
    );
  }
}

/// Saved contacts: tap to start a conversation.
class _ContactList extends StatelessWidget {
  const _ContactList({
    required this.contacts,
    required this.canConnect,
    required this.onConnect,
    required this.onRename,
    required this.onRemove,
  });

  final List<Contact> contacts;
  final bool canConnect;
  final void Function(Contact) onConnect;
  final void Function(Contact) onRename;
  final void Function(Contact) onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (contacts.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          'Aucun contact. Enregistrez quelqu’un pour le retrouver ici '
          'sans retaper son ID.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (final contact in contacts)
            ListTile(
              key: ValueKey('contact-${contact.id}'),
              leading: CircleAvatar(
                child: Text(contact.name.characters.first.toUpperCase()),
              ),
              title: Text(contact.name),
              subtitle: Text(DismessageId.format(contact.id)),
              enabled: canConnect,
              onTap: () => onConnect(contact),
              trailing: PopupMenuButton<String>(
                key: ValueKey('contact-menu-${contact.id}'),
                tooltip: 'Options',
                onSelected: (action) =>
                    action == 'rename' ? onRename(contact) : onRemove(contact),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('Renommer')),
                  PopupMenuItem(value: 'remove', child: Text('Supprimer')),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final ServerStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      ServerStatus.online => ('En ligne', Colors.green),
      ServerStatus.connecting => ('Connexion…', Colors.orange),
      ServerStatus.offline => ('Hors ligne', Colors.red),
    };
    return Chip(
      avatar: Icon(Icons.circle, size: 12, color: color),
      label: Text(label),
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
