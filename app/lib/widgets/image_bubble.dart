import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/chat_session.dart';

/// An image in the conversation.
///
/// For the receiver it stays blurred until tapped; only then is the real
/// image fetched. The sender sees whether it has been opened.
class ImageBubble extends StatelessWidget {
  const ImageBubble({super.key, required this.image, required this.onOpen});

  final ChatImage image;
  final VoidCallback onOpen;

  static const maxWidth = 260.0;

  @override
  Widget build(BuildContext context) {
    final ratio = (image.width / image.height).clamp(0.5, 2.0);
    return Align(
      alignment: image.fromMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: image.fromMe
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: SizedBox(
                width: maxWidth,
                child: AspectRatio(
                  aspectRatio: ratio,
                  child: _content(context),
                ),
              ),
            ),
            if (image.fromMe) _receipt(context),
          ],
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final bytes = image.bytes;
    if (bytes != null && (image.fromMe || image.status == ImageStatus.opened)) {
      return Semantics(
        image: true,
        label: 'Image',
        child: GestureDetector(
          key: ValueKey('image-${image.id}'),
          onTap: () => _showFullScreen(context),
          child: Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
        ),
      );
    }
    final (icon, label) = switch (image.status) {
      ImageStatus.loading => (null, 'Ouverture…'),
      ImageStatus.unavailable => (
        Icons.hide_image_outlined,
        'Image indisponible',
      ),
      _ => (Icons.visibility_outlined, 'Appuyer pour voir'),
    };
    return Material(
      color: Colors.black,
      child: InkWell(
        key: ValueKey('image-${image.id}'),
        onTap: image.status == ImageStatus.blurred ? onOpen : null,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // The preview is tiny and already blurred; blur again so no
            // upscaling artefact gives anything away.
            ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Image.memory(
                image.preview,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.low,
              ),
            ),
            ColoredBox(color: Colors.black.withValues(alpha: 0.25)),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon == null)
                    const SizedBox.square(
                      dimension: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: Colors.white,
                      ),
                    )
                  else
                    Icon(icon, color: Colors.white, size: 32),
                  const SizedBox(height: 8),
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _receipt(BuildContext context) {
    final opened = image.status == ImageStatus.opened;
    final style = Theme.of(context).textTheme.labelSmall;
    return Padding(
      padding: const EdgeInsets.only(top: 4, right: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            opened ? Icons.done_all : Icons.blur_on,
            size: 14,
            color: style?.color,
          ),
          const SizedBox(width: 4),
          Text(opened ? 'Ouverte' : 'Pas encore ouverte', style: style),
        ],
      ),
    );
  }

  void _showFullScreen(BuildContext context) {
    final bytes = image.bytes;
    if (bytes == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (context) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
          ),
          body: Center(
            child: InteractiveViewer(maxScale: 5, child: Image.memory(bytes)),
          ),
        ),
      ),
    );
  }
}
