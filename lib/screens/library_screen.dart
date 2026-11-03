import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/responsive.dart';
import '../services/library_service.dart';
import '../services/player_service.dart';
import '../widgets/cover_image.dart';
import '../widgets/track_tile.dart';
import 'detail_screens.dart';

/// 我的：本地收藏 / 自建歌单 / 历史（游客态全部本地数据）
class LibraryScreen extends StatelessWidget {
  final int initialTab;
  const LibraryScreen({super.key, this.initialTab = 0});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      initialIndex: initialTab.clamp(0, 3),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('我的'),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: '设置',
              onPressed: () => Navigator.pushNamed(context, '/settings'),
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: '收藏歌曲'),
              Tab(text: '收藏歌单/专辑'),
              Tab(text: '本地歌单'),
              Tab(text: '历史播放'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _FavTracksTab(),
            _FavCollectionsTab(),
            _MyPlaylistsTab(),
            _HistoryTab(),
          ],
        ),
      ),
    );
  }
}

class _FavTracksTab extends StatelessWidget {
  const _FavTracksTab();
  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryService>();
    final tracks = library.favoriteTracks;
    if (tracks.isEmpty) return const Center(child: Text('还没有收藏的歌曲'));
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.play_arrow),
          title: Text('播放全部 (${tracks.length})'),
          onTap: () => context.read<PlayerService>().playQueue(tracks, 0),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: tracks.length,
            itemBuilder: (context, i) => TrackTile(
              track: tracks[i],
              onTap: () => context.read<PlayerService>().playQueue(tracks, i),
            ),
          ),
        ),
      ],
    );
  }
}

class _FavCollectionsTab extends StatelessWidget {
  const _FavCollectionsTab();
  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryService>();
    if (library.favoritePlaylists.isEmpty && library.favoriteAlbums.isEmpty) {
      return const Center(child: Text('还没有收藏的歌单或专辑'));
    }
    return ListView(
      children: [
        for (final p in library.favoritePlaylists)
          ListTile(
            leading: CoverImage(cover: p.cover, width: 52, height: 52),
            title: Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('歌单 · ${p.countTracks} 首'),
            trailing: IconButton(
              icon: const Icon(Icons.favorite),
              onPressed: () => library.toggleFavPlaylist(p),
            ),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                  builder: (_) => PlaylistDetailScreen(playlist: p)),
            ),
          ),
        for (final a in library.favoriteAlbums)
          ListTile(
            leading: CoverImage(cover: a.cover, width: 52, height: 52),
            title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('专辑 · ${a.artistNames}'),
            trailing: IconButton(
              icon: const Icon(Icons.favorite),
              onPressed: () => library.toggleFavAlbum(a),
            ),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                  builder: (_) => AlbumDetailScreen(album: a)),
            ),
          ),
      ],
    );
  }
}

class _MyPlaylistsTab extends StatelessWidget {
  const _MyPlaylistsTab();

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryService>();
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('新建歌单'),
        onPressed: () => _create(context),
      ),
      body: library.myPlaylists.isEmpty
          ? const Center(child: Text('还没有本地歌单'))
          : ListView.builder(
              itemCount: library.myPlaylists.length,
              itemBuilder: (context, i) {
                final p = library.myPlaylists[i];
                return ListTile(
                  leading: CoverImage(
                    cover: p.tracks.isNotEmpty ? p.tracks.first.cover : null,
                    width: 52,
                    height: 52,
                  ),
                  title: Text(p.name),
                  subtitle: Text('${p.tracks.length} 首'),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => library.deletePlaylist(p.id),
                  ),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                        builder: (_) => LocalPlaylistScreen(playlistId: p.id)),
                  ),
                );
              },
            ),
    );
  }

  Future<void> _create(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建本地歌单'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '歌单名称'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('创建')),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty && context.mounted) {
      await context.read<LibraryService>().createPlaylist(name);
    }
  }
}

/// 本地歌单详情
class LocalPlaylistScreen extends StatelessWidget {
  final String playlistId;
  const LocalPlaylistScreen({super.key, required this.playlistId});

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryService>();
    final playlist =
        library.myPlaylists.where((p) => p.id == playlistId).firstOrNull;
    if (playlist == null) {
      return Scaffold(
          appBar: AppBar(), body: const Center(child: Text('歌单已删除')));
    }
    final tracks = playlist.tracks;
    return Scaffold(
      appBar: AppBar(title: Text(playlist.name)),
      body: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.play_arrow),
            title: Text('播放全部 (${tracks.length})'),
            onTap: tracks.isEmpty
                ? null
                : () => context.read<PlayerService>().playQueue(tracks, 0),
          ),
          Expanded(
            child: tracks.isEmpty
                ? const Center(child: Text('歌单是空的，从歌曲菜单里添加'))
                : ListView.builder(
                    itemCount: tracks.length,
                    itemBuilder: (context, i) => Dismissible(
                      key: ValueKey(tracks[i].id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        color: Theme.of(context).colorScheme.errorContainer,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 16),
                        child: const Icon(Icons.delete_outline),
                      ),
                      onDismissed: (_) =>
                          library.removeFromPlaylist(playlistId, tracks[i].id),
                      child: TrackTile(
                        track: tracks[i],
                        onTap: () =>
                            context.read<PlayerService>().playQueue(tracks, i),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _HistoryTab extends StatelessWidget {
  const _HistoryTab();
  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryService>();
    final tracks = library.history;
    if (tracks.isEmpty) return const Center(child: Text('还没有播放历史'));
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.delete_sweep_outlined),
          title: const Text('清空历史'),
          onTap: () => library.clearHistory(),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: tracks.length,
            itemBuilder: (context, i) => TrackTile(
              track: tracks[i],
              onTap: () => context.read<PlayerService>().playQueue(tracks, i),
            ),
          ),
        ),
      ],
    );
  }
}

/// 宽屏内容限宽包装（我的/设置等表单类页面共用）
Widget formPage(BuildContext context, Widget child) {
  if (isWide(context)) return ConstrainedCenter(child: child);
  return child;
}
