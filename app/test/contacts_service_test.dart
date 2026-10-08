import 'package:dismessage/services/contacts_service.dart';
import 'package:dismessage/services/identity_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('save, list sorted by name, label', () async {
    final contacts = ContactsService(MemoryStore());
    await contacts.save('318343691', 'zoé');
    await contacts.save('123456789', 'Alice');
    expect(contacts.contacts.map((c) => c.name), ['Alice', 'zoé']);
    expect(contacts.label('123456789'), 'Alice');
    expect(contacts.label('999999999'), '999 999 999');
  });

  test('persists across restarts, and only stores id + name', () async {
    final store = MemoryStore();
    await ContactsService(store).save('318343691', 'Bob');
    expect(
      store.values[ContactsService.key],
      '[{"id":"318343691","name":"Bob"}]',
    );
    expect(ContactsService(store).byId('318343691')?.name, 'Bob');
  });

  test('saving again renames', () async {
    final contacts = ContactsService(MemoryStore());
    await contacts.save('318343691', 'Bob');
    await contacts.save('318343691', 'Robert');
    expect(contacts.contacts.single.name, 'Robert');
  });

  test('remove', () async {
    final store = MemoryStore();
    final contacts = ContactsService(store);
    await contacts.save('318343691', 'Bob');
    await contacts.remove('318343691');
    expect(contacts.contacts, isEmpty);
    expect(ContactsService(store).contacts, isEmpty);
  });

  test('names are trimmed, collapsed and limited', () {
    expect(ContactsService.cleanName('  Jean   Paul  '), 'Jean Paul');
    expect(ContactsService.cleanName('   '), isNull);
    expect(
      ContactsService.cleanName('x' * 100),
      hasLength(ContactsService.maxNameLength),
    );
  });

  test('rejects invalid input', () async {
    final contacts = ContactsService(MemoryStore());
    expect(() => contacts.save('12', 'Bob'), throwsArgumentError);
    expect(() => contacts.save('318343691', '  '), throwsArgumentError);
  });

  test('corrupted storage is ignored', () {
    final store = MemoryStore()
      ..values[ContactsService.key] =
          '[{"id":"bad","name":"X"},{"id":"318343691","name":"Ok"},3';
    expect(ContactsService(store).contacts, isEmpty);
    store.values[ContactsService.key] =
        '[{"id":"bad","name":"X"},{"id":"318343691","name":"Ok"},3]';
    expect(ContactsService(store).contacts.single.name, 'Ok');
  });

  group('who can ask for a conversation', () {
    const bob = '318343691';
    const stranger = '123456789';

    test('everyone by default; a blocked ID no more', () async {
      final contacts = ContactsService(MemoryStore());
      expect(contacts.allowsRequestFrom(stranger), isTrue);
      await contacts.block(stranger);
      expect(contacts.isBlocked(stranger), isTrue);
      expect(contacts.allowsRequestFrom(stranger), isFalse);
      await contacts.unblock(stranger);
      expect(contacts.allowsRequestFrom(stranger), isTrue);
    });

    test(
      'contacts only: unknown IDs are left out, even blocked contacts',
      () async {
        final contacts = ContactsService(MemoryStore());
        await contacts.save(bob, 'Bob');
        await contacts.setContactsOnly(true);
        expect(contacts.allowsRequestFrom(bob), isTrue);
        expect(contacts.allowsRequestFrom(stranger), isFalse);
        await contacts.block(bob);
        expect(contacts.allowsRequestFrom(bob), isFalse);
      },
    );

    test('kept across restarts, separately from the address book', () async {
      final store = MemoryStore();
      final contacts = ContactsService(store);
      await contacts.block(stranger);
      await contacts.block(bob);
      await contacts.setContactsOnly(true);
      final again = ContactsService(store);
      expect(again.blocked, [stranger, bob]);
      expect(again.contactsOnly, isTrue);
      expect(again.contacts, isEmpty, reason: 'blocking saves no contact');
    });

    test('invalid or corrupted entries are ignored', () async {
      final store = MemoryStore()
        ..values[ContactsService.blockedKey] = '["bad", "318343691", 3]';
      expect(ContactsService(store).blocked, [bob]);
      store.values[ContactsService.blockedKey] = '{oops';
      expect(ContactsService(store).blocked, isEmpty);
      final contacts = ContactsService(MemoryStore());
      await contacts.block('42');
      expect(contacts.blocked, isEmpty);
    });
  });

  test('notifies listeners', () async {
    final contacts = ContactsService(MemoryStore());
    var calls = 0;
    contacts.addListener(() => calls++);
    await contacts.save('318343691', 'Bob');
    await contacts.remove('318343691');
    expect(calls, 2);
  });
}
