import 'dart:convert';

import 'constants.dart';
import 'dismessage_id.dart';
import 'entry_id.dart';
import 'file_transfer.dart';
import 'text_diff.dart';

/// Thrown when a frame cannot be decoded or fails validation.
class FrameFormatException extends FormatException {
  const FrameFormatException(super.message);
}

/// Base class of every message exchanged over the WebSocket.
sealed class Frame {
  const Frame();

  /// Wire type, stored in the `t` field.
  String get type;

  Map<String, Object?> fieldsToJson();

  Map<String, Object?> toJson() => {'t': type, ...fieldsToJson()};

  String encode() => jsonEncode(toJson());

  /// Decodes a raw WebSocket text message. Throws [FrameFormatException].
  static Frame decode(Object? raw) {
    if (raw is! String) throw const FrameFormatException('expected text');
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      throw const FrameFormatException('invalid JSON');
    }
    return fromJson(json);
  }

  static Frame fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const FrameFormatException('frame must be an object');
    }
    final r = _Reader(json);
    try {
      return switch (r.str('t')) {
        'register' => RegisterFrame(id: r.id('id'), secret: r.secret()),
        'registered' => RegisteredFrame(id: r.id('id')),
        'id_taken' => IdTakenFrame(id: r.id('id')),
        'release' => ReleaseFrame(id: r.id('id'), secret: r.secret()),
        'connect_request' => ConnectRequestFrame(to: r.id('to')),
        'incoming_request' => IncomingRequestFrame(from: r.id('from')),
        'connect_accept' => ConnectAcceptFrame(from: r.id('from')),
        'connect_reject' => ConnectRejectFrame(peer: r.id('peer')),
        'connect_cancel' => ConnectCancelFrame(peer: r.id('peer')),
        'session_started' => SessionStartedFrame(
          sid: r.str('sid'),
          peer: r.id('peer'),
        ),
        'peer_offline' => PeerOfflineFrame(peer: r.id('peer')),
        'peer_left' => PeerLeftFrame(sid: r.str('sid')),
        'session_leave' => SessionLeaveFrame(sid: r.str('sid')),
        'draft_ops' => DraftOpsFrame(
          sid: r.str('sid'),
          seq: r.seq(),
          ops: r.ops(),
        ),
        'draft_snapshot' => DraftSnapshotFrame(
          sid: r.str('sid'),
          seq: r.seq(),
          text: r.text(),
        ),
        'draft_resync' => DraftResyncFrame(sid: r.str('sid')),
        'draft_clear' => DraftClearFrame(sid: r.str('sid'), seq: r.seq()),
        'message_commit' => MessageCommitFrame(
          sid: r.str('sid'),
          seq: r.seq(),
          text: r.text(),
          // Versions before bubble IDs send no "mid": derive a stable one.
          mid: r.optionalEntryId('mid') ?? EntryId.legacy(r.seq()),
          reply: r.optionalEntryId('reply'),
        ),
        'image_offer' => ImageOfferFrame(
          sid: r.str('sid'),
          img: r.imageId(),
          width: r.dimension('w'),
          height: r.dimension('h'),
          preview: r.base64('preview', kMaxImagePreviewLength),
          reply: r.optionalEntryId('reply'),
        ),
        'image_request' => ImageRequestFrame(
          sid: r.str('sid'),
          img: r.imageId(),
        ),
        'image_data' => ImageDataFrame(
          sid: r.str('sid'),
          img: r.imageId(),
          data: r.base64('data', kMaxImageDataLength),
        ),
        'voice' => VoiceFrame(
          sid: r.str('sid'),
          mid: r.entryId('mid'),
          durationMs: r.durationMs(),
          mime: r.audioMime(),
          data: r.base64('data', kMaxVoiceDataLength),
          reply: r.optionalEntryId('reply'),
        ),
        'file_offer' => FileOfferFrame(
          sid: r.str('sid'),
          fid: r.entryId('fid'),
          name: r.fileName(),
          size: r.fileSize(),
          reply: r.optionalEntryId('reply'),
        ),
        'file_accept' => FileAcceptFrame(
          sid: r.str('sid'),
          fid: r.entryId('fid'),
        ),
        'file_cancel' => FileCancelFrame(
          sid: r.str('sid'),
          fid: r.entryId('fid'),
        ),
        'file_chunk' => FileChunkFrame(
          sid: r.str('sid'),
          fid: r.entryId('fid'),
          index: r.chunkIndex('i', last: FileChunks.count(kMaxFileBytes) - 1),
          data: r.base64('data', kMaxFileChunkDataLength),
        ),
        'file_ack' => FileAckFrame(
          sid: r.str('sid'),
          fid: r.entryId('fid'),
          count: r.chunkIndex('n', last: FileChunks.count(kMaxFileBytes)),
        ),
        'reaction' => ReactionFrame(
          sid: r.str('sid'),
          ref: r.entryId('ref'),
          emoji: r.emoji(),
        ),
        'presence_watch' => PresenceWatchFrame(ids: r.idList('ids')),
        'presence' => PresenceFrame(
          id: r.id('id'),
          online: r.boolean('online'),
        ),
        'error' => ErrorFrame(code: r.str('code'), message: r.str('message')),
        'ping' => const PingFrame(),
        'pong' => const PongFrame(),
        final other => throw FrameFormatException('unknown type "$other"'),
      };
    } on FrameFormatException {
      rethrow;
    } on FormatException catch (e) {
      throw FrameFormatException(e.message);
    }
  }
}

