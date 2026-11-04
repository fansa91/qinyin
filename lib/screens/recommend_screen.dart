import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/responsive.dart';
import '../core/utils.dart';
import '../models/models.dart';
import '../services/play_resolver.dart';
import '../services/player_service.dart';
import '../services/qishui_service.dart';
import '../services/recommend_pager.dart';
import '../services/settings_service.dart';
import '../widgets/cover_image.dart';
import '../widgets/fresh_pager.dart';
import 'player_screen.dart';

/// 推荐：页面本体就是新鲜模式播放形态（定版样板图口径）。
///
/// 数据源（2026-11-04 实测，见 QISHUI_API.md §15）：官方推荐流经车机
/// 开放平台通道（open.douyin.com LunaOpenSDK）游客可直接取到，主源即它；
/// 平台源异常时自动回退 §14 的三源组合（相关歌曲 + 发现歌单 + 电台）。
/// 游客拿到的是未个性化版（官方自述「登录后推荐更准」），文案如实标注。
///
/// 形态：直接复用 [FreshPager]（与播放页同一份纵向 PageView + 队列推进
/// 实现），队列就是推荐流，队尾 loadMore 接 [RecommendPager]。
/// 桌面端（≥900）沿用现有双栏播放页 [DesktopPlayer]，不强求滑动。
///
/// 进页衔接策略（不打断优先）：
/// - 队列已是推荐流 → 直接展示，什么都不动；
/// - 有别的来源的曲目在播/已载入 → 不抢队列，先出提示页，
///   用户点「开始刷推荐」才接管（显式动作不算打断）；
/// - 什么都没在播 → 首次切到本页时自动以推荐流建队起播。
class RecommendScreen extends StatefulWidget {
  /// 当前是否被选中展示（IndexedStack 下靠它感知「进入本页」）
  final bool active;
  final VoidCallback? onGoHome;
  final VoidCallback? onGoMine;
  const RecommendScreen({
    super.key,
    this.active = false,
    this.onGoHome,
    this.onGoMine,
  });

  @override
  State<RecommendScreen> createState() => _RecommendScreenState();
}

enum RecommendEnter { showPager, showGate, startQueue }

/// 进页决策（纯函数，可测）：见 RecommendScreen 类注释的衔接策略
RecommendEnter decideRecommendEnter({
  required bool queueIsRecommend,
  required bool hasQueue,
  required bool hasCurrentTrack,
}) {
  if (queueIsRecommend && hasQueue) return RecommendEnter.showPager;
  if (hasCurrentTrack) return RecommendEnter.showGate;
  return RecommendEnter.startQueue;
}

class _RecommendScreenState extends State<RecommendScreen> {
  final List<Track> _tracks = [];
  RecommendPager? _pager;
  Future<void>? _initFuture;
  String? _initError;
  bool _enterHandled = false;
  bool _starting = false;
  bool _startFailed = false;

