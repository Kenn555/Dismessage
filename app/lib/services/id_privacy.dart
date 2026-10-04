import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/foundation.dart';

/// Which IDs are shown in full. My ID and saved contacts' IDs are masked
/// ("482 *** 075") until the user reveals them; an unknown peer's ID always
/// shows in full, to know who it is. Not saved: masked at every launch.
class IdPrivacy extends ChangeNotifier {
  bool _showMine = false;
  bool _showContacts = false;

  bool get showMine => _showMine;
  bool get showContacts => _showContacts;

  void toggleMine() {
    _showMine = !_showMine;
    notifyListeners();
  }

  void toggleContacts() {
    _showContacts = !_showContacts;
    notifyListeners();
  }

  /// My own ID, as displayed.
  String mine(String id) =>
      _showMine ? DismessageId.format(id) : DismessageId.mask(id);

  /// A saved contact's ID, as displayed.
  String contact(String id) =>
      _showContacts ? DismessageId.format(id) : DismessageId.mask(id);
}
