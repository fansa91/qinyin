import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/player_service.dart';
import '../services/play_queue.dart';
import 'cover_image.dart';
import 'seek_bar.dart';

/// 迷你播放条（移动端）与桌面通栏播放条共用组件。
/// 桌面通栏时 [fullBar] 为 true，额外显示进度与队列/循环/音量控制。
class MiniPlayer extends StatelessWidget {
  final VoidCallback? onTapCover;
  final bool fullBar;
  const MiniPlayer({super.key, this.onTapCover, this.fullBar = false});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final track = player.currentTrack;
    if (track == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final progress = player.duration.inMilliseconds > 0
        ? player.position.inMilliseconds / player.duration.inMilliseconds
        : 0.0;
    return Material(
      color: scheme.surfaceContainer,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 桌面通栏：可拖动 SeekBar（此前是只读 LinearProgressIndicator，
          // 点/拖都没反应——即用户报的「进度条无法操作」）；紧凑迷你条保留
          // 2px 只读进度线（点封面进播放页用完整 SeekBar）。
          if (fullBar)
            SeekBar(
              position: player.position,
              duration: player.duration,
              onSeek: player.seek,
            )
          else
            LinearProgressIndicator(
              value: progress.clamp(0, 1).toDouble(),
              minHeight: 2,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          InkWell(
            onTap: onTapCover,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  CoverImage(cover: track.cover, width: 44, height: 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(track.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall),
                        Text(track.artistNames,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                  if (fullBar) ...[
                    IconButton(
                      icon: const Icon(Icons.skip_previous),
                      onPressed: player.prev,
                    ),
                  ],
                  IconButton(
                    icon: Icon(player.loading
                        ? Icons.hourglass_top
                        : player.playing
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_filled),
                    iconSize: 34,
                    onPressed: player.toggle,
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next),
                    onPressed: player.next,
                  ),
                  if (fullBar) ...[
                    IconButton(
                      tooltip: player.mode.label,
                      icon: Icon(switch (player.mode.name) {
                        'shuffle' => Icons.shuffle,
                        'single' => Icons.repeat_one,
                        _ => Icons.repeat,
                      }),
                      onPressed: player.cycleMode,
                    ),
                    SizedBox(
                      width: 110,
                      child: Slider(
                        value: player.settings.volume,
                        onChanged: player.setVolume,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