  @override
  void initState() {
    super.initState();
    _initFuture = _init();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) _onEnter();
    });
  }

  @override
  void didUpdateWidget(RecommendScreen old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      _enterHandled = false;
      _onEnter();
    }
    if (!widget.active) _enterHandled = false;
  }

  /// 构造一个全新的分页器（初始构造与「刷新换一批」共用同一条路，
  /// 保证刷新是真重建而不是假动作）。
  Future<RecommendPager> _createPager() async {
    final service = context.read<QishuiService>();
    // 主源（车机开放平台官方推荐流）不依赖 homeFeed：
    // homeFeed 只为回退源提供电台与歌单快照，失败时单独兜底为空
    final deviceId = await PlatformFeedService.loadOrCreateDeviceId();
    final platform = PlatformFeedService(deviceId: deviceId);
    HomeFeed? feed;
    try {
      feed = await service.homeFeed();
    } catch (_) {
      feed = null;
    }
    return RecommendPager(
      fetchPlatformPage: (cursor) => platform.songTabPage(cursor),
      fetchRelated: service.relatedTracks,
      fetchPlaylistList: (cursor) => service.discoverMix(cursor: cursor),
      fetchPlaylistTracks: (id, {cursor}) =>
          service.playlistDetail(id, cursor: cursor),
      fetchRadioPage: service.radioTracksPage,
      radioIds: feed?.radios.map((r) => r.id).toList() ?? const [],
    )..prime(
        playlists: feed?.playlists ?? const [],
        mixCursor: feed?.mixCursor,
        mixHasMore: feed?.mixHasMore ?? false,
      );
  }

  Future<void> _init() async {
    try {
      _pager = await _createPager();
      if (mounted) setState(() => _initError = null);
    } catch (e) {
      if (mounted) setState(() => _initError = '加载失败，请检查网络');
    }
  }

  bool _refreshing = false;

  /// 刷新换一批：新建分页器重新拉第一批，成功才换队列；
  /// 失败保留当前队列与已加载列表不动，只提示。刷新是用户显式动作，
  /// 允许接管队列（与进页「不打断优先」不冲突）。
  Future<void> _refresh() async {
    if (_refreshing || _starting) return;
    _refreshing = true;
    if (mounted) setState(() {});
    try {
      final pager = await _createPager();
      var first = await pager.nextPage();
      // 空批但还有后续时多翻两页，避免把空列表当新一批交付
      for (var i = 0; i < 2 && first.isEmpty && pager.hasMore; i++) {
        first = await pager.nextPage();
      }
      if (first.isEmpty) {
        throw StateError('推荐流返回空');
      }
      if (!mounted) return;
      _pager = pager;
      _tracks
        ..clear()
        ..addAll(first);
      await context.read<PlayerService>().playQueue(
            List.of(_tracks),
            0,
            loadMore: _fetchNext,
            tag: PlayerService.recommendQueueTag,
          );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('刷新失败，已保留当前内容')),
        );
      }
    } finally {
      _refreshing = false;
      if (mounted) setState(() {});
    }
  }

  /// 页面与播放队列共用同一个分页器：队列续拉回来的曲目同步进已加载列表，
  /// 刷着听、听着刷是同一条流。
  Future<List<Track>> _fetchNext() async {
    final pager = _pager;
    if (pager == null) return const [];
    final more = await pager.nextPage();
    if (more.isNotEmpty) _tracks.addAll(more);
    return more;
  }

  RecommendEnter _decide(PlayerService player) => decideRecommendEnter(
        queueIsRecommend: player.queueTag == PlayerService.recommendQueueTag,
        hasQueue: player.hasQueue,
        hasCurrentTrack: player.currentTrack != null,
      );

  void _onEnter() {
    if (_enterHandled) return;
    _enterHandled = true;
    final player = context.read<PlayerService>();
    if (_decide(player) == RecommendEnter.startQueue) {
      _startQueue();
    }
  }

  /// 以推荐流建队列并起播。force=true 为提示页按钮的显式接管
  /// （允许覆盖正在播的其他来源）；自动进入时若中途有别的曲目开始播，
  /// 临门一脚再查一次，变卦就放弃接管、让提示页接手。
  Future<void> _startQueue({bool force = false}) async {
    if (_starting) return;
    _starting = true;
    if (mounted) setState(() => _startFailed = false);
    try {
      await _initFuture;
      if (!mounted) return;
      if (_pager == null) {
        if (mounted) setState(() => _startFailed = true);
        return;
      }
      if (_tracks.isEmpty) {
        await _fetchNext();
        if (!mounted) return;
      }
      if (_tracks.isEmpty && !_pager!.hasMore) {
        if (mounted) setState(() => _startFailed = true);
        return;
      }
      final player = context.read<PlayerService>();
      if (!force && _decide(player) != RecommendEnter.startQueue) return;
      await player.playQueue(
        List.of(_tracks),
        0,
        loadMore: _fetchNext,
        tag: PlayerService.recommendQueueTag,
      );
    } catch (_) {
      if (mounted) setState(() => _startFailed = true);
    } finally {
      _starting = false;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final enter = _decide(player);
    if (enter == RecommendEnter.showPager) {
      if (isExpanded(context)) {
        // 桌面双栏播放形态之上保留推荐页头（刷新/列表/搜索入口不丢）
        return Column(
          children: [
            _header(context),
            const Expanded(child: DesktopPlayer()),
          ],
        );
      }
      return _buildSwipe(context);
    }
    if (enter == RecommendEnter.showGate) {
      return _buildGate(context, player);
    }
    // startQueue 分支：自动建队进行中 / 失败重试
    if (_initError != null || _startFailed) {
      return _buildError(context);
    }
    return _buildLoading(context);
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 8, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('推荐',
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 2),
                Text(
                  '官方推荐流 · 游客版（登录后推荐更准）',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '刷新推荐（换一批）',
            icon: _refreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: _refreshing ? null : _refresh,
          ),
          IconButton(
            tooltip: '已加载列表',
            icon: const Icon(Icons.queue_music),
            onPressed: _tracks.isEmpty ? null : () => _showLoadedList(context),
          ),
          IconButton(
            tooltip: '搜索',
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.pushNamed(context, '/search'),
          ),
        ],
      ),
    );
  }

  Widget _buildSwipe(BuildContext context) {
    final player = context.watch<PlayerService>();
    return Column(
      children: [
        _header(context),
        Expanded(
          child: Stack(
            children: [
              FreshPager(
                pageBuilder: (context, track, i) => _RecommendFreshPage(
                  track: track,
                  index: i,
                  onGoHome: widget.onGoHome,
                  onGoMine: widget.onGoMine,
                ),
              ),
              // 右侧页指示点（窗口化：以当前页为中心最多 9 个）
              Positioned(
                right: 6,
                top: 0,
                bottom: 0,
                child: Center(child: _pageDots(player)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _pageDots(PlayerService player) {
    final total = player.queueItems.length;
    if (total < 2) return const SizedBox.shrink();
    const window = 9;
    var start = player.currentIndex - window ~/ 2;
    if (start < 0) start = 0;
    if (start + window > total) start = (total - window).clamp(0, total);
    final count = total - start > window ? window : total - start;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var k = 0; k < count; k++)
          Container(
            width: (start + k) == player.currentIndex ? 7 : 5,
            height: (start + k) == player.currentIndex ? 7 : 5,
            margin: const EdgeInsets.symmetric(vertical: 3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: (start + k) == player.currentIndex
                  ? scheme.primary
                  : scheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
          ),
      ],
    );
  }

  Widget _buildGate(BuildContext context, PlayerService player) {
    final t = player.currentTrack;
    return Column(
      children: [
        _header(context),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.music_note,
                      size: 44,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 14),
                  const Text('正在播放其他内容', style: TextStyle(fontSize: 16)),
                  const SizedBox(height: 6),
                  if (t != null)
                    Text(
                      '《${t.name}》- ${t.artistNames}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  const SizedBox(height: 6),
                  const Text('为不打断当前播放，推荐流还没有接管队列',
                      style: TextStyle(fontSize: 12)),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed:
                        _starting ? null : () => _startQueue(force: true),
                    icon: _starting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_arrow),
                    label: const Text('开始刷推荐'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLoading(BuildContext context) {
    return Column(
      children: [
        _header(context),
        const Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 14),
                Text('正在准备推荐流…'),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildError(BuildContext context) {
    return Column(
      children: [
        _header(context),
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('推荐流加载失败，请检查网络'),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () {
                    setState(() {
                      _initError = null;
                      _startFailed = false;
                    });
                    if (_pager == null) {
                      _initFuture = _init();
                    }
                    _startQueue();
                  },
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _showLoadedList(BuildContext context) {
    final player = context.read<PlayerService>();
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('已加载的推荐曲目')),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _tracks.length,
                itemBuilder: (_, i) {
                  final t = _tracks[i];
                  return ListTile(
                    leading: CoverImage(cover: t.cover, width: 40, height: 40),
                    title: Text(t.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(t.artistNames,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    selected: player.queueTag ==
                            PlayerService.recommendQueueTag &&
                        i == player.currentIndex,
                    onTap: () {
                      if (player.queueTag ==
                          PlayerService.recommendQueueTag) {
                        player.jumpTo(i);
                      }
                      Navigator.pop(ctx);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 推荐页的新鲜模式单页（按定版样板图）：大封面（右上角实际音质芯片）、
/// 歌名/歌手、一行当前歌词、只读互动计数排、下一首露出条、底部三键。
class _RecommendFreshPage extends StatelessWidget {
  final Track track;
  final int index;
  final VoidCallback? onGoHome;
  final VoidCallback? onGoMine;
  const _RecommendFreshPage({
    required this.track,
    required this.index,
    this.onGoHome,
    this.onGoMine,
  });

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final resolver = context.read<PlayResolver>();
    final isCurrent = player.currentIndex == index;
    final seo = isCurrent
        ? player.currentSeo ?? resolver.cachedSeo(track.id)
        : resolver.cachedSeo(track.id);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _tintOf(context).withValues(alpha: 0.55),
            Theme.of(context).scaffoldBackgroundColor,
          ],
        ),
      ),
      child: FutureBuilder<SeoTrack>(
        future: seo != null ? Future.value(seo) : resolver.seo(track.id),
        builder: (context, snap) => _content(context, snap.data, isCurrent),
      ),
    );
  }

  Color _tintOf(BuildContext context) {
    final hex = track.coverColorHex;
    if (hex != null && hex.length == 6) {
      final v = int.tryParse(hex, radix: 16);
      if (v != null) return Color(0xFF000000 | v);
    }
    return Theme.of(context).colorScheme.primaryContainer;
  }

  Widget _content(BuildContext context, SeoTrack? seo, bool isCurrent) {
    final player = context.watch<PlayerService>();
    final scheme = Theme.of(context).colorScheme;
    final fullTrack = seo?.track ?? track;
    final lines = seo?.lyricLines ?? const <LyricLine>[];
    final lineIndex = isCurrent ? lyricIndexAt(lines, player.position) : -1;
    final currentLyric = lines.isEmpty
        ? ''
        : lines[(lineIndex < 0 ? 0 : lineIndex).clamp(0, lines.length - 1)]
            .text;
    final nextTrack = isCurrent &&
            player.currentIndex + 1 < player.queueItems.length
        ? player.queueItems[player.currentIndex + 1]
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              GestureDetector(
                onTap: seo == null
                    ? null
                    : () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => LyricsScreen(seo: seo),
                          ),
                        ),
                child: CoverImage(
                  cover: fullTrack.cover,
                  width: double.infinity,
                  height: MediaQuery.sizeOf(context).height * 0.34,
                  radius: 16,
                  small: false,
                ),
              ),
              if (isCurrent)
                Positioned(
                  top: 10,
                  right: 10,
                  child: _qualityChip(context, player),
                ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 20,
            child: currentLyric.isEmpty
                ? null
                : Text(
                    '“$currentLyric”',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
          ),
          const SizedBox(height: 6),
          Text(
            fullTrack.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 4),
          Text(
            fullTrack.artistNames,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          // 互动计数（平台/seo 真数字，只读展示，不做假互动）
          Row(
            children: [
              _ReadStat(
                icon: Icons.favorite,
                label: formatCount(fullTrack.countCollected ?? 0),
              ),
              const SizedBox(width: 26),
              _ReadStat(
                icon: Icons.mode_comment,
                label: formatCount(fullTrack.countComment ?? 0),
              ),
              const SizedBox(width: 26),
              _ReadStat(
                icon: Icons.share,
                label: formatCount(fullTrack.countShared ?? 0),
              ),
            ],
          ),
          const Spacer(),
          if (nextTrack != null)
            Material(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => player.next(),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Row(
                    children: [
                      CoverImage(
                          cover: nextTrack.cover, width: 36, height: 36),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '下一首：${nextTrack.name} — ${nextTrack.artistNames}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                      const Icon(Icons.keyboard_arrow_up, size: 20),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _RecKey(
                icon: Icons.headphones_outlined,
                label: '发现',
                onTap: onGoHome ??
                    () => Navigator.popUntil(context, (r) => r.isFirst),
              ),
              IconButton.filled(
                iconSize: 34,
                icon: Icon((player.loading || player.preparingLossless) &&
                        isCurrent
                    ? Icons.hourglass_top
                    : (player.playing && isCurrent)
                        ? Icons.pause
                        : Icons.play_arrow),
                onPressed: () async {
                  if (isCurrent) {
                    await player.toggle();
                  } else {
                    await player.jumpTo(index);
                  }
                },
              ),
              _RecKey(
                icon: Icons.person_outline,
                label: '我的',
                onTap: onGoMine ??
                    () => Navigator.popUntil(context, (r) => r.isFirst),
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

  /// 右上角音质芯片：只显示当前曲实际在播的档，准备无损时显示准备态，
  /// 绝不按设置值虚报
  Widget _qualityChip(BuildContext context, PlayerService player) {
    final scheme = Theme.of(context).colorScheme;
    final String text;
    if (player.preparingLossless) {
      text = '无损准备中';
    } else if (player.currentQuality == 'lossless') {
      text = '无损 FLAC';
    } else if (player.currentQuality != null &&
        SettingsService.qualityOptions.contains(player.currentQuality)) {
      text = SettingsService.qualityLabel(player.currentQuality!)
          .split('(')
          .first
          .trim();
    } else {
      return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (player.preparingLossless)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          Text(text,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.onPrimaryContainer)),
        ],
      ),
    );
  }
}

class _ReadStat extends StatelessWidget {
  final IconData icon;
  final String label;
  const _ReadStat({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20, color: scheme.primary),
        const SizedBox(width: 5),
        Text(label, style: Theme.of(context).textTheme.titleSmall),
      ],
    );
  }
}

class _RecKey extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _RecKey({required this.icon, required this.label, required this.onTap});

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
