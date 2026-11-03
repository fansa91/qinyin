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
/// - 纵向 PageView 承载整条队列，一页一首；
/// - 用户滑动落点 onPageChanged → 与按钮完全相同的推进入口：
///   LIST/SINGLE 走 PlayerService.jumpTo（队列线性定位），
///   SHUFFLE 按滑动方向走 PlayerService.next()/prev()（随机/历史栈）；
/// - 反过来，按钮切歌、播完自动推进改变 currentIndex 时，
///   监听器把 PageView 同步动画到新下标（_syncGuard 防回环）。
/// 两种方向最终都汇入 PlayerService._playAt（含预取与续拉）。
class FreshPlayer extends StatefulWidget {
  const FreshPlayer({super.key});

  @override
  State<FreshPlayer> createState() => _FreshPlayerState();
}

class _FreshPlayerState extends State<FreshPlayer> {
  PageController? _controller;
  PlayerService? _player;
  bool _syncGuard = false;
  int _lastIndex = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final player = context.read<PlayerService>();
    if (_player != player) {
      _player?.removeListener(_onPlayerChanged);
      _player = player;
      _lastIndex = player.currentIndex;
      _controller?.dispose();
      _controller = PageController(initialPage: player.currentIndex);
      player.addListener(_onPlayerChanged);
    }
  }

  @override
  void dispose() {
    _player?.removeListener(_onPlayerChanged);
    _controller?.dispose();
    super.dispose();
  }

  /// 播放器下标变化（按钮/自动推进）→ 同步 PageView
  void _onPlayerChanged() {
    final player = _player;
    final controller = _controller;
    if (player == null || controller == null || !controller.hasClients) return;
    final page = controller.page?.round();
    if (page != null && page != player.currentIndex) {
      _syncGuard = true;
      controller
          .animateToPage(
            player.currentIndex,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          )
          .whenComplete(() => _syncGuard = false);
    }
    if (mounted) setState(() => _lastIndex = player.currentIndex);
  }

  /// 用户滑动落点 → 队列推进（与按钮共用入口）
  Future<void> _onSwipe(int page) async {
    final player = _player;
    if (player == null || _syncGuard) return;
    if (page == player.currentIndex) return;
    if (player.mode == QueueLoopMode.shuffle) {
      if (page > _lastIndex) {
        await player.next();
      } else {
        await player.prev();
      }
      _onPlayerChanged();
    } else {
      await player.jumpTo(page);
    }
    _lastIndex = player.currentIndex;
  }

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
      body: PageView.builder(
        controller: _controller,
        scrollDirection: Axis.vertical,
        itemCount: player.queueItems.length,
        onPageChanged: _onSwipe,
        itemBuilder: (context, i) =>
            _FreshPage(track: player.queueItems[i], index: i),
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

class _FreshContent extends StatelessWidget {
  final Track track;
  final SeoTrack? seo;
  final bool isCurrent;
  const _FreshContent(
      {required this.track, required this.seo, required this.isCurrent});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final library = context.watch<LibraryService>();
    final scheme = Theme.of(context).colorScheme;
    final fullTrack = seo?.track ?? track;
    final lines = seo?.lyricLines ?? const <LyricLine>[];
    final currentLineIndex =
        isCurrent ? lyricIndexAt(lines, player.position) : -1;
    final currentLyric = lines.isEmpty
        ? ''
        : lines[(currentLineIndex < 0 ? 0 : currentLineIndex)
                .clamp(0, lines.length - 1)]
            .text;
    final progress = player.duration.inMilliseconds > 0
        ? player.position.inMilliseconds / player.duration.inMilliseconds
        : 0.0;
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
            onTap: seo == null
                ? null
                : () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => LyricsScreen(seo: seo!),
                      ),
                    ),
            child: CoverImage(
              cover: fullTrack.cover,
              width: double.infinity,
              height: MediaQuery.sizeOf(context).height * 0.38,
              radius: 16,
              small: false,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            currentLyric,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
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
                    : () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => CommentsScreen(seo: seo!),
                          ),
                        ),
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
          const Spacer(),
          if (isCurrent) ...[
            Slider(
              value: progress.clamp(0, 1).toDouble(),
              onChanged: (v) => player.seek(
                  Duration(milliseconds: (v * player.duration.inMilliseconds).round())),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(formatDurationMs(player.position.inMilliseconds),
                    style: Theme.of(context).textTheme.bodySmall),
                Text(formatDurationMs(player.duration.inMilliseconds),
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ] else
            const SizedBox(height: 48),
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
            const ListTile(title: Text('播放音质（游客最高 AAC ≈258k）')),
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
                    ],
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
                  Expanded(child: _LyricList(lines: lines, currentIndex: idx)),
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

/// 歌词滚动列表（当前行高亮 + 自动滚动）
class _LyricList extends StatefulWidget {
  final List<LyricLine> lines;
  final int currentIndex;
  const _LyricList({required this.lines, required this.currentIndex});

  @override
  State<_LyricList> createState() => _LyricListState();
}

class _LyricListState extends State<_LyricList> {
  final ScrollController _controller = ScrollController();

  @override
  void didUpdateWidget(_LyricList old) {
    super.didUpdateWidget(old);
    if (widget.currentIndex != old.currentIndex && widget.currentIndex >= 0) {
      final target = (widget.currentIndex * 44.0 - 120).clamp(0, double.infinity);
      _controller.animateTo(
        target.toDouble(),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
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

class CommentsScreen extends StatelessWidget {
  final SeoTrack seo;
  const CommentsScreen({super.key, required this.seo});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('评论')),
      body: Column(
        children: [
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('游客模式仅可查看评论，不可发表/点赞'),
          ),
          const Divider(),
          Expanded(
            child: seo.comments.isEmpty
                ? const Center(child: Text('暂无评论'))
                : ListView.separated(
                    itemCount: seo.comments.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final c = seo.comments[i];
                      return ListTile(
                        title: Row(
                          children: [
                            Expanded(
                              child: Text(c.nickname,
                                  style: Theme.of(context).textTheme.titleSmall),
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
      ),
    );
  }
}

// 保持种子色引用（主题在 main 接线）
const Color qinyinSeed = kDefaultSeed;
