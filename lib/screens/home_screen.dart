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
  String? _mixCursor;
  bool _mixHasMore = false;
  bool _loadingMore = false;
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
      try {
        _radioPicks =
            await context.read<QishuiService>().radioTracks(feed.radios.first.id);
      } catch (_) {}
    }
    return feed;
  }

  Future<void> _loadMorePlaylists() async {
    if (!_mixHasMore || _loadingMore) return;
    _loadingMore = true;
    try {
      final (more, next, hasMore) = await context
          .read<QishuiService>()
          .discoverMix(cursor: _mixCursor ?? '0');
      setState(() {
        final seen = _playlists.map((p) => p.id).toSet();
        _playlists.addAll(more.where((p) => seen.add(p.id)));
        _mixCursor = next;
        _mixHasMore = hasMore;
      });
    } catch (_) {
    } finally {
      _loadingMore = false;
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
                const SliverToBoxAdapter(child: SectionHeader('推荐歌单')),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: isWide(context) ? 4 : 2,
                      mainAxisSpacing: 14,
                      crossAxisSpacing: 14,
                      childAspectRatio: 0.82,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) {
                        if (i == _playlists.length) {
                          return Center(
                            child: _loadingMore
                                ? const CircularProgressIndicator()
                                : TextButton(
                                    onPressed: _loadMorePlaylists,
                                    child: const Text('加载更多'),
                                  ),
                          );
                        }
                        final p = _playlists[i];
                        return InkWell(
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => PlaylistDetailScreen(playlist: p),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AspectRatio(
                                aspectRatio: 1,
                                child: CoverImage(
                                  cover: p.cover,
                                  radius: 12,
                                  small: false,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(p.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style:
                                      Theme.of(context).textTheme.bodyMedium),
                            ],
                          ),
                        );
                      },
                      childCount:
                          _playlists.length + (_mixHasMore ? 1 : 0),
                    ),
                  ),
                ),
              ],
              if (_radioPicks.isNotEmpty) ...[
                const SliverToBoxAdapter(child: SectionHeader('随便听听')),
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
