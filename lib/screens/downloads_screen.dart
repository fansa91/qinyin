import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/responsive.dart';
import '../models/models.dart';
import '../services/download_service.dart';
import '../services/player_service.dart';

/// 下载管理：多选删除、进度显示、点按播放本地文件。
/// M4A 文件不写 ID3 标签（格式限制，如实标注）。
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  final Set<String> _selected = {};
  bool _selectMode = false;

  @override
  Widget build(BuildContext context) {
    final downloads = context.watch<DownloadService>();
    final records = downloads.records;
    final Widget body = records.isEmpty && downloads.tasks.isEmpty
        ? const Center(child: Text('还没有下载的歌曲'))
        : ListView(
            children: [
              for (final entry in downloads.tasks.entries)
                ListTile(
                  leading: const Icon(Icons.downloading),
                  title: const Text('正在下载…'),
                  subtitle: LinearProgressIndicator(
                    value: entry.value.progress >= 0 ? entry.value.progress : null,
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => downloads.cancel(entry.key),
                  ),
                ),
              for (final r in records)
                ListTile(
                  leading: _selectMode
                      ? Checkbox(
                          value: _selected.contains(r.trackId),
                          onChanged: (v) => setState(() {
                            if (v == true) {
                              _selected.add(r.trackId);
                            } else {
                              _selected.remove(r.trackId);
                            }
                          }),
                        )
                      : const Icon(Icons.audio_file_outlined),
                  title:
                      Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                      '${r.artist} · ${r.quality} · ${(r.size / 1024 / 1024).toStringAsFixed(1)} MB · ${r.path.endsWith('.flac') ? 'FLAC' : 'M4A'}（未写标签）'),
                  onTap: _selectMode
                      ? () => setState(() {
                            if (!_selected.remove(r.trackId)) {
                              _selected.add(r.trackId);
                            }
                          })
                      : () => _playLocal(context, r),
                  onLongPress: () =>
                      setState(() => _selectMode = !_selectMode),
                ),
            ],
          );
    return Scaffold(
      appBar: AppBar(
        title: const Text('下载管理'),
        actions: [
          if (_selectMode) ...[
            TextButton(
              onPressed: () => setState(() {
                _selected
                  ..clear()
                  ..addAll(records.map((r) => r.trackId));
              }),
              child: const Text('全选'),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除所选',
              onPressed: _selected.isEmpty
                  ? null
                  : () async {
                      await downloads.deleteRecords(_selected);
                      setState(() {
                        _selected.clear();
                        _selectMode = false;
                      });
                    },
            ),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => setState(() {
                _selectMode = false;
                _selected.clear();
              }),
            ),
          ] else
            IconButton(
              icon: const Icon(Icons.checklist),
              tooltip: '多选',
              onPressed: records.isEmpty
                  ? null
                  : () => setState(() => _selectMode = true),
            ),
        ],
      ),
      body: isWide(context) ? ConstrainedCenter(child: body) : body,
    );
  }

  void _playLocal(BuildContext context, DownloadRecord r) {
    final track = Track(
      id: r.trackId,
      name: r.title,
      artists: r.artist.isEmpty
          ? const []
          : [ArtistRef(id: '', name: r.artist)],
    );
    context.read<PlayerService>().playTrack(track);
  }
}
