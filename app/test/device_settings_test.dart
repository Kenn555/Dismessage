import 'package:dismessage/services/identity_service.dart';
import 'package:dismessage/services/media_devices.dart';
import 'package:dismessage/widgets/device_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeLister implements MediaDeviceLister {
  @override
  Future<List<MediaDevice>> cameras() async => const [
    MediaDevice(id: 'cam-1', label: 'Webcam intégrée'),
    MediaDevice(id: 'cam-2', label: 'Logitech C920'),
  ];

  @override
  Future<List<MediaDevice>> microphones() async => const [
    MediaDevice(id: 'mic-1', label: 'Micro du casque'),
  ];
}

void main() {
  late MemoryStore store;
  late DevicePreferences devices;

  setUp(() {
    store = MemoryStore();
    devices = DevicePreferences(store, lister: _FakeLister());
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DeviceSettings(devices: devices)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the default device comes first and is the initial choice', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Par défaut'), findsNWidgets(2));
    expect(devices.cameraId, isNull);
  });

  testWidgets('choosing a camera keeps it', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('camera-choice')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Logitech C920').last);
    await tester.pumpAndSettle();

    expect(devices.cameraId, 'cam-2');
    expect(store.getString(DevicePreferences.cameraKey), 'cam-2');
    expect(find.text('Logitech C920'), findsOneWidget);
    expect(DevicePreferences(store, lister: _FakeLister()).cameraId, 'cam-2');
  });

  testWidgets('choosing a microphone keeps it, and it can be undone', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('microphone-choice')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Micro du casque').last);
    await tester.pumpAndSettle();
    expect(devices.microphoneId, 'mic-1');

    await devices.setMicrophone(null);
    await tester.pumpAndSettle();
    expect(devices.microphoneId, isNull);
    expect(find.text('Par défaut'), findsNWidgets(2));
  });

  testWidgets('a device unplugged since shows as the default', (tester) async {
    await devices.setCamera('gone');
    await pump(tester);
    expect(find.text('Par défaut'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
