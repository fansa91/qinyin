import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/responsive.dart';
import '../models/models.dart';
import '../services/player_service.dart';
import '../services/qishui_service.dart';
import '../widgets/cover_image.dart';
import '../widgets/section_header.dart';
import '../widgets/track_tile.dart';
import 'detail_screens.dart';
import 'radio_screen.dart';

/// 首页：发现块流（电台 + 推荐歌单 + 随便听听歌曲列表），下拉刷新。
/// 排行榜卡需要 chart 数据，游客首页无直达接口，拼不出就不显示（不造假）。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<HomeFeed> _future;
  List<Track> _radioPicks = [];
  String? _picksRadioId;
  bool _refreshingPicks = false;
  String? _mixCursor;
  bool _mixHasMore = false;
  final List<Playlist> _playlists = [];

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<HomeFeed> _load() async {
    final feed = await context.read<QishuiService>().homeFeed();
    _playlists
      ..clear()
      ..addAll(feed.playlists);
    _mixCursor = feed.mixCursor;
    _mixHasMore = feed.mixHasMore;
    if (feed.radios.isNotEmpty) {
      _picksRadioId = feed.radios.first.id;
      try {
        _radioPicks =
            await context.read<QishuiService>().radioTracks(feed.radios.first.id);
      } catch (_) {}
    }
    return feed;
  }

  /// 「随便听听」换一批：电台曲目流重新拉取（接口本身是流式下发，
  /// 重拉即新一批）；失败保留旧列表并提示，加载中防重复点。
  Future<void> _refreshPicks() async {
    final radioId = _picksRadioId;
    if (radioId == null || _refreshingPicks) return;
    setState(() => _refreshingPicks = true);
    try {
      final fresh = await context.read<QishuiService>().radioTracks(radioId);
      if (!mounted) return;
      if (fresh.isEmpty) throw StateError('电台返回空');
      setState(() => _radioPicks = fresh);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('刷新失败，已保留当前内容')),
        );
      }
    } finally {
      if (mounted) setState(() => _refreshingPicks = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<HomeFeed>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('加载失败，请检查网络'),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => setState(() => _future = _load()),
                  child: const Text('重试'),
                ),
              ],
            ),
          );
        }
        final feed = snap.data!;
        return RefreshIndicator(
          onRefresh: () async => setState(() => _future = _load()),
          child: CustomScrollView(
            slivers: [
              SliverAppBar(
                floating: true,
                title: const Text('沁音'),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.search),
                    onPressed: () => Navigator.pushNamed(context, '/search'),
                  ),
                ],
              ),
              if (feed.radios.isNotEmpty) ...[
                const SliverToBoxAdapter(child: SectionHeader('电台')),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 118,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: feed.radios.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 14),
                      itemBuilder: (context, i) {
                        final radio = feed.radios[i];
                        return InkWell(
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => RadioScreen(radio: radio),
                            ),
                          ),
                          child: SizedBox(
                            width: 84,
                            child: Column(
                              children: [
                                CoverImage(
                                  cover: radio.cover,
                                  width: 72,
                                  height: 72,
                                  radius: 36,
                                ),
                                const SizedBox(height: 6),
                                Text(radio.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style:
                                        Theme.of(context).textTheme.bodySmall),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
              if (_playlists.isNotEmpty) ...[
                SliverToBoxAdapter(
                  child: SectionHeader(
                    '推荐歌单',
                    actionLabel: '更多',
                    onAction: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => MorePlaylistsScreen(
                          initialPlaylists: List.of(_playlists),
                          initialCursor: _mixCursor,
                          initialHasMore: _mixHasMore,
                        ),
                      ),
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: isWide(context) ? 4 : 2,
                      mainAxisSpacing: 14,
                      crossAxisSpacing: 14,
                      childAspectRatio: 0.82,
                    ),
                    // 「加载更多」格已整体删除（用户点名）：首页该板块
                    // 停在首批内容；续看走板块头「更多」的独立列表页
                    // （MorePlaylistsScreen 自带分页，不受影响）。
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => PlaylistCard(playlist: _playlists[i]),
                      childCount: _playlists.length,
                    ),
                  ),
                ),
              ],
              if (_radioPicks.isNotEmpty) ...[
                SliverToBoxAdapter(
                  child: SectionHeader(
                    '随便听听',
                    actionLabel: _refreshingPicks ? '刷新中…' : '刷新',
                    onAction: _refreshingPicks ? null : _refreshPicks,
                  ),
                ),
                SliverList.builder(
                  itemCount: _radioPicks.length,
                  itemBuilder: (context, i) => TrackTile(
                    track: _radioPicks[i],
                    onTap: () => context
                        .read<PlayerService>()
                        .playQueue(_radioPicks, i),
                  ),
                ),
              ],
              const SliverToBoxAdapter(child: SizedBox(height: 16)),
            ],
          ),
        );
      },
    );
  }
}

/// 推荐歌单卡片（首页网格与「更多」完整列表页共用同一份实现）
class PlaylistCard extends StatelessWidget {
  final Playlist playlist;
  const PlaylistCard({super.key, required this.playlist});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => PlaylistDetailScreen(playlist: playlist),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: CoverImage(
              cover: playlist.cover,
              radius: 12,
              small: false,
            ),
          ),
          const SizedBox(height: 6),
          Text(playlist.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

/// 推荐歌单「更多」：完整列表页（与首页同一 discover/mix 数据源，
/// 游标分页续拉；首页已加载的部分直接带入，不重拉第一页）。
class MorePlaylistsScreen extends StatefulWidget {
  final List<Playlist> initialPlaylists;
  final String? initialCursor;
  final bool initialHasMore;
  const MorePlaylistsScreen({
    super.key,
    required this.initialPlaylists,
    required this.initialCursor,
    required this.initialHasMore,
  });

  @override
  State<MorePlaylistsScreen> createState() => _MorePlaylistsScreenState();
}

class _MorePlaylistsScreenState extends State<MorePlaylistsScreen> {
  late final List<Playlist> _playlists = List.of(widget.initialPlaylists);
  late String? _cursor = widget.initialCursor;
  late bool _hasMore = widget.initialHasMore;
  bool _loading = false;

  Future<void> _loadMore() async {
    if (!_hasMore || _loading) return;
    setState(() => _loading = true);
    try {
      final (more, next, hasMore) = await context
          .read<QishuiService>()
          .discoverMix(cursor: _cursor ?? '0');
      if (!mounted) return;
      setState(() {
        final seen = _playlists.map((p) => p.id).toSet();
        _playlists.addAll(more.where((p) => seen.add(p.id)));
        _cursor = next;
        _hasMore = hasMore;
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('加载更多失败，请稍后重试')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('推荐歌单')),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: isWide(context) ? 4 : 2,
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                childAspectRatio: 0.82,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) => PlaylistCard(playlist: _playlists[i]),
                childCount: _playlists.length,
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: _hasMore
                    ? (_loading
                        ? const CircularProgressIndicator()
                        : TextButton(
                            onPressed: _loadMore,
                            child: const Text('加载更多'),
                          ))
                    : const Text('没有更多了',
                        style: TextStyle(fontSize: 12)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