/// Frames belonging to an established chat session.
sealed class SessionFrame extends Frame {
  const SessionFrame({required this.sid});
  final String sid;
}

class RegisterFrame extends Frame {
  const RegisterFrame({required this.id, required this.secret});
  final String id;
  final String secret;
  @override
  String get type => 'register';
  @override
  Map<String, Object?> fieldsToJson() => {'id': id, 'secret': secret};
}

class RegisteredFrame extends Frame {
  const RegisteredFrame({required this.id});
  final String id;
  @override
  String get type => 'registered';
  @override
  Map<String, Object?> fieldsToJson() => {'id': id};
}

class IdTakenFrame extends Frame {
  const IdTakenFrame({required this.id});
  final String id;
  @override
  String get type => 'id_taken';
  @override
  Map<String, Object?> fieldsToJson() => {'id': id};
}

class ReleaseFrame extends Frame {
  const ReleaseFrame({required this.id, required this.secret});
  final String id;
  final String secret;
  @override
  String get type => 'release';
  @override
  Map<String, Object?> fieldsToJson() => {'id': id, 'secret': secret};
}

class ConnectRequestFrame extends Frame {
  const ConnectRequestFrame({required this.to});
  final String to;
  @override
  String get type => 'connect_request';
  @override
  Map<String, Object?> fieldsToJson() => {'to': to};
}

class IncomingRequestFrame extends Frame {
  const IncomingRequestFrame({required this.from});
  final String from;
  @override
  String get type => 'incoming_request';
  @override
  Map<String, Object?> fieldsToJson() => {'from': from};
}

class ConnectAcceptFrame extends Frame {
  const ConnectAcceptFrame({required this.from});
  final String from;
  @override
  String get type => 'connect_accept';
  @override
  Map<String, Object?> fieldsToJson() => {'from': from};
}

/// Client → server: rejects the request of [peer].
/// Server → client: [peer] rejected your request.
class ConnectRejectFrame extends Frame {
  const ConnectRejectFrame({required this.peer});
  final String peer;
  @override
  String get type => 'connect_reject';
  @override
  Map<String, Object?> fieldsToJson() => {'peer': peer};
}

/// Client → server: withdraws my pending request to [peer].
/// Server → client: the request [peer] sent you is withdrawn (cancelled,
/// timed out or requester disconnected).
class ConnectCancelFrame extends Frame {
  const ConnectCancelFrame({required this.peer});
  final String peer;
  @override
  String get type => 'connect_cancel';
  @override
  Map<String, Object?> fieldsToJson() => {'peer': peer};
}

class SessionStartedFrame extends SessionFrame {
  const SessionStartedFrame({required super.sid, required this.peer});
  final String peer;
  @override
  String get type => 'session_started';
  @override
  Map<String, Object?> fieldsToJson() => {'sid': sid, 'peer': peer};
}

class PeerOfflineFrame extends Frame {
  const PeerOfflineFrame({required this.peer});
  final String peer;
  @override
  String get type => 'peer_offline';
  @override
  Map<String, Object?> fieldsToJson() => {'peer': peer};
}

