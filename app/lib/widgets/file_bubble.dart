import 'package:flutter/material.dart';

import '../services/chat_session.dart';
import '../theme/app_theme.dart';

/// `532 o`, `12,4 Ko`, `3,1 Mo`, `1,2 Go`.
String formatFileSize(int bytes) {
  const units = ['o', 'Ko', 'Mo', 'Go'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = unit == 0 || value >= 100 ? 0 : 1;
  final text = value.toStringAsFixed(digits).replaceAll('.', ',');
  return '${text.endsWith(',0') ? text.substring(0, text.length - 2) : text} '
      '${units[unit]}';
}

/// A file sent directly: name, size, then the receiver's choice, the
/// progress and, once saved, where it is.
class FileBubble extends StatelessWidget {
  const FileBubble({
    super.key,
    required this.file,
    this.onAccept,
    this.onCancel,
    this.onOpen,
    this.onShowInFolder,
    this.header,
  });

  final ChatFile file;

  /// Receiver: accept the offer (null once the conversation ended).
  final VoidCallback? onAccept;

  /// Refuse the offer, or stop the transfer.
  final VoidCallback? onCancel;
  final VoidCallback? onOpen;
  final VoidCallback? onShowInFolder;

  /// Reply quote, if this file answers another bubble.
  final Widget? header;

  String get _status {
    final mine = file.fromMe;
    return switch (file.status) {
      FileStatus.awaiting =>
        mine ? 'En attente de confirmation…' : 'Vous propose ce fichier',
      FileStatus.transferring =>
        '${formatFileSize(file.transferred)} / ${formatFileSize(file.size)}'
            ' · ${(file.progress * 100).floor()} %',
      FileStatus.done =>
        mine
            ? 'Reçu'
            : [
                'Enregistré dans ${file.saved?.location ?? 'Téléchargements'}',
                if (file.saved != null && file.saved!.name != file.name)
                  'sous « ${file.saved!.name} »',
              ].join(' '),
      FileStatus.declined => mine ? 'Refusé' : 'Vous avez refusé',
      FileStatus.cancelled => 'Transfert annulé',
      FileStatus.failed => 'Échec : ${file.error ?? 'erreur inconnue'}',
    };
  }

  IconData get _icon => switch (file.status) {
    FileStatus.done => Icons.task_rounded,
    FileStatus.declined ||
    FileStatus.cancelled ||
    FileStatus.failed => Icons.block_rounded,
    _ => Icons.insert_drive_file_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mine = file.fromMe;
    final foreground = mine ? Colors.white : scheme.onSurface;
    final muted = foreground.withValues(alpha: 0.75);
    const big = Radius.circular(20);
    const small = Radius.circular(6);
    final saved = file.saved;
    final actions = <Widget>[
      if (file.status == FileStatus.awaiting && !mine) ...[
        FilledButton.tonalIcon(
          key: ValueKey('file-accept-${file.id}'),
          onPressed: onAccept,
          icon: const Icon(Icons.download_rounded, size: 18),
          label: const Text('Accepter'),
        ),
        _TextAction(
          key: ValueKey('file-decline-${file.id}'),
          label: 'Refuser',
          color: foreground,
          onPressed: onCancel,
        ),
      ] else if (file.active)
        _TextAction(
          key: ValueKey('file-cancel-${file.id}'),
          label: 'Annuler',
          color: foreground,
          onPressed: onCancel,
        ),
      if (file.status == FileStatus.done && saved != null) ...[
        if (saved.canOpen)
          _TextAction(
            key: ValueKey('file-open-${file.id}'),
            label: 'Ouvrir',
            color: foreground,
            onPressed: onOpen,
          ),
        if (saved.canShowInFolder)
          _TextAction(
            key: ValueKey('file-folder-${file.id}'),
            label: 'Afficher dans le dossier',
            color: foreground,
            onPressed: onShowInFolder,
          ),
      ],
    ];
    return Container(
      key: ValueKey('file-${file.id}'),
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.fromLTRB(10, 10, 14, 8),
      constraints: const BoxConstraints(maxWidth: 360),
      decoration: BoxDecoration(
        gradient: mine ? AppTheme.brandGradient : null,
        color: mine ? null : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.only(
          topLeft: big,
          topRight: big,
          bottomLeft: mine ? big : small,
          bottomRight: mine ? small : big,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header != null)
            Padding(padding: const EdgeInsets.only(bottom: 8), child: header),
          Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: mine
                    ? Colors.white.withValues(alpha: 0.2)
                    : scheme.primary.withValues(alpha: 0.12),
                child: Icon(_icon, color: mine ? Colors.white : scheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      file.status == FileStatus.transferring
                          ? _status
                          : '${formatFileSize(file.size)} · $_status',
                      key: ValueKey('file-status-${file.id}'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: file.status == FileStatus.failed && !mine
                            ? scheme.error
                            : muted,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (file.status == FileStatus.transferring) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: file.progress,
                minHeight: 4,
                color: mine ? Colors.white : scheme.primary,
                backgroundColor: foreground.withValues(alpha: 0.2),
              ),
            ),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 4,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: actions,
            ),
          ],
        ],
      ),
    );
  }
}

class _TextAction extends StatelessWidget {
  const _TextAction({
    super.key,
    required this.label,
    required this.color,
    required this.onPressed,
  });

  final String label;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    style: TextButton.styleFrom(foregroundColor: color),
    onPressed: onPressed,
    child: Text(label),
  );
}
