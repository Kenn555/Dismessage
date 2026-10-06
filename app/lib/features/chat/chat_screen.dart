import 'dart:async';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../services/camera_capture.dart';
import '../../services/chat_session.dart';
import '../../services/connection_service.dart';
import '../../services/contacts_service.dart';
import '../../services/file_storage.dart';
import '../../services/id_privacy.dart';
import '../../services/image_codec.dart';
import '../../services/voice_player.dart';
import '../../services/voice_recorder.dart';
import '../../theme/app_theme.dart';
import '../../widgets/bubble_shell.dart';
import '../../widgets/contact_avatar.dart';
import '../../widgets/contact_dialog.dart';
import '../../widgets/dismessage_logo.dart';
import '../../widgets/emoji_panel.dart';
import '../../widgets/file_bubble.dart';
import '../../widgets/image_bubble.dart';
import '../../widgets/live_draft_bubble.dart';
import '../../widgets/message_actions.dart';
import '../../widgets/voice_bubble.dart';
import 'camera_screen.dart';

export 'package:image_picker/image_picker.dart' show ImageSource;

/// Lets the user take or choose a picture; null if cancelled.
typedef ImagePickerFn = Future<Uint8List?> Function(ImageSource source);

/// Turns picked bytes into a sendable image.
typedef ImageEncoderFn = Future<EncodedImage> Function(Uint8List bytes);