class PeerLeftFrame extends SessionFrame {
  const PeerLeftFrame({required super.sid});
  @override
  String get type => 'peer_left';
  @override
  Map<String, Object?> fieldsToJson() => {'sid': sid};
}

/// Client → server: the user closed the chat; the peer gets `peer_left`.
class SessionLeaveFrame extends SessionFrame {
  const SessionLeaveFrame({required super.sid});
  @override
  String get type => 'session_leave';
  @override
  Map<String, Object?> fieldsToJson() => {'sid': sid};
}

/// Frames relayed verbatim between the two peers of a session.
sealed class RelayedFrame extends SessionFrame {
  const RelayedFrame({required super.sid});
}

class DraftOpsFrame extends RelayedFrame {
  const DraftOpsFrame({
    required super.sid,
    required this.seq,
    required this.ops,
  });
  final int seq;
  final List<EditOp> ops;
  @override
  String get type => 'draft_ops';
  @override
  Map<String, Object?> fieldsToJson() => {
    'sid': sid,
    'seq': seq,
    'ops': [for (final op in ops) op.toJson()],
  };
}

class DraftSnapshotFrame extends RelayedFrame {
  const DraftSnapshotFrame({
    required super.sid,
    required this.seq,
    required this.text,
  });
  final int seq;
  final String text;
  @override
  String get type => 'draft_snapshot';
  @override
  Map<String, Object?> fieldsToJson() => {'sid': sid, 'seq': seq, 'text': text};
}

class DraftResyncFrame extends RelayedFrame {
  const DraftResyncFrame({required super.sid});
  @override
  String get type => 'draft_resync';
  @override
  Map<String, Object?> fieldsToJson() => {'sid': sid};
}

class DraftClearFrame extends RelayedFrame {
  const DraftClearFrame({required super.sid, required this.seq});
  final int seq;
  @override
  String get type => 'draft_clear';
  @override
  Map<String, Object?> fieldsToJson() => {'sid': sid, 'seq': seq};
}

/// The draft becomes a definitive message, identified by [mid] (see
/// [EntryId]). [reply] is the ID of the bubble it answers, if any.
class MessageCommitFrame extends RelayedFrame {
  const MessageCommitFrame({
    required super.sid,
    required this.seq,
    required this.text,
    required this.mid,
    this.reply,
  });
  final int seq;
  final String text;
  final String mid;
  final String? reply;
  @override
  String get type => 'message_commit';
  @override
  Map<String, Object?> fieldsToJson() => {
    'sid': sid,
    'seq': seq,
    'text': text,
    'mid': mid,
    'reply': ?reply,
  };
}

/// Sender → receiver: an image is available. Only a tiny, already blurred
/// [preview] (base64 JPEG) travels; the real image is sent on request.
class ImageOfferFrame extends RelayedFrame {
  const ImageOfferFrame({
    required super.sid,
    required this.img,
    required this.width,
    required this.height,
    required this.preview,
    this.reply,
  });

  /// Image ID, also its bubble ID (an [EntryId]).
  final String img;
  final int width;
  final int height;
  final String preview;
  final String? reply;
  @override
  String get type => 'image_offer';
  @override
  Map<String, Object?> fieldsToJson() => {
    'sid': sid,
    'img': img,
    'w': width,
    'h': height,
    'preview': preview,
    'reply': ?reply,
  };
}

/// Receiver → sender: the user tapped to open the image (also the
/// "opened" receipt).
class ImageRequestFrame extends RelayedFrame {
  const ImageRequestFrame({required super.sid, required this.img});
  final String img;
  @override
  String get type => 'image_request';
  @override
  Map<String, Object?> fieldsToJson() => {'sid': sid, 'img': img};
}

/// Sender → receiver: the full image (base64 JPEG).
class ImageDataFrame extends RelayedFrame {
  const ImageDataFrame({
    required super.sid,
    required this.img,
    required this.data,
  });
  final String img;
  final String data;
  @override
  String get type => 'image_data';
  @override
  Map<String, Object?> fieldsToJson() => {'sid': sid, 'img': img, 'data': data};
}

/// A recorded voice message, sent whole (base64 [data] of type [mime]).
class VoiceFrame extends RelayedFrame {
  const VoiceFrame({
    required super.sid,
    required this.mid,
    required this.durationMs,
    required this.mime,
    required this.data,
    this.reply,
  });
  final String mid;
  final int durationMs;
  final String mime;
  final String data;
  final String? reply;
  @override
  String get type => 'voice';
  @override
  Map<String, Object?> fieldsToJson() => {
    'sid': sid,
    'mid': mid,
    'ms': durationMs,
    'mime': mime,
    'data': data,
    'reply': ?reply,
  };
}

