import 'package:flutter/material.dart';

import 'emoji_panel.dart';

/// What the user picked in the long-press menu of a bubble.
sealed class MessageAction {
  const MessageAction();
}

class ReactAction extends MessageAction {
  const ReactAction(this.emoji);
  final String emoji;
}

class ReplyAction extends MessageAction {
  const ReplyAction();
}

class CopyAction extends MessageAction {
  const CopyAction();
}

/// Quick reactions, as in most messengers; "+" opens the full panel.
const quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

/// Long-press menu: reactions (peer bubbles only), reply, copy.
Future<MessageAction?> showMessageActions(
  BuildContext context, {
  required bool canReact,
  required bool canReply,
  required bool canCopy,
  String? currentReaction,
}) {
  return showModalBottomSheet<MessageAction>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _ActionsSheet(
      canReact: canReact,
      canReply: canReply,
      canCopy: canCopy,
      currentReaction: currentReaction,
    ),
  );
}

class _ActionsSheet extends StatefulWidget {
  const _ActionsSheet({
    required this.canReact,
    required this.canReply,
    required this.canCopy,
    required this.currentReaction,
  });

  final bool canReact;
  final bool canReply;
  final bool canCopy;
  final String? currentReaction;

  @override
  State<_ActionsSheet> createState() => _ActionsSheetState();
}

class _ActionsSheetState extends State<_ActionsSheet> {
  bool _allEmojis = false;

  void _pick(MessageAction action) => Navigator.pop(context, action);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_allEmojis) {
      return SafeArea(
        child: EmojiPanel(onSelected: (e) => _pick(ReactAction(e))),
      );
    }
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.canReact)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 4,
                children: [
                  for (final emoji in quickReactions)
                    _EmojiButton(
                      key: ValueKey('react-$emoji'),
                      emoji: emoji,
                      selected: emoji == widget.currentReaction,
                      onTap: () => _pick(ReactAction(emoji)),
                    ),
                  IconButton.filledTonal(
                    key: const Key('react-more'),
                    tooltip: 'Autres émojis',
                    icon: const Icon(Icons.add_rounded),
                    onPressed: () => setState(() => _allEmojis = true),
                  ),
                ],
              ),
            ),
          if (widget.canReact && widget.currentReaction != null)
            ListTile(
              key: const Key('react-remove'),
              leading: Icon(Icons.close_rounded, color: scheme.error),
              title: const Text('Retirer ma réaction'),
              onTap: () => _pick(ReactAction(widget.currentReaction!)),
            ),
          if (widget.canReply)
            ListTile(
              key: const Key('action-reply'),
              leading: const Icon(Icons.reply_rounded),
              title: const Text('Répondre'),
              onTap: () => _pick(const ReplyAction()),
            ),
          if (widget.canCopy)
            ListTile(
              key: const Key('action-copy'),
              leading: const Icon(Icons.copy_rounded),
              title: const Text('Copier'),
              onTap: () => _pick(const CopyAction()),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _EmojiButton extends StatelessWidget {
  const _EmojiButton({
    super.key,
    required this.emoji,
    required this.selected,
    required this.onTap,
  });

  final String emoji;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      shape: const CircleBorder(),
      color: selected ? scheme.primaryContainer : Colors.transparent,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox.square(
          dimension: 48,
          child: Center(
            child: Text(emoji, style: const TextStyle(fontSize: 26)),
          ),
        ),
      ),
    );
  }
}
