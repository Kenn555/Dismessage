import 'constants.dart';
import 'entry_id.dart';
import 'frames.dart';
import 'text_diff.dart';

/// Sending side of the live draft: turns local text changes into frames.
///
/// The UI calls [update] on every keystroke and [flush] every
/// [kDraftBatchMs]; the timer itself lives in the app.
class DraftSender {
  DraftSender(this.sid);

  final String sid;
  final List<EditOp> _pending = [];
  String _text = '';
  int _seq = 0;
  int _opsSinceSnapshot = 0;
  bool _needsSnapshot = false;

  String get text => _text;
  bool get hasPending => _pending.isNotEmpty || _needsSnapshot;

  /// Records the new local draft text.
  void update(String newText) {
    final op = TextDiff.compute(_text, newText);
    if (op == null) return;
    _text = newText;
    // Coalesce consecutive appends to keep frames small.
    if (_pending.isNotEmpty && op.del == 0) {
      final last = _pending.last;
      if (op.pos == last.pos + last.ins.length) {
        _pending[_pending.length - 1] = EditOp(
          pos: last.pos,
          del: last.del,
          ins: last.ins + op.ins,
        );
        return;
      }
    }
    _pending.add(op);
  }

  /// Forces the next [flush] to send a full snapshot (peer asked a resync).
  void requestSnapshot() => _needsSnapshot = true;

  /// Returns the frame summarizing pending changes, or null if none.
  RelayedFrame? flush() {
    if (_needsSnapshot) return _snapshot();
    if (_pending.isEmpty) return null;
    if (_text.isEmpty) {
      _reset();
      return DraftClearFrame(sid: sid, seq: ++_seq);
    }
    _opsSinceSnapshot += _pending.length;
    if (_opsSinceSnapshot >= kSnapshotEvery) return _snapshot();
    final ops = List<EditOp>.of(_pending);
    _pending.clear();
    return DraftOpsFrame(sid: sid, seq: ++_seq, ops: ops);
  }

  /// Turns the current draft into a definitive message, or null if blank.
  ///
  /// [mid] identifies the message (default: a new [EntryId]); [reply] is
  /// the ID of the bubble it answers.
  MessageCommitFrame? commit({String? mid, String? reply}) {
    if (_text.trim().isEmpty) return null;
    final frame = MessageCommitFrame(
      sid: sid,
      seq: ++_seq,
      text: _text,
      mid: mid ?? EntryId.generate(),
      reply: reply,
    );
    _text = '';
    _reset();
    return frame;
  }

  DraftSnapshotFrame _snapshot() {
    _reset();
    return DraftSnapshotFrame(sid: sid, seq: ++_seq, text: _text);
  }

  void _reset() {
    _pending.clear();
    _opsSinceSnapshot = 0;
    _needsSnapshot = false;
  }
}