/// Sender → receiver: proposes a file. Nothing more leaves before the
/// receiver accepts it ([FileAcceptFrame]).
class FileOfferFrame extends RelayedFrame {
  const FileOfferFrame({
    required super.sid,
    required this.fid,
    required this.name,
    required this.size,
    this.reply,
  });

  /// File ID, also its bubble ID (an [EntryId]).
  final String fid;

  /// Name chosen by the sender; the receiver sanitizes it ([FileNames]).
  final String name;
  final int size;
  final String? reply;
  @override
  String get type => 'file_offer';
  @override
  Map<String, Object?> fieldsToJson() => {
    'sid': sid,
    'fid': fid,
    'name': name,
    'size': size,
    'reply': ?reply,
  };
}

/// Receiver → sender: the user accepted the file; chunks may come.
class FileAcceptFrame extends RelayedFrame {
  const FileAcceptFrame({required super.sid, required this.fid});
  final String fid;
  @override
  String get type => 'file_accept';
  @override
  Map<String, Object?> fieldsToJson() => {'sid': sid, 'fid': fid};
}

/// Either way: the receiver refused the file, or one side stopped the
/// transfer (cancelled, or an error).
class FileCancelFrame extends RelayedFrame {
  const FileCancelFrame({required super.sid, required this.fid});
  final String fid;
  @override
  String get type => 'file_cancel';
  @override
  Map<String, Object?> fieldsToJson() => {'sid': sid, 'fid': fid};
}

/// Sender → receiver: chunk [index] of the file (base64 [data], see
/// [FileChunks]).
class FileChunkFrame extends RelayedFrame {
  const FileChunkFrame({
    required super.sid,
    required this.fid,
    required this.index,
    required this.data,
  });
  final String fid;
  final int index;
  final String data;
  @override
  String get type => 'file_chunk';
  @override
  Map<String, Object?> fieldsToJson() => {
    'sid': sid,
    'fid': fid,
    'i': index,
    'data': data,
  };
}

/// Receiver → sender: the first [count] chunks are written to disk. When
/// [count] covers the whole file, it is saved.
class FileAckFrame extends RelayedFrame {
  const FileAckFrame({
    required super.sid,
    required this.fid,
    required this.count,
  });
  final String fid;
  final int count;
  @override
  String get type => 'file_ack';
  @override
  Map<String, Object?> fieldsToJson() => {'sid': sid, 'fid': fid, 'n': count};
}

/// Reacts to the bubble [ref] of the peer; an empty [emoji] removes it.
class ReactionFrame extends RelayedFrame {
  const ReactionFrame({
    required super.sid,
    required this.ref,
    required this.emoji,
  });
  final String ref;
  final String emoji;
  @override
  String get type => 'reaction';
  @override
  Map<String, Object?> fieldsToJson() => {
    'sid': sid,
    'ref': ref,
    'emoji': emoji,
  };
}

/// Client → server: the IDs whose presence I want to follow (replaces the
/// previous list). The server answers with one [PresenceFrame] per ID.
class PresenceWatchFrame extends Frame {
  const PresenceWatchFrame({required this.ids});
  final List<String> ids;
  @override
  String get type => 'presence_watch';
  @override
  Map<String, Object?> fieldsToJson() => {'ids': ids};
}

/// Server → client: a watched ID went online or offline.
class PresenceFrame extends Frame {
  const PresenceFrame({required this.id, required this.online});
  final String id;
  final bool online;
  @override
  String get type => 'presence';
  @override
  Map<String, Object?> fieldsToJson() => {'id': id, 'online': online};
}

class ErrorFrame extends Frame {
  const ErrorFrame({required this.code, required this.message});
  final String code;
  final String message;
  @override
  String get type => 'error';
  @override
  Map<String, Object?> fieldsToJson() => {'code': code, 'message': message};
}

class PingFrame extends Frame {
  const PingFrame();
  @override
  String get type => 'ping';
  @override
  Map<String, Object?> fieldsToJson() => const {};
}

