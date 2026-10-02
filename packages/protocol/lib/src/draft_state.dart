import 'text_diff.dart';

/// Outcome of applying a remote draft frame.
enum DraftUpdate {
  /// The draft changed.
  applied,

  /// Duplicate, stale or received while waiting for a resync.
  ignored,

  /// A frame is missing or did not apply: ask the sender for a snapshot.
  needsResync,
}

/// Receiving side of the live draft: rebuilds the peer's text in order.
class DraftState {
  String _text = '';
  int _lastSeq = 0;
  bool _awaitingResync = false;

  String get text => _text;
  int get lastSeq => _lastSeq;
  bool get awaitingResync => _awaitingResync;

  DraftUpdate applyOps(int seq, List<EditOp> ops) {
    if (_awaitingResync || seq <= _lastSeq) return DraftUpdate.ignored;
    if (seq != _lastSeq + 1) return _desync();
    try {
      _text = TextDiff.applyAll(_text, ops);
    } on RangeError {
      return _desync();
    }
    _lastSeq = seq;
    return DraftUpdate.applied;
  }

  /// Snapshots, clears and commits carry the full state: they always resync.
  DraftUpdate applySnapshot(int seq, String text) {
    if (seq <= _lastSeq) return DraftUpdate.ignored;
    _text = text;
    _lastSeq = seq;
    _awaitingResync = false;
    return DraftUpdate.applied;
  }

  DraftUpdate clear(int seq) => applySnapshot(seq, '');

  /// Returns the committed message text, or null for a stale frame.
  String? commit(int seq, String text) =>
      applySnapshot(seq, '') == DraftUpdate.applied ? text : null;

  DraftUpdate _desync() {
    _awaitingResync = true;
    return DraftUpdate.needsResync;
  }
}
