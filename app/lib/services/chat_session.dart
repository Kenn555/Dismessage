import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/foundation.dart';

import 'image_codec.dart';

/// One item of the conversation: a text message or an image.
sealed class ChatEntry {
  ChatEntry({required this.fromMe}) : at = DateTime.now();
  final bool fromMe;
  final DateTime at;
}

class ChatMessage extends ChatEntry {
  ChatMessage({required this.text, required super.fromMe});
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
    required this.id,
    required this.width,
    required this.height,
    required this.preview,
    required this.status,
    required super.fromMe,
    this.bytes,
  });

  final String id;
  final int width;
  final int height;
  final Uint8List preview;
  ImageStatus status;

  /// Full JPEG: always present for the sender, only once opened otherwise.
  Uint8List? bytes;
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
  final Map<String, ChatImage> _images = {};
  Timer? _flushTimer;
  bool _peerLeft = false;

  List<ChatEntry> get messages => List.unmodifiable(_entries);

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

  /// Sends the current draft as a message. Returns false if blank.
  bool sendMessage() {
    if (_peerLeft) return false;
    _cancelFlush();
    final frame = _sender.commit();
    if (frame == null) return false;
    _send(frame);
    _entries.add(ChatMessage(text: frame.text, fromMe: true));
    notifyListeners();
    return true;
  }

  /// Offers an image: only its blurred preview leaves now; the full image
  /// is sent when the peer opens it.
  ChatImage? sendImage(EncodedImage image) {
    if (_peerLeft) return null;
    final entry = ChatImage(
      id: _newImageId(),
      width: image.width,
      height: image.height,
      preview: image.preview,
      bytes: image.bytes,
      status: ImageStatus.sent,
      fromMe: true,
    );
    _images[entry.id] = entry;
    _entries.add(entry);
    _send(
      ImageOfferFrame(
        sid: sid,
        img: entry.id,
        width: entry.width,
        height: entry.height,
        preview: base64Encode(entry.preview),
      ),
    );
    notifyListeners();
    return entry;
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
      case MessageCommitFrame(:final seq, :final text):
        final committed = _remote.commit(seq, text);
        if (committed != null) {
          _entries.add(ChatMessage(text: committed, fromMe: false));
        }
      case DraftResyncFrame():
        _sender.requestSnapshot();
        _flush();
      case ImageOfferFrame(:final img, :final width, :final height):
        if (_images.containsKey(img)) return;
        final preview = _decode(frame.preview);
        if (preview == null) return;
        final entry = ChatImage(
          id: img,
          width: width,
          height: height,
          preview: preview,
          status: ImageStatus.blurred,
          fromMe: false,
        );
        _images[img] = entry;
        _entries.add(entry);
      case ImageRequestFrame(:final img):
        final entry = _images[img];
        final bytes = entry?.bytes;
        if (entry == null || !entry.fromMe || bytes == null) return;
        _send(ImageDataFrame(sid: sid, img: img, data: base64Encode(bytes)));
        entry.status = ImageStatus.opened;
      case ImageDataFrame(:final img, :final data):
        final entry = _images[img];
        // Only accept what we asked for.
        if (entry == null || entry.fromMe) return;
        if (entry.status != ImageStatus.loading) return;
        final bytes = _decode(data);
        if (bytes == null) return;
        entry
          ..bytes = bytes
          ..status = ImageStatus.opened;
    }
    notifyListeners();
  }

  void markPeerLeft() {
    if (_peerLeft) return;
    _peerLeft = true;
    _cancelFlush();
    _remote.clear(_remote.lastSeq + 1);
    for (final image in _images.values) {
      if (image.status == ImageStatus.loading) {
        image.status = ImageStatus.unavailable;
      }
    }
    notifyListeners();
  }

  String _newImageId() =>
      List.generate(16, (_) => _random.nextInt(16).toRadixString(16)).join();

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
