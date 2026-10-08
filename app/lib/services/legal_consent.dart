import '../legal/legal_texts.dart';
import 'identity_service.dart';

/// Whether the user confirmed their age and accepted the current terms
/// ([kTermsVersion]); on this device only. Until then, the app does not
/// connect to the relay.
class LegalConsent {
  LegalConsent(this._store);

  static const key = 'dismessage.termsAccepted';

  final KeyValueStore _store;

  bool get accepted => _store.getString(key) == kTermsVersion;

  Future<void> accept() => _store.setString(key, kTermsVersion);
}
