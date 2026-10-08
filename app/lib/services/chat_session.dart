import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/foundation.dart';

import 'file_storage.dart';
import 'image_codec.dart';

/// One bubble of the conversation: a text, an image, a voice message or a
/// file.
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

enum FileStatus {
  /// Offered: the receiver has not answered yet.
  awaiting,

  /// Accepted, chunks are flowing.
  transferring,

  /// Saved on the receiver's disk.
  done,

  /// The receiver refused it.
  declined,

  /// Stopped by one side, or the conversation ended.
  cancelled,

  /// A read or write error ([ChatFile.error]).
  failed,
}

/// A file sent directly to the peer, after their confirmation.
class ChatFile extends ChatEntry {
  ChatFile({
    required super.id,
    required this.name,
    required this.size,
    required super.fromMe,
    super.replyTo,
  });

  /// Sender's name (sanitized); see [saved] for the name on disk.
  final String name;
  final int size;
  FileStatus status = FileStatus.awaiting;

  /// Bytes written on the receiver's disk.
  int transferred = 0;

  /// Receiver: where the file was saved, once [FileStatus.done].
  SavedFile? saved;

  /// Why it [FileStatus.failed], in French.
  String? error;

  bool get active =>
      status == FileStatus.awaiting || status == FileStatus.transferring;

  double get progress => size == 0 ? 1 : transferred / size;
}

/// Sender side of a file transfer.
class _Upload {
  _Upload(this.source) : transfer = OutgoingTransfer(source.size);
  final ChosenFile source;
  final OutgoingTransfer transfer;

  /// Reads happen one after the other, in chunk order.
  Future<void> chain = Future.value();
}

/// Receiver side of a file transfer.
class _Download {
  _Download(int size) : transfer = IncomingTransfer(size);
  final IncomingTransfer transfer;
  FileSink? sink;
  int written = 0;

