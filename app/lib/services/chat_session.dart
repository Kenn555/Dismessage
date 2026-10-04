import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/foundation.dart';

import 'image_codec.dart';

/// One bubble of the conversation: a text, an image or a voice message.
sealed class ChatEntry {
  ChatEntry({required this.id, required this.fromMe, this.replyTo})
    : at = DateTime.now();

  /// [EntryId] shared by both peers, to react or reply.
  final String id;
  final bool fromMe;
  final DateTime at;

  /// ID of the bubble this one answers.
  final String? replyTo;

  /// The single reaction on this bubble: the peer's on mine, mine on theirs.
  String? reaction;
}

class ChatMessage extends ChatEntry {
  ChatMessage({
    required super.id,
    required this.text,
    required super.fromMe,
    super.replyTo,
  });
  final String text;
}

enum ImageStatus {
  /// Receiver: only the blurred preview, waiting for a tap.
  blurred,

  /// Receiver: tapped, waiting for the full image.
  loading,

  /// Receiver: full image shown. Sender: the peer opened it.
  opened,

  /// Sender: the peer has not opened it yet.
  sent,

  /// Receiver: the sender left before the image could be fetched.
  unavailable,
}

class ChatImage extends ChatEntry {
  ChatImage({
    required super.id,
    required this.width,
    required this.height,
    required this.preview,
    required this.status,
    required super.fromMe,
    super.replyTo,
    this.bytes,
  });

  final int width;
  final int height;
  final Uint8List preview;
  ImageStatus status;

  /// Full JPEG: always present for the sender, only once opened otherwise.
  Uint8List? bytes;
}

class ChatVoice extends ChatEntry {
  ChatVoice({
    required super.id,
    required this.bytes,
    required this.mime,
    required this.duration,
    required super.fromMe,
    super.replyTo,
  });
  final Uint8List bytes;
  final String mime;
  final Duration duration;
}

/// A recorded voice message, ready to be sent.
class RecordedVoice {
  const RecordedVoice({
    required this.bytes,
    required this.mime,
    required this.duration,
  });
  final Uint8List bytes;
  final String mime;
  final Duration duration;
}

/// One live conversation with a peer. Nothing is persisted.
class ChatSession extends ChangeNotifier {
  ChatSession({
    required this.sid,
    required this.peer,
    required void Function(Frame frame) send,
    Random? random,
  }) : _send = send,
       _random = random ?? Random.secure(),
       _sender = DraftSender(sid);

  final String sid;
  final String peer;
  final void Function(Frame frame) _send;
  final Random _random;
  final DraftSender _sender;
  final DraftState _remote = DraftState();
  final List<ChatEntry> _entries = [];
  final Map<String, ChatEntry> _byId = {};
  Timer? _flushTimer;
  bool _peerLeft = false;

  List<ChatEntry> get messages => List.unmodifiable(_entries);

  /// The bubble with this ID, if any.
  ChatEntry? byId(String id) => _byId[id];

  /// What the peer is typing right now.
  String get remoteDraft => _remote.text;

  bool get peerLeft => _peerLeft;

  /// Called on every local keystroke; frames are batched every
  /// [kDraftBatchMs].
  void updateDraft(String text) {
    if (_peerLeft) return;
    _sender.update(text);
    _flushTimer ??= Timer(const Duration(milliseconds: kDraftBatchMs), _flush);
  }

  /// Sends the current draft as a message, answering [replyTo] if given.
  /// Returns false if blank.
  bool sendMessage({ChatEntry? replyTo}) {
    if (_peerLeft) return false;
    _cancelFlush();
    final frame = _sender.commit(mid: _newId(), reply: _known(replyTo?.id));
    if (frame == null) return false;
    _send(frame);
    _add(
      ChatMessage(
        id: frame.mid,
        text: frame.text,
        fromMe: true,
        replyTo: frame.reply,
      ),
    );
    notifyListeners();
    return true;
  }

  /// Sends [text] typed outside the chat (a notification's reply field).
  /// The draft being typed in the chat, if any, is kept and streamed again.
  bool sendQuickReply(String text) {
    if (_peerLeft) return false;
    _cancelFlush();
    final draft = _sender.text;
    final frame = _sender.commitText(text.trim(), mid: _newId());
    if (frame == null) return false;
    _send(frame);
    _add(ChatMessage(id: frame.mid, text: frame.text, fromMe: true));
    if (draft.isNotEmpty) {
      _sender.update(draft);
      _flush();
    }
    notifyListeners();
    return true;
  }

  /// Offers an image: only its blurred preview leaves now; the full image
  /// is sent when the peer opens it.
  ChatImage? sendImage(EncodedImage image, {ChatEntry? replyTo}) {
    if (_peerLeft) return null;
    final entry = ChatImage(
      id: _newId(),
      width: image.width,
      height: image.height,
      preview: image.preview,
      bytes: image.bytes,
      status: ImageStatus.sent,
      fromMe: true,
      replyTo: _known(replyTo?.id),
    );
    _add(entry);
    _send(
      ImageOfferFrame(
        sid: sid,
        img: entry.id,
        width: entry.width,
        height: entry.height,
        preview: base64Encode(entry.preview),
        reply: entry.replyTo,
      ),
    );
    notifyListeners();
    return entry;
  }

