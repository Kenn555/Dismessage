import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../services/chat_session.dart';
import '../../services/connection_service.dart';
import '../../services/contacts_service.dart';
import '../../services/image_codec.dart';
import '../../widgets/contact_dialog.dart';
import '../../widgets/emoji_panel.dart';
import '../../widgets/image_bubble.dart';
import '../../widgets/live_draft_bubble.dart';

/// Lets the user choose a picture; null if cancelled.
typedef ImagePickerFn = Future<Uint8List?> Function();

/// Turns picked bytes into a sendable image.
typedef ImageEncoderFn = Future<EncodedImage> Function(Uint8List bytes);

Future<Uint8List?> _pickFromGallery() async {
  final file = await ImagePicker().pickImage(
    source: ImageSource.gallery,
    // Native downscale on mobile: less work for the Dart encoder.
    maxWidth: 2560,
    maxHeight: 2560,
  );
  return file?.readAsBytes();
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.session,
    required this.connection,
    required this.contacts,
    this.pickImage = _pickFromGallery,
    this.encodeImage = ImageCodec.encodeInBackground,
  });

  final ChatSession session;
  final ConnectionService connection;
  final ContactsService contacts;
  final ImagePickerFn pickImage;
  final ImageEncoderFn encodeImage;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  bool _showEmojis = false;
  bool _preparingImage = false;

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

  /// Inserts [emoji] at the cursor (or replaces the selection).
  void _insertEmoji(String emoji) {
    final value = _input.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final text = value.text.replaceRange(selection.start, selection.end, emoji);
    if (text.length > kMaxTextLength) return;
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
        offset: selection.start + emoji.length,
      ),
    );
    // Programmatic changes do not trigger onChanged: stream it ourselves.
    _session.updateDraft(text);
  }

  Future<void> _sendImage() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _preparingImage = true);
    try {
      final picked = await widget.pickImage();
      if (picked == null) return;
      final encoded = await widget.encodeImage(picked);
      _session.sendImage(encoded);
    } on ImageCodecException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text("Impossible d'envoyer l'image.")),
      );
    } finally {
      if (mounted) setState(() => _preparingImage = false);
    }
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
                  for (final entry in _session.messages)
                    switch (entry) {
                      ChatMessage() => _MessageBubble(message: entry),
                      ChatImage() => ImageBubble(
                        image: entry,
                        onOpen: () => _session.openImage(entry),
                      ),
                    },
                  LiveDraftBubble(text: _session.remoteDraft),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 12, 12),
                child: Row(
                  children: [
                    IconButton(
                      key: const Key('emoji-toggle'),
                      tooltip: _showEmojis ? 'Clavier' : 'Émojis',
                      icon: Icon(
                        _showEmojis
                            ? Icons.keyboard_outlined
                            : Icons.emoji_emotions_outlined,
                      ),
                      onPressed: _session.peerLeft
                          ? null
                          : () => setState(() => _showEmojis = !_showEmojis),
                    ),
                    IconButton(
                      key: const Key('send-image'),
                      tooltip: 'Envoyer une image',
                      icon: _preparingImage
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.image_outlined),
                      onPressed: _session.peerLeft || _preparingImage
                          ? null
                          : _sendImage,
                    ),
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
            if (_showEmojis && !_session.peerLeft)
              EmojiPanel(onSelected: _insertEmoji),
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
