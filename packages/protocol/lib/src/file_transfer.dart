import 'constants.dart';

/// How a file is cut into chunks of [kFileChunkBytes].
abstract final class FileChunks {
  /// Number of chunks of a file of [size] bytes (0 for an empty file).
  static int count(int size) => (size + kFileChunkBytes - 1) ~/ kFileChunkBytes;

  /// Offset of chunk [index].
  static int offset(int index) => index * kFileChunkBytes;

  /// Length of chunk [index] of a file of [size] bytes.
  static int length(int size, int index) {
    final start = offset(index);
    final end = start + kFileChunkBytes;
    return (end > size ? size : end) - start;
  }
}

/// Sender side: which chunk to send next, at most [kFileWindowChunks]
/// ahead of the receiver's acknowledgements.
class OutgoingTransfer {
  OutgoingTransfer(this.size) : chunkCount = FileChunks.count(size);

  final int size;
  final int chunkCount;
  int _next = 0;
  int _acked = 0;
  bool _done = false;

  /// Chunks the receiver wrote (and acknowledged).
  int get ackedChunks => _acked;

  /// Bytes the receiver wrote.
  int get ackedBytes => _acked == chunkCount ? size : FileChunks.offset(_acked);

  /// The receiver confirmed the whole file is saved.
  bool get done => _done;

  /// Index of the next chunk to send, or null when the window is full or
  /// everything was sent.
  int? nextChunk() {
    if (_next >= chunkCount || _next - _acked >= kFileWindowChunks) {
      return null;
    }
    return _next++;
  }

  /// The receiver wrote the first [count] chunks. Returns false for an
  /// impossible count (going back, or beyond what was sent).
  bool ack(int count) {
    if (count < _acked || count > _next) return false;
    _acked = count;
    if (count == chunkCount) _done = true;
    return true;
  }
}

/// Receiver side: checks that chunks arrive in order with the expected
/// length.
class IncomingTransfer {
  IncomingTransfer(this.size) : chunkCount = FileChunks.count(size);

  final int size;
  final int chunkCount;
  int _received = 0;
  int _bytes = 0;

  int get receivedChunks => _received;
  int get receivedBytes => _bytes;
  bool get complete => _received == chunkCount;

  /// Records chunk [index] of [length] bytes. Returns false if it is not
  /// the expected one: the transfer must then be abandoned.
  bool accept(int index, int length) {
    if (index != _received || complete) return false;
    if (length != FileChunks.length(size, index)) return false;
    _received++;
    _bytes += length;
    return true;
  }
}

/// File names coming from the peer, made safe to write on any system.
abstract final class FileNames {
  static const fallback = 'fichier';

  static final _forbidden = RegExp(r'[<>:"/\\|?*\x00-\x1F\x7F]');
  static final _reserved = RegExp(
    r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])$',
    caseSensitive: false,
  );

  /// Whether [name] is acceptable in a frame (before [sanitize]).
  static bool isValid(String name) =>
      name.isNotEmpty &&
      name.length <= kMaxFileNameLength &&
      !name.contains(RegExp(r'[\x00-\x1F\x7F]'));

  /// A name without path, forbidden characters or reserved Windows name.
  static String sanitize(String name) {
    // Keep only the last path component, whatever the separator.
    var safe = name.split(RegExp(r'[/\\]')).last;
    safe = safe.replaceAll(_forbidden, '_').trim();
    // Windows drops trailing dots and spaces; leading dots hide files.
    safe = safe.replaceAll(RegExp(r'[. ]+$'), '');
    safe = safe.replaceAll(RegExp(r'^\.+'), '');
    if (safe.isEmpty) return fallback;
    final (stem, extension) = split(safe);
    if (_reserved.hasMatch(stem.trim())) safe = '_$safe';
    if (safe.length > kMaxFileNameLength) {
      final keep = kMaxFileNameLength - extension.length;
      safe = keep > 0
          ? _cut(stem, keep) + extension
          : _cut(safe, kMaxFileNameLength);
    }
    return safe;
  }

  /// `rapport.final.pdf` → (`rapport.final`, `.pdf`); no extension → ''.
  static (String, String) split(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return (name, '');
    return (name.substring(0, dot), name.substring(dot));
  }

  /// [name], or `name (2).ext`, `name (3).ext`… until [taken] says no.
  static String unique(String name, bool Function(String candidate) taken) {
    if (!taken(name)) return name;
    final (stem, extension) = split(name);
    for (var n = 2; ; n++) {
      final candidate = '$stem ($n)$extension';
      if (!taken(candidate)) return candidate;
    }
  }

  /// Cuts to [max] code units without splitting a surrogate pair.
  static String _cut(String text, int max) {
    if (text.length <= max) return text;
    var end = max;
    final unit = text.codeUnitAt(end - 1);
    if (unit >= 0xD800 && unit <= 0xDBFF) end--;
    return text.substring(0, end);
  }
}
