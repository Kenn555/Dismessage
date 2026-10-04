import 'dart:math';

/// Identifies one bubble of a conversation (text, image or voice message),
/// so the peer can react or reply to it. Random hex, unique per session.
abstract final class EntryId {
  static final RegExp _pattern = RegExp(r'^[0-9a-f]{8,32}$');

  static String generate([Random? random]) {
    final rng = random ?? Random.secure();
    return List.generate(16, (_) => rng.nextInt(16).toRadixString(16)).join();
  }

  static bool isValid(String id) => _pattern.hasMatch(id);
}