class PongFrame extends Frame {
  const PongFrame();
  @override
  String get type => 'pong';
  @override
  Map<String, Object?> fieldsToJson() => const {};
}

class _Reader {
  _Reader(this.json);
  final Map<String, Object?> json;

  String str(String key) {
    final value = json[key];
    if (value is! String || value.isEmpty) {
      throw FrameFormatException('"$key" must be a non-empty string');
    }
    return value;
  }

  String id(String key) {
    final value = str(key);
    if (!DismessageId.isValid(value)) {
      throw FrameFormatException('"$key" is not a valid ID');
    }
    return value;
  }

  String secret() {
    final value = str('secret');
    if (value.length > kMaxSecretLength) {
      throw const FrameFormatException('"secret" too long');
    }
    return value;
  }

  int seq() {
    final value = json['seq'];
    if (value is! int || value < 1) {
      throw const FrameFormatException('"seq" must be a positive integer');
    }
    return value;
  }

  String text() {
    final value = json['text'];
    if (value is! String || value.length > kMaxTextLength) {
      throw const FrameFormatException('"text" invalid or too long');
    }
    return value;
  }

  static final _base64 = RegExp(r'^[A-Za-z0-9+/=_-]+$');
  static final _audioMime = RegExp(
    r'^audio/[a-z0-9.+-]{1,40}(;[ a-z0-9.=,"-]{1,60})?$',
  );

  String imageId() => entryId('img');

  String entryId(String key) {
    final value = str(key);
    if (!EntryId.isValid(value)) {
      throw FrameFormatException('"$key" invalid');
    }
    return value;
  }

  String? optionalEntryId(String key) =>
      json[key] == null ? null : entryId(key);

  bool boolean(String key) {
    final value = json[key];
    if (value is! bool) throw FrameFormatException('"$key" must be a boolean');
    return value;
  }

  List<String> idList(String key) {
    final value = json[key];
    if (value is! List || value.length > kMaxPresenceWatch) {
      throw FrameFormatException('"$key" must be a list of IDs');
    }
    return [
      for (final id in value)
        if (id is String && DismessageId.isValid(id))
          id
        else
          throw FrameFormatException('"$key" contains an invalid ID'),
    ];
  }

  /// An emoji, or empty to remove a reaction.
  String emoji() {
    final value = json['emoji'];
    if (value is! String ||
        value.length > kMaxReactionLength ||
        value.trim() != value) {
      throw const FrameFormatException('"emoji" invalid');
    }
    return value;
  }

  int durationMs() {
    final value = json['ms'];
    if (value is! int || value < 1 || value > (kMaxVoiceSeconds + 5) * 1000) {
      throw const FrameFormatException('"ms" invalid');
    }
    return value;
  }

  String audioMime() {
    final value = str('mime');
    if (!_audioMime.hasMatch(value)) {
      throw const FrameFormatException('"mime" must be an audio type');
    }
    return value;
  }

  String fileName() {
    final value = str('name');
    if (!FileNames.isValid(value)) {
      throw const FrameFormatException('"name" invalid');
    }
    return value;
  }

  int fileSize() {
    final value = json['size'];
    if (value is! int || value < 0 || value > kMaxFileBytes) {
      throw const FrameFormatException('"size" invalid');
    }
    return value;
  }

  int chunkIndex(String key, {required int last}) {
    final value = json[key];
    if (value is! int || value < 0 || value > last) {
      throw FrameFormatException('"$key" invalid');
    }
    return value;
  }

  int dimension(String key) {
    final value = json[key];
    if (value is! int || value < 1 || value > 10000) {
      throw FrameFormatException('"$key" must be between 1 and 10000');
    }
    return value;
  }

  String base64(String key, int maxLength) {
    final value = str(key);
    if (value.length > maxLength) {
      throw FrameFormatException('"$key" too large');
    }
    if (!_base64.hasMatch(value)) {
      throw FrameFormatException('"$key" is not base64');
    }
    return value;
  }

  List<EditOp> ops() {
    final value = json['ops'];
    if (value is! List || value.isEmpty) {
      throw const FrameFormatException('"ops" must be a non-empty list');
    }
    final ops = [for (final op in value) EditOp.fromJson(op)];
    final inserted = ops.fold<int>(0, (n, op) => n + op.ins.length);
    if (inserted > kMaxTextLength) {
      throw const FrameFormatException('"ops" too large');
    }
    return ops;
  }
}
