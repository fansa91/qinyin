import 'package:flutter/material.dart';

/// 歌曲列表行徽标（TrackTile 统一使用，歌单详情/首页/搜索/电台等各处一致）：
/// [VipBadge] 付费/VIP 曲目；[QualityBadge] 该曲数据可得的最高音质档。

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
