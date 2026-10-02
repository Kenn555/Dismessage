import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../services/chat_session.dart';
import '../../services/connection_service.dart';
import '../../services/contacts_service.dart';
import '../../services/image_codec.dart';
import '../../theme/app_theme.dart';
import '../../widgets/contact_avatar.dart';
import '../../widgets/contact_dialog.dart';
import '../../widgets/dismessage_logo.dart';
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
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: ListenableBuilder(
          listenable: Listenable.merge([widget.contacts, _session]),
          builder: (context, _) {
            final contact = widget.contacts.byId(_session.peer);
            final id = DismessageId.format(_session.peer);
            final live = !_session.peerLeft;
            return Row(
              children: [
                ContactAvatar(
                  id: _session.peer,
                  name: contact?.name,
                  radius: 19,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        contact?.name ?? id,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                      Row(
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: live
                                  ? const Color(0xFF10B981)
                                  : theme.colorScheme.outline,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              [
                                if (contact != null) id,
                                live ? 'En direct' : 'Déconnecté',
                              ].join(' · '),
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
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
                icon: Icon(
                  saved ? Icons.edit_outlined : Icons.person_add_alt_1_rounded,
                ),
                onPressed: _saveContact,
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListenableBuilder(
        listenable: _session,
        builder: (context, _) {
          final empty =
              _session.messages.isEmpty && _session.remoteDraft.isEmpty;
          return Column(
            children: [
              if (_session.peerLeft)
                MaterialBanner(
                  content: const Text("L'interlocuteur s'est déconnecté."),
                  leading: const Icon(Icons.link_off_rounded),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      child: const Text('Retour'),
                    ),
                  ],
                ),
              Expanded(
                child: empty
                    ? const _EmptyConversation()
                    : ListView(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
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
              _composer(context),
              if (_showEmojis && !_session.peerLeft)
                EmojiPanel(onSelected: _insertEmoji),
            ],
          );
        },
      ),
    );
  }

  /// Pill-shaped input bar with emoji / image actions and a send button.
  Widget _composer(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = !_session.peerLeft;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(28),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  children: [
                    IconButton(
                      key: const Key('emoji-toggle'),
                      tooltip: _showEmojis ? 'Clavier' : 'Émojis',
                      icon: Icon(
                        _showEmojis
                            ? Icons.keyboard_alt_outlined
                            : Icons.emoji_emotions_outlined,
                      ),
                      onPressed: enabled
                          ? () => setState(() => _showEmojis = !_showEmojis)
                          : null,
                    ),
                    Expanded(
                      child: TextField(
                        key: const Key('chat-input'),
                        controller: _input,
                        focusNode: _focus,
                        autofocus: true,
                        enabled: enabled,
                        maxLength: kMaxTextLength,
                        textInputAction: TextInputAction.send,
                        onChanged: _session.updateDraft,
                        onSubmitted: (_) => _send(),
                        decoration: const InputDecoration(
                          hintText: 'Écrivez… on vous voit en direct',
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(vertical: 14),
                          counterText: '',
                        ),
                      ),
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
                      onPressed: enabled && !_preparingImage
                          ? _sendImage
                          : null,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            _SendButton(onPressed: enabled ? _send : null),
          ],
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      label: 'Envoyer',
      child: Material(
        key: const Key('send'),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        color: Colors.transparent,
        child: Ink(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: enabled ? AppTheme.brandGradient : null,
            color: enabled
                ? null
                : Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
          child: InkWell(
            onTap: onPressed,
            child: Icon(
              Icons.send_rounded,
              color: enabled
                  ? Colors.white
                  : Theme.of(context).colorScheme.outline,
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown before the first message: explains the live typing.
class _EmptyConversation extends StatelessWidget {
  const _EmptyConversation();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const DismessageLogo(size: 64),
            const SizedBox(height: 20),
            Text('Dites bonjour 👋', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Votre interlocuteur voit chaque lettre au moment où vous '
              'la tapez. Les messages ne sont jamais enregistrés.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mine = message.fromMe;
    final foreground = mine ? Colors.white : scheme.onSurface;
    const big = Radius.circular(20);
    const small = Radius.circular(6);
    final time =
        '${message.at.hour.toString().padLeft(2, '0')}:'
        '${message.at.minute.toString().padLeft(2, '0')}';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          gradient: mine ? AppTheme.brandGradient : null,
          color: mine ? null : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.only(
            topLeft: big,
            topRight: big,
            bottomLeft: mine ? big : small,
            bottomRight: mine ? small : big,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message.text,
              style: theme.textTheme.bodyLarge?.copyWith(color: foreground),
            ),
            const SizedBox(height: 2),
            Text(
              time,
              style: theme.textTheme.labelSmall?.copyWith(
                color: foreground.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
