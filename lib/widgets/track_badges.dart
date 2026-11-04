import 'package:flutter/material.dart';

/// 歌曲列表行徽标（TrackTile 统一使用，歌单详情/首页/搜索/电台等各处一致）：
/// [VipBadge] 付费/VIP 曲目；[QualityBadge] 该曲数据可得的最高音质档。

/// 专辑名行（各播放面曲目信息区统一形态）：专辑图标 + 专辑名，
/// 与歌手行同色系（onSurfaceVariant 次级色）。专辑名缺失（数据未
/// 带）时整行不渲染——如实留空，不编造。
class AlbumLine extends StatelessWidget {
  final String albumName;
  final bool center;
  const AlbumLine({super.key, required this.albumName, this.center = false});

  @override
  Widget build(BuildContext context) {
    if (albumName.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment:
          center ? MainAxisAlignment.center : MainAxisAlignment.start,
      children: [
        Icon(Icons.album_outlined, size: 15, color: scheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            albumName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// 音质档 → 徽标文案（官方口径：无损 / 臻品=highest / 高清=higher / 标准=medium）
String? qualityBadgeLabel(String topQuality) => switch (topQuality) {
      'lossless' => '无损',
      'highest' => '臻品',
      'higher' => '高清',
      'medium' => '标准',
      _ => null,
    };

class VipBadge extends StatelessWidget {
  const VipBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'VIP',
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w800,
          color: scheme.onTertiaryContainer,
          height: 1.2,
        ),
      ),
    );
  }
}

class QualityBadge extends StatelessWidget {
  final String topQuality;
  const QualityBadge({super.key, required this.topQuality});

  @override
  Widget build(BuildContext context) {
    final label = qualityBadgeLabel(topQuality);
    if (label == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.primary.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: scheme.primary,
          height: 1.2,
        ),
      ),
    );
  }
}
