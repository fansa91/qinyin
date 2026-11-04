import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/utils.dart';
import '../services/player_service.dart';
import '../services/play_queue.dart';
import 'cover_image.dart';
import 'seek_bar.dart';
import 'track_badges.dart';

/// 迷你播放条（移动端）与桌面通栏播放条共用组件。
/// 桌面通栏时 [fullBar] 为 true，额外显示进度与队列/循环/音量控制。
/// [floating] 为移动壳层的悬浮形态：圆角卡片 + 阴影，由壳层用
/// Positioned 浮在页面内容之上（两侧小边距、接近满宽），不占布局
/// 高度；内部排布与高度与普通形态完全一致（不压扁）。桌面通栏不用。
class MiniPlayer extends StatelessWidget {
  final VoidCallback? onTapCover;
  final bool fullBar;
  final bool floating;
  const MiniPlayer({
    super.key,
    this.onTapCover,
    this.fullBar = false,
    this.floating = false,
  });

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    // 只绑定主会话：推荐会话占用输出时按「无主队列内容」隐藏——
    // 推荐曲目永不出现在 mini 条上（会话隔离，用户定版）
    if (!player.miniBarHasContent) return const SizedBox.shrink();
    final track = player.currentTrack!;
    final scheme = Theme.of(context).colorScheme;
    final progress = player.duration.inMilliseconds > 0
        ? player.position.inMilliseconds / player.duration.inMilliseconds
        : 0.0;
    // 副行形态分端（用户定版）：移动悬浮条是「歌手 · 3:33」——
    // 总时长拼行尾（引擎时长优先，未就绪退曲目元数据时长；都
    // 没有就不拼、不摆假数）；桌面通栏副行只要「歌手 · 专辑」
    // （复用 artistAlbumText，专辑为空只剩歌手名），不再拼时长
    // ——桌面端的时长由通栏进度条右端数字承担。
    final totalMs = player.duration.inMilliseconds > 0
        ? player.duration.inMilliseconds
        : track.durationMs;
    final artistLine = fullBar
        ? artistAlbumText(track)
        : totalMs > 0
            ? '${track.artistNames} · ${formatDurationMs(totalMs)}'
            : track.artistNames;
    return Material(
      color: scheme.surfaceContainer,
      elevation: floating ? 6 : 0,
      shadowColor: scheme.shadow,
      borderRadius: floating ? BorderRadius.circular(16) : BorderRadius.zero,
      clipBehavior: floating ? Clip.antiAlias : Clip.none,
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
              // 时间数字在进度条左右两端同行呈现（1:23 ━━━ 3:33），
              // 随位置流实时更新；拖动 seek 行为与原来一致
              showTimes: true,
              inlineTimes: true,
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
                        Text(artistLine,
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
