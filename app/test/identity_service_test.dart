import 'package:dismessage/services/identity_service.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('first launch creates a valid identity', () async {
    final identity = await IdentityService(MemoryStore()).load();
    expect(DismessageId.isValid(identity.id), isTrue);
    expect(identity.secret, isNotEmpty);
  });

  test('ID is stable across launches', () async {
    final store = MemoryStore();
    final first = await IdentityService(store).load();
    final second = await IdentityService(store).load();
    expect(second.id, first.id);
    expect(second.secret, first.secret);
  });

  test('regenerate replaces the stored identity', () async {
    final store = MemoryStore();
    final service = IdentityService(store);
    final before = await service.load();
    final after = await service.regenerate();
    expect(after.id, isNot(before.id));
    expect((await IdentityService(store).load()).id, after.id);
  });

  test('corrupted stored ID is replaced', () async {
    final store = MemoryStore()
      ..values[IdentityService.idKey] = 'oops'
      ..values[IdentityService.secretKey] = 'x';
    final identity = await IdentityService(store).load();
    expect(DismessageId.isValid(identity.id), isTrue);
  });

  test('PrefsStore persists through SharedPreferences', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final first = await IdentityService(PrefsStore(prefs)).load();
    expect(prefs.getString(IdentityService.idKey), first.id);
    final again = await IdentityService(PrefsStore(prefs)).load();
    expect(again.id, first.id);
  });
}
