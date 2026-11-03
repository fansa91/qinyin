import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/utils.dart';
import '../models/models.dart';
import '../services/library_service.dart';
import '../services/player_service.dart';
import '../services/qishui_service.dart';
import '../widgets/cover_image.dart';
import '../widgets/section_header.dart';
import '../widgets/track_tile.dart';

/// 详情页共用骨架：沉浸头部 + 播放全部 + 曲目列表
class _DetailScaffold extends StatelessWidget {
  final String title;
  final CoverArt? cover;
  final String subtitle;
  final String? meta;
  final List<Track> tracks;
  final Widget? favoriteButton;
  final VoidCallback? onPlayAll;
  final VoidCallback? onReachEnd;

  const _DetailScaffold({
    required this.title,
    required this.cover,
    required this.subtitle,
    required this.tracks,
    this.meta,
    this.favoriteButton,
    this.onPlayAll,
    this.onReachEnd,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final controller = ScrollController();
    controller.addListener(() {
      if (controller.position.pixels >
          controller.position.maxScrollExtent - 300) {
        onReachEnd?.call();
      }
    });
    return Scaffold(
      body: CustomScrollView(
        controller: controller,
        slivers: [
          SliverAppBar(
            expandedHeight: 210,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      scheme.primaryContainer,
                      scheme.surface,
                    ],
                  ),
                ),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 52, 16, 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        CoverImage(
                            cover: cover, width: 118, height: 118, radius: 12),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Text(title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style:
                                      Theme.of(context).textTheme.titleLarge),
                              if (subtitle.isNotEmpty)
                                Text(subtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium),
                              if (meta != null)
                                Text(meta!,
                                    style:
                                        Theme.of(context).textTheme.bodySmall),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            actions: [if (favoriteButton != null) favoriteButton!],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Row(
                children: [
                  FilledButton.icon(
                    icon: const Icon(Icons.play_arrow),
                    label: Text('播放全部 (${tracks.length})'),
                    onPressed: tracks.isEmpty ? null : onPlayAll,
                  ),
                ],
              ),
            ),
          ),
          SliverList.builder(
            itemCount: tracks.length,
            itemBuilder: (context, i) => TrackTile(
              track: tracks[i],
              onTap: () =>
                  context.read<PlayerService>().playQueue(tracks, i),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class PlaylistDetailScreen extends StatefulWidget {
  final Playlist playlist;
  const PlaylistDetailScreen({super.key, required this.playlist});

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  List<Track> _tracks = [];
  String? _nextCursor;
  bool _loading = true;
  bool _loadingMore = false;
  Playlist? _detail;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final (playlist, tracks, next) =
          await context.read<QishuiService>().playlistDetail(widget.playlist.id);
      setState(() {
        _detail = playlist.title.isNotEmpty ? playlist : widget.playlist;
        _tracks = tracks;
        _nextCursor = next;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  /// 分页续拉：同时追加进正在播的本歌单队列
  Future<void> _loadMore() async {
    if (_nextCursor == null || _loadingMore) return;
    _loadingMore = true;
    try {
      final (_, more, next) = await context
          .read<QishuiService>()
          .playlistDetail(widget.playlist.id, cursor: _nextCursor);
      if (more.isNotEmpty) {
        setState(() {
          final seen = _tracks.map((t) => t.id).toSet();
          _tracks = [..._tracks, ...more.where((t) => seen.add(t.id))];
          _nextCursor = next;
        });
        final player = context.read<PlayerService>();
        if (player.currentTrack != null &&
            _tracks.any((t) => t.id == player.currentTrack!.id)) {
          player.appendToQueue(more);
        }
      } else {
        setState(() => _nextCursor = null);
      }
    } catch (_) {
    } finally {
      _loadingMore = false;
    }
  }

  Future<List<Track>> _queueLoadMore() async {
    if (_nextCursor == null) return const [];
    final (_, more, next) = await context
        .read<QishuiService>()
        .playlistDetail(widget.playlist.id, cursor: _nextCursor);
    _nextCursor = next;
    if (mounted && more.isNotEmpty) {
      setState(() {
        final seen = _tracks.map((t) => t.id).toSet();
        _tracks = [..._tracks, ...more.where((t) => seen.add(t.id))];
      });
    }
    return more;
  }

  @override
  Widget build(BuildContext context) {
    final playlist = _detail ?? widget.playlist;
    final library = context.watch<LibraryService>();
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return _DetailScaffold(
      title: playlist.title,
      cover: playlist.cover,
      subtitle: playlist.desc,
      meta: '${playlist.countTracks} 首 · 收藏 ${formatCount(playlist.countCollected)}',
      tracks: _tracks,
      onReachEnd: _loadMore,
      onPlayAll: () => context.read<PlayerService>().playQueue(
            _tracks,
            0,
            loadMore: _nextCursor == null ? null : _queueLoadMore,
          ),
      favoriteButton: IconButton(
        icon: Icon(library.isFavPlaylist(playlist.id)
            ? Icons.favorite
            : Icons.favorite_border),
        tooltip: '收藏歌单',
        onPressed: () => library.toggleFavPlaylist(playlist),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class AlbumDetailScreen extends StatelessWidget {
  final Album album;
  const AlbumDetailScreen({super.key, required this.album});

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryService>();
    return FutureBuilder<(Album, List<Track>)>(
      future: context.read<QishuiService>().albumDetail(album.id),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        if (snap.hasError) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('加载失败，请检查网络')),
          );
        }
        final (info, tracks) = snap.data!;
        final detail = info.name.isNotEmpty ? info : album;
        return _DetailScaffold(
          title: detail.name,
          cover: detail.cover,
          subtitle: detail.artistNames,
          meta:
              '${detail.countTracks > 0 ? detail.countTracks : tracks.length} 首 · ${formatEpochSeconds(detail.releaseDate)}',
          tracks: tracks,
          onPlayAll: () =>
              context.read<PlayerService>().playQueue(tracks, 0),
          favoriteButton: IconButton(
            icon: Icon(library.isFavAlbum(detail.id)
                ? Icons.favorite
                : Icons.favorite_border),
            tooltip: '收藏专辑',
            onPressed: () => library.toggleFavAlbum(detail),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------

class ArtistScreen extends StatelessWidget {
  final ArtistRef artist;
  const ArtistScreen({super.key, required this.artist});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(ArtistRef, List<Track>, List<Album>)>(
      future: context.read<QishuiService>().artistDetail(artist.id),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        if (snap.hasError) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('加载失败，请检查网络')),
          );
        }
        final (info, tracks, albums) = snap.data!;
        return Scaffold(
          appBar: AppBar(title: Text(info.name.isNotEmpty ? info.name : artist.name)),
          body: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      CoverImage(
                        cover: info.avatar ?? artist.avatar,
                        width: 84,
                        height: 84,
                        radius: 42,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(info.name,
                            style: Theme.of(context).textTheme.headlineSmall),
                      ),
                    ],
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SectionHeader('热门歌曲')),
              SliverList.builder(
                itemCount: tracks.length,
                itemBuilder: (context, i) => TrackTile(
                  track: tracks[i],
                  rank: i + 1,
                  onTap: () =>
                      context.read<PlayerService>().playQueue(tracks, i),
                ),
              ),
              if (albums.isNotEmpty) ...[
                const SliverToBoxAdapter(child: SectionHeader('热门专辑')),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 14,
                      crossAxisSpacing: 14,
                      childAspectRatio: 0.85,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) {
                        final a = albums[i];
                        return InkWell(
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => AlbumDetailScreen(album: a),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AspectRatio(
                                aspectRatio: 1,
                                child: CoverImage(
                                    cover: a.cover, radius: 12, small: false),
                              ),
                              const SizedBox(height: 6),
                              Text(a.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                            ],
                          ),
                        );
                      },
                      childCount: albums.length,
                    ),
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
