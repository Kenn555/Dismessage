import 'dart:async';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/foundation.dart';

class ChatMessage {
  ChatMessage({required this.text, required this.fromMe}) : at = DateTime.now();
  final String text;
  final bool fromMe;
  final DateTime at;
}

/// One live conversation with a peer. Nothing is persisted.
class ChatSession extends ChangeNotifier {
  ChatSession({
    required this.sid,
    required this.peer,
    required void Function(Frame frame) send,
  }) : _send = send,
       _sender = DraftSender(sid);

  final String sid;
  final String peer;
  final void Function(Frame frame) _send;
  final DraftSender _sender;
  final DraftState _remote = DraftState();
  final List<ChatMessage> _messages = [];
  Timer? _flushTimer;
  bool _peerLeft = false;

  List<ChatMessage> get messages => List.unmodifiable(_messages);

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
    _messages.add(ChatMessage(text: frame.text, fromMe: true));
    notifyListeners();
    return true;
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
          _messages.add(ChatMessage(text: committed, fromMe: false));
        }
      case DraftResyncFrame():
        _sender.requestSnapshot();
        _flush();
    }
    notifyListeners();
  }

  void markPeerLeft() {
    if (_peerLeft) return;
    _peerLeft = true;
    _cancelFlush();
    _remote.clear(_remote.lastSeq + 1);
    notifyListeners();
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
