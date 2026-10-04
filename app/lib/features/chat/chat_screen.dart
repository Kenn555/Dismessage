import 'dart:async';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../services/chat_session.dart';
import '../../services/connection_service.dart';
import '../../services/contacts_service.dart';
import '../../services/image_codec.dart';
import '../../services/voice_player.dart';
import '../../services/voice_recorder.dart';
import '../../theme/app_theme.dart';
import '../../widgets/bubble_shell.dart';
import '../../widgets/contact_avatar.dart';
import '../../widgets/contact_dialog.dart';
import '../../widgets/dismessage_logo.dart';
import '../../widgets/emoji_panel.dart';
import '../../widgets/image_bubble.dart';
import '../../widgets/live_draft_bubble.dart';
import '../../widgets/message_actions.dart';
import '../../widgets/voice_bubble.dart';

export 'package:image_picker/image_picker.dart' show ImageSource;

/// Lets the user take or choose a picture; null if cancelled.
typedef ImagePickerFn = Future<Uint8List?> Function(ImageSource source);

/// Turns picked bytes into a sendable image.
typedef ImageEncoderFn = Future<EncodedImage> Function(Uint8List bytes);

Future<Uint8List?> _pickImage(ImageSource source) async {
  final file = await ImagePicker().pickImage(
    source: source,
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
    this.pickImage = _pickImage,
    this.cameraAvailable,
    this.encodeImage = ImageCodec.encodeInBackground,
    this.createRecorder = platformVoiceRecorder,
    this.createAudioBackend = platformAudioBackend,
  });

  final ChatSession session;
  final ConnectionService connection;
  final ContactsService contacts;
  final ImagePickerFn pickImage;

  /// Whether a photo can be taken here; detected when null (no camera
  /// support on Windows: the gallery opens directly).
  final bool? cameraAvailable;
  final ImageEncoderFn encodeImage;
  final VoiceRecorder Function() createRecorder;
  final AudioBackend Function() createAudioBackend;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  late final _focus = FocusNode(onKeyEvent: _onKey);
  final _scroll = ScrollController();
  late final _player = VoicePlayer(widget.createAudioBackend);
  late final bool _cameraAvailable =
      widget.cameraAvailable ??
      ImagePicker().supportsImageSource(ImageSource.camera);

  /// One key per bubble, to scroll to the original of a reply.
  final Map<String, GlobalKey> _keys = {};
  bool _showEmojis = false;
  bool _preparingImage = false;
  ChatEntry? _replyTo;
  String? _highlighted;
  Timer? _highlightTimer;

  VoiceRecorder? _recorder;
  bool _recording = false;
  final _recordClock = Stopwatch();
  Timer? _recordTicker;

  ChatSession get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _session.addListener(_scrollToBottom);
    _player.addListener(_onPlayerChanged);
  }

  @override
  void dispose() {
    _session.removeListener(_scrollToBottom);
    _player
      ..removeListener(_onPlayerChanged)
      ..dispose();
    _recordTicker?.cancel();
    _highlightTimer?.cancel();
    final recorder = _recorder;
    if (recorder != null) {
      if (_recording) recorder.cancel();
      recorder.dispose();
    }
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

  void _onPlayerChanged() {
    final error = _player.error;
    if (error != null && mounted) _snack(error);
  }

  void _snack(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  /// Physical keyboard: Enter sends, Shift+Enter starts a new line.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final enter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!enter || HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) _send();
    return KeyEventResult.handled;
  }

  void _send() {
    if (_session.sendMessage(replyTo: _replyTo)) {
      _input.clear();
      setState(() => _replyTo = null);
    }
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

  /// Camera or gallery from the same button (gallery only without camera).
  Future<void> _chooseImage() async {
    var source = ImageSource.gallery;
    if (_cameraAvailable) {
      final picked = await showModalBottomSheet<ImageSource>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                key: const Key('pick-camera'),
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Prendre une photo'),
                onTap: () => Navigator.pop(context, ImageSource.camera),
              ),
              ListTile(
                key: const Key('pick-gallery'),
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Choisir dans la galerie'),
                onTap: () => Navigator.pop(context, ImageSource.gallery),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
      if (picked == null) return;
      source = picked;
    }
    await _sendImage(source);
  }

  Future<void> _sendImage(ImageSource source) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _preparingImage = true);
    try {
      final picked = await widget.pickImage(source);
      if (picked == null) return;
      final encoded = await widget.encodeImage(picked);
      if (_session.sendImage(encoded, replyTo: _replyTo) != null && mounted) {
        setState(() => _replyTo = null);
      }
    } on ImageCodecException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      // Show the cause: a remote friend can then report it.
      final cause = e.toString().split('\n').first;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${source == ImageSource.camera ? "Impossible d'utiliser l'appareil photo" : "Impossible d'envoyer l'image"} '
            '(${cause.length > 160 ? '${cause.substring(0, 160)}…' : cause}).',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _preparingImage = false);
    }
  }

  Future<void> _startRecording() async {
    final recorder = _recorder ??= widget.createRecorder();
    try {
      await recorder.start();
    } on VoiceRecorderException catch (e) {
      if (mounted) _snack(e.message);
      return;
    } catch (_) {
      if (mounted) _snack('Micro indisponible.');
      return;
    }
    if (!mounted) return;
    _recordClock
      ..reset()
      ..start();
    setState(() {
      _recording = true;
      _showEmojis = false;
    });
    _recordTicker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_recordClock.elapsed >= recorder.maxDuration) {
        _stopRecording(send: true);
      } else {
        setState(() {});
      }
    });
  }

  Future<void> _stopRecording({required bool send}) async {
    final recorder = _recorder;
    if (!_recording || recorder == null) return;
    _recordTicker?.cancel();
    _recordClock.stop();
    setState(() => _recording = false);
    if (!send) {
      await recorder.cancel();
      return;
    }
    final RecordedVoice? voice;
    try {
      voice = await recorder.stop();
    } catch (_) {
      if (mounted) _snack("L'enregistrement a échoué.");
      return;
    }
    if (!mounted || _session.peerLeft) return;
    if (voice == null) {
      _snack('Aucun son enregistré.');
    } else if (_session.sendVoice(voice, replyTo: _replyTo) == null) {
      _snack('Message vocal trop long.');
    } else {
      setState(() => _replyTo = null);
    }
  }

  void _startReply(ChatEntry entry) {
    if (_session.peerLeft) return;
    setState(() => _replyTo = entry);
    _focus.requestFocus();
  }

  Future<void> _showActions(ChatEntry entry) async {
    final live = !_session.peerLeft;
    final canCopy = entry is ChatMessage;
    if (!live && !canCopy) return;
    final action = await showMessageActions(
      context,
      canReact: live && !entry.fromMe,
      canReply: live,
      canCopy: canCopy,
      currentReaction: entry.fromMe ? null : entry.reaction,
    );
    if (!mounted) return;
    switch (action) {
      case ReactAction(:final emoji):
        _session.react(entry, emoji);
      case ReplyAction():
        _startReply(entry);
      case CopyAction():
        if (entry is ChatMessage) {
          await Clipboard.setData(ClipboardData(text: entry.text));
          if (mounted) _snack('Message copié');
        }
      case null:
        break;
    }
  }

  /// Scrolls to the quoted bubble and flashes it.
  void _jumpTo(String id) {
    final target = _keys[id]?.currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      alignment: 0.3,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
    _highlightTimer?.cancel();
    setState(() => _highlighted = id);
    _highlightTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _highlighted = null);
    });
  }

  String _author(ChatEntry entry) => entry.fromMe
      ? 'Vous'
      : widget.contacts.byId(_session.peer)?.name ??
            DismessageId.format(_session.peer);

  Widget? _quoteFor(ChatEntry entry, {required bool onBrand}) {
    final id = entry.replyTo;
    final target = id == null ? null : _session.byId(id);
    if (target == null) return null;
    return ReplyQuote(
      key: ValueKey('quote-${entry.id}'),
      author: _author(target),
      snippet: entrySnippet(target),
      onBrand: onBrand,
      onTap: () => _jumpTo(target.id),
    );
  }

  Widget _bubble(ChatEntry entry) {
    final live = !_session.peerLeft;
    return BubbleShell(
      key: _keys.putIfAbsent(entry.id, GlobalKey.new),
      entry: entry,
      highlighted: _highlighted == entry.id,
      onReply: live ? () => _startReply(entry) : null,
      onActions: () => _showActions(entry),
      child: switch (entry) {
        ChatMessage() => _MessageBubble(
          message: entry,
          header: _quoteFor(entry, onBrand: entry.fromMe),
        ),
        ChatImage() => ImageBubble(
          image: entry,
          onOpen: () => _session.openImage(entry),
          header: _quoteFor(entry, onBrand: false),
        ),
        ChatVoice() => VoiceBubble(
          voice: entry,
          player: _player,
          header: _quoteFor(entry, onBrand: entry.fromMe),
        ),
      },
    );
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
    _snack('${draft.name} ajouté aux contacts.');
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
                                  ? AppTheme.online
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
                    // Not lazy: every bubble must exist to jump to a quote.
                    : SingleChildScrollView(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final entry in _session.messages)
                              _bubble(entry),
                            LiveDraftBubble(text: _session.remoteDraft),
                          ],
                        ),
                      ),
              ),
              if (_replyTo != null && !_session.peerLeft) _replyBar(context),
              _composer(context),
              if (_showEmojis && !_session.peerLeft && !_recording)
                EmojiPanel(onSelected: _insertEmoji),
            ],
          );
        },
      ),
    );
  }

  /// The bubble being answered, above the input.
  Widget _replyBar(BuildContext context) {
    final target = _replyTo!;
    return Padding(
      key: const Key('reply-bar'),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: ReplyQuote(
                author: target.fromMe
                    ? 'Réponse à vous-même'
                    : 'Réponse à ${_author(target)}',
                snippet: entrySnippet(target),
                onTap: () => _jumpTo(target.id),
              ),
            ),
          ),
          IconButton(
            key: const Key('reply-cancel'),
            tooltip: 'Annuler la réponse',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => setState(() => _replyTo = null),
          ),
        ],
      ),
    );
  }

  /// Pill-shaped input bar with emoji / image actions and a send (or
  /// microphone) button.
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
                constraints: const BoxConstraints(minHeight: 52),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(28),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: _recording ? _recordingRow(context) : _inputRow(enabled),
              ),
            ),
            const SizedBox(width: 8),
            ValueListenableBuilder(
              valueListenable: _input,
              builder: (context, value, _) {
                if (_recording) {
                  return _SendButton(
                    onPressed: () => _stopRecording(send: true),
                  );
                }
                if (value.text.trim().isEmpty) {
                  return _SendButton(
                    key: const Key('record-voice'),
                    icon: Icons.mic_rounded,
                    label: 'Message vocal',
                    onPressed: enabled ? _startRecording : null,
                  );
                }
                return _SendButton(onPressed: enabled ? _send : null);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _inputRow(bool enabled) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
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
            minLines: 1,
            maxLines: 6,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            textCapitalization: TextCapitalization.sentences,
            onChanged: _session.updateDraft,
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
          tooltip: _cameraAvailable ? 'Photo' : 'Envoyer une image',
          icon: _preparingImage
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  _cameraAvailable
                      ? Icons.photo_camera_outlined
                      : Icons.image_outlined,
                ),
          onPressed: enabled && !_preparingImage ? _chooseImage : null,
        ),
      ],
    );
  }

  Widget _recordingRow(BuildContext context) {
    final theme = Theme.of(context);
    final max = _recorder?.maxDuration;
    return Row(
      key: const Key('recording'),
      children: [
        IconButton(
          key: const Key('record-cancel'),
          tooltip: 'Supprimer',
          icon: Icon(
            Icons.delete_outline_rounded,
            color: theme.colorScheme.error,
          ),
          onPressed: () => _stopRecording(send: false),
        ),
        const _RecordingDot(),
        const SizedBox(width: 10),
        Text(
          [
            formatVoiceDuration(_recordClock.elapsed),
            if (max != null) formatVoiceDuration(max),
          ].join(' / '),
          style: theme.textTheme.titleSmall?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            'Enregistrement…',
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// Blinking red dot while the microphone records.
class _RecordingDot extends StatefulWidget {
  const _RecordingDot();

  @override
  State<_RecordingDot> createState() => _RecordingDotState();
}

class _RecordingDotState extends State<_RecordingDot>
    with SingleTickerProviderStateMixin {
  late final _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 1.0, end: 0.25).animate(_blink),
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Theme.of(context).colorScheme.error,
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({
    super.key = const Key('send'),
    required this.onPressed,
    this.icon = Icons.send_rounded,
    this.label = 'Envoyer',
  });

  final VoidCallback? onPressed;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: Material(
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
                icon,
                color: enabled
                    ? Colors.white
                    : Theme.of(context).colorScheme.outline,
              ),
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
  const _MessageBubble({required this.message, this.header});

  final ChatMessage message;

  /// Reply quote, if this message answers another bubble.
  final Widget? header;

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
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: EdgeInsets.fromLTRB(
        header == null ? 14 : 6,
        header == null ? 10 : 6,
        14,
        8,
      ),
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
          if (header != null)
            Padding(padding: const EdgeInsets.only(bottom: 6), child: header),
          Padding(
            padding: EdgeInsets.only(left: header == null ? 0 : 8),
            child: Text(
              message.text,
              style: theme.textTheme.bodyLarge?.copyWith(color: foreground),
            ),
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
    );
  }
}
