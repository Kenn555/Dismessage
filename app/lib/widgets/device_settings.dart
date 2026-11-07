import 'package:flutter/material.dart';

import '../services/media_devices.dart';

/// The choice of camera and microphone, in the settings.
class DeviceSettings extends StatefulWidget {
  const DeviceSettings({super.key, required this.devices});

  final DevicePreferences devices;

  @override
  State<DeviceSettings> createState() => _DeviceSettingsState();
}

class _DeviceSettingsState extends State<DeviceSettings> {
  late final Future<List<MediaDevice>> _cameras = widget.devices.lister
      .cameras();
  late final Future<List<MediaDevice>> _microphones = widget.devices.lister
      .microphones();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.devices,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              'Périphériques',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          _DeviceChoice(
            key: const Key('camera-choice'),
            label: 'Caméra',
            icon: Icons.videocam_outlined,
            devices: _cameras,
            selected: widget.devices.cameraId,
            onChanged: widget.devices.setCamera,
          ),
          _DeviceChoice(
            key: const Key('microphone-choice'),
            label: 'Micro',
            icon: Icons.mic_none_rounded,
            devices: _microphones,
            selected: widget.devices.microphoneId,
            onChanged: widget.devices.setMicrophone,
          ),
        ],
      ),
    );
  }
}

class _DeviceChoice extends StatelessWidget {
  const _DeviceChoice({
    super.key,
    required this.label,
    required this.icon,
    required this.devices,
    required this.selected,
    required this.onChanged,
  });

  final String label;
  final IconData icon;
  final Future<List<MediaDevice>> devices;
  final String? selected;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: FutureBuilder<List<MediaDevice>>(
        future: devices,
        builder: (context, snapshot) {
          final found = snapshot.data ?? const <MediaDevice>[];
          // Unplugged since: shown as the default, which is what will be used.
          final known = found.any((d) => d.id == selected) ? selected : null;
          return DropdownButtonFormField<String?>(
            // The list arrives after the first build.
            key: ValueKey('$known-${found.length}'),
            value: known,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: label,
              prefixIcon: Icon(icon),
            ),
            items: [
              const DropdownMenuItem<String?>(child: Text('Par défaut')),
              for (final device in found)
                DropdownMenuItem<String?>(
                  value: device.id,
                  child: Text(device.label, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: onChanged,
          );
        },
      ),
    );
  }
}
