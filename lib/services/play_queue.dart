import 'dart:math';

import '../models/models.dart';

/// 循环模式（与官方 QueueLoopMode 同名同义）
enum QueueLoopMode {
  /// 列表循环
  list,

  /// 随机
  shuffle,

  /// 单曲循环
  single,
}

extension QueueLoopModeLabel on QueueLoopMode {
  String get label => switch (this) {
        QueueLoopMode.list => '列表循环',
        QueueLoopMode.shuffle => '随机播放',
        QueueLoopMode.single => '单曲循环',
      };
  String get wire => switch (this) {
        QueueLoopMode.list => 'list',
        QueueLoopMode.shuffle => 'shuffle',
        QueueLoopMode.single => 'single',
      };
}

/// 纯本地播放队列：推进逻辑与 UI/按钮/手势无关，三处共用同一套。
///
/// - 手动切歌（按钮、上下滑）：SINGLE 与 LIST 都是线性±1（绕回），
///   SHUFFLE 时下一首随机抽（不重复当前），上一首回退播放历史栈。
/// - 自动播完推进：SINGLE 原地重播，LIST 线性+1 绕回，SHUFFLE 随机。
class PlayQueue {
  List<Track> items;
  int index;
  QueueLoopMode mode;
  final Random _random;
  final List<int> _history = [];

  PlayQueue({
    List<Track>? items,
    this.index = 0,
    this.mode = QueueLoopMode.list,
    Random? random,
  })  : items = items ?? <Track>[],
        _random = random ?? Random();

  bool get isEmpty => items.isEmpty;
  Track? get current =>
      items.isEmpty ? null : items[index.clamp(0, items.length - 1)];

  void setQueue(List<Track> tracks, int startIndex) {
    items = List.of(tracks);
    index = tracks.isEmpty ? 0 : startIndex.clamp(0, tracks.length - 1);
    _history.clear();
  }

  void append(Iterable<Track> more) {
    final seen = items.map((t) => t.id).toSet();
    items.addAll(more.where((t) => seen.add(t.id)));
  }

  void jumpTo(int i) {
    if (items.isEmpty) return;
    final target = i.clamp(0, items.length - 1);
    if (target != index) _history.add(index);
    index = target;
  }

  int _randomOther() {
    if (items.length <= 1) return index;
    var next = _random.nextInt(items.length);
    while (next == index) {
      next = _random.nextInt(items.length);
    }
    return next;
  }

  /// 手动下一首目标下标（不改变状态）
  int? peekManualNext() {
    if (items.isEmpty) return null;
    return switch (mode) {
      QueueLoopMode.shuffle => items.length <= 1 ? index : null, // 随机不可预知
      _ => (index + 1) % items.length,
    };
  }

  /// 手动下一首（按钮/上滑共用），返回新下标
  int? manualNext() {
    if (items.isEmpty) return null;
    final target = switch (mode) {
      QueueLoopMode.shuffle => _randomOther(),
      _ => (index + 1) % items.length,
    };
    _history.add(index);
    index = target;
    return index;
  }

  /// 手动上一首（按钮/下滑共用），返回新下标
  int? manualPrev() {
    if (items.isEmpty) return null;
    int target;
    if (mode == QueueLoopMode.shuffle && _history.isNotEmpty) {
      target = _history.removeLast();
    } else {
      target = (index - 1 + items.length) % items.length;
    }
    index = target;
    return index;
  }

  /// 播完自动推进，返回新下标；SINGLE 时返回当前下标表示重播
  int? autoNext() {
    if (items.isEmpty) return null;
    final target = switch (mode) {
      QueueLoopMode.single => index,
      QueueLoopMode.shuffle => _randomOther(),
      QueueLoopMode.list => (index + 1) % items.length,
    };
    if (target != index) _history.add(index);
    index = target;
    return index;
  }
}
