import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/responsive.dart';
import '../core/theme.dart';
import '../core/utils.dart';
import '../models/models.dart';
import '../services/library_service.dart';
import '../services/play_queue.dart';
import '../services/play_resolver.dart';
import '../services/player_service.dart';
import '../services/settings_service.dart';
import '../widgets/cover_image.dart';
import '../widgets/download_button.dart';
import '../widgets/fresh_pager.dart';
import '../widgets/seek_bar.dart';

/// 播放页：移动端为新鲜模式（纵向 PageView 上下滑切歌），
/// 桌面 ≥900 为官方双栏（左封面 + 右歌词列）。
class PlayerScreen extends StatelessWidget {
  const PlayerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    if (isExpanded(context)) return const DesktopPlayer();
    return const FreshPlayer();
  }
}

// ---------------------------------------------------------------------------
// 移动端新鲜模式
// ---------------------------------------------------------------------------

/// 上下滑切歌实现说明（硬性口径）：
/// - 纵向 PageView 承载整条队列，一页一首，机制在 [FreshPager] 组件里
///   （播放页与推荐页组件级共用，全 App 只有一份实现）；
/// - 用户滑动落点 → 与按钮完全相同的推进入口（jumpTo / next / prev）；
/// - 按钮切歌、播完自动推进改变下标时，FreshPager 监听并同步 PageView。
/// 两种方向最终都汇入 PlayerService._playAt（含预取与续拉）。
class FreshPlayer extends StatelessWidget {
  const FreshPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    if (!player.hasQueue) {
      return Scaffold(
        appBar: AppBar(title: const Text('新鲜模式')),
        body: const Center(child: Text('暂无播放队列')),
      );
    }
    return Scaffold(
      body: FreshPager(
        pageBuilder: (context, track, i) => _FreshPage(track: track, index: i),
      ),
    );
  }
}

class _FreshPage extends StatelessWidget {
  final Track track;
  final int index;
  const _FreshPage({required this.track, required this.index});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final resolver = context.read<PlayResolver>();
    final isCurrent = player.currentIndex == index;
    final seo = isCurrent
        ? player.currentSeo ?? resolver.cachedSeo(track.id)
        : resolver.cachedSeo(track.id);
    final tint = _tintOf(track, context);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            tint.withValues(alpha: 0.55),
            Theme.of(context).scaffoldBackgroundColor,
          ],
        ),
      ),
      child: SafeArea(
        child: FutureBuilder<SeoTrack>(
          future: seo != null ? Future.value(seo) : resolver.seo(track.id),
          builder: (context, snap) {
            final data = snap.data;
            return _FreshContent(
              track: track,
              seo: data,
              isCurrent: isCurrent,
            );
          },
        ),
      ),
    );
  }

  Color _tintOf(Track track, BuildContext context) {
    final hex = track.coverColorHex;
    if (hex != null && hex.length == 6) {
      final v = int.tryParse(hex, radix: 16);
      if (v != null) return Color(0xFF000000 | v);
    }
    return Theme.of(context).colorScheme.primaryContainer;
  }
}

/// 新鲜模式单页内容：封面/歌曲信息/互动排 + 歌词·评论切换页签 + 进度条 + 底键。
/// 歌词与评论在同一区域二选一切换（页签），不再跳独立页。
class _FreshContent extends StatefulWidget {
  final Track track;
  final SeoTrack? seo;
  final bool isCurrent;
  const _FreshContent(
      {required this.track, required this.seo, required this.isCurrent});

  @override
  State<_FreshContent> createState() => _FreshContentState();
}