  /// Writes happen one after the other, in chunk order.
  Future<void> chain = Future.value();
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
    FileStorage? files,
  }) : _send = send,
       _random = random ?? Random.secure(),
       _files = files,
       _sender = DraftSender(sid);

  final String sid;
  final String peer;
  final void Function(Frame frame) _send;
  final Random _random;
  FileStorage? _files;
  final Map<String, _Upload> _uploads = {};
  final Map<String, _Download> _downloads = {};
  bool _disposed = false;
  final DraftSender _sender;
  final DraftState _remote = DraftState();
  final List<ChatEntry> _entries = [];
  final Map<String, ChatEntry> _byId = {};
  Timer? _flushTimer;
  bool _peerLeft = false;
  bool _viewing = false;
  int _unread = 0;

  List<ChatEntry> get messages => List.unmodifiable(_entries);

  /// Whether this conversation is the one on screen.
  bool get viewing => _viewing;
  set viewing(bool value) {
    if (_viewing == value) return;
    _viewing = value;
    if (value) _unread = 0;
    notifyListeners();
  }

  /// Peer bubbles received while this conversation was not on screen.
  int get unread => _unread;

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

  /// Offers [file] to the peer; nothing else leaves until they accept.
  /// Returns null if the conversation ended or the file is too large.
  ChatFile? sendFile(ChosenFile file, {ChatEntry? replyTo}) {
    if (_peerLeft || file.size < 0 || file.size > kMaxFileBytes) return null;
    final entry = ChatFile(
      id: _newId(),
      name: FileNames.sanitize(file.name),
      size: file.size,
      fromMe: true,
      replyTo: _known(replyTo?.id),
    );
    _uploads[entry.id] = _Upload(file);
    _add(entry);
    _send(
      FileOfferFrame(
        sid: sid,
        fid: entry.id,
        name: entry.name,
        size: entry.size,
        reply: entry.replyTo,
      ),
    );
    notifyListeners();
    return entry;
  }

  /// Receiver accepts [file]: it is written to the downloads as it comes.
  Future<void> acceptFile(ChatFile file) async {
    if (file.fromMe || file.status != FileStatus.awaiting || _peerLeft) return;
    if (_byId[file.id] != file) return;
    file.status = FileStatus.transferring;
    final download = _downloads[file.id] = _Download(file.size);
    notifyListeners();
    final FileSink sink;
    try {
      sink = await (_files ??= platformFileStorage()).create(
        file.name,
        file.size,
      );
    } catch (e) {
      return _fail(file, _describe(e));
    }
    if (file.status != FileStatus.transferring || _disposed) {
      // Cancelled meanwhile.
      await sink.abort();
      return;
    }
    download.sink = sink;
    _send(FileAcceptFrame(sid: sid, fid: file.id));
    // Nothing will come for an empty file: finish it now.
    if (file.size == 0) _queueWrite(file, download, null);
  }

  /// Receiver refuses [file], or either side stops its transfer.
  void cancelFile(ChatFile file) {
    if (!file.active || _byId[file.id] != file) return;
    file.status = !file.fromMe && file.status == FileStatus.awaiting
        ? FileStatus.declined
        : FileStatus.cancelled;
    if (!_peerLeft) _send(FileCancelFrame(sid: sid, fid: file.id));
    _release(file);
    notifyListeners();
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
      case FileOfferFrame(:final fid, :final size):
        if (_byId.containsKey(fid)) return;
        _add(
          ChatFile(
            id: fid,
            name: FileNames.sanitize(frame.name),
            size: size,
            fromMe: false,
            replyTo: _known(frame.reply),
          ),
        );
      case FileAcceptFrame(:final fid):
        final file = _byId[fid];
        final upload = _uploads[fid];
        if (file is! ChatFile || upload == null) return;
        if (file.status != FileStatus.awaiting) return;
        file.status = FileStatus.transferring;
        _pump(file, upload);
      case FileChunkFrame(:final fid, :final index):
        final file = _byId[fid];
        final download = _downloads[fid];
        // Only what we accepted, in order, with the announced size.
        if (file is! ChatFile || download?.sink == null) return;
        if (file.status != FileStatus.transferring) return;
        final bytes = _decode(frame.data);
        if (bytes == null || !download!.transfer.accept(index, bytes.length)) {
          return _fail(file, 'Données reçues invalides.');
        }
        _queueWrite(file, download, bytes);
        return;
      case FileAckFrame(:final fid, :final count):
        final file = _byId[fid];
        final upload = _uploads[fid];
        if (file is! ChatFile || upload == null) return;
        if (file.status != FileStatus.transferring) return;
        if (!upload.transfer.ack(count)) {
          return _fail(file, 'Accusé de réception invalide.');
        }
        file.transferred = upload.transfer.ackedBytes;
        if (upload.transfer.done) {
          file.status = FileStatus.done;
          _release(file);
        } else {
          _pump(file, upload);
        }
      case FileCancelFrame(:final fid):
        final file = _byId[fid];
        if (file is! ChatFile || !file.active) return;
        file.status = file.fromMe && file.status == FileStatus.awaiting
            ? FileStatus.declined
            : FileStatus.cancelled;
        _release(file);
      case ReactionFrame(:final ref, :final emoji):
        final entry = _byId[ref];
        // The peer can only react to my bubbles.
        if (entry == null || !entry.fromMe) return;
        entry.reaction = emoji.isEmpty ? null : emoji;
      case KeyOfferFrame() || SealedFrame():
        // Encryption is ConnectionService's: they never get here.
        return;
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
    _stopTransfers();
    notifyListeners();
  }

  void _stopTransfers() {
    for (final file in _entries.whereType<ChatFile>()) {
      if (!file.active) continue;
      file.status = FileStatus.cancelled;
      _release(file);
    }
  }

  /// Sends the next chunks the window allows, read in order.
  void _pump(ChatFile file, _Upload upload) {
    for (
      var index = upload.transfer.nextChunk();
      index != null;
      index = upload.transfer.nextChunk()
    ) {
      final chunk = index;
      upload.chain = upload.chain
          .then((_) async {
            if (file.status != FileStatus.transferring) return;
            final length = FileChunks.length(file.size, chunk);
            final bytes = await upload.source.read(
              FileChunks.offset(chunk),
              length,
            );
            if (file.status != FileStatus.transferring) return;
            if (bytes.length != length) {
              throw const FileStorageException(
                "Le fichier a changé pendant l'envoi.",
              );
            }
            _send(
              FileChunkFrame(
                sid: sid,
                fid: file.id,
                index: chunk,
                data: base64Encode(bytes),
              ),
            );
          })
          .catchError((Object e) {
            _fail(file, _describe(e));
          });
    }
  }

  /// Writes [bytes] after the previous chunks, then acknowledges; the last
  /// one (or none, for an empty file) finishes the file.
  void _queueWrite(ChatFile file, _Download download, Uint8List? bytes) {
    download.chain = download.chain
        .then((_) async {
          final sink = download.sink!;
          if (file.status != FileStatus.transferring) return;
          if (bytes != null) {
            await sink.write(bytes);
            download.written++;
            file.transferred += bytes.length;
          }
          if (file.status != FileStatus.transferring) return;
          if (download.written == download.transfer.chunkCount) {
            final saved = await sink.close();
            _downloads.remove(file.id);
            file
              ..saved = saved
              ..status = FileStatus.done;
          }
          _send(FileAckFrame(sid: sid, fid: file.id, count: download.written));
          _notify();
        })
        .catchError((Object e) {
          _fail(file, _describe(e));
        });
  }

  /// Stops a transfer after an error, telling the peer.
  void _fail(ChatFile file, String message) {
    if (!file.active) return;
    file
      ..status = FileStatus.failed
      ..error = message;
    if (!_peerLeft && !_disposed) {
      _send(FileCancelFrame(sid: sid, fid: file.id));
    }
    _release(file);
    _notify();
  }

  /// Frees what a stopped transfer holds; a partial download is deleted.
  void _release(ChatFile file) {
    final upload = _uploads.remove(file.id);
    if (upload != null) {
      upload.chain = upload.chain
          .catchError((_) {})
          .then((_) => upload.source.close())
          .catchError((_) {});
    }
    final download = _downloads.remove(file.id);
    if (download != null) {
      download.chain = download.chain
          .catchError((_) {})
          .then((_) => download.sink?.abort())
          .catchError((_) {});
    }
  }

  static String _describe(Object error) => error is FileStorageException
      ? error.message
      : error.toString().split('\n').first;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  String _newId() => EntryId.generate(_random);

  void _add(ChatEntry entry) {
    _byId[entry.id] = entry;
    _entries.add(entry);
    if (!entry.fromMe && !_viewing) _unread++;
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
    _disposed = true;
    _cancelFlush();
    _stopTransfers();
    super.dispose();
  }
}
