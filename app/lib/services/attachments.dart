import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/foundation.dart';

import 'chat_session.dart';
import 'file_storage.dart';
import 'image_codec.dart';

/// Turns picked bytes into a sendable image.
typedef ImageEncoderFn = Future<EncodedImage> Function(Uint8List bytes);

/// What the user chose or pasted, not sent yet: pictures as bytes (a copied
/// bitmap, the gallery) and files of any type.
class Attachments {
  const Attachments({this.images = const [], this.files = const []});

  final List<Uint8List> images;
  final List<ChosenFile> files;

  bool get isEmpty => images.isEmpty && files.isEmpty;
  int get count => images.length + files.length;

  /// Size of the files, the pictures not being sent as they are.
  int get filesSize => files.fold(0, (total, file) => total + file.size);

  /// Gives up on them: nothing was sent.
  Future<void> discard() async {
    for (final file in files) {
      await file.close();
    }
  }
}

/// "3 fichiers", "1 image et 2 fichiers".
String describeAttachments(int images, int files) => [
  if (images > 0) images == 1 ? '1 image' : '$images images',
  if (files > 0) files == 1 ? '1 fichier' : '$files fichiers',
].join(' et ');

/// Encodes [attachments] then offers everything at once, so that the peer
/// answers for all of it with a single validation.
///
/// A file that is a picture shows as an image bubble, like any other; one
/// that cannot be read as a picture goes as a plain file. Returns what the
/// user should be told, if anything.
Future<String?> sendAttachments(
  ChatSession session,
  Attachments attachments, {
  required ImageEncoderFn encode,
  ChatEntry? replyTo,
}) async {
  final images = <EncodedImage>[];
  final files = <ChosenFile>[];
  String? error;
  final tooLarge = <ChosenFile>[];
  var skippedImages = 0;
  var skippedFiles = 0;

  for (final picture in attachments.images) {
    if (images.length >= kMaxImagesPerSend) {
      skippedImages++;
      continue;
    }
    try {
      images.add(await encode(picture));
    } on ImageCodecException catch (e) {
      error ??= e.message;
    } catch (e) {
      error ??= _failure("Impossible d'envoyer l'image", e);
    }
  }

  for (final file in attachments.files) {
    if (file.size > kMaxFileBytes) {
      tooLarge.add(file);
      await file.close();
      continue;
    }
    final isPicture =
        FileNames.isImage(file.name) &&
        file.size <= kMaxImageFileBytes &&
        images.length < kMaxImagesPerSend;
    if (isPicture) {
      try {
        final bytes = await file.read(0, file.size);
        images.add(await encode(bytes));
        await file.close();
        continue;
      } catch (_) {
        // Not readable as a picture: it still goes, as a file.
      }
    }
    if (files.length >= kMaxFilesPerSend) {
      skippedFiles++;
      await file.close();
      continue;
    }
    files.add(file);
  }

  if (session.peerLeft) {
    for (final file in files) {
      await file.close();
    }
    return null;
  }
  session.sendBatch(images: images, files: files, replyTo: replyTo);

  final limit = formatFileSize(kMaxFileBytes);
  if (tooLarge.length == 1) {
    return 'Fichier trop volumineux (${formatFileSize(tooLarge.single.size)}, '
        'maximum $limit) : ${tooLarge.single.name} n’est pas envoyé.';
  }
  if (tooLarge.isNotEmpty) {
    return '${tooLarge.length} fichiers dépassent $limit : ils ne sont pas '
        'envoyés.';
  }
  if (skippedFiles > 0) {
    return 'Seuls les $kMaxFilesPerSend premiers fichiers sont envoyés.';
  }
  if (skippedImages > 0) {
    return 'Seules les $kMaxImagesPerSend premières images sont envoyées.';
  }
  return error;
}

/// Shows the cause: a remote friend can then report it.
String _failure(String what, Object error) {
  final cause = error.toString().split('\n').first;
  final short = cause.length > 160 ? '${cause.substring(0, 160)}…' : cause;
  return '$what ($short).';
}
