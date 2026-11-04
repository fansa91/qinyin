// 新鲜模式播放页上下滑切歌（硬性验收项）：
// 纵向 PageView 承载队列，上滑=下一首、下滑=上一首，与按钮切歌共用
// PlayerService.next()/prev()/jumpTo → PlayQueue 推进逻辑。
//
// 测试手法说明：测试环境无音频平台插件，_playAt 里的 play()/setVolume
// 平台 future 永不完成（真机正常）。因此本测试同步建队列、切歌调用不
// await 其播放部分——队列下标在 PlayQueue 里同步落位，断言只验证
// 「滑动手势 → 队列推进 → 页面跟随」这条链，这正是上下滑切歌的语义。
// 也不用 pumpAndSettle（loading 指示器会让 settle 永不返回），改有界 pump。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qinyin/models/models.dart';
import 'package:qinyin/screens/player_screen.dart';
import 'package:qinyin/services/download_service.dart';
import 'package:qinyin/services/library_service.dart';
import 'package:qinyin/services/play_resolver.dart';
import 'package:qinyin/services/player_service.dart';
import 'package:qinyin/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

SeoTrack fakeSeo(String id) => SeoTrack(
      track: Track(id: id, name: '歌曲$id'),
      lyricRaw: '[0,3000]<0,500,0>一行歌词',
      streams: const [
        PlayStream(
            quality: 'higher',
            codecType: 'aac',
            bitrate: 130000,
            mainUrl: 'https://cdn.example.com/x.m4a'),
      ],
      expireAt: 9999999999,
    );

/// 有界推进帧：让 PageView 滑动/切页动画（300ms）在假时间里走完
Future<void> pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('上滑切下一首、下滑切上一首（与队列推进共用）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    await settings.init();
    final library = LibraryService();
    await library.init();
    final resolver = PlayResolver((id) async => fakeSeo(id));
    final player = PlayerService(resolver, settings, library);
    // 播放页含下载按钮（与 main.dart 同口径提供 DownloadService）
    final downloads = DownloadService(resolver, settings);
    // 注意：必须在测试体结尾显式 dispose（框架的 Timer 不变量检查
    // 早于 addTearDown 执行，靠 addTearDown 取消周期 Timer 会误报）

    // 同步建队列（与 playQueue 内部落位方式一致：queue.setQueue）
    player.queue.setQueue(
      [
        Track(id: '1', name: '歌曲1'),
        Track(id: '2', name: '歌曲2'),
        Track(id: '3', name: '歌曲3'),
      ],
      0,
    );
    expect(player.hasQueue, isTrue);
    expect(player.currentIndex, 0);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: library),
          ChangeNotifierProvider.value(value: player),
          ChangeNotifierProvider.value(value: downloads),
          Provider.value(value: resolver),
        ],
        child: const MaterialApp(home: FreshPlayer()),
      ),
    );
    await pumpFrames(tester);
    // 纵向分页器（切歌）与封面区横向分页器（歌词）并存，按方向区分
    final verticalPager = find.byWidgetPredicate(
        (w) => w is PageView && w.scrollDirection == Axis.vertical);
    final horizontalPager = find.byWidgetPredicate(
        (w) => w is PageView && w.scrollDirection == Axis.horizontal);
    expect(verticalPager, findsOneWidget);
    expect(find.text('歌曲1'), findsOneWidget);

    // 上滑 → 下一首
    await tester.fling(verticalPager, const Offset(0, -500), 1200);
    await pumpFrames(tester);
    expect(player.currentIndex, 1, reason: '上滑应推进到下一首');
    expect(find.text('歌曲2'), findsOneWidget);

    // 再上滑 → 第三首
    await tester.fling(verticalPager, const Offset(0, -500), 1200);
    await pumpFrames(tester);
    expect(player.currentIndex, 2);

    // 下滑 → 上一首
    await tester.fling(verticalPager, const Offset(0, 500), 1200);
    await pumpFrames(tester);
    expect(player.currentIndex, 1, reason: '下滑应回到上一首');
    expect(find.text('歌曲2'), findsOneWidget);

    // 按钮切歌与滑动共用同一推进口径（下标同步落位，不 await 播放部分）
    unawaited(player.next());
    await pumpFrames(tester);
    expect(player.currentIndex, 2);
    unawaited(player.prev());
    await pumpFrames(tester);
    expect(player.currentIndex, 1);

    // ── 移动端播放页新交互（页签已撤）：封面区横向分页进歌词页 ──
    // 无歌词/评论页签
    expect(find.byType(SegmentedButton<int>), findsNothing,
        reason: '移动端播放页不应再有歌词/评论页签');
    expect(horizontalPager, findsWidgets);
    final hPager = tester.widget<PageView>(horizontalPager.first);
    expect(hPager.controller?.page, 1, reason: '横向分页初始停在封面页');
    // 右滑 → 歌词页（page=0），且不切歌（纵向队列下标不动）
    await tester.fling(horizontalPager.first, const Offset(500, 0), 1200);
    await pumpFrames(tester);
    expect(tester.widget<PageView>(horizontalPager.first).controller?.page, 0,
        reason: '右滑应进入歌词页');
    expect(find.text('一行歌词'), findsWidgets, reason: '歌词页应显示歌词行');
    expect(player.currentIndex, 1, reason: '横向滑动不应触发切歌');

    // 左滑回封面页（page=1）
    await tester.fling(horizontalPager.first, const Offset(-500, 0), 1200);
    await pumpFrames(tester);
    expect(tester.widget<PageView>(horizontalPager.first).controller?.page, 1,
        reason: '左滑应回到封面页');

    // 评论改遮盖式抽屉：点评论入口弹出 BottomSheet（底层页不动）
    await tester.tap(find.byIcon(Icons.mode_comment_outlined).first);
    await pumpFrames(tester);
    expect(find.byType(BottomSheet), findsOneWidget,
        reason: '评论应以遮盖式抽屉弹出');
    expect(find.byType(CommentsList), findsOneWidget);
    // 点遮罩关闭
    await tester.tapAt(const Offset(10, 10));
    await pumpFrames(tester);
    expect(find.byType(BottomSheet), findsNothing);

    player.dispose(); // 取消周期存进度 Timer，过框架不变量检查
  });
}
