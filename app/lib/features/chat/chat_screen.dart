import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/material.dart';

import '../../services/chat_session.dart';
import '../../services/connection_service.dart';
import '../../services/contacts_service.dart';
import '../../widgets/contact_dialog.dart';
import '../../widgets/live_draft_bubble.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.session,
    required this.connection,
    required this.contacts,
  });

  final ChatSession session;
  final ConnectionService connection;
  final ContactsService contacts;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();

  ChatSession get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _session.addListener(_scrollToBottom);
  }

  @override
  void dispose() {
    _session.removeListener(_scrollToBottom);
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  void _send() {
    if (_session.sendMessage()) _input.clear();
    _focus.requestFocus();
  }

  /// Saves (or renames) the peer; only the name and ID are kept.
  Future<void> _saveContact() async {
    final existing = widget.contacts.byId(_session.peer);
    final draft = await showContactDialog(
      context,
      id: _session.peer,
      name: existing?.name,
    );
    if (draft == null) return;
    await widget.contacts.save(draft.id, draft.name);
    if (!mounted || existing != null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${draft.name} ajouté aux contacts.')),
    );
  }

  void _onPop(bool didPop, Object? _) {
    // A newer session may already have replaced this one.
    if (didPop && widget.connection.session == _session) {
      widget.connection.leaveSession();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: _onPop,
      child: _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: ListenableBuilder(
          listenable: widget.contacts,
          builder: (context, _) {
            final contact = widget.contacts.byId(_session.peer);
            final id = DismessageId.format(_session.peer);
            if (contact == null) return Text(id);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(contact.name),
                Text(id, style: Theme.of(context).textTheme.bodySmall),
              ],
            );
          },
        ),
        actions: [
          ListenableBuilder(
            listenable: widget.contacts,
            builder: (context, _) {
              final saved = widget.contacts.byId(_session.peer) != null;
              return IconButton(
                key: const Key('save-contact'),
                tooltip: saved
                    ? 'Renommer le contact'
                    : 'Enregistrer le contact',
                icon: Icon(saved ? Icons.edit_outlined : Icons.person_add_alt),
                onPressed: _saveContact,
              );
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _session,
        builder: (context, _) => Column(
          children: [
            if (_session.peerLeft)
              MaterialBanner(
                content: const Text("L'interlocuteur s'est déconnecté."),
                leading: const Icon(Icons.link_off),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('Retour'),
                  ),
                ],
              ),
            Expanded(
              child: ListView(
                controller: _scroll,
                padding: const EdgeInsets.all(12),
                children: [
                  for (final message in _session.messages)
                    _MessageBubble(message: message),
                  LiveDraftBubble(text: _session.remoteDraft),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('chat-input'),
                        controller: _input,
                        focusNode: _focus,
                        autofocus: true,
                        enabled: !_session.peerLeft,
                        maxLength: kMaxTextLength,
                        textInputAction: TextInputAction.send,
                        onChanged: _session.updateDraft,
                        onSubmitted: (_) => _send(),
                        decoration: const InputDecoration(
                          hintText:
                              'Écrivez… votre interlocuteur vous voit en direct',
                          border: OutlineInputBorder(),
                          counterText: '',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      key: const Key('send'),
                      icon: const Icon(Icons.send),
                      onPressed: _session.peerLeft ? null : _send,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mine = message.fromMe;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: mine ? scheme.primary : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(
          message.text,
          style: TextStyle(color: mine ? scheme.onPrimary : scheme.onSurface),
        ),
      ),
    );
  }
}
