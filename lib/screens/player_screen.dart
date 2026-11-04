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
import '../widgets/track_badges.dart';

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
            return _FreshContent(track: track, seo: data, isCurrent: isCurrent);
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

/// 新鲜模式单页内容：头部行 + 封面区（横向分页：右滑进歌词页）+
/// 进度条 + 底键。歌词/评论不再用页签（移动端已撤，桌面页签不动）：
/// - 歌词：封面区横向 PageView（左=歌词页、右=封面页，初始停封面
///   页），与推荐页同方向口径；歌词用共享 [LyricList] 且禁手动
///   滚动，纵向手势留给外层 FreshPager 切歌，不被横向分页误吞；
/// - 评论：点计数行评论入口开遮盖式抽屉（与推荐页同款：浮层盖在
///   本页之上、底层不动，高度 ≈50% 屏高，用户定版口径）。
class _FreshContent extends StatefulWidget {
  final Track track;
  final SeoTrack? seo;
  final bool isCurrent;
  const _FreshContent({
    required this.track,
    required this.seo,
    required this.isCurrent,
  });

  @override
  State<_FreshContent> createState() => _FreshContentState();
}

class _FreshContentState extends State<_FreshContent> {
  /// 封面区横向分页：0 歌词页（在左）、1 封面页（初始停靠页）
  late final PageController _hController = PageController(initialPage: 1);

  @override
  void dispose() {
    _hController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final seo = widget.seo;
    final isCurrent = widget.isCurrent;
    final player = context.watch<PlayerService>();
    final scheme = Theme.of(context).colorScheme;
    final fullTrack = seo?.track ?? track;
    final lines = seo?.lyricLines ?? const <LyricLine>[];
    final currentLineIndex = isCurrent
        ? lyricIndexAt(lines, player.position)
        : -1;
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
                child: Text(
                  '新鲜模式',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.search),
                onPressed: () => Navigator.pushNamed(context, '/search'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 封面区横向分页：右滑进歌词页、左滑回封面页（点封面同效）
          Expanded(
            child: PageView(
              controller: _hController,
              children: [
                _lyricsPane(context, lines, currentLineIndex),
                _coverPane(context, fullTrack, seo, isCurrent),
              ],
            ),
          ),
          const SizedBox(height: 8),
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
                icon: Icon(
                  player.loading && isCurrent
                      ? Icons.hourglass_top
                      : (player.playing && isCurrent)
                      ? Icons.pause
                      : Icons.play_arrow,
                ),
                onPressed: () async {
                  if (isCurrent) {
                    await player.toggle();
                  } else {
                    await player.jumpTo(
                      player.queueItems.indexWhere((t) => t.id == track.id),
                    );
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
              child: Text(
                player.error!,
                style: TextStyle(color: scheme.error, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  /// 封面页（横向分页右侧页）：封面/歌名/歌手/互动计数排。
  /// 点封面滑到左侧歌词页（与右滑同效）。
  Widget _coverPane(
    BuildContext context,
    Track fullTrack,
    SeoTrack? seo,
    bool isCurrent,
  ) {
    final track = widget.track;
    final player = context.watch<PlayerService>();
    final library = context.watch<LibraryService>();
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => _hController.animateToPage(
            0,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          ),
          child: CoverImage(
            cover: fullTrack.cover,
            width: double.infinity,
            height: MediaQuery.sizeOf(context).height * 0.30,
            radius: 16,
            small: false,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          fullTrack.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 4),
        Text(
          fullTrack.artistNames,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        if (fullTrack.albumName.isNotEmpty) ...[
          const SizedBox(height: 4),
          AlbumLine(albumName: fullTrack.albumName),
        ],
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
              onTap: seo == null ? null : () => _showComments(context, seo),
            ),
            const SizedBox(width: 18),
            _StatButton(
              icon: Icons.share_outlined,
              label: formatCount(fullTrack.countShared ?? 0),
              onTap: () => SharePlus.instance.share(
                ShareParams(
                  text: '我在沁音听《${fullTrack.name}》- ${fullTrack.artistNames}',
                ),
              ),
            ),
            const SizedBox(width: 18),
            TrackDownloadButton(track: fullTrack),
            const Spacer(),
            ActionChip(
              avatar: const Icon(Icons.high_quality, size: 16),
              label: Text(
                isCurrent && player.currentQuality != null
                    ? SettingsService.qualityLabel(
                        player.currentQuality!,
                      ).split(' ').first
                    : '音质',
              ),
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
                Text('正在准备无损（下载并解密中）…', style: TextStyle(fontSize: 12)),
              ],
            ),
          ),
      ],
    );
  }

  /// 歌词页（横向分页左侧页）：与推荐页歌词页同形态（标题行 +
  /// 共享 [LyricList]）；禁手动滚动，纵向手势留给外层切歌。
  Widget _lyricsPane(
    BuildContext context,
    List<LyricLine> lines,
    int currentLineIndex,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.lyrics_outlined, size: 18, color: scheme.primary),
            const SizedBox(width: 6),
            Text('歌词', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            Text(
              '左滑回封面',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: LyricList(
            lines: lines,
            currentIndex: currentLineIndex,
            userScrollable: false,
          ),
        ),
      ],
    );
  }