  /// Sends a recorded voice message. Returns null if empty or too large.
  ChatVoice? sendVoice(RecordedVoice voice, {ChatEntry? replyTo}) {
    if (_peerLeft) return null;
    if (voice.bytes.isEmpty || voice.bytes.length > kMaxVoiceBytes) return null;
    final ms = voice.duration.inMilliseconds.clamp(1, kMaxVoiceSeconds * 1000);
    final entry = ChatVoice(
      id: _newId(),
      bytes: voice.bytes,
      mime: voice.mime,
      duration: Duration(milliseconds: ms),
      fromMe: true,
      replyTo: _known(replyTo?.id),
    );
    _add(entry);
    _send(
      VoiceFrame(
        sid: sid,
        mid: entry.id,
        durationMs: ms,
        mime: entry.mime,
        data: base64Encode(entry.bytes),
        reply: entry.replyTo,
      ),
    );
    notifyListeners();
    return entry;
  }

  /// Reacts to a peer bubble; the same emoji again removes the reaction.
  void react(ChatEntry entry, String emoji) {
    if (_peerLeft || entry.fromMe || _byId[entry.id] != entry) return;
    final next = entry.reaction == emoji ? null : emoji;
    entry.reaction = next;
    _send(ReactionFrame(sid: sid, ref: entry.id, emoji: next ?? ''));
    notifyListeners();
  }

  /// Receiver tapped a blurred image: ask the sender for it.
  void openImage(ChatImage image) {
    if (image.fromMe || image.status != ImageStatus.blurred) return;
    if (_peerLeft) {
      image.status = ImageStatus.unavailable;
    } else {
      image.status = ImageStatus.loading;
      _send(ImageRequestFrame(sid: sid, img: image.id));
    }
    notifyListeners();
  }

  void receive(RelayedFrame frame) {
    switch (frame) {
      case DraftOpsFrame(:final seq, :final ops):
        if (_remote.applyOps(seq, ops) == DraftUpdate.needsResync) {
          _send(DraftResyncFrame(sid: sid));
        }
      case DraftSnapshotFrame(:final seq, :final text):
        _remote.applySnapshot(seq, text);
      case DraftClearFrame(:final seq):
        _remote.clear(seq);
      case MessageCommitFrame(:final seq, :final text, :final mid):
        final committed = _remote.commit(seq, text);
        if (committed != null && !_byId.containsKey(mid)) {
          _add(
            ChatMessage(
              id: mid,
              text: committed,
              fromMe: false,
              replyTo: _known(frame.reply),
            ),
          );
        }
      case DraftResyncFrame():
        _sender.requestSnapshot();
        _flush();
      case ImageOfferFrame(:final img, :final width, :final height):
        if (_byId.containsKey(img)) return;
        final preview = _decode(frame.preview);
        if (preview == null) return;
        _add(
          ChatImage(
            id: img,
            width: width,
            height: height,
            preview: preview,
            status: ImageStatus.blurred,
            fromMe: false,
            replyTo: _known(frame.reply),
          ),
        );
      case ImageRequestFrame(:final img):
        final entry = _byId[img];
        if (entry is! ChatImage || !entry.fromMe) return;
        final bytes = entry.bytes;
        if (bytes == null) return;
        _send(ImageDataFrame(sid: sid, img: img, data: base64Encode(bytes)));
        entry.status = ImageStatus.opened;
      case ImageDataFrame(:final img, :final data):
        final entry = _byId[img];
        // Only accept what we asked for.
        if (entry is! ChatImage || entry.fromMe) return;
        if (entry.status != ImageStatus.loading) return;
        final bytes = _decode(data);
        if (bytes == null) return;
        entry
          ..bytes = bytes
          ..status = ImageStatus.opened;
      case VoiceFrame(:final mid, :final durationMs, :final mime):
        if (_byId.containsKey(mid)) return;
        final bytes = _decode(frame.data);
        if (bytes == null || bytes.isEmpty) return;
        _add(
          ChatVoice(
            id: mid,
            bytes: bytes,
            mime: mime,
            duration: Duration(milliseconds: durationMs),
            fromMe: false,
            replyTo: _known(frame.reply),
          ),
        );
      case ReactionFrame(:final ref, :final emoji):
        final entry = _byId[ref];
        // The peer can only react to my bubbles.
        if (entry == null || !entry.fromMe) return;
        entry.reaction = emoji.isEmpty ? null : emoji;
    }
    notifyListeners();
  }

  void markPeerLeft() {
    if (_peerLeft) return;
    _peerLeft = true;
    _cancelFlush();
    _remote.clear(_remote.lastSeq + 1);
    for (final image in _entries.whereType<ChatImage>()) {
      if (image.status == ImageStatus.loading) {
        image.status = ImageStatus.unavailable;
      }
    }
    notifyListeners();
  }

  String _newId() => EntryId.generate(_random);

  void _add(ChatEntry entry) {
    _byId[entry.id] = entry;
    _entries.add(entry);
  }

  /// Keeps a reply reference only if it points to an existing bubble.
  String? _known(String? id) => id != null && _byId.containsKey(id) ? id : null;

  static Uint8List? _decode(String data) {
    try {
      return base64Decode(data);
    } on FormatException {
      return null;
    }
  }

  void _flush() {
    _flushTimer = null;
    final frame = _sender.flush();
    if (frame != null) _send(frame);
  }

  void _cancelFlush() {
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  @override
  void dispose() {
    _cancelFlush();
    super.dispose();
  }
}
