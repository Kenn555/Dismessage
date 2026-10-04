import 'dart:convert';
import 'dart:math';

/// A stable, AnyDesk-like 9-digit identifier (first digit never 0).
abstract final class DismessageId {
  static const int length = 9;
  static final RegExp _pattern = RegExp(r'^[1-9][0-9]{8}$');

  /// Generates a new random ID using a cryptographically secure source.
  static String generate([Random? random]) {
    final rng = random ?? Random.secure();
    final buffer = StringBuffer()..write(1 + rng.nextInt(9));
    for (var i = 1; i < length; i++) {
      buffer.write(rng.nextInt(10));
    }
    return buffer.toString();
  }

  /// Generates the secret proving ownership of an ID (32 random bytes).
  static String generateSecret([Random? random]) {
    final rng = random ?? Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    return base64Url.encode(bytes);
  }

  /// Whether [id] is a normalized ID (9 digits, no separator).
  static bool isValid(String id) => _pattern.hasMatch(id);

  /// Normalizes user input ("482 913 075", "482-913-075") to "482913075".
  /// Returns null when the input is not a valid ID.
  static String? parse(String input) {
    final normalized = input.replaceAll(RegExp(r'[\s\-.]'), '');
    return isValid(normalized) ? normalized : null;
  }

  /// Formats a normalized ID as "XXX XXX XXX".
  static String format(String id) {
    if (!isValid(id)) {
      throw ArgumentError.value(id, 'id', 'Not a valid Dismessage ID');
    }
    return '${id.substring(0, 3)} ${id.substring(3, 6)} ${id.substring(6)}';
  }

  /// Formats a normalized ID with its middle group hidden: "482 *** 075".
  /// Enough to tell IDs apart, not to reach someone.
  static String mask(String id) {
    if (!isValid(id)) {
      throw ArgumentError.value(id, 'id', 'Not a valid Dismessage ID');
    }
    return '${id.substring(0, 3)} *** ${id.substring(6)}';
  }
}
