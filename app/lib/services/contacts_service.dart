import 'dart:convert';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/foundation.dart';

import 'identity_service.dart';

/// A saved peer: only a name and an ID, never any message.
class Contact {
  const Contact({required this.id, required this.name});

  final String id;
  final String name;

  Map<String, String> toJson() => {'id': id, 'name': name};
}

/// Local address book (stored on this device only).
class ContactsService extends ChangeNotifier {
  ContactsService(this._store) {
    _load();
  }

  static const key = 'dismessage.contacts';

  /// Blocked IDs (JSON list) and the "contacts only" option, on this device
  /// too: the relay knows nothing of them.
  static const blockedKey = 'dismessage.blocked';
  static const contactsOnlyKey = 'dismessage.contactsOnly';
  static const maxNameLength = 40;

  final KeyValueStore _store;
  final Map<String, Contact> _byId = {};
  final Set<String> _blocked = {};
  bool _contactsOnly = false;

  /// Blocked IDs, in the order they were blocked.
  List<String> get blocked => List.unmodifiable(_blocked);

  bool isBlocked(String id) => _blocked.contains(id);

  /// Only saved contacts can ask for a conversation.
  bool get contactsOnly => _contactsOnly;

  /// Whether a chat request from [id] reaches the user. The others are
  /// ignored without an answer: the requester only sees no reply, never
  /// that they are blocked.
  bool allowsRequestFrom(String id) =>
      !_blocked.contains(id) && (!_contactsOnly || _byId.containsKey(id));

  Future<void> block(String id) async {
    if (!DismessageId.isValid(id) || !_blocked.add(id)) return;
    await _persistPrivacy();
  }

  Future<void> unblock(String id) async {
    if (!_blocked.remove(id)) return;
    await _persistPrivacy();
  }

  Future<void> setContactsOnly(bool value) async {
    if (value == _contactsOnly) return;
    _contactsOnly = value;
    await _persistPrivacy();
  }

  /// Contacts sorted by name.
  List<Contact> get contacts =>
      _byId.values.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  Contact? byId(String id) => _byId[id];

  /// The contact name if saved, otherwise the formatted ID.
  String label(String id) => _byId[id]?.name ?? DismessageId.format(id);

  /// Normalizes a name; null if unusable.
  static String? cleanName(String input) {
    final name = input.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (name.isEmpty) return null;
    return name.length > maxNameLength
        ? name.substring(0, maxNameLength)
        : name;
  }

  /// Adds or renames a contact.
  Future<void> save(String id, String name) async {
    final clean = cleanName(name);
    if (!DismessageId.isValid(id)) {
      throw ArgumentError.value(id, 'id', 'Not a valid Dismessage ID');
    }
    if (clean == null) throw ArgumentError.value(name, 'name', 'Empty name');
    _byId[id] = Contact(id: id, name: clean);
    await _persist();
  }

  Future<void> remove(String id) async {
    if (_byId.remove(id) == null) return;
    await _persist();
  }

  void _load() {
    _contactsOnly = _store.getString(contactsOnlyKey) == 'true';
    try {
      final blocked = jsonDecode(_store.getString(blockedKey) ?? '[]');
      for (final id in blocked as List<Object?>) {
        if (id is String && DismessageId.isValid(id)) _blocked.add(id);
      }
    } on Object {
      // Corrupted storage: nobody blocked.
    }
    final raw = _store.getString(key);
    if (raw == null) return;
    try {
      for (final item in jsonDecode(raw) as List<Object?>) {
        if (item is! Map) continue;
        final id = item['id'];
        final name = item['name'];
        if (id is String && DismessageId.isValid(id) && name is String) {
          final clean = cleanName(name);
          if (clean != null) _byId[id] = Contact(id: id, name: clean);
        }
      }
    } on FormatException {
      // Corrupted storage: start with an empty address book.
    }
  }

  Future<void> _persistPrivacy() async {
    notifyListeners();
    await _store.setString(blockedKey, jsonEncode(_blocked.toList()));
    await _store.setString(contactsOnlyKey, '$_contactsOnly');
  }

  Future<void> _persist() async {
    notifyListeners();
    await _store.setString(
      key,
      jsonEncode([for (final c in _byId.values) c.toJson()]),
    );
  }
}