class _FreshContentState extends State<_FreshContent> {
  int _tab = 0; // 0 歌词 1 评论

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final seo = widget.seo;
    final isCurrent = widget.isCurrent;
    final player = context.watch<PlayerService>();
    final library = context.watch<LibraryService>();
    final scheme = Theme.of(context).colorScheme;
    final fullTrack = seo?.track ?? track;
    final lines = seo?.lyricLines ?? const <LyricLine>[];
    final currentLineIndex =
        isCurrent ? lyricIndexAt(lines, player.position) : -1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_down),
                onPressed: () => Navigator.pop(context),
              ),
              const Expanded(
                child: Text('新鲜模式',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              ),
              IconButton(
                icon: const Icon(Icons.search),
                onPressed: () => Navigator.pushNamed(context, '/search'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          GestureDetector(
            // 点封面切到歌词页签（原跳独立歌词页，已改页签形态）
            onTap: () => setState(() => _tab = 0),
            child: CoverImage(
              cover: fullTrack.cover,
              width: double.infinity,
              height: MediaQuery.sizeOf(context).height * 0.30,
              radius: 16,
              small: false,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  fullTrack.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            fullTrack.artistNames,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _StatButton(
                icon: library.isFavTrack(track.id)
                    ? Icons.favorite
                    : Icons.favorite_border,
                label: formatCount(fullTrack.countCollected ?? 0),
                active: library.isFavTrack(track.id),
                onTap: () => library.toggleFavTrack(fullTrack),
              ),
              const SizedBox(width: 18),
              _StatButton(
                icon: Icons.mode_comment_outlined,
                label: formatCount(fullTrack.countComment ?? 0),
                onTap: seo == null
                    ? null
                    : () => setState(() => _tab = 1),
              ),
              const SizedBox(width: 18),
              _StatButton(
                icon: Icons.share_outlined,
                label: formatCount(fullTrack.countShared ?? 0),
                onTap: () => SharePlus.instance.share(
                  ShareParams(
                      text: '我在沁音听《${fullTrack.name}》- ${fullTrack.artistNames}'),
                ),
              ),
              const SizedBox(width: 18),
              TrackDownloadButton(track: fullTrack),
              const Spacer(),
              ActionChip(
                avatar: const Icon(Icons.high_quality, size: 16),
                label: Text(isCurrent && player.currentQuality != null
                    ? SettingsService.qualityLabel(player.currentQuality!)
                        .split(' ')
                        .first
                    : '音质'),
                onPressed: () => _showQualitySheet(context),
              ),
            ],
          ),
          if (isCurrent && player.preparingLossless)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('正在准备无损（下载并解密中）…',
                      style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
          const SizedBox(height: 12),
          // 歌词 / 评论切换页签（同一区域二选一）
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, icon: Icon(Icons.lyrics_outlined, size: 16), label: Text('歌词')),
              ButtonSegment(value: 1, icon: Icon(Icons.mode_comment_outlined, size: 16), label: Text('评论')),
            ],
            selected: {_tab},
            onSelectionChanged: (s) => setState(() => _tab = s.first),
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: _tab == 0
                ? _LyricList(
                    lines: lines,
                    currentIndex: currentLineIndex,
                    userScrollable: false,
                  )
                : CommentsList(comments: seo?.comments ?? const []),
          ),
          if (isCurrent)
            SeekBar(
              position: player.position,
              duration: player.duration,
              onSeek: player.seek,
              showTimes: true,
            )
          else
            const SizedBox(height: 76),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _BottomKey(
                icon: Icons.explore_outlined,
                label: '发现',
                onTap: () => Navigator.popUntil(context, (r) => r.isFirst),
              ),
              IconButton.filled(
                iconSize: 34,
                icon: Icon(player.loading && isCurrent
                    ? Icons.hourglass_top
                    : (player.playing && isCurrent)
                        ? Icons.pause
                        : Icons.play_arrow),
                onPressed: () async {
                  if (isCurrent) {
                    await player.toggle();
                  } else {
                    await player.jumpTo(
                        player.queueItems.indexWhere((t) => t.id == track.id));
                  }
                },
              ),
              _BottomKey(
                icon: Icons.person_outline,
                label: '我的',
                onTap: () {
                  Navigator.popUntil(context, (r) => r.isFirst);
                },
              ),
            ],
          ),
          if (player.error != null && isCurrent)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(player.error!,
                  style: TextStyle(color: scheme.error, fontSize: 12)),
            ),
        ],
      ),
    );
  }

  void _showQualitySheet(BuildContext context) {
    final player = context.read<PlayerService>();
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
                title: Text('播放音质'),
                subtitle: Text('无损仅推荐流部分曲目提供，其余最高 AAC ≈258k')),
            for (final q in SettingsService.qualityOptions)
              RadioListTile<String>(
                value: q,
                groupValue: player.settings.defaultQuality,
                title: Text(SettingsService.qualityLabel(q)),
                onChanged: (v) {
                  if (v != null) player.setQuality(v);
                  Navigator.pop(ctx);
                },
              ),
            ListTile(
              leading: const Icon(Icons.repeat),
              title: Text('循环模式：${player.mode.label}'),
              subtitle: const Text('点按切换 列表循环 / 随机 / 单曲循环'),
              onTap: () {
                player.cycleMode();
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _StatButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool active;
  const _StatButton(
      {required this.icon, required this.label, this.onTap, this.active = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: active ? scheme.primary : null),
          const SizedBox(width: 4),
          Text(label),
        ],
      ),
    );
  }
}