Future<Uint8List?> _pickImage(ImageSource source) async {
  final file = await ImagePicker().pickImage(
    source: source,
    // Native downscale (mobile, browser canvas): the Dart encoder is slow on
    // a 12 MP photo, and on the web it runs on the UI thread.
    maxWidth: kMaxImageSide.toDouble(),
    maxHeight: kMaxImageSide.toDouble(),
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
    this.createCamera = platformCameraCapture,
    this.encodeImage = ImageCodec.encodeInBackground,
    this.createRecorder = platformVoiceRecorder,
    this.createAudioBackend = platformAudioBackend,
    this.pickFile = platformPickFile,
    this.privacy,
    this.active = true,
  });

  final ChatSession session;
  final ConnectionService connection;
  final ContactsService contacts;
  final ImagePickerFn pickImage;

  /// Whether a photo can be taken here; detected when null.
  final bool? cameraAvailable;

  /// Live webcam where `image_picker` cannot take photos itself (desktop
  /// browsers, Windows); null elsewhere.
  final CameraCapture? Function() createCamera;
  final ImageEncoderFn encodeImage;
  final VoiceRecorder Function() createRecorder;
  final AudioBackend Function() createAudioBackend;

  /// Chooses a file to send directly to the peer.
  final FilePickerFn pickFile;

  /// Which IDs are shown in full (a saved contact's is masked by default).
  final IdPrivacy? privacy;

  /// Whether this conversation is the one on screen (several stay built).
  final bool active;

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
      (widget.createCamera() != null ||
          ImagePicker().supportsImageSource(ImageSource.camera));

  /// One key per bubble, to scroll to the original of a reply.
  final Map<String, GlobalKey> _keys = {};
  bool _showEmojis = false;
  bool _preparingImage = false;
  ChatEntry? _replyTo;
  String? _highlighted;
  Timer? _highlightTimer;

  /// Bubbles already laid out, to scroll only when one is added.
  int _shownCount = 0;

  /// The list is scrolled up: show the "jump to the bottom" button.
  final _scrolledUp = ValueNotifier(false);

  /// Bubbles arrived below while scrolled up.
  final _newBelow = ValueNotifier(false);

  VoiceRecorder? _recorder;
  bool _recording = false;
  final _recordClock = Stopwatch();
  Timer? _recordTicker;

  ChatSession get _session => widget.session;
  late final IdPrivacy _privacy = widget.privacy ?? IdPrivacy();

  @override
  void initState() {
    super.initState();
    _shownCount = _session.messages.length;
    _session.addListener(_onSessionChanged);
    _scroll.addListener(_onScroll);
    _player.addListener(_onPlayerChanged);
    _scrollToBottom();
  }

  @override
  void didUpdateWidget(ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _refocus();
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
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
    _scrolledUp.dispose();
    _newBelow.dispose();
    super.dispose();
  }

  /// Follows new bubbles only: the peer's typing lives outside the list
  /// and never moves it. Scrolled up, a received bubble does not pull the
  /// user down (the button shows it); my own always does.
  void _onSessionChanged() {
    final entries = _session.messages;
    if (entries.length <= _shownCount) {
      _shownCount = entries.length;
      return;
    }
    _shownCount = entries.length;
    final atBottom =
        !_scroll.hasClients || _scroll.position.extentAfter < _bottomSlack;
    if (entries.last.fromMe || atBottom) {
      _scrollToBottom();
    } else {
      _newBelow.value = true;
    }
  }

  /// Distance from the bottom still considered "at the bottom".
  static const _bottomSlack = 80.0;

  void _onScroll() {
    final up = _scroll.position.extentAfter > _bottomSlack * 2;
    _scrolledUp.value = up;
    if (!up) _newBelow.value = false;
  }

  /// The cursor always comes back to the input after an action (emoji,
  /// photo, voice, reply…).
  void _refocus() {
    if (!mounted || !widget.active || _session.peerLeft) return;
    _focus.requestFocus();
  }

  void _toggleEmojis() {
    setState(() => _showEmojis = !_showEmojis);
    _refocus();
    // Back to the keyboard: the field already had the focus, show it.
    if (!_showEmojis) SystemChannels.textInput.invokeMethod('TextInput.show');
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
    _refocus();
  }

  /// Inserts [emoji] at the cursor (or replaces the selection).
  void _insertEmoji(String emoji) {
    final value = _input.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final text = value.text.replaceRange(selection.start, selection.end, emoji);
    if (text.length > kMaxTextLength) return _refocus();
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
        offset: selection.start + emoji.length,
      ),
    );
    // Programmatic changes do not trigger onChanged: stream it ourselves.
    _session.updateDraft(text);
    _refocus();
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
      if (picked == null) return _refocus();
      source = picked;
    }
    await _sendImage(source);
  }

  Future<void> _sendImage(ImageSource source) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _preparingImage = true);
    try {
      final camera = source == ImageSource.camera
          ? widget.createCamera()
          : null;
      final picked = camera == null
          ? await widget.pickImage(source)
          : await navigator.push<Uint8List>(
              MaterialPageRoute(
                fullscreenDialog: true,
                builder: (_) => CameraScreen(capture: camera),
              ),
            );
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
      _refocus();
    }
  }

  /// Offers a file: the peer must accept it before anything is sent.
  Future<void> _chooseFile() async {
    final ChosenFile? picked;
    try {
      picked = await widget.pickFile();
    } catch (e) {
      final cause = e.toString().split('\n').first;
      if (mounted) _snack('Impossible de choisir un fichier ($cause).');
      return _refocus();
    }
    if (picked == null || !mounted) return _refocus();
    if (picked.size > kMaxFileBytes) {
      await picked.close();
      _snack(
        'Fichier trop volumineux (${formatFileSize(picked.size)}, '
        'maximum ${formatFileSize(kMaxFileBytes)}).',
      );
      return _refocus();
    }
    if (_session.sendFile(picked, replyTo: _replyTo) == null) {
      await picked.close();
    } else {
      setState(() => _replyTo = null);
    }
    _refocus();
  }

  Future<void> _openSaved(ChatFile file, {bool folder = false}) async {
    final saved = file.saved;
    if (saved == null) return;
    final ok = folder ? await saved.showInFolder() : await saved.open();
    if (!ok && mounted) {
      _snack(
        folder
            ? "Impossible d'ouvrir le dossier."
            : 'Aucune application ne sait ouvrir ce fichier.',
      );
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
    _refocus();
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
    _refocus();
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
    _refocus();
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
        ChatFile() => FileBubble(
          file: entry,
          onAccept: live ? () => _session.acceptFile(entry) : null,
          onCancel: () {
            _session.cancelFile(entry);
            _refocus();
          },
          onOpen: () => _openSaved(entry),
          onShowInFolder: () => _openSaved(entry, folder: true),
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
    _refocus();
    if (!mounted || existing != null) return;
    _snack('${draft.name} ajouté aux contacts.');
  }

  /// Leaves (or, once the peer is gone, closes) this conversation.
  void _close() => widget.connection.closeSession(_session);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: ListenableBuilder(
          listenable: Listenable.merge([widget.contacts, _session, _privacy]),
          builder: (context, _) {
            final contact = widget.contacts.byId(_session.peer);
            final id = DismessageId.format(_session.peer);
            // A saved contact is known by name: its ID can stay masked.
            final shownId = contact == null
                ? id
                : _privacy.contact(_session.peer);
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
                                if (contact != null) shownId,
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
          ListenableBuilder(
            listenable: _session,
            builder: (context, _) => IconButton(
              key: const Key('close-session'),
              tooltip: _session.peerLeft
                  ? 'Fermer la conversation'
                  : 'Quitter la conversation',
              icon: const Icon(Icons.logout_rounded),
              onPressed: _close,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListenableBuilder(
        listenable: _session,
        builder: (context, _) {
          final empty = _session.messages.isEmpty;
          return Column(
            children: [
              if (_session.peerLeft)
                MaterialBanner(
                  content: const Text("L'interlocuteur s'est déconnecté."),
                  leading: const Icon(Icons.link_off_rounded),
                  actions: [
                    TextButton(
                      key: const Key('banner-close'),
                      onPressed: _close,
                      child: const Text('Fermer'),
                    ),
                  ],
                ),
              Expanded(
                child: empty
                    ? const _EmptyConversation()
                    : Stack(
                        children: [
                          // Not lazy: every bubble must exist to jump to a
                          // quote.
                          SingleChildScrollView(
                            key: const Key('chat-list'),
                            controller: _scroll,
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (final entry in _session.messages)
                                  _bubble(entry),
                              ],
                            ),
                          ),
                          Positioned(
                            right: 16,
                            bottom: 8,
                            child: _JumpToBottom(
                              visible: _scrolledUp,
                              fresh: _newBelow,
                              onPressed: _jumpToBottom,
                            ),
                          ),
                        ],
                      ),
              ),
              // Fixed above the input: the peer's typing never moves the
              // list, which can be scrolled meanwhile.
              _liveDraft(context),
              // Taps here keep the input focused (no "tap outside").
              TextFieldTapRegion(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_replyTo != null && !_session.peerLeft)
                      _replyBar(context),
                    _composer(context),
                    if (_showEmojis && !_session.peerLeft && !_recording)
                      ExcludeFocus(child: EmojiPanel(onSelected: _insertEmoji)),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _jumpToBottom() {
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
    _refocus();
  }

  /// What the peer is typing, at most a third of the screen high; a long
  /// draft shows its end.
  Widget _liveDraft(BuildContext context) {
    final draft = _session.remoteDraft;
    return ConstrainedBox(
      key: const Key('live-draft-zone'),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.35,
      ),
      child: SingleChildScrollView(
        reverse: true,
        padding: EdgeInsets.symmetric(
          horizontal: 16,
          vertical: draft.isEmpty ? 0 : 2,
        ),
        child: LiveDraftBubble(text: draft),
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
            onPressed: () {
              setState(() => _replyTo = null);
              _refocus();
            },
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
          crossAxisAlignment: CrossAxisAlignment.center,
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
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        IconButton(
          key: const Key('emoji-toggle'),
          tooltip: _showEmojis ? 'Clavier' : 'Émojis',
          icon: Icon(
            _showEmojis
                ? Icons.keyboard_alt_outlined
                : Icons.emoji_emotions_outlined,
          ),
          onPressed: enabled ? _toggleEmojis : null,
        ),
        Expanded(
          child: TextField(
            key: const Key('chat-input'),
            controller: _input,
            focusNode: _focus,
            autofocus: widget.active,
            enabled: enabled,
            maxLength: kMaxTextLength,
            minLines: 1,
            maxLines: 6,
            // Emoji panel open: keep the cursor, without the virtual
            // keyboard over the panel.
            keyboardType: _showEmojis
                ? TextInputType.none
                : TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            textCapitalization: TextCapitalization.sentences,
            onChanged: _session.updateDraft,
            decoration: const InputDecoration(
              hintText: 'Écrivez…',
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
          key: const Key('send-file'),
          tooltip: 'Envoyer un fichier',
          icon: const Icon(Icons.attach_file_rounded),
          onPressed: enabled ? _chooseFile : null,
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

/// Round button back to the latest bubble, with a dot when new ones
/// arrived below.
class _JumpToBottom extends StatelessWidget {
  const _JumpToBottom({
    required this.visible,
    required this.fresh,
    required this.onPressed,
  });

  final ValueListenable<bool> visible;
  final ValueListenable<bool> fresh;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([visible, fresh]),
      builder: (context, _) => AnimatedScale(
        scale: visible.value ? 1 : 0,
        duration: const Duration(milliseconds: 150),
        child: Badge(
          isLabelVisible: fresh.value,
          smallSize: 10,
          child: ExcludeFocus(
            child: FloatingActionButton.small(
              key: const Key('jump-to-bottom'),
              heroTag: null,
              tooltip: 'Derniers messages',
              backgroundColor: scheme.surfaceContainerHighest,
              foregroundColor: scheme.onSurface,
              onPressed: visible.value ? onPressed : null,
              child: const Icon(Icons.keyboard_arrow_down_rounded),
            ),
          ),
        ),
      ),
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
      // As wide as the widest line: the text stays left-aligned under a
      // wider quote, the time stays on the right.
      child: IntrinsicWidth(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
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
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                time,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: foreground.withValues(alpha: 0.7),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
