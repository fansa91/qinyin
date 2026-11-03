// 推荐页进页衔接决策（纯函数）：不打断正在播的其他来源是硬口径。
import 'package:flutter_test/flutter_test.dart';
import 'package:qinyin/screens/recommend_screen.dart';

void main() {
  group('decideRecommendEnter', () {
    test('队列已是推荐流 → 直接展示滑动页', () {
      expect(
        decideRecommendEnter(
            queueIsRecommend: true, hasQueue: true, hasCurrentTrack: true),
        RecommendEnter.showPager,
      );
    });

    test('别的内容在播 → 提示页，不抢队列', () {
      expect(
        decideRecommendEnter(
            queueIsRecommend: false, hasQueue: true, hasCurrentTrack: true),
        RecommendEnter.showGate,
      );
    });

    test('什么都没在播 → 自动建队', () {
      expect(
        decideRecommendEnter(
            queueIsRecommend: false, hasQueue: false, hasCurrentTrack: false),
        RecommendEnter.startQueue,
      );
    });

    test('标记是推荐流但队列已空 → 重新建队', () {
      expect(
        decideRecommendEnter(
            queueIsRecommend: true, hasQueue: false, hasCurrentTrack: false),
        RecommendEnter.startQueue,
      );
    });
  });
}