  /// 评论抽屉（遮盖式，与推荐页同款）：showModalBottomSheet 浮层
  /// 盖在本页之上，底层不动；高度 ≈50% 屏高（用户定版口径），
  /// 带拖动把手，可下拉/点遮罩关闭。内容复用共享 [CommentsList]。
  void _showComments(BuildContext context, SeoTrack seo) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.sizeOf(ctx).height * 0.5,
        child: SafeArea(
          top: false,
          child: CommentsList(comments: seo.comments),
        ),
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
              subtitle: Text('无损仅推荐流部分曲目提供，其余最高 AAC ≈258k'),
            ),
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
  const _StatButton({
    required this.icon,
    required this.label,
    this.onTap,
    this.active = false,
  });

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
  const _BottomKey({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 桌面双栏播放页：左封面 + 右歌词列
// ---------------------------------------------------------------------------

class DesktopPlayer extends StatelessWidget {
  /// 嵌入推荐页时为 true（壳层通栏播放条在推荐页隐藏，用户定版）：
  /// - 展示与控制全程绑定**推荐会话**（会话隔离）：当前曲/进度/
  ///   切歌都读 PlayerService 的推荐会话视图，未占用输出时 seo 走
  ///   resolver 缓存，绝不拿主会话状态冒充；
  /// - 封面下方内置控制行（进度 SeekBar + 上一首/播放暂停/下一首），
  ///   否则推荐页将没有任何进度/播放控制；
  /// - AppBar 不再放队列按钮——与推荐页头的「已加载列表」重复，
  ///   推荐页内只留页头那一个入口；
  /// - Scaffold/AppBar 底色与推荐页顶部同色（页面顶色公式）。
  /// 独立播放页（false，缺省）行为不变：绑定主会话（引擎视图），
  /// 控制走壳层通栏条，队列按钮保留在本处 AppBar。
  final bool embedded;
  const DesktopPlayer({super.key, this.embedded = false});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final track = embedded ? player.recommendCurrentTrack : player.currentTrack;
    if (track == null) {
      return const Scaffold(body: Center(child: Text('暂无播放内容')));
    }
    final seo = embedded
        ? (player.recommendIsActive ? player.currentSeo : null) ??
              context.read<PlayResolver>().cachedSeo(track.id)
        : player.currentSeo;
    final fullTrack = seo?.track ?? track;
    final lines = seo?.lyricLines ?? const <LyricLine>[];
    final position = embedded ? player.recommendPosition : player.position;
    final duration = embedded ? player.recommendDuration : player.duration;
    final playing = embedded ? player.recommendPlaying : player.playing;
    final loading = embedded ? player.recommendLoading : player.loading;
    final preparing = embedded
        ? player.recommendPreparingLossless
        : player.preparingLossless;
    final quality = embedded ? player.recommendQuality : player.currentQuality;
    final idx = lyricIndexAt(lines, position);
    final scheme = Theme.of(context).colorScheme;
    // 桌面推荐页顶部同色：embedded 时整页垫页面顶色（与推荐页
    // header/状态栏区同一公式），无色块分界
    final topColor = embedded ? recommendPageTopColor(context, track) : null;
    return Scaffold(
      backgroundColor: topColor,
      appBar: AppBar(
        backgroundColor: topColor,
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
          if (!embedded)
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
            // 矮窗口时左栏（封面+控制行+信息）可能超高：可滚动兜底，
            // 够高时仍垂直居中（embedded 控制行加入后总高变大）
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
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
                        if (embedded) ...[
                          // 封面下方即控制行（与移动端推荐页同一精神）：
                          // 壳层通栏条在推荐页隐藏，进度与切歌/播放暂停靠
                          // 这里，且全程走推荐会话入口（隔离口径）
                          const SizedBox(height: 16),
                          SizedBox(
                            width: 360,
                            child: SeekBar(
                              position: position,
                              duration: duration,
                              onSeek: player.recommendSeek,
                              showTimes: true,
                            ),
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.skip_previous),
                                iconSize: 30,
                                onPressed: player.recommendPrev,
                              ),
                              const SizedBox(width: 8),
                              IconButton.filled(
                                iconSize: 30,
                                icon: Icon(
                                  loading
                                      ? Icons.hourglass_top
                                      : playing
                                      ? Icons.pause
                                      : Icons.play_arrow,
                                ),
                                onPressed: player.toggleRecommend,
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                icon: const Icon(Icons.skip_next),
                                iconSize: 30,
                                onPressed: player.recommendNext,
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 24),
                        // 歌名 + 徽标（与移动端 TrackTile 同一套：音质 + VIP；
                        // 桌面推荐页此前缺失，本次对齐补上）
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Flexible(
                              child: Text(
                                fullTrack.name,
                                style: Theme.of(
                                  context,
                                ).textTheme.headlineSmall,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (fullTrack.topQuality.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              QualityBadge(topQuality: fullTrack.topQuality),
                            ],
                            if (fullTrack.isVip) ...[
                              const SizedBox(width: 8),
                              const VipBadge(),
                            ],
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          fullTrack.artistNames,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                        if (fullTrack.albumName.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          AlbumLine(
                            albumName: fullTrack.albumName,
                            center: true,
                          ),
                        ],
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
                        if (preparing)
                          const Padding(
                            padding: EdgeInsets.only(top: 14),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                                SizedBox(width: 8),
                                Text(
                                  '正在准备无损（下载并解密中）…',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        if (quality != null &&
                            SettingsService.qualityOptions.contains(quality))
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Chip(
                              avatar: const Icon(Icons.high_quality, size: 16),
                              label: Text(
                                SettingsService.qualityLabel(
                                  quality,
                                ).split(' ').first,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
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
                            .map(
                              (e) =>
                                  '${_makerLabel(e.key)}：${e.value.join('、')}',
                            )
                            .join('   '),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
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
                                LyricList(lines: lines, currentIndex: idx),
                                CommentsList(
                                  comments: seo?.comments ?? const [],
                                ),
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
        // ListenableBuilder 让表头播放/暂停键与列表选中态跟随全局
        // 播放状态实时同步（点表头键不关表、图标原地翻转）
        child: ListenableBuilder(
          listenable: player,
          builder: (ctx, _) {
            final current = player.currentTrack;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.queue_music),
                  title: const Text('播放队列'),
                  subtitle: current == null
                      ? null
                      : Text(
                          '《${current.name}》- ${current.artistNames}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                  // 队列页原本只能点选跳播、没有暂停入口（用户实报）：
                  // 表头补与全局状态同步的播放/暂停键
                  trailing: IconButton.filled(
                    tooltip: player.playing ? '暂停' : '播放',
                    icon: Icon(
                      player.loading
                          ? Icons.hourglass_top
                          : player.playing
                              ? Icons.pause
                              : Icons.play_arrow,
                    ),
                    onPressed: current == null ? null : player.toggle,
                  ),
                ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: player.queueItems.length,
                    itemBuilder: (_, i) {
                      final t = player.queueItems[i];
                      return ListTile(
                        leading:
                            CoverImage(cover: t.cover, width: 40, height: 40),
                        // 徽标与移动端 TrackTile 同一套（音质 + VIP）
                        title: Row(
                          children: [
                            Flexible(
                              child: Text(
                                t.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (t.topQuality.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              QualityBadge(topQuality: t.topQuality),
                            ],
                            if (t.isVip) ...[
                              const SizedBox(width: 6),
                              const VipBadge()
                            ],
                          ],
                        ),
                        subtitle: Text(
                          t.artistNames,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        selected: i == player.currentIndex,
                        onTap: () {
                          player.jumpTo(i);
                          Navigator.pop(ctx);
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 歌词滚动列表（当前行高亮 + 自动滚动）。播放页与推荐页的歌词页共用
/// 同一份实现（推荐页经 player_screen 导出复用，不要再造第二份）。
/// [userScrollable]=false 时禁用手动滚动（新鲜模式页内嵌用法：纵向手势
/// 要留给 PageView 切歌，不能被歌词列表抢走；自动滚动不受影响）。
class LyricList extends StatefulWidget {
  final List<LyricLine> lines;
  final int currentIndex;
  final bool userScrollable;
  const LyricList({
    super.key,
    required this.lines,
    required this.currentIndex,
    this.userScrollable = true,
  });

  @override
  State<LyricList> createState() => LyricListState();
}

class LyricListState extends State<LyricList> {
  final ScrollController _controller = ScrollController();

  @override
  void didUpdateWidget(LyricList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentIndex != oldWidget.currentIndex &&
        widget.currentIndex >= 0) {
      // 等一帧再滚：PageView 页内初建/切换时 controller 可能尚未挂载，
      // 直接 animateTo 会抛 'ScrollController not attached'
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_controller.hasClients) return;
        final target = (widget.currentIndex * 44.0 - 120).clamp(
          0,
          double.infinity,
        );
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
      physics: widget.userScrollable
          ? null
          : const NeverScrollableScrollPhysics(),
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
    final isCurrent = player.currentTrack?.id == seo.track.id;
    final idx = isCurrent ? lyricIndexAt(lines, player.position) : -1;
    // 曲目头补专辑名：标题两行——歌名 + 「歌手 · 专辑」（有的才拼）
    final subtitle = [
      if (seo.track.artistNames.isNotEmpty) seo.track.artistNames,
      if (seo.track.albumName.isNotEmpty) seo.track.albumName,
    ].join(' · ');
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              seo.track.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).appBarTheme.titleTextStyle ??
                  Theme.of(context).textTheme.titleLarge,
            ),
            if (subtitle.isNotEmpty)
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
          ],
        ),
        actions: [
          // 正在播放页补播放/暂停（本页展示的正是当前曲时才有）：
          // 与全局状态同步，暂停/续播当前曲；非当前曲不显示，
          // 避免在本页误控别的曲目
          if (isCurrent)
            IconButton(
              tooltip: player.playing ? '暂停' : '播放',
              icon: Icon(
                player.loading
                    ? Icons.hourglass_top
                    : player.playing
                        ? Icons.pause
                        : Icons.play_arrow,
              ),
              onPressed: player.toggle,
            ),
        ],
      ),
      body: LyricList(lines: lines, currentIndex: idx),
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
          title: Text('游客模式仅可查看评论，不可发表/点赞', style: TextStyle(fontSize: 12)),
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
                            child: Text(
                              c.nickname,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          const Icon(Icons.favorite, size: 14),
                          const SizedBox(width: 2),
                          Text(
                            formatCount(c.diggCount),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
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
