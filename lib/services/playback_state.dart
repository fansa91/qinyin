import 'dart:convert';

import '../models/models.dart';
import 'play_queue.dart';

/// 播放状态全局持久化的快照结构（纯数据 + JSON 往返，可测）。
///
/// 只存曲目元数据（[Track.toJson] 口径，与收藏/历史落盘同一套）与
/// 位置/下标/模式——**不存播放直链**（签名链 24h 过期，恢复时由
/// PlayResolver 按需重新解析）。会话续拉回调（loadMore）是闭包，
/// 无法落盘，恢复后的会话不带续拉（见 PlayerService.restorePersisted
/// 的口径说明）。
/// 推荐场景的选择已有独立持久化（PlatformFeedService.saveScene，
/// 推荐页进页时自行恢复），本快照不重复存场景，只存推荐会话的
/// 曲目/下标/位置。
class SessionSnapshot {
  final List<Track> items;
  final int index;
  final int positionMs;
  const SessionSnapshot({
    required this.items,
    required this.index,
    required this.positionMs,
  });

  bool get hasContent => items.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'items': items.map((t) => t.toJson()).toList(),
        'index': index,
        'positionMs': positionMs,
      };

  /// 解析失败（类型不符/单曲损坏）时尽量降级：坏曲目跳过、
  /// 下标收敛到合法范围；整体不是 Map 时返回 null。
  static SessionSnapshot? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final list = raw['items'];
    if (list is! List) return null;
    final items = <Track>[];
    for (final e in list) {
      try {
        if (e is Map<String, dynamic>) items.add(Track.fromJson(e));
      } catch (_) {
        // 单曲数据损坏不拖垮整个会话
      }
    }
    if (items.isEmpty) return null;
    final idx = (raw['index'] as num?)?.toInt() ?? 0;
    final pos = (raw['positionMs'] as num?)?.toInt() ?? 0;
    return SessionSnapshot(
      items: items,
      index: idx.clamp(0, items.length - 1),
      positionMs: pos < 0 ? 0 : pos,
    );
  }
}

class PlaybackSnapshot {
  static const int currentVersion = 1;

  /// 占用引擎（音频输出）的会话名：'main' / 'recommend'
  final String active;
  final QueueLoopMode mode;
  final SessionSnapshot? main;
  final SessionSnapshot? recommend;
  const PlaybackSnapshot({
    required this.active,
    required this.mode,
    this.main,
    this.recommend,
  });

  Map<String, dynamic> toJson() => {
        'v': currentVersion,
        'active': active,
        'mode': mode.wire,
        if (main != null) 'main': main!.toJson(),
        if (recommend != null) 'recommend': recommend!.toJson(),
      };

  String encode() => jsonEncode(toJson());

  static QueueLoopMode _modeOf(Object? raw) => switch (raw) {
        'shuffle' => QueueLoopMode.shuffle,
        'single' => QueueLoopMode.single,
        _ => QueueLoopMode.list,
      };

  /// 从 SharedPreferences 里读到的原始值解析：入参可为 JSON 字符串
  /// 或已解码的 Map。**任何**损坏/版本不兼容 → 返回 null，调用方
  /// 静默丢弃、回默认态，绝不抛。
  static PlaybackSnapshot? tryParse(Object? raw) {
    try {
      Object? decoded = raw;
      if (raw is String) {
        if (raw.isEmpty) return null;
        decoded = jsonDecode(raw);
      }
      if (decoded is! Map) return null;
      if (decoded['v'] != currentVersion) return null;
      final main = SessionSnapshot.fromJson(decoded['main']);
      final recommend = SessionSnapshot.fromJson(decoded['recommend']);
      if (main == null && recommend == null) return null;
      var active = '${decoded['active']}';
      // active 指向的会话无内容时回落到有内容的一侧
      if (active == 'recommend' && recommend == null) active = 'main';
      if (active != 'recommend' && main == null) active = 'recommend';
      if (active != 'main' && active != 'recommend') active = 'main';
      return PlaybackSnapshot(
        active: active,
        mode: _modeOf(decoded['mode']),
        main: main,
        recommend: recommend,
      );
    } catch (_) {
      return null;
    }
  }
}
