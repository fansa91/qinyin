import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/download_service.dart';

/// 下载按钮三态（纯映射，可测）
enum DownloadButtonState { ready, downloading, downloaded }

DownloadButtonState downloadButtonState({
  required bool isDownloaded,
  required bool isDownloading,
}) =>
    isDownloaded
        ? DownloadButtonState.downloaded
        : isDownloading
            ? DownloadButtonState.downloading
            : DownloadButtonState.ready;

/// 播放页「下载当前曲目」按钮（图标+文案，与新鲜页计数行同形态）。
/// 行为与下载管理完全一致：走 [DownloadService.download] 同一条链路
/// （下载音质、同一任务/记录、VIP 试听段拦截提示）。
/// 状态与 DownloadService 实时对照：未下载 / 下载中（带进度，
/// 点按取消）/ 已下载。
class TrackDownloadButton extends StatelessWidget {
  final Track track;
  const TrackDownloadButton({super.key, required this.track});

  @override
  Widget build(BuildContext context) {
    final downloads = context.watch<DownloadService>();
    final scheme = Theme.of(context).colorScheme;
    final state = downloadButtonState(
      isDownloaded: downloads.isDownloaded(track.id),
      isDownloading: downloads.isDownloading(track.id),
    );
    final progress = downloads.tasks[track.id]?.progress ?? -1;
    final (icon, label) = switch (state) {
      DownloadButtonState.downloaded => (Icons.download_done, '已下载'),
      DownloadButtonState.downloading => (
          Icons.downloading,
          progress >= 0 ? '下载中 ${(progress * 100).round()}%' : '下载中…',
        ),
      DownloadButtonState.ready => (Icons.download_outlined, '下载'),
    };
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => _onTap(context, state),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state == DownloadButtonState.downloading && progress < 0)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(icon,
                color: state == DownloadButtonState.downloaded
                    ? scheme.primary
                    : null),
          const SizedBox(width: 4),
          Text(label),
        ],
      ),
    );
  }

  Future<void> _onTap(BuildContext context, DownloadButtonState state) async {
    final messenger = ScaffoldMessenger.of(context);
    final downloads = context.read<DownloadService>();
    switch (state) {
      case DownloadButtonState.downloading:
        downloads.cancel(track.id);
      case DownloadButtonState.downloaded:
        messenger.showSnackBar(
            const SnackBar(content: Text('已下载，可在「下载」页查看管理')));
      case DownloadButtonState.ready:
        try {
          await downloads.download(track);
          messenger
              .showSnackBar(const SnackBar(content: Text('下载完成')));
        } on VipDownloadException catch (e) {
          messenger.showSnackBar(SnackBar(content: Text(e.message)));
        } catch (e) {
          messenger
              .showSnackBar(SnackBar(content: Text('下载失败：$e')));
        }
    }
  }
}
