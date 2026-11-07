import 'package:flutter/material.dart';

import '../services/chat_session.dart';
import '../services/file_storage.dart';
import '../theme/app_theme.dart';

export '../services/file_storage.dart' show formatFileSize;

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
    this.grouped = false,
  });

  final ChatFile file;

  /// Part of a group: the receiver answers once, above ([GroupOfferBar]).
  final bool grouped;

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
      if (file.status == FileStatus.awaiting && !mine && !grouped) ...[
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
      ] else if (file.active && (mine || file.status != FileStatus.awaiting))
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

/// The single validation of what the peer sent together.
class GroupOfferBar extends StatelessWidget {
  const GroupOfferBar({
    super.key,
    required this.group,
    required this.label,
    required this.onAccept,
    required this.onDecline,
  });

  final String group;

  /// "3 fichiers (12 Mo)".
  final String label;
  final VoidCallback? onAccept;

  /// Null when there is nothing to refuse (only images).
  final VoidCallback? onDecline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        key: ValueKey('group-offer-$group'),
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            Text(
              label,
              style: theme.textTheme.titleSmall?.copyWith(
                color: scheme.onPrimaryContainer,
              ),
            ),
            // On a narrow phone the two buttons go on two lines.
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (onDecline != null)
                  _TextAction(
                    key: ValueKey('group-decline-$group'),
                    label: 'Tout refuser',
                    color: scheme.onPrimaryContainer,
                    onPressed: onDecline,
                  ),
                FilledButton.icon(
                  key: ValueKey('group-accept-$group'),
                  onPressed: onAccept,
                  icon: const Icon(Icons.download_done_rounded, size: 18),
                  label: const Text('Tout accepter'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Several files sent together, in one bubble: one row each.
class FileGroupBubble extends StatelessWidget {
  const FileGroupBubble({
    super.key,
    required this.files,
    this.onCancel,
    this.onOpen,
    this.onShowInFolder,
    this.header,
  });

  final List<ChatFile> files;

  /// Stops one file (refuses it, if it is still waiting).
  final void Function(ChatFile file)? onCancel;
  final void Function(ChatFile file)? onOpen;
  final void Function(ChatFile file)? onShowInFolder;
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mine = files.first.fromMe;
    final foreground = mine ? Colors.white : scheme.onSurface;
    final muted = foreground.withValues(alpha: 0.75);
    const big = Radius.circular(20);
    const small = Radius.circular(6);
    return Container(
      key: ValueKey('file-group-${files.first.group}'),
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
      constraints: const BoxConstraints(maxWidth: 420),
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
          for (final file in files)
            _GroupRow(
              file: file,
              foreground: foreground,
              muted: muted,
              onCancel: onCancel == null ? null : () => onCancel!(file),
              onOpen: onOpen == null ? null : () => onOpen!(file),
              onShowInFolder: onShowInFolder == null
                  ? null
                  : () => onShowInFolder!(file),
            ),
        ],
      ),
    );
  }
}

class _GroupRow extends StatelessWidget {
  const _GroupRow({
    required this.file,
    required this.foreground,
    required this.muted,
    this.onCancel,
    this.onOpen,
    this.onShowInFolder,
  });

  final ChatFile file;
  final Color foreground;
  final Color muted;
  final VoidCallback? onCancel;
  final VoidCallback? onOpen;
  final VoidCallback? onShowInFolder;

  String get _status {
    final mine = file.fromMe;
    return switch (file.status) {
      FileStatus.awaiting => mine ? 'En attente…' : 'À confirmer',
      FileStatus.transferring =>
        file.transferred == 0 ? 'En file…' : '${(file.progress * 100).floor()} %',
      FileStatus.done => mine ? 'Reçu' : 'Enregistré',
      FileStatus.declined => 'Refusé',
      FileStatus.cancelled => 'Annulé',
      FileStatus.failed => 'Échec : ${file.error ?? 'erreur inconnue'}',
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final saved = file.saved;
    return Padding(
      key: ValueKey('file-${file.id}'),
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                file.status == FileStatus.done
                    ? Icons.task_rounded
                    : Icons.insert_drive_file_rounded,
                size: 20,
                color: muted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '${formatFileSize(file.size)} · $_status',
                      key: ValueKey('file-status-${file.id}'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: muted,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              if (file.status == FileStatus.done && saved != null) ...[
                if (saved.canOpen)
                  IconButton(
                    key: ValueKey('file-open-${file.id}'),
                    tooltip: 'Ouvrir',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.open_in_new_rounded, color: foreground),
                    onPressed: onOpen,
                  ),
                if (saved.canShowInFolder)
                  IconButton(
                    key: ValueKey('file-folder-${file.id}'),
                    tooltip: 'Afficher dans le dossier',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.folder_open_rounded, color: foreground),
                    onPressed: onShowInFolder,
                  ),
              ],
              if (file.active)
                IconButton(
                  key: ValueKey('file-cancel-${file.id}'),
                  tooltip: file.status == FileStatus.awaiting && !file.fromMe
                      ? 'Refuser ce fichier'
                      : 'Annuler',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.close_rounded, color: foreground),
                  onPressed: onCancel,
                ),
            ],
          ),
          if (file.status == FileStatus.transferring)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 28, right: 8),
              child: LinearProgressIndicator(
                value: file.progress,
                minHeight: 3,
                color: foreground,
                backgroundColor: foreground.withValues(alpha: 0.2),
              ),
            ),
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
