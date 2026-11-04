import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/responsive.dart';
import '../core/utils.dart';
import '../models/models.dart';
import '../services/download_service.dart';
import '../services/library_service.dart';
import '../services/player_service.dart';
import '../screens/detail_screens.dart';
import 'cover_image.dart';
import 'track_badges.dart';

/// 歌曲行：封面/歌名/歌手/时长 + 正在播放高亮 + 更多菜单（收藏/下载/加歌单）
///
/// [trackNumber]/[trackTotal]：专辑曲序——**仅专辑页**按行传入，
/// 菜单下载时透传给 DownloadService 写进标签；其他列表不传。
class TrackTile extends StatelessWidget {
  final Track track;
  final VoidCallback? onTap;
  final int? rank;
  final bool showDownloadAction;
  final int? trackNumber;
  final int? trackTotal;

  const TrackTile({
    super.key,
    required this.track,
    this.onTap,
    this.rank,
    this.showDownloadAction = true,
    this.trackNumber,
    this.trackTotal,
  });

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final isCurrent = player.currentTrack?.id == track.id;
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      selected: isCurrent,
      selectedTileColor: scheme.secondaryContainer.withValues(alpha: 0.4),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (rank != null)
            SizedBox(
              width: 24,
              child: Text('$rank',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: rank! <= 3 ? scheme.primary : scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      )),
            ),
          CoverImage(cover: track.cover, width: 48, height: 48),
        ],
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              track.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: isCurrent ? FontWeight.w700 : FontWeight.normal,
                color: isCurrent ? scheme.primary : null,
              ),
            ),
          ),
          if (track.topQuality.isNotEmpty) ...[
            const SizedBox(width: 6),
            QualityBadge(topQuality: track.topQuality),
          ],
          if (track.isVip) ...[
            const SizedBox(width: 6),
            const VipBadge(),
          ],
        ],
      ),
      subtitle: Text(
        [
          if (track.artistNames.isNotEmpty) track.artistNames,
          if (track.albumName.isNotEmpty) track.albumName,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isCurrent && player.playing)
            Icon(Icons.equalizer, size: 18, color: scheme.primary)
          else
            Text(formatDurationMs(track.durationMs),
                style: Theme.of(context).textTheme.bodySmall),
          IconButton(
            icon: const Icon(Icons.more_vert, size: 20),
            onPressed: () => _showMenu(context),
          ),
        ],
      ),
      onTap: onTap,
    );
  }

  void _showMenu(BuildContext context) {
    final library = context.read<LibraryService>();
    final downloads = context.read<DownloadService>();
    showModalBottomSheet<void>(
      context: context,
      constraints:
          const BoxConstraints(maxWidth: Breakpoints.menuSheetMaxWidth),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(library.isFavTrack(track.id)
                  ? Icons.favorite
                  : Icons.favorite_border),
              title: Text(library.isFavTrack(track.id) ? '取消收藏' : '收藏歌曲'),
              onTap: () async {
                await library.toggleFavTrack(track);
                if (ctx.mounted) Navigator.pop(ctx);
              },
            ),
            if (showDownloadAction)
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: Text(downloads.isDownloaded(track.id) ? '已下载' : '下载'),
                onTap: () async {
                  Navigator.pop(ctx);
                  try {
                    await downloads.download(track,
                        trackNumber: trackNumber, trackTotal: trackTotal);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(const SnackBar(content: Text('下载完成')));
                    }
                  } on VipDownloadException catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text(e.message)));
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text('下载失败：$e')));
                    }
                  }
                },
              ),
            if (track.artists.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text('查看歌手：${track.artists.first.name}'),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          ArtistScreen(artist: track.artists.first),
                    ),
                  );
                },
              ),
            ListTile(
              leading: const Icon(Icons.playlist_add),
              title: const Text('添加到本地歌单'),
              onTap: () {
                Navigator.pop(ctx);
                _pickPlaylist(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _pickPlaylist(BuildContext context) {
    final library = context.read<LibraryService>();
    showModalBottomSheet<void>(
      context: context,
      constraints:
          const BoxConstraints(maxWidth: Breakpoints.menuSheetMaxWidth),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final p in library.myPlaylists)
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: Text(p.name),
                subtitle: Text('${p.tracks.length} 首'),
                onTap: () async {
                  await library.addToPlaylist(p.id, track);
                  if (ctx.mounted) Navigator.pop(ctx);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('已添加到「${p.name}」')));
                  }
                },
              ),
            if (library.myPlaylists.isEmpty)
              const ListTile(title: Text('还没有本地歌单，去「我的」里新建')),
          ],
        ),
      ),
    );
  }
}
