/// A single text edit: delete [del] code units at [pos], then insert [ins].
class EditOp {
  const EditOp({required this.pos, required this.del, required this.ins});

  final int pos;
  final int del;
  final String ins;

  Map<String, Object?> toJson() => {'pos': pos, 'del': del, 'ins': ins};

  factory EditOp.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('op must be an object');
    final pos = json['pos'];
    final del = json['del'];
    final ins = json['ins'];
    if (pos is! int || pos < 0) throw const FormatException('op.pos invalid');
    if (del is! int || del < 0) throw const FormatException('op.del invalid');
    if (ins is! String) throw const FormatException('op.ins invalid');
    return EditOp(pos: pos, del: del, ins: ins);
  }

  @override
  bool operator ==(Object other) =>
      other is EditOp && other.pos == pos && other.del == del && other.ins == ins;

  @override
  int get hashCode => Object.hash(pos, del, ins);

  @override
  String toString() => 'EditOp(pos: $pos, del: $del, ins: "$ins")';
}

/// Minimal single-edit diff between two strings, in O(n).
abstract final class TextDiff {
  /// Returns the edit turning [oldText] into [newText], or null if equal.
  ///
  /// Uses common prefix/suffix, never splitting a UTF-16 surrogate pair.
  static EditOp? compute(String oldText, String newText) {
    if (oldText == newText) return null;

    final maxPrefix =
        oldText.length < newText.length ? oldText.length : newText.length;
    var prefix = 0;
    while (prefix < maxPrefix &&
        oldText.codeUnitAt(prefix) == newText.codeUnitAt(prefix)) {
      prefix++;
    }
    if (prefix > 0 && _isHighSurrogate(oldText.codeUnitAt(prefix - 1))) {
      prefix--;
    }

    final maxSuffix = maxPrefix - prefix;
    var suffix = 0;
    while (suffix < maxSuffix &&
        oldText.codeUnitAt(oldText.length - 1 - suffix) ==
            newText.codeUnitAt(newText.length - 1 - suffix)) {
      suffix++;
    }
    if (suffix > 0 &&
        _isLowSurrogate(oldText.codeUnitAt(oldText.length - suffix))) {
      suffix--;
    }

    return EditOp(
      pos: prefix,
      del: oldText.length - prefix - suffix,
      ins: newText.substring(prefix, newText.length - suffix),
    );
  }

  /// Applies [op] to [text]. Throws [RangeError] if the op does not fit.
  static String apply(String text, EditOp op) {
    if (op.pos > text.length || op.pos + op.del > text.length) {
      throw RangeError('Edit $op out of range for length ${text.length}');
    }
    return text.replaceRange(op.pos, op.pos + op.del, op.ins);
  }

  /// Applies [ops] in order.
  static String applyAll(String text, Iterable<EditOp> ops) =>
      ops.fold(text, apply);

  static bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;
  static bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;
}
