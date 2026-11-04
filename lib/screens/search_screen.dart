import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/responsive.dart';
import '../core/utils.dart';
import '../models/models.dart';
import '../services/library_service.dart';
import '../services/player_service.dart';
import '../services/qishui_service.dart';
import '../widgets/cover_image.dart';
import '../widgets/track_tile.dart';
import 'detail_screens.dart';

/// 搜索页：输入联想（sug）+ 搜索历史 + 平台真搜索结果。
///
/// 全文搜索走车机开放平台通道（QISHUI_API.md §16，游客可用）：
/// 歌曲/歌手实测有结果；歌单页签同样接平台搜索，但游客态上游当前
/// 恒回空（err_no=0、result_groups=[]），空态如实呈现、不是本地 bug。
/// App 本体搜索被掏空的是 beta-luna 通道（§12），与此无关。
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

/// 单个结果页签的分页状态（cursor 非行号，照上游 next_cursor 推进）
class _TabPaging<T> {
  final List<T> items = [];
  final Set<String> seen = {};
  String searchId = '';
  String? nextCursor;
  bool hasMore = false;
  bool loading = false;
  bool loadingMore = false;
  bool loaded = false;
  bool failed = false;

  void reset(String id) {
    items.clear();
    seen.clear();
    searchId = id;
    nextCursor = null;
    hasMore = false;
    loading = false;
    loadingMore = false;
    loaded = false;
    failed = false;
  }
}

