import 'package:dismessage/services/identity_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final prod = Uri.parse('wss://dismessage.onrender.com/ws');
final local = Uri.parse('ws://localhost:8080/ws');

void main() {
  test('first launch: no identity, the relay gives one', () {
    expect(IdentityService(MemoryStore()).load(prod), isNull);
  });

  test('the identity a relay gave is kept across launches', () async {
    final store = MemoryStore();
    await IdentityService(
      store,
    ).save(prod, const Identity(id: '482913075', secret: 'signed'));
    final again = IdentityService(store).load(prod)!;
    expect(again.id, '482913075');
    expect(again.secret, 'signed');
  });

  test('one identity per relay, kept when switching back', () async {
    final service = IdentityService(MemoryStore());
    await service.save(prod, const Identity(id: '482913075', secret: 'p'));
    expect(service.load(local), isNull);
    await service.save(local, const Identity(id: '123456789', secret: 'l'));
    expect(service.load(prod)!.id, '482913075');
    expect(service.load(local)!.id, '123456789');
  });

  test('the ID of an older version is tried on a new relay', () async {
    final store = MemoryStore()
      ..values[IdentityService.idKey] = '482913075'
      ..values[IdentityService.secretKey] = 'my-own';
    final service = IdentityService(store);
    expect(service.load(prod)!.secret, 'my-own');
    await service.save(prod, const Identity(id: '482913075', secret: 'signed'));
    expect(service.load(prod)!.secret, 'signed');
    // Never overwritten: still tried on another relay.
    expect(service.load(local)!.secret, 'my-own');
  });

  test('a corrupted stored ID is ignored', () {
    final store = MemoryStore()
      ..values[IdentityService.idKey] = 'oops'
      ..values[IdentityService.secretKey] = 'x';
    expect(IdentityService(store).load(prod), isNull);
  });

  test('PrefsStore persists through SharedPreferences', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await IdentityService(
      PrefsStore(prefs),
    ).save(prod, const Identity(id: '482913075', secret: 's'));
    expect(prefs.getString(IdentityService.idKeyFor(prod)), '482913075');
    expect(IdentityService(PrefsStore(prefs)).load(prod)!.id, '482913075');
  });
}
