import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/responsive.dart';
import '../models/models.dart';
import '../services/download_service.dart';
import '../services/player_service.dart';

/// 下载管理：多选删除、进度显示、点按播放本地文件。
/// 每条记录按实际结果标注标签状态（已写/未写/写失败）。
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
                  title: Text(
                    entry.value.title.isEmpty
                        ? '正在下载…'
                        : entry.value.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (entry.value.artist.isNotEmpty ||
                          entry.value.format.isNotEmpty)
                        Text(
                          [
                            if (entry.value.artist.isNotEmpty)
                              entry.value.artist,
                            if (entry.value.format.isNotEmpty)
                              entry.value.format,
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        value: entry.value.progress >= 0
                            ? entry.value.progress
                            : null,
                      ),
                    ],
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
                    [
                      '${r.artist} · ${r.quality} · ${(r.size / 1024 / 1024).toStringAsFixed(1)} MB · ${r.formatLabel} · ${_tagLabel(r.tagStatus)}',
                      if (r.tagError.isNotEmpty) '标签问题：${r.tagError}',
                    ].join('\n'),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
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
          ] else ...[
            if (records.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.delete_sweep_outlined),
                tooltip: '清除已完成记录',
                onPressed: () => _confirmClearRecords(context, downloads),
              ),
            IconButton(
              icon: const Icon(Icons.checklist),
              tooltip: '多选',
              onPressed: records.isEmpty
                  ? null
                  : () => setState(() => _selectMode = true),
            ),
          ],
        ],
      ),
      body: isWide(context) ? ConstrainedCenter(child: body) : body,
    );
  }

  /// 清除已完成记录的二次确认：文案写清「仅清除记录，文件保留」
  /// 与连带后果（记录没了之后不再认本地文件），用户明确点头才清。
  Future<void> _confirmClearRecords(
    BuildContext context,
    DownloadService downloads,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除已完成记录'),
        content: const Text(
          '仅清除下载记录，已下载的歌曲文件会保留在设备上，不会被删除。\n\n'
          '清除后，这些歌曲将不再出现在下载管理中，播放时也不再自动使用本地文件。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清除记录'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await downloads.clearCompletedRecords();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已清除下载记录（文件保留）')),
        );
      }
    }
  }

  static String _tagLabel(String tagStatus) => switch (tagStatus) {
        'tagged' => '已写标签',
        'tagged_text' => '已写标签（无封面）',
        'failed' => '标签写入失败',
        _ => '未写标签',
      };

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
