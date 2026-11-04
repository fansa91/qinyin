// 推荐页进页衔接决策（纯函数）：会话隔离口径——推荐会话有内容就
// 展示它自己的状态；只有主会话在忙且推荐会话为空时才出提示页。
import 'package:flutter_test/flutter_test.dart';
import 'package:qinyin/screens/recommend_screen.dart';

void main() {
  group('decideRecommendEnter（会话隔离）', () {
    test('推荐会话已有内容 → 直接展示会话状态（无论主会话忙闲）', () {
      expect(
        decideRecommendEnter(sessionHasContent: true, mainHasContent: true),
        RecommendEnter.showPager,
      );
      expect(
        decideRecommendEnter(sessionHasContent: true, mainHasContent: false),
        RecommendEnter.showPager,
      );
    });

    test('推荐会话为空、主会话有内容 → 提示页，不打断主会话', () {
      expect(
        decideRecommendEnter(sessionHasContent: false, mainHasContent: true),
        RecommendEnter.showGate,
      );
    });

    test('两边都空 → 自动建推荐会话起播', () {
      expect(
        decideRecommendEnter(sessionHasContent: false, mainHasContent: false),
        RecommendEnter.startQueue,
      );
    });
  });
}
