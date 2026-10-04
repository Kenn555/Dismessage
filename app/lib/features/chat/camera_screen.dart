import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/camera_capture.dart';

/// Full-screen webcam: live preview and a shutter button. Pops with the
/// JPEG bytes, or null if closed.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key, required this.capture});

  final CameraCapture capture;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  bool _ready = false;
  bool _shooting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      await widget.capture.open();
      if (mounted) setState(() => _ready = true);
    } on CameraCaptureException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Webcam inaccessible ($e).');
      }
    }
  }

  Future<void> _shoot() async {
    setState(() => _shooting = true);
    try {
      final Uint8List bytes = await widget.capture.takePicture();
      if (mounted) Navigator.pop(context, bytes);
    } catch (e) {
      if (mounted) {
        setState(() {
          _shooting = false;
          _error = e is CameraCaptureException
              ? e.message
              : 'La photo n’a pas pu être prise ($e).';
        });
      }
    }
  }

  @override
  void dispose() {
    widget.capture.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Prendre une photo'),
        leading: IconButton(
          key: const Key('camera-close'),
          tooltip: 'Fermer',
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: error != null
                    ? Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.no_photography_outlined,
                              color: Colors.white70,
                              size: 48,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              error,
                              key: const Key('camera-error'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                      )
                    : !_ready
                    ? const CircularProgressIndicator(color: Colors.white)
                    : AspectRatio(
                        aspectRatio: widget.capture.aspectRatio,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: widget.capture.preview(),
                        ),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Semantics(
                button: true,
                label: 'Prendre la photo',
                child: GestureDetector(
                  key: const Key('camera-shutter'),
                  onTap: _ready && !_shooting && error == null ? _shoot : null,
                  child: Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 5),
                    ),
                    padding: const EdgeInsets.all(5),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _ready && error == null
                            ? Colors.white
                            : Colors.white24,
                      ),
                      child: _shooting
                          ? const Padding(
                              padding: EdgeInsets.all(18),
                              child: CircularProgressIndicator(strokeWidth: 3),
                            )
                          : null,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
