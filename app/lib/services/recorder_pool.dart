import 'package:flutter/foundation.dart';
import 'package:record_platform_interface/record_platform_interface.dart';

/// The `record` recorders (Windows and web), reused and never disposed.
///
/// `record_windows` 1.0.7 crashes the app when a streaming recorder is
/// disposed: each sound chunk reaches the platform thread through a queued
/// callback that calls the recorder's stream handler, and `dispose` sets
/// that handler to null before the callbacks already queued have run (an
/// access violation in `record_windows_plugin.dll`, each time the live
/// microphone went off with the camera). A recorder that is only cancelled
/// keeps its handler, whose sink is simply gone: a late chunk is dropped.
///
/// Recreating a recorder under the same ID is no way out either: the plugin
/// keeps the first one and the new stream would stay silent.
class RecorderPool {
  RecorderPool._();

  static final List<String> _free = [];
  static int _count = 0;

  static RecordPlatform get _platform => RecordPlatform.instance;

  /// A recorder for the caller alone, until [give] hands it back.
  static Future<String> take() async {
    if (_free.isNotEmpty) return _free.removeLast();
    final id = 'dismessage-recorder-${_count++}';
    await _platform.create(id);
    return id;
  }

  /// Stops whatever [id] still records and makes it available again.
  static Future<void> give(String id) async {
    try {
      await _platform.cancel(id);
    } catch (_) {
      // Not recording.
    }
    if (!_free.contains(id)) _free.add(id);
  }

  /// Forgets every recorder (a test's fake plugin knows none of them).
  @visibleForTesting
  static void reset() => _free.clear();
}
