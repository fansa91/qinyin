import 'package:flutter/material.dart';

import '../models/models.dart';

/// 封面动态取色：曲目自带 coverColorHex 优先，缺失时退回主题
/// primaryContainer（新鲜页页面底色的取色来源）。
Color coverTintColor(BuildContext context, Track? track) {
  final hex = track?.coverColorHex;
  if (hex != null && hex.length == 6) {
    final v = int.tryParse(hex, radix: 16);
    if (v != null) return Color(0xFF000000 | v);
  }
  return Theme.of(context).colorScheme.primaryContainer;
}

/// 推荐页的页面顶色：封面取色以 55% 混入页面底色后的实色，与
/// 新鲜页渐变顶端同公式。推荐页顶部（状态栏区/header 一带）、
/// 新鲜页正文、桌面嵌入口径共用它，保证无色块分界、无跳色，
/// 切歌换封面时同步变化。
Color recommendPageTopColor(BuildContext context, Track? track) =>
    Color.alphaBlend(
      coverTintColor(context, track).withValues(alpha: 0.55),
      Theme.of(context).scaffoldBackgroundColor,
    );

/// 时长（毫秒）→ m:ss
String formatDurationMs(int ms) {
  if (ms <= 0) return '0:00';
  final d = Duration(milliseconds: ms);
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// 计数 → 万/亿 简写（官方 stats 口径）
String formatCount(int n) {
  if (n < 10000) return '$n';
  if (n < 100000000) {
    final v = n / 10000;
    return '${v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)}万';
  }
  final v = n / 100000000;
  return '${v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)}亿';
}

/// epoch 秒 → yyyy-MM-dd
String formatEpochSeconds(int s) {
  if (s <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(s * 1000);
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
