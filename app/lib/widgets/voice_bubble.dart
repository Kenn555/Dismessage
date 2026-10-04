import 'package:flutter/material.dart';

import '../services/chat_session.dart';
import '../services/voice_player.dart';
import '../services/voice_recorder.dart';
import '../theme/app_theme.dart';

/// A voice message: play / pause, progress and duration.
class VoiceBubble extends StatelessWidget {
  const VoiceBubble({
    super.key,
    required this.voice,
    required this.player,
    this.header,
  });

  final ChatVoice voice;
  final VoicePlayer player;

  /// Reply quote, if this message answers another one.
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mine = voice.fromMe;
    final foreground = mine ? Colors.white : scheme.onSurface;
    const big = Radius.circular(20);
    const small = Radius.circular(6);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
      constraints: const BoxConstraints(maxWidth: 300),
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
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 0, 6),
              child: header,
            ),
          ListenableBuilder(
            listenable: player,
            builder: (context, _) {
              final playing = player.isPlaying(voice);
              final position = player.positionOf(voice);
              final total = voice.duration.inMilliseconds;
              final progress = total == 0
                  ? 0.0
                  : (position.inMilliseconds / total).clamp(0.0, 1.0);
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: ValueKey('voice-play-${voice.id}'),
                    tooltip: playing ? 'Pause' : 'Écouter',
                    color: foreground,
                    icon: Icon(
                      playing
                          ? Icons.pause_circle_filled_rounded
                          : Icons.play_circle_fill_rounded,
                      size: 38,
                    ),
                    onPressed: () => player.toggle(voice),
                  ),
                  SizedBox(
                    width: 150,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 4,
                        color: foreground,
                        backgroundColor: foreground.withValues(alpha: 0.25),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    formatVoiceDuration(
                      position > Duration.zero ? position : voice.duration,
                    ),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: foreground,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
