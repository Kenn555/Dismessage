import 'dart:async';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../services/attachments.dart';
import '../../services/camera_capture.dart';
import '../../services/chat_session.dart';
import '../../services/clipboard_images.dart';
import '../../services/connection_service.dart';
import '../../services/contacts_service.dart';
import '../../services/desktop_overlay.dart';
import '../../services/file_storage.dart';
import '../../services/id_privacy.dart';
import '../../services/image_codec.dart';
import '../../services/live_fullscreen.dart';
import '../../services/live_link.dart';
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
import '../../widgets/live_view.dart';
import '../../widgets/message_actions.dart';
import '../../widgets/voice_bubble.dart';
import 'camera_screen.dart';

export 'package:image_picker/image_picker.dart' show ImageSource;

/// Lets the user take a picture, or choose several (at most
/// [kMaxImagesPerSend]); empty if cancelled.
typedef ImagePickerFn = Future<List<Uint8List>> Function(ImageSource source);

Future<List<Uint8List>> _pickImage(ImageSource source) async {
  // Native downscale (mobile, browser canvas): the Dart encoder is slow on
  // a 12 MP photo, and on the web it runs on the UI thread.
  final side = kMaxImageSide.toDouble();
  final picker = ImagePicker();
  final files = source == ImageSource.camera
      ? [
          ?await picker.pickImage(
            source: source,
            maxWidth: side,
            maxHeight: side,
          ),
        ]
      : await picker.pickMultiImage(
          maxWidth: side,
          maxHeight: side,
          limit: kMaxImagesPerSend,
        );
  return [for (final file in files) await file.readAsBytes()];
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
    this.pickFile = platformPickFiles,
    this.clipboardImages,
    this.overlay,
    this.fullscreen,
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

  /// Chooses files to send directly to the peer.
  final FilePickerFn pickFile;

  /// Images and files pasted into the input; the platform's when null.
  final ClipboardImages? clipboardImages;

  /// The Windows overlay panel (header button); null elsewhere.
  final DesktopOverlay? overlay;

  /// The peer's camera in full screen.
  final LiveFullscreen? fullscreen;

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
  late final ClipboardImages _clipboard =
      widget.clipboardImages ?? platformClipboardImages();
  StreamSubscription<Attachments>? _pastes;
  StreamSubscription<String>? _liveNotices;

  @override
  void initState() {
    super.initState();
    _syncInput();
    _pastes = _clipboard.pasted.listen(_onPasted);
    _liveNotices = _session.live.notices.listen((message) {
      if (mounted && widget.active) _snack(message);
    });
    widget.fullscreen?.addListener(_onFullscreen);
    _shownCount = _session.messages.length;
    _session.addListener(_onSessionChanged);
    _scroll.addListener(_onScroll);
    _player.addListener(_onPlayerChanged);
    _scrollToBottom();
  }

  @override
  void didUpdateWidget(ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _syncInput();
      _refocus();
    }
  }

  /// Takes what was typed elsewhere (the Windows overlay panel).
  void _syncInput() {
    final draft = _session.localDraft;
    if (_input.text == draft) return;
    _input.value = TextEditingValue(
      text: draft,
      selection: TextSelection.collapsed(offset: draft.length),
    );
  }

  /// Back from full screen: the keyboard returns to the input.
  void _onFullscreen() {
    if (widget.fullscreen?.active ?? false) return;
    // What was typed in the panel over the camera.
    _syncInput();
    _refocus();
  }

  @override
  void dispose() {
    _pastes?.cancel();
    _liveNotices?.cancel();
    widget.fullscreen?.removeListener(_onFullscreen);
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

  /// Physical keyboard: Enter sends, Shift+Enter starts a new line. On
  /// Windows, Ctrl+V also pastes pictures.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.keyV &&
        keyboard.isControlPressed &&
        !keyboard.isShiftPressed &&
        !keyboard.isAltPressed &&
        _clipboard.readsOnPasteKey) {
      if (event is KeyDownEvent) _paste();
      return KeyEventResult.handled;
    }
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

  /// Inserts [inserted] (an emoji, pasted text) at the cursor, or replaces
  /// the selection.
  void _insertText(String inserted) {
    final value = _input.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final text = value.text.replaceRange(
      selection.start,
      selection.end,
      inserted,
    );
    if (text.length > kMaxTextLength) return _refocus();
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
        offset: selection.start + inserted.length,
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
    final navigator = Navigator.of(context);
    final List<Uint8List> picked;
    setState(() => _preparingImage = true);
    try {
      final camera = source == ImageSource.camera
          ? widget.createCamera()
          : null;
      picked = camera == null
          ? await widget.pickImage(source)
          : [
              ?await navigator.push<Uint8List>(
                MaterialPageRoute(
                  fullscreenDialog: true,
                  builder: (_) => CameraScreen(capture: camera),
                ),
              ),
            ];
    } catch (e) {
      if (mounted) {
        setState(() => _preparingImage = false);
        _snack(
          _failure(
            source == ImageSource.camera
                ? "Impossible d'utiliser l'appareil photo"
                : "Impossible d'envoyer l'image",
            e,
          ),
        );
      }
      return _refocus();
    }
    await _sendImages(picked);
  }

  Future<void> _sendImages(List<Uint8List> pictures) =>
      _sendAttachments(Attachments(images: pictures));

  /// Encodes what was chosen or pasted, then offers it all at once: the peer
  /// answers with a single validation. Only the first answers the reply in
  /// progress.
  Future<void> _sendAttachments(Attachments attachments) async {
    if (!mounted) return;
    if (attachments.isEmpty) {
      // Cancelled: the image button may be waiting for this.
      setState(() => _preparingImage = false);
      return _refocus();
    }
    final messenger = ScaffoldMessenger.of(context);
    final replyTo = _replyTo;
    final before = _session.messages.length;
    setState(() => _preparingImage = true);
    String? notice;
    try {
      notice = await sendAttachments(
        _session,
        attachments,
        encode: widget.encodeImage,
        replyTo: replyTo,
      );
      if (mounted && _session.messages.length > before) {
        setState(() => _replyTo = null);
      }
    } finally {
      if (mounted) setState(() => _preparingImage = false);
      _refocus();
    }
    if (notice != null) {
      messenger.showSnackBar(SnackBar(content: Text(notice)));
    }
  }

  /// Shows the cause: a remote friend can then report it.
  static String _failure(String what, Object error) {
    final cause = error.toString().split('\n').first;
    final short = cause.length > 160 ? '${cause.substring(0, 160)}…' : cause;
    return '$what ($short).';
  }

  /// Ctrl+V on Windows: the pictures and files on the clipboard, else its
  /// text.
  Future<void> _paste() async {
    final content = await _clipboard.read();
    if (!mounted || _session.peerLeft) {
      await content.discard();
      return;
    }
    if (!content.isEmpty) return _confirmPaste(content);
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty || !mounted) return;
    _insertText(text);
  }

  /// What was pasted in the browser, while this input has the focus.
  void _onPasted(Attachments content) {
    if (!mounted || !widget.active || !_focus.hasFocus) {
      content.discard();
      return;
    }
    _confirmPaste(content);
  }

  /// A picture inserted by the Android keyboard (its clipboard, a sticker).
  void _onContentInserted(KeyboardInsertedContent content) {
    final data = content.data;
    if (data == null || !content.mimeType.startsWith('image/')) return;
    _confirmPaste(Attachments(images: [data]));
  }

  /// A paste can be a mistake: what would leave is shown first.
  Future<void> _confirmPaste(Attachments content) async {
    if (_session.peerLeft || _preparingImage) {
      await content.discard();
      return;
    }
    final send = await showDialog<bool>(
      context: context,
      builder: (context) => _PasteDialog(content: content),
    );
    if (send ?? false) {
      await _sendAttachments(content);
    } else {
      await content.discard();
      _refocus();
    }
  }

  /// Offers files: the peer must accept them before anything is sent.
  Future<void> _chooseFile() async {
    final List<ChosenFile> picked;
    try {
      picked = await widget.pickFile();
    } catch (e) {
      final cause = e.toString().split('\n').first;
      if (mounted) _snack('Impossible de choisir un fichier ($cause).');
      return _refocus();
    }
    if (!mounted) return;
    await _sendAttachments(Attachments(files: picked));
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

  /// The bubbles, what was sent together answered once and its files in one
  /// bubble.
  List<Widget> _timelineWidgets() {
    final done = <String>{};
    return [
      for (final entry in _session.messages)
        ...switch (entry.group) {
          null => [_bubble(entry)],
          final group => _groupMember(entry, group, done),
        },
    ];
  }

  List<Widget> _groupMember(ChatEntry entry, String group, Set<String> done) {
    final members = _session.inGroup(group);
    final files = members.whereType<ChatFile>().toList();
    final first = done.add(group);
    return [
      if (first && !entry.fromMe) ?_groupBar(group, members, files),
      // Several files share a bubble, at the place of the first one.
      if (entry is! ChatFile || files.length == 1)
        _bubble(entry, grouped: true)
      else if (entry == files.first)
        _bubble(entry, grouped: true, groupFiles: files),
    ];
  }

  /// What is left to answer in this group: nothing once it was answered.
  Widget? _groupBar(
    String group,
    List<ChatEntry> members,
    List<ChatFile> files,
  ) {
    final waiting = files
        .where((f) => f.status == FileStatus.awaiting)
        .toList();
    final blurred = members
        .whereType<ChatImage>()
        .where((i) => i.status == ImageStatus.blurred)
        .length;
    if (waiting.isEmpty && blurred == 0) return null;
    final live = !_session.peerLeft;
    final size = waiting.fold(0, (total, f) => total + f.size);
    return GroupOfferBar(
      group: group,
      label: [
        describeAttachments(blurred, waiting.length),
        if (waiting.isNotEmpty) '(${formatFileSize(size)})',
      ].join(' '),
      onAccept: live
          ? () {
              _session.acceptGroup(group);
              _refocus();
            }
          : null,
      onDecline: waiting.isEmpty
          ? null
          : () {
              _session.cancelGroup(group);
              _refocus();
            },
    );
  }

  Widget _bubble(
    ChatEntry entry, {
    bool grouped = false,
    List<ChatFile>? groupFiles,
  }) {
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
        ChatFile() when groupFiles != null => FileGroupBubble(
          files: groupFiles,
          onCancel: (file) {
            _session.cancelFile(file);
            _refocus();
          },
          onOpen: _openSaved,
          onShowInFolder: (file) => _openSaved(file, folder: true),
          header: _quoteFor(entry, onBrand: entry.fromMe),
        ),
        ChatFile() => FileBubble(
          file: entry,
          grouped: grouped,
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

  /// The safety code: the same on both screens unless the relay sits in the
  /// middle of the key exchange.
  Future<void> _verifyEncryption() async {
    final code = await widget.connection.safetyCode(_session);
    if (!mounted) return;
    final name = widget.contacts.label(_session.peer);
    final theme = Theme.of(context);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('encryption-dialog'),
        icon: const Icon(Icons.lock_outline_rounded),
        title: const Text('Chiffrement de bout en bout'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              code == null
                  ? 'Échange des clés en cours…'
                  : 'Comparez ce code avec celui de $name, de vive voix ou '
                        'par un autre moyen. S’il est identique, personne, pas '
                        'même le serveur, ne peut lire cette conversation.',
            ),
            if (code != null) ...[
              const SizedBox(height: 16),
              SelectableText(
                code,
                key: const Key('safety-code'),
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Le code change à chaque conversation.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fermer'),
          ),
        ],
      ),
    );
    _refocus();
  }

  /// Ends the conversation and ignores the peer's requests from now on.
  Future<void> _blockPeer() async {
    final peer = _session.peer;
    final name = widget.contacts.label(peer);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Bloquer $name ?'),
        content: const Text(
          'La conversation se ferme et ses demandes seront ignorées, sans '
          'qu’il le sache. Vous pourrez le débloquer dans les réglages.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            key: const Key('confirm-block'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Bloquer'),
          ),
        ],
      ),
    );
    if (confirmed != true) return _refocus();
    await widget.contacts.block(peer);
    _close();
  }

  void _toggleFullscreen() => widget.fullscreen?.toggle(_session);

  /// See the peer's camera, or stop.
  void _toggleLive() {
    final live = _session.live;
    if (live.watch == LiveWatch.idle) {
      live.request();
    } else {
      live.stopWatching();
    }
    _refocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Rebuilt without the screen: only the shortcuts depend on the camera.
    return ListenableBuilder(
      listenable: _session.timeline,
      builder: (context, child) => CallbackShortcuts(
        bindings: {
          if (_session.live.watch == LiveWatch.watching) ...{
            const SingleActivator(LogicalKeyboardKey.f11): _toggleFullscreen,
            const SingleActivator(
              LogicalKeyboardKey.keyF,
              control: true,
              alt: true,
            ): _toggleFullscreen,
          },
        },
        child: child!,
      ),
      child: _screen(context, theme),
    );
  }

  Widget _screen(BuildContext context, ThemeData theme) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: ListenableBuilder(
          // Not the session: the peer's typing would rebuild this each time.
          listenable: Listenable.merge([
            widget.contacts,
            _session.timeline,
            _privacy,
          ]),
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
            listenable: _session.timeline,
            builder: (context, _) {
              final watch = _session.live.watch;
              return IconButton(
                key: const Key('live-toggle'),
                tooltip: switch (watch) {
                  LiveWatch.idle => 'Demander à voir sa caméra',
                  LiveWatch.requesting => 'Annuler la demande',
                  LiveWatch.watching => 'Fermer la vue',
                },
                icon: Icon(switch (watch) {
                  LiveWatch.idle => Icons.videocam_outlined,
                  LiveWatch.requesting => Icons.hourglass_top_rounded,
                  LiveWatch.watching => Icons.videocam_off_outlined,
                }),
                onPressed: _session.peerLeft ? null : _toggleLive,
              );
            },
          ),
          if (widget.overlay case final overlay?)
            IconButton(
              key: const Key('enter-overlay'),
              tooltip: 'Superposer aux autres fenêtres (Ctrl+Alt+D)',
              icon: const Icon(Icons.picture_in_picture_alt_rounded),
              onPressed: () => overlay.enter(_session),
            ),
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
            listenable: _session.timeline,
            builder: (context, _) => IconButton(
              key: const Key('close-session'),
              tooltip: _session.peerLeft
                  ? 'Fermer la conversation'
                  : 'Quitter la conversation',
              icon: const Icon(Icons.logout_rounded),
              onPressed: _close,
            ),
          ),
          PopupMenuButton<VoidCallback>(
            key: const Key('chat-menu'),
            tooltip: 'Plus',
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (action) => action(),
            itemBuilder: (_) => [
              PopupMenuItem(
                key: const Key('verify-encryption'),
                value: _verifyEncryption,
                child: const ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.lock_outline_rounded),
                  title: Text('Vérifier le chiffrement'),
                ),
              ),
              PopupMenuItem(
                key: const Key('block-peer'),
                value: _blockPeer,
                child: const ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.block_rounded),
                  title: Text('Bloquer'),
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListenableBuilder(
        // The peer's typing rebuilds only its own zone below: every bubble
        // would otherwise be rebuilt at each of their keystrokes.
        listenable: _session.timeline,
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
              if (_session.reconnecting) _reconnectingBar(context),
              if (_session.live.share == LiveShare.asked) _liveRequestBanner(),
              if (_session.live.share == LiveShare.starting ||
                  _session.live.share == LiveShare.sharing)
                _sharingBar(context),
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
                              children: _timelineWidgets(),
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
              ListenableBuilder(
                listenable: _session.typing,
                builder: (context, _) => _liveDraft(context),
              ),
              // The view itself goes to the sidebar, when there is one.
              if (widget.active &&
                  (_session.live.watch == LiveWatch.requesting ||
                      (_session.live.watch == LiveWatch.watching &&
                          !LiveViewInSidebar.of(context))))
                _liveZone(context),
              // Taps here keep the input focused (no "tap outside").
              TextFieldTapRegion(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_replyTo != null && !_session.peerLeft)
                      _replyBar(context),
                    _composer(context),
                    if (_showEmojis && !_session.peerLeft && !_recording)
                      ExcludeFocus(child: EmojiPanel(onSelected: _insertText)),
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

  /// The peer asks for my camera: it stays off unless I agree, here, each
  /// time. Buttons rather than a dialog: Enter, while typing, answers nothing.
  Widget _liveRequestBanner() {
    final name = widget.contacts.label(_session.peer);
    return MaterialBanner(
      key: const Key('live-request-banner'),
      leading: const Icon(Icons.videocam_rounded),
      content: Text(
        '$name demande à voir votre caméra. Elle reste éteinte si vous '
        'refusez.',
      ),
      actions: [
        TextButton(
          key: const Key('live-deny'),
          onPressed: () {
            _session.live.declineRequest();
            _refocus();
          },
          child: const Text('Refuser'),
        ),
        FilledButton(
          key: const Key('live-allow'),
          onPressed: () {
            _session.live.acceptRequest();
            _refocus();
          },
          child: const Text('Autoriser'),
        ),
      ],
    );
  }

  /// As long as my camera is on, it shows, with what the peer sees.
  Widget _sharingBar(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = widget.contacts.label(_session.peer);
    return Material(
      key: const Key('live-sharing-bar'),
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            const _RecordingDot(),
            const SizedBox(width: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 48,
                height: 36,
                child: LiveSurface(image: _session.live.ownImage),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '$name voit votre caméra',
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onErrorContainer,
                ),
              ),
            ),
            TextButton(
              key: const Key('live-stop-sharing'),
              onPressed: () {
                _session.live.stopSharing();
                _refocus();
              },
              child: const Text('Arrêter'),
            ),
          ],
        ),
      ),
    );
  }

  /// A connection dropped, mine or the peer's: the conversation waits for it
  /// (what is written leaves once it is back).
  Widget _reconnectingBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = _session.meAway
        ? 'Connexion perdue : reconnexion… Vos messages partiront à son retour.'
        : '${widget.contacts.label(_session.peer)} a perdu la connexion : '
              'en attente de son retour…';
    return Container(
      key: const Key('reconnecting-bar'),
      width: double.infinity,
      color: scheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: scheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The peer's camera above the input, half as wide. A tap (or F11) puts it
  /// in full screen.
  Widget _liveZone(BuildContext context) {
    final live = _session.live;
    if (live.watch == LiveWatch.requesting) {
      final name = widget.contacts.label(_session.peer);
      return Padding(
        key: const Key('live-waiting'),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          children: [
            const SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'En attente de l’accord de $name…',
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // The field: the width less the margins and the send button.
        final field = constraints.maxWidth - 12 - 12 - 8 - 52;
        return Padding(
          padding: const EdgeInsets.only(left: 12, top: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: ValueListenableBuilder(
              valueListenable: live.image,
              builder: (context, image, child) {
                final maxHeight = MediaQuery.sizeOf(context).height * 0.4;
                final width = field / 2;
                final height = width / liveAspectRatio(image);
                return SizedBox(
                  width: height > maxHeight
                      ? maxHeight * liveAspectRatio(image)
                      : width,
                  height: height > maxHeight ? maxHeight : height,
                  child: child,
                );
              },
              child: _liveView(live),
            ),
          ),
        );
      },
    );
  }

  Widget _liveView(LiveLink live) => LiveViewCard(
    image: live.image,
    onFullscreen: widget.fullscreen == null ? null : _toggleFullscreen,
    onClose: _toggleLive,
  );

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
            contentInsertionConfiguration: ContentInsertionConfiguration(
              onContentInserted: _onContentInserted,
            ),
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

/// What was pasted, sent only once confirmed.
class _PasteDialog extends StatelessWidget {
  const _PasteDialog({required this.content});

  final Attachments content;

  String get _title {
    final images = content.images.take(kMaxImagesPerSend).toList();
    if (content.files.isEmpty && images.length == 1) return 'Envoyer l’image ?';
    return 'Envoyer ${describeAttachments(images.length, content.files.length)} ?';
  }

  @override
  Widget build(BuildContext context) {
    final images = content.images.take(kMaxImagesPerSend).toList();
    final single = images.length == 1 && content.files.isEmpty;
    return AlertDialog(
      key: const Key('paste-dialog'),
      title: Text(_title),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (single)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 280),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(images.single, fit: BoxFit.contain),
                  ),
                )
              else if (images.isNotEmpty)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final image in images)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.memory(
                          image,
                          width: 80,
                          height: 80,
                          fit: BoxFit.cover,
                          cacheWidth: 160,
                        ),
                      ),
                  ],
                ),
              for (final file in content.files)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.insert_drive_file_rounded),
                  title: Text(file.name, overflow: TextOverflow.ellipsis),
                  subtitle: Text(formatFileSize(file.size)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          key: const Key('paste-send'),
          autofocus: true,
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Envoyer'),
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
