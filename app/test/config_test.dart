import 'package:dismessage/config.dart';
import 'package:flutter_test/flutter_test.dart';

String choose({
  String override = '',
  bool isWeb = false,
  bool isRelease = false,
  bool isAndroid = false,
  String? page,
}) => chooseServerUri(
  override: override,
  isWeb: isWeb,
  isRelease: isRelease,
  isAndroid: isAndroid,
  page: page == null ? null : Uri.parse(page),
).toString();

void main() {
  const prod = 'wss://dismessage.onrender.com/ws';

  test('SERVER_URL always wins', () {
    expect(
      choose(override: 'https://abc-8080.euw.devtunnels.ms', isRelease: true),
      'wss://abc-8080.euw.devtunnels.ms/ws',
    );
  });

  test('release apps (Android, Windows) use the production relay', () {
    expect(choose(isRelease: true, isAndroid: true), prod);
    expect(choose(isRelease: true), prod);
  });

  test('debug apps use a local relay', () {
    expect(choose(), 'ws://localhost:8080/ws');
    expect(choose(isAndroid: true), 'ws://10.0.2.2:8080/ws');
  });

  test('web on GitHub Pages uses the production relay', () {
    expect(
      choose(
        isWeb: true,
        isRelease: true,
        page: 'https://kenn555.github.io/Dismessage/',
      ),
      prod,
    );
  });

  test('web served by a relay talks back to it', () {
    expect(
      choose(
        isWeb: true,
        isRelease: true,
        page: 'https://abc-8080.euw.devtunnels.ms/',
      ),
      'wss://abc-8080.euw.devtunnels.ms/ws',
    );
    expect(
      choose(isWeb: true, page: 'http://localhost:8080/'),
      'ws://localhost:8080/ws',
    );
  });
}
