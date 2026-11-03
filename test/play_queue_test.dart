import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:qinyin/models/models.dart';
import 'package:qinyin/services/play_queue.dart';

Track t(String id) => Track(id: id, name: '歌$id');

PlayQueue pq(List<String> ids, {QueueLoopMode mode = QueueLoopMode.list}) =>
    PlayQueue(items: ids.map(t).toList(), mode: mode, random: Random(42));

void main() {
  group('LIST 模式', () {
    test('手动 next/prev 线性绕回（按钮与滑动共用口径）', () {
      final q = pq(['1', '2', '3']);
      expect(q.manualNext(), 1);
      expect(q.manualNext(), 2);
      expect(q.manualNext(), 0); // 绕回
      expect(q.manualPrev(), 2);
    });
    test('autoNext 线性绕回', () {
      final q = pq(['1', '2']);
      q.jumpTo(1);
      expect(q.autoNext(), 0);
    });
    test('peekManualNext 给预取用，不改状态', () {
      final q = pq(['1', '2', '3']);
      expect(q.peekManualNext(), 1);
      expect(q.index, 0);
    });
  });

  group('SINGLE 模式', () {
    test('autoNext 原地重播', () {
      final q = pq(['1', '2', '3'], mode: QueueLoopMode.single);
      q.jumpTo(1);
      expect(q.autoNext(), 1);
      expect(q.index, 1);
    });
    test('手动切歌仍线性（滑动/按钮不受单曲循环拦截）', () {
      final q = pq(['1', '2', '3'], mode: QueueLoopMode.single);
      expect(q.manualNext(), 1);
      expect(q.manualPrev(), 0);
    });
  });

  group('SHUFFLE 模式', () {
    test('手动 next 随机且不等于当前', () {
      final q = pq(['1', '2', '3', '4', '5'], mode: QueueLoopMode.shuffle);
      for (var i = 0; i < 10; i++) {
        final before = q.index;
        final next = q.manualNext();
        expect(next, isNot(before));
        expect(next, inInclusiveRange(0, 4));
      }
    });
    test('prev 回退播放历史栈', () {
      final q = pq(['1', '2', '3', '4', '5'], mode: QueueLoopMode.shuffle);
      final first = q.index;
      q.manualNext();
      final second = q.index;
      expect(q.manualPrev(), first);
      expect(q.index, first);
      expect(second, isNot(first));
    });
    test('autoNext 随机推进', () {
      final q = pq(['1', '2', '3'], mode: QueueLoopMode.shuffle);
      final before = q.index;
      expect(q.autoNext(), isNot(before));
    });
    test('peekManualNext 为 null（随机不可预取）', () {
      final q = pq(['1', '2'], mode: QueueLoopMode.shuffle);
      expect(q.peekManualNext(), isNull);
    });
  });

  group('队列维护', () {
    test('append 去重', () {
      final q = pq(['1', '2']);
      q.append([t('2'), t('3')]);
      expect(q.items.map((e) => e.id), ['1', '2', '3']);
    });
    test('空队列推进返回 null', () {
      final q = PlayQueue();
      expect(q.manualNext(), isNull);
      expect(q.autoNext(), isNull);
      expect(q.current, isNull);
    });
  });
}
