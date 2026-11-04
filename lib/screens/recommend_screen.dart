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
import '../widgets/seek_bar.dart';
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
/// 单页内部再套一层横向分页：右滑进当前曲的歌词页、左滑回推荐流页；
/// 底部是可拖动 SeekBar（无「发现/播放/我的」三键行——回首页/我的走
/// 壳层导航）；点评论开遮盖式抽屉（浮层盖住本页、底层不动）。
/// 整个页面包在 SafeArea 里：本页是壳层里唯一没有 AppBar 的主页面，
/// 不包就会与 iPhone 状态栏时间重叠（用户实报）。
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
  const RecommendScreen({
    super.key,
    this.active = false,
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
    final Widget content;
    if (enter == RecommendEnter.showPager) {
      if (isExpanded(context)) {
        // 桌面双栏播放形态之上保留推荐页头（刷新/列表/搜索入口不丢）
        content = Column(
          children: [
            _header(context),
            const Expanded(child: DesktopPlayer()),
          ],
        );
      } else {
        content = _buildSwipe(context);
      }
    } else if (enter == RecommendEnter.showGate) {
      content = _buildGate(context, player);
    } else if (_initError != null || _startFailed) {
      // startQueue 分支：自动建队失败重试
      content = _buildError(context);
    } else {
      // startQueue 分支：自动建队进行中
      content = _buildLoading(context);
    }
    // 顶部安全区：本页无 AppBar，header 与右侧页指示点等贴边元素都要
    // 让开状态栏/刘海（iPhone 上 header 曾与状态栏时间重叠，用户实报）。
    // bottom 不包：页面下缘贴的是壳层导航栏而非屏幕边缘，导航栏自理
    // 底部 inset，包了反而多出一条空白。
    return SafeArea(bottom: false, child: content);
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
/// 歌名/歌手、一行当前歌词、只读互动计数排、下一首露出条，底部 SeekBar。
///
/// 页面内部再分横向两页（横向 PageView，初始停在推荐流页）：
/// - 右滑 → 左侧的歌词页（当前曲歌词，同步滚动沿用播放页 [LyricList]）；
/// - 左滑 → 回推荐流页。
/// 横向分页只吃横向拖动，纵向手势仍归外层 FreshPager 切歌（歌词列表
/// 禁用手动滚动也是为此，见 [LyricList] 口径），两边互不吞手势。
/// 评论不切页不开新页：点计数开遮盖式抽屉，浮层盖在本页之上。
class _RecommendFreshPage extends StatefulWidget {
  final Track track;
  final int index;
  const _RecommendFreshPage({
    required this.track,
    required this.index,
  });

  @override
  State<_RecommendFreshPage> createState() => _RecommendFreshPageState();
}

class _RecommendFreshPageState extends State<_RecommendFreshPage> {
  /// 横向分页：0 歌词页（在左）、1 推荐流页（初始停靠页）
  late final PageController _hController = PageController(initialPage: 1);

  @override
  void dispose() {
    _hController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final resolver = context.read<PlayResolver>();
    final isCurrent = player.currentIndex == widget.index;
    final seo = isCurrent
        ? player.currentSeo ?? resolver.cachedSeo(widget.track.id)
        : resolver.cachedSeo(widget.track.id);
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
        future: seo != null ? Future.value(seo) : resolver.seo(widget.track.id),
        builder: (context, snap) => _content(context, snap.data, isCurrent),
      ),
    );
  }

  Color _tintOf(BuildContext context) {
    final hex = widget.track.coverColorHex;
    if (hex != null && hex.length == 6) {
      final v = int.tryParse(hex, radix: 16);
      if (v != null) return Color(0xFF000000 | v);
    }
    return Theme.of(context).colorScheme.primaryContainer;
  }

  Widget _content(BuildContext context, SeoTrack? seo, bool isCurrent) {
    final player = context.watch<PlayerService>();
    final scheme = Theme.of(context).colorScheme;
    final fullTrack = seo?.track ?? widget.track;
    final lines = seo?.lyricLines ?? const <LyricLine>[];
    final lineIndex = isCurrent ? lyricIndexAt(lines, player.position) : -1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: PageView(
              controller: _hController,
              children: [
                _lyricsPane(context, lines, lineIndex),
                _mainPane(context, seo, fullTrack, lines, lineIndex, isCurrent),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // 底部整行 = 进度条：原「发现 / 播放 / 我的」三键行已去掉
          // （回首页/我的走壳层导航），与播放页共用同一 SeekBar 行为。
          if (isCurrent)
            SeekBar(
              position: player.position,
              duration: player.duration,
              onSeek: player.seek,
              showTimes: true,
            )
          else
            // 非当前页占位（与播放页同口径），避免切页时底部高度跳动
            const SizedBox(height: 76),
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

  /// 推荐流页（横向分页右侧页）：封面/歌名/歌手/计数排/下一首露出条。
  Widget _mainPane(
    BuildContext context,
    SeoTrack? seo,
    Track fullTrack,
    List<LyricLine> lines,
    int lineIndex,
    bool isCurrent,
  ) {
    final player = context.watch<PlayerService>();
    final scheme = Theme.of(context).colorScheme;
    final currentLyric = lines.isEmpty
        ? ''
        : lines[(lineIndex < 0 ? 0 : lineIndex).clamp(0, lines.length - 1)]
            .text;
    final nextTrack = isCurrent &&
            player.currentIndex + 1 < player.queueItems.length
        ? player.queueItems[player.currentIndex + 1]
        : null;
    return Column(
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
        // 互动计数（平台/seo 真数字，只读展示，不做假互动）；
        // 评论计数可点：开遮盖式评论抽屉（见 _showComments）
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
              onTap: seo == null ? null : () => _showComments(context, seo),
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
                    CoverImage(cover: nextTrack.cover, width: 36, height: 36),
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
      ],
    );
  }

  /// 歌词页（横向分页左侧页）：与播放页共用同一份 [LyricList]
  /// （当前行高亮 + 同步自动滚动）；禁手动滚动，纵向手势留给外层切歌。
  Widget _lyricsPane(
      BuildContext context, List<LyricLine> lines, int lineIndex) {
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
              '左滑回推荐',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: LyricList(
            lines: lines,
            currentIndex: lineIndex,
            userScrollable: false,
          ),
        ),
      ],
    );
  }

  /// 评论抽屉（遮盖式）：showModalBottomSheet 是独立浮层路由，盖在
  /// 推荐页之上——底层页面只被遮罩压暗，不位移、不挤压。高度取
  /// 约五成屏高（≈50%，用户定版口径），带拖动把手，可下拉关闭、
  /// 点遮罩关闭。评论内容复用共享只读 [CommentsList]。
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
  final VoidCallback? onTap;
  const _ReadStat({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20, color: scheme.primary),
        const SizedBox(width: 5),
        Text(label, style: Theme.of(context).textTheme.titleSmall),
      ],
    );
    if (onTap == null) return row;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: row,
      ),
    );
  }
}