class _BottomKey extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _BottomKey({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [Icon(icon), Text(label, style: const TextStyle(fontSize: 12))],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 桌面双栏播放页：左封面 + 右歌词列
// ---------------------------------------------------------------------------

class DesktopPlayer extends StatelessWidget {
  const DesktopPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final track = player.currentTrack;
    if (track == null) {
      return const Scaffold(body: Center(child: Text('暂无播放内容')));
    }
    final seo = player.currentSeo;
    final fullTrack = seo?.track ?? track;
    final lines = seo?.lyricLines ?? const <LyricLine>[];
    final idx = lyricIndexAt(lines, player.position);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('正在播放'),
        actions: [
          IconButton(
            tooltip: '循环模式：${player.mode.label}',
            icon: Icon(switch (player.mode) {
              QueueLoopMode.shuffle => Icons.shuffle,
              QueueLoopMode.single => Icons.repeat_one,
              QueueLoopMode.list => Icons.repeat,
            }),
            onPressed: player.cycleMode,
          ),
          IconButton(
            tooltip: '队列',
            icon: const Icon(Icons.queue_music),
            onPressed: () => _showQueue(context),
          ),
        ],
      ),
      body: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CoverImage(
                    cover: fullTrack.cover,
                    width: 360,
                    height: 360,
                    radius: 16,
                    small: false,
                  ),
                  const SizedBox(height: 24),
                  Text(fullTrack.name,
                      style: Theme.of(context).textTheme.headlineSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 6),
                  Text(fullTrack.artistNames,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.favorite_border, size: 18),
                      const SizedBox(width: 4),
                      Text(formatCount(fullTrack.countCollected ?? 0)),
                      const SizedBox(width: 20),
                      const Icon(Icons.mode_comment_outlined, size: 18),
                      const SizedBox(width: 4),
                      Text(formatCount(fullTrack.countComment ?? 0)),
                      const SizedBox(width: 20),
                      TrackDownloadButton(track: fullTrack),
                    ],
                  ),
                  if (player.preparingLossless)
                    const Padding(
                      padding: EdgeInsets.only(top: 14),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 8),
                          Text('正在准备无损（下载并解密中）…',
                              style: TextStyle(fontSize: 12)),
                        ],
                      ),
                    ),
                  if (player.currentQuality != null &&
                      SettingsService.qualityOptions
                          .contains(player.currentQuality))
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Chip(
                        avatar: const Icon(Icons.high_quality, size: 16),
                        label: Text(SettingsService.qualityLabel(
                                player.currentQuality!)
                            .split(' ')
                            .first),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 32, 32, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (fullTrack.makers.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        fullTrack.makers.entries
                            .map((e) =>
                                '${_makerLabel(e.key)}：${e.value.join('、')}')
                            .join('   '),
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  // 歌词 / 评论切换页签（与移动端同一口径）
                  Expanded(
                    child: DefaultTabController(
                      length: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const TabBar(
                            isScrollable: true,
                            tabAlignment: TabAlignment.start,
                            tabs: [
                              Tab(text: '歌词'),
                              Tab(text: '评论'),
                            ],
                          ),
                          Expanded(
                            child: TabBarView(
                              children: [
                                _LyricList(lines: lines, currentIndex: idx),
                                CommentsList(
                                    comments: seo?.comments ?? const []),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _makerLabel(String key) => switch (key) {
        'composers' => '作曲',
        'lyricists' => '作词',
        'arrangers' => '编曲',
        'producers' => '制作',
        _ => key,
      };

  void _showQueue(BuildContext context) {
    final player = context.read<PlayerService>();
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: player.queueItems.length,
          itemBuilder: (_, i) {
            final t = player.queueItems[i];
            return ListTile(
              leading: CoverImage(cover: t.cover, width: 40, height: 40),
              title: Text(t.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(t.artistNames,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              selected: i == player.currentIndex,
              onTap: () {
                player.jumpTo(i);
                Navigator.pop(ctx);
              },
            );
          },
        ),
      ),
    );
  }
}

/// 歌词滚动列表（当前行高亮 + 自动滚动）。
/// [userScrollable]=false 时禁用手动滚动（新鲜模式页内嵌用法：纵向手势
/// 要留给 PageView 切歌，不能被歌词列表抢走；自动滚动不受影响）。
class _LyricList extends StatefulWidget {
  final List<LyricLine> lines;
  final int currentIndex;
  final bool userScrollable;
  const _LyricList({
    required this.lines,
    required this.currentIndex,
    this.userScrollable = true,
  });

  @override
  State<_LyricList> createState() => _LyricListState();
}

class _LyricListState extends State<_LyricList> {
  final ScrollController _controller = ScrollController();

  @override
  void didUpdateWidget(_LyricList old) {
    super.didUpdateWidget(old);
    if (widget.currentIndex != old.currentIndex && widget.currentIndex >= 0) {
      // 等一帧再滚：PageView 页内初建/切换时 controller 可能尚未挂载，
      // 直接 animateTo 会抛 'ScrollController not attached'
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_controller.hasClients) return;
        final target =
            (widget.currentIndex * 44.0 - 120).clamp(0, double.infinity);
        _controller.animateTo(
          target.toDouble(),
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (widget.lines.isEmpty) {
      return const Center(child: Text('暂无歌词'));
    }
    return ListView.builder(
      controller: _controller,
      physics:
          widget.userScrollable ? null : const NeverScrollableScrollPhysics(),
      itemCount: widget.lines.length,
      itemBuilder: (context, i) {
        final active = i == widget.currentIndex;
        return SizedBox(
          height: 44,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              widget.lines[i].text,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: active ? scheme.primary : scheme.onSurfaceVariant,
                    fontWeight: active ? FontWeight.w700 : FontWeight.normal,
                    fontSize: active ? 19 : 16,
                  ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 全量歌词页 / 评论页
// ---------------------------------------------------------------------------

class LyricsScreen extends StatelessWidget {
  final SeoTrack seo;
  const LyricsScreen({super.key, required this.seo});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final lines = seo.lyricLines;
    final idx = player.currentTrack?.id == seo.track.id
        ? lyricIndexAt(lines, player.position)
        : -1;
    return Scaffold(
      appBar: AppBar(title: Text(seo.track.name)),
      body: _LyricList(lines: lines, currentIndex: idx),
    );
  }
}

/// 评论列表（只读）：播放页歌词/评论页签与独立评论页共用同一份实现。
/// 顶部带游客只读提示行。
class CommentsList extends StatelessWidget {
  final List<SeoComment> comments;
  const CommentsList({super.key, required this.comments});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const ListTile(
          dense: true,
          leading: Icon(Icons.info_outline, size: 18),
          title: Text('游客模式仅可查看评论，不可发表/点赞',
              style: TextStyle(fontSize: 12)),
        ),
        const Divider(height: 1),
        Expanded(
          child: comments.isEmpty
              ? const Center(child: Text('暂无评论'))
              : ListView.separated(
                  itemCount: comments.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final c = comments[i];
                    return ListTile(
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(c.nickname,
                                style:
                                    Theme.of(context).textTheme.titleSmall),
                          ),
                          const Icon(Icons.favorite, size: 14),
                          const SizedBox(width: 2),
                          Text(formatCount(c.diggCount),
                              style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(c.content),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class CommentsScreen extends StatelessWidget {
  final SeoTrack seo;
  const CommentsScreen({super.key, required this.seo});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('评论')),
      body: CommentsList(comments: seo.comments),
    );
  }
}

// 保持种子色引用（主题在 main 接线）
const Color qinyinSeed = kDefaultSeed;
