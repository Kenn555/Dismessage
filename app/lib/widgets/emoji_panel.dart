import 'package:flutter/material.dart';

/// Built-in emoji picker (no external package, nothing to download).
class EmojiPanel extends StatelessWidget {
  const EmojiPanel({super.key, required this.onSelected});

  final ValueChanged<String> onSelected;

  static const categories = <(IconData, String, List<String>)>[
    (
      Icons.emoji_emotions_outlined,
      'Smileys',
      [
        '😀', '😃', '😄', '😁', '😆', '😅', '😂', '🤣', '🙂', '🙃', //
        '😉', '😊', '😇', '🥰', '😍', '🤩', '😘', '😗', '😚', '😋',
        '😛', '😜', '🤪', '😝', '🤑', '🤗', '🤭', '🤫', '🤔', '🤐',
        '🤨', '😐', '😑', '😶', '😏', '😒', '🙄', '😬', '😮‍💨', '🤥',
        '😌', '😔', '😪', '🤤', '😴', '😷', '🤒', '🤕', '🤢', '🤮',
        '🥵', '🥶', '🥴', '😵', '🤯', '🤠', '🥳', '😎', '🤓', '🧐',
        '😕', '😟', '🙁', '😮', '😯', '😲', '😳', '🥺', '😦', '😧',
        '😨', '😰', '😥', '😢', '😭', '😱', '😖', '😣', '😞', '😓',
        '😩', '😫', '🥱', '😤', '😡', '😠', '🤬', '😈', '💀', '💩',
        '🤡', '👻', '👽', '🤖', '😺', '😸', '😹', '😻', '😼', '🙈',
      ],
    ),
    (
      Icons.waving_hand_outlined,
      'Gestes',
      [
        '👋', '🤚', '🖐️', '✋', '🖖', '👌', '🤌', '🤏', '✌️', '🤞', //
        '🤟', '🤘', '🤙', '👈', '👉', '👆', '👇', '☝️', '👍', '👎',
        '✊', '👊', '🤛', '🤜', '👏', '🙌', '👐', '🤲', '🤝', '🙏',
        '✍️', '💪', '🦾', '👀', '👁️', '🧠', '🫶', '🙋', '🤷', '🤦',
        '🙆', '🙅', '💁', '🙇', '🧑‍💻', '🕺', '💃', '🏃', '🚶', '🧘',
      ],
    ),
    (
      Icons.favorite_border,
      'Cœurs',
      [
        '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '🤎', '💔', //
        '❣️', '💕', '💞', '💓', '💗', '💖', '💘', '💝', '💟', '💯',
        '✨', '⭐', '🌟', '💫', '🔥', '💥', '💢', '💦', '💨', '🎉',
        '🎊', '✅', '❌', '❓', '❗', '⚠️', '🚫', '💤', '💬', '💭',
      ],
    ),
    (
      Icons.pets_outlined,
      'Nature',
      [
        '🐶', '🐱', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼', '🐨', '🐯', //
        '🦁', '🐮', '🐷', '🐸', '🐵', '🐔', '🐧', '🐦', '🦄', '🐝',
        '🦋', '🐢', '🐍', '🐙', '🐬', '🐳', '🌸', '🌹', '🌻', '🌷',
        '🌲', '🌴', '🍀', '🍁', '🌙', '☀️', '⛅', '🌧️', '❄️', '🌈',
      ],
    ),
    (
      Icons.restaurant_outlined,
      'Nourriture',
      [
        '🍏', '🍎', '🍐', '🍊', '🍋', '🍌', '🍉', '🍇', '🍓', '🍒', //
        '🍑', '🥭', '🍍', '🥥', '🥑', '🍅', '🥕', '🌽', '🥐', '🥖',
        '🧀', '🥚', '🍳', '🥞', '🍔', '🍟', '🍕', '🌭', '🥪', '🌮',
        '🍣', '🍜', '🍝', '🍰', '🎂', '🍫', '🍩', '🍪', '☕', '🍵',
        '🥤', '🍺', '🍷', '🥂', '🍾',
      ],
    ),
    (
      Icons.sports_soccer_outlined,
      'Activités',
      [
        '⚽', '🏀', '🏈', '⚾', '🎾', '🏐', '🏉', '🎱', '🏓', '🏸', //
        '🥊', '🎮', '🕹️', '🎲', '🧩', '🎯', '🎳', '🎸', '🎹', '🎧',
        '🎤', '🎬', '📷', '📱', '💻', '⌚', '💡', '📚', '✏️', '📌',
        '🎁', '🎈', '🏆', '🥇', '🚗', '✈️', '🚀', '🏠', '⏰', '💰',
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DefaultTabController(
      length: categories.length,
      child: Material(
        color: scheme.surfaceContainer,
        child: SizedBox(
          height: 260,
          child: Column(
            children: [
              TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  for (final (icon, label, _) in categories)
                    Tab(icon: Icon(icon, semanticLabel: label)),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    for (final (_, _, emojis) in categories)
                      GridView.extent(
                        maxCrossAxisExtent: 44,
                        padding: const EdgeInsets.all(8),
                        children: [
                          for (final emoji in emojis)
                            InkWell(
                              key: ValueKey('emoji-$emoji'),
                              borderRadius: BorderRadius.circular(8),
                              onTap: () => onSelected(emoji),
                              child: Center(
                                child: Text(
                                  emoji,
                                  style: const TextStyle(fontSize: 26),
                                ),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
