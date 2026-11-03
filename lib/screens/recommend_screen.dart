import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/player_service.dart';
import '../services/qishui_service.dart';
import '../services/recommend_pager.dart';
import '../widgets/track_tile.dart';

/// 推荐：可连续刷的歌曲流（官方推荐流本体）。
///
/// 数据源（2026-11-04 实测，见 QISHUI_API.md §15）：官方推荐流经车机
/// 开放平台通道（open.douyin.com LunaOpenSDK）游客可直接取到，主源即它；
/// 平台源异常时自动回退 §14 的三源组合（相关歌曲 + 发现歌单 + 电台）。
/// 游客拿到的是未个性化版（官方自述「登录后推荐更准」），文案如实标注。
class RecommendScreen extends StatefulWidget {
  const RecommendScreen({super.key});

  @override
  State<RecommendScreen> createState() => _RecommendScreenState();
}

class _RecommendScreenState extends State<RecommendScreen> {
  final ScrollController _scroll = ScrollController();
  final List<Track> _tracks = [];
  RecommendPager? _pager;
  bool _initialLoading = true;
  bool _loadingMore = false;
  bool _loadMoreFailed = false;
  String? _initError;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _init();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    setState(() {
      _initialLoading = true;
      _initError = null;
    });
    try {
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
      final pager = RecommendPager(
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
      _pager = pager;
      _tracks.clear();
      final first = await pager.nextPage();
      if (!mounted) return;
      if (first.isEmpty && !pager.hasMore) {
        // 主源与回退源都没能出曲：按加载失败处理，给重试入口
        setState(() {
          _initError = '加载失败，请检查网络';
          _initialLoading = false;
        });
        return;
      }
      setState(() {
        _tracks.addAll(first);
        _initialLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _initError = '加载失败，请检查网络';
        _initialLoading = false;
      });
    }
  }

  void _onScroll() {
    if (_scroll.position.extentAfter < 500) _loadMore();
  }

  /// 页面与播放队列共用同一个分页器：队列续拉回来的曲目同步进页面列表，
  /// 刷着听、听着刷是同一条流。
  Future<List<Track>> _fetchNext() async {
    final pager = _pager;
    if (pager == null) return const [];
    final more = await pager.nextPage();
    if (more.isNotEmpty && mounted) {
      setState(() => _tracks.addAll(more));
    }
    return more;
  }

  Future<void> _loadMore() async {
    final pager = _pager;
    if (pager == null || _loadingMore || !pager.hasMore) return;
    _loadingMore = true;
    if (mounted) setState(() => _loadMoreFailed = false);
    try {
      await _fetchNext();
    } catch (_) {
      if (mounted) setState(() => _loadMoreFailed = true);
    } finally {
      _loadingMore = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _refresh() async {
    final pager = _pager;
    if (pager == null) return;
    pager.reset();
    setState(() {
      _tracks.clear();
      _loadMoreFailed = false;
    });
    try {
      await _fetchNext();
    } catch (_) {
      if (mounted) setState(() => _loadMoreFailed = true);
    }
    if (mounted) setState(() {});
  }

  void _playAt(int index) {
    context.read<PlayerService>().playQueue(
          List.of(_tracks),
          index,
          loadMore: _fetchNext,
        );
  }

  @override
  Widget build(BuildContext context) {
    if (_initialLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_initError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_initError!),
            const SizedBox(height: 12),
            FilledButton(onPressed: _init, child: const Text('重试')),
          ],
        ),
      );
    }
    final pager = _pager!;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          const SliverAppBar(
            floating: true,
            title: Text('推荐'),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                '官方推荐流 · 游客版（登录后推荐更准）',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
          ),
          if (_tracks.isEmpty && !pager.hasMore)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('暂时没有可推荐的歌曲'),
                    const SizedBox(height: 12),
                    FilledButton(
                        onPressed: _refresh, child: const Text('刷新试试')),
                  ],
                ),
              ),
            )
          else ...[
            SliverList.builder(
              itemCount: _tracks.length,
              itemBuilder: (context, i) => TrackTile(
                track: _tracks[i],
                onTap: () => _playAt(i),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Center(child: _footer(pager)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _footer(RecommendPager pager) {
    if (_loadMoreFailed) {
      return TextButton.icon(
        onPressed: _loadMore,
        icon: const Icon(Icons.refresh, size: 18),
        label: const Text('加载失败，点此重试'),
      );
    }
    if (!pager.hasMore) {
      return TextButton.icon(
        onPressed: _refresh,
        icon: const Icon(Icons.refresh, size: 18),
        label: const Text('已经到底了，点此换一批'),
      );
    }
    if (_loadingMore) {
      return const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      );
    }
    return const SizedBox.shrink();
  }
}
