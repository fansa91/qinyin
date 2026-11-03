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