class _SearchScreenState extends State<SearchScreen>
    with SingleTickerProviderStateMixin {
  final _controller = TextEditingController();
  List<String> _sugs = [];
  Timer? _debounce;
  bool _sugLoading = false;

  PlatformFeedService? _platform;
  String? _activeQuery;
  late final TabController _tabs;
  final _tracks = _TabPaging<Track>();
  final _artists = _TabPaging<ArtistHit>();
  final _playlists = _TabPaging<Playlist>();
  final _trackScroll = ScrollController();
  final _artistScroll = ScrollController();
  final _playlistScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this)
      ..addListener(() {
        if (!_tabs.indexIsChanging) _ensureTabLoaded(_tabs.index);
      });
    _trackScroll.addListener(() => _onScroll(0));
    _artistScroll.addListener(() => _onScroll(1));
    _playlistScroll.addListener(() => _onScroll(2));
    PlatformFeedService.loadOrCreateDeviceId().then((id) {
      if (mounted) {
        setState(() => _platform = PlatformFeedService(deviceId: id));
        _ensureTabLoaded(_tabs.index);
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _tabs.dispose();
    _trackScroll.dispose();
    _artistScroll.dispose();
    _playlistScroll.dispose();
    super.dispose();
  }

  // --- 联想 ---

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      if (q.trim().isEmpty) {
        setState(() => _sugs = []);
        return;
      }
      setState(() => _sugLoading = true);
      try {
        final sugs = await context.read<QishuiService>().sug(q);
        if (mounted && _controller.text == q) {
          setState(() {
            _sugs = sugs;
            _sugLoading = false;
          });
        }
      } catch (_) {
        if (mounted) setState(() => _sugLoading = false);
      }
    });
  }

  // --- 搜索会话 ---

  void _submit(String word) {
    final q = word.trim();
    if (q.isEmpty) return;
    context.read<LibraryService>().addSearchHistory(q);
    setState(() {
      _activeQuery = q;
      _sugs = [];
      final sid = PlatformFeedService.newSearchId();
      _tracks.reset(sid);
      _artists.reset(PlatformFeedService.newSearchId());
      _playlists.reset(PlatformFeedService.newSearchId());
    });
    _ensureTabLoaded(_tabs.index);
  }

  void _ensureTabLoaded(int index) {
    if (_activeQuery == null || _platform == null) return;
    switch (index) {
      case 0:
        if (!_tracks.loaded && !_tracks.loading) _loadTracks();
      case 1:
        if (!_artists.loaded && !_artists.loading) _loadArtists();
      case 2:
        if (!_playlists.loaded && !_playlists.loading) _loadPlaylists();
    }
  }

  void _onScroll(int index) {
    final c = [ _trackScroll, _artistScroll, _playlistScroll ][index];
    if (c.position.extentAfter < 500) {
      switch (index) {
        case 0:
          _loadTracks(more: true);
        case 1:
          _loadArtists(more: true);
        case 2:
          _loadPlaylists(more: true);
      }
    }
  }

  /// 歌曲分页：首屏与续页共用；返回本次新增（去重后）供播放队列 loadMore。
  Future<List<Track>> _fetchTrackPage({bool more = false}) async {
    final st = _tracks;
    final platform = _platform;
    if (platform == null || _activeQuery == null) return const [];
    if (more ? (st.loadingMore || !st.hasMore) : st.loading) return const [];
    setState(() {
      if (more) {
        st.loadingMore = true;
      } else {
        st.loading = true;
        st.failed = false;
      }
    });
    try {
      final (page, hasMore, next) = await platform.searchTracks(
        query: _activeQuery!,
        searchId: st.searchId,
        cursor: more ? (st.nextCursor ?? '0') : '0',
      );
      final fresh = page.where((t) => st.seen.add(t.id)).toList();
      if (!mounted) return fresh;
      setState(() {
        st.items.addAll(fresh);
        st.hasMore = hasMore && next != null;
        st.nextCursor = next;
        st.loaded = true;
        st.loading = false;
        st.loadingMore = false;
      });
      return fresh;
    } catch (_) {
      if (mounted) {
        setState(() {
          st.loading = false;
          st.loadingMore = false;
          if (!more) st.failed = true;
        });
      }
      return const [];
    }
  }

  Future<void> _loadTracks({bool more = false}) => _fetchTrackPage(more: more);

  Future<void> _loadArtists({bool more = false}) async {
    final st = _artists;
    final platform = _platform;
    if (platform == null || _activeQuery == null) return;
    if (more ? (st.loadingMore || !st.hasMore) : st.loading) return;
    setState(() {
      if (more) {
        st.loadingMore = true;
      } else {
        st.loading = true;
        st.failed = false;
      }
    });
    try {
      final (page, hasMore, next) = await platform.searchArtists(
        query: _activeQuery!,
        searchId: st.searchId,
        cursor: more ? (st.nextCursor ?? '0') : '0',
      );
      if (!mounted) return;
      setState(() {
        st.items.addAll(page.where((a) => st.seen.add(a.artist.id)));
        st.hasMore = hasMore && next != null;
        st.nextCursor = next;
        st.loaded = true;
        st.loading = false;
        st.loadingMore = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          st.loading = false;
          st.loadingMore = false;
          if (!more) st.failed = true;
        });
      }
    }
  }

  Future<void> _loadPlaylists({bool more = false}) async {
    final st = _playlists;
    final platform = _platform;
    if (platform == null || _activeQuery == null) return;
    if (more ? (st.loadingMore || !st.hasMore) : st.loading) return;
    setState(() {
      if (more) {
        st.loadingMore = true;
      } else {
        st.loading = true;
        st.failed = false;
      }
    });
    try {
      final (page, hasMore, next) = await platform.searchPlaylists(
        query: _activeQuery!,
        searchId: st.searchId,
        cursor: more ? (st.nextCursor ?? '0') : '0',
      );
      if (!mounted) return;
      setState(() {
        st.items.addAll(page.where((p) => st.seen.add(p.id)));
        st.hasMore = hasMore && next != null;
        st.nextCursor = next;
        st.loaded = true;
        st.loading = false;
        st.loadingMore = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          st.loading = false;
          st.loadingMore = false;
          if (!more) st.failed = true;
        });
      }
    }
  }

  void _playTrack(int index) {
    context.read<PlayerService>().playQueue(
          List.of(_tracks.items),
          index,
          loadMore: _tracks.hasMore
              ? () => _fetchTrackPage(more: true)
              : null,
        );
  }

  // --- UI ---

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryService>();
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '搜歌名/歌手/歌单'),
          onChanged: _onChanged,
          onSubmitted: _submit,
        ),
        actions: [
          if (_sugLoading)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
        bottom: _activeQuery == null
            ? null
            : TabBar(
                controller: _tabs,
                tabs: const [
                  Tab(text: '歌曲'),
                  Tab(text: '歌手'),
                  Tab(text: '歌单'),
                ],
              ),
      ),
      // 宽屏自适应：浏览区与结果列表统一限宽居中（AppBar 与页签
      // 条是窗口 chrome，保持满宽）；compact 下约束不起作用。
      body: _activeQuery == null
          ? ConstrainedCenter(
              maxWidth: Breakpoints.searchMaxWidth,
              child: _buildBrowse(library),
            )
          : _platform == null
              ? const Center(child: CircularProgressIndicator())
              : ConstrainedCenter(
                  maxWidth: Breakpoints.searchMaxWidth,
                  child: TabBarView(
                    controller: _tabs,
                    children: [
                      _buildTracks(),
                      _buildArtists(),
                      _buildPlaylists(),
                    ],
                  ),
                ),
    );
  }

  Widget _buildBrowse(LibraryService library) {
    return ListView(
      children: [
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('游客搜索走车机开放平台通道，可搜歌曲、歌手与歌单'),
        ),
        for (final s in _sugs)
          ListTile(
            leading: const Icon(Icons.search),
            title: Text(s),
            onTap: () {
              _controller.text = s;
              _submit(s);
            },
          ),
        if (_sugs.isEmpty && library.searchHistory.isNotEmpty) ...[
          ListTile(
            title: const Text('搜索历史'),
            trailing: TextButton(
              onPressed: library.clearSearchHistory,
              child: const Text('清空'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              children: [
                for (final h in library.searchHistory)
                  ActionChip(
                    label: Text(h),
                    onPressed: () {
                      _controller.text = h;
                      _submit(h);
                    },
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _tabBody<T>({
    required _TabPaging<T> st,
    required ScrollController controller,
    required VoidCallback retry,
    required String emptyText,
    required Widget Function(BuildContext, int) itemBuilder,
  }) {
    if (st.loading && st.items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (st.failed && st.items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('加载失败，请检查网络'),
            const SizedBox(height: 12),
            FilledButton(onPressed: retry, child: const Text('重试')),
          ],
        ),
      );
    }
    if (st.loaded && st.items.isEmpty) {
      return Center(child: Text(emptyText));
    }
    return ListView.builder(
      controller: controller,
      itemCount: st.items.length + 1,
      itemBuilder: (context, i) {
        if (i == st.items.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: st.loadingMore
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : Text(
                      st.hasMore ? '' : '已经到底了',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
            ),
          );
        }
        return itemBuilder(context, i);
      },
    );
  }

  Widget _buildTracks() {
    return _tabBody<Track>(
      st: _tracks,
      controller: _trackScroll,
      retry: () => _loadTracks(),
      emptyText: '没有找到相关歌曲',
      itemBuilder: (context, i) => TrackTile(
        track: _tracks.items[i],
        onTap: () => _playTrack(i),
      ),
    );
  }

  Widget _buildArtists() {
    return _tabBody<ArtistHit>(
      st: _artists,
      controller: _artistScroll,
      retry: () => _loadArtists(),
      emptyText: '没有找到相关歌手',
      itemBuilder: (context, i) {
        final hit = _artists.items[i];
        return ListTile(
          leading: CoverImage(
            cover: hit.artist.avatar,
            width: 48,
            height: 48,
            radius: 24,
          ),
          title: Text(hit.artist.name),
          subtitle: Text([
            if (hit.countTracks > 0) '${formatCount(hit.countTracks)} 首歌曲',
            if (hit.countAlbums > 0) '${formatCount(hit.countAlbums)} 张专辑',
          ].join(' · ')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ArtistScreen(artist: hit.artist),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlaylists() {
    return _tabBody<Playlist>(
      st: _playlists,
      controller: _playlistScroll,
      retry: () => _loadPlaylists(),
      emptyText: '没有找到相关歌单',
      itemBuilder: (context, i) {
        final p = _playlists.items[i];
        return ListTile(
          leading: CoverImage(cover: p.cover, width: 48, height: 48),
          title: Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text([
            if (p.countTracks > 0) '${p.countTracks} 首',
            if (p.countCollected > 0) '收藏 ${formatCount(p.countCollected)}',
          ].join(' · ')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => PlaylistDetailScreen(playlist: p),
            ),
          ),
        );
      },
    );
  }
}
