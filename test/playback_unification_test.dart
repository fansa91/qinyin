// 播放统一性验收：全 App 只有一个播放引擎、一条当前队列。
//
// 背景（用户实报）：「迷你播放器只对首页上的歌单和歌曲有效；当播放
// 首页的歌曲的时候，推荐的歌曲就暂停。」代码级确诊：引擎层本就
// 单一（main.dart 只构造一份 PlayerService、内部只有一个
// AudioPlayer，所有来源的点播都汇入 playQueue/jumpTo），分裂在
// 队列所有权层——推荐队列被外部点播换队后即蒸发，回推荐页只能
// 从第一首重建，体验上像两个互不隶属的播放器。
//
// 修复后的语义（本文件锁住）：
// - 外部来源接管推荐队列时，PlayerService 先把推荐会话快照挂起
//   （曲目 + 下标 + 续拉回调），交接是干净换队，不残留第二份状态；
// - resumeRecommendQueue 从挂起处原样恢复（下标/续拉回调一并还原）；
// - MiniPlayer 与任意页面拿到的是同一个 PlayerService 实例，且它
//   反映/控制的当前曲目与来源无关（推荐来源的队列在首页 tab 的
//   mini 条上同样可控）；
// - 推荐页提示页在有挂起会话时给出「继续刷推荐」恢复入口。
//
// 测试手法与既有播放测试一致：测试环境无音频插件，_playAt 的平台
// future 不完成，因此点播调用不 await 其播放部分——队列状态在
// PlayQueue/playQueue 里同步落位，断言只验状态链。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qinyin/main.dart';
import 'package:qinyin/models/models.dart';
import 'package:qinyin/screens/home_screen.dart';
import 'package:qinyin/screens/recommend_screen.dart';
import 'package:qinyin/services/download_service.dart';
import 'package:qinyin/services/library_service.dart';
import 'package:qinyin/services/play_resolver.dart';
import 'package:qinyin/services/player_service.dart';
import 'package:qinyin/services/qishui_service.dart';
import 'package:qinyin/services/settings_service.dart';
import 'package:qinyin/widgets/mini_player.dart';
import 'package:shared_preferences/shared_preferences.dart';

SeoTrack fakeSeo(String id) => SeoTrack(
      track: Track(id: id, name: '歌曲$id', durationMs: 213000),
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

Track t(String id, String name) => Track(id: id, name: name);

Future<PlayerService> makePlayer() async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsService();
  await settings.init();
  final library = LibraryService();
  await library.init();
  final resolver = PlayResolver((id) async => fakeSeo(id));
  return PlayerService(resolver, settings, library);
}

/// 有界推进帧（与 recommend_page_test 同口径）
Future<void> pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void usePhoneSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(() => tester.view.reset());
}

void main() {
  // 服务级用例也走 testWidgets：纯 test() 环境里 AudioPlayer 构造的
  // 平台初始化 future 会以异步错误冒出（testWidgets 的 FakeAsync
  // 环境则与既有播放测试同口径，平台 future 不完成、状态同步落位）。
  group('PlayerService 推荐会话挂起/恢复', () {
    testWidgets('外部点播接管推荐队列时挂起快照，恢复回到原曲目与下标',
        (tester) async {
      final player = await makePlayer();
      final rec = [t('r1', '推荐歌曲1'), t('r2', '推荐歌曲2'), t('r3', '推荐歌曲3')];
      Future<List<Track>> loader() async => [t('r4', '推荐歌曲4')];

      unawaited(player.playQueue(rec, 0,
          tag: PlayerService.recommendQueueTag, loadMore: loader));
      unawaited(player.jumpTo(2));
      expect(player.queueTag, PlayerService.recommendQueueTag);
      expect(player.currentIndex, 2);
      expect(player.hasSuspendedRecommend, isFalse);

      // 首页点播接管：当前队列干净换成新来源，推荐会话被挂起
      final home = [t('h1', '首页歌曲1'), t('h2', '首页歌曲2')];
      unawaited(player.playQueue(home, 1));
      expect(player.queueTag, isNull);
      expect(player.currentTrack?.id, 'h2');
      expect(player.hasSuspendedRecommend, isTrue,
          reason: '推荐会话应被挂起而不是蒸发');
      expect(player.suspendedRecommendTrack?.id, 'r3',
          reason: '快照应停在接管时的当前曲目');

      // 再来一次外部接管：快照不被覆盖（仍是推荐会话那份）
      unawaited(player.playQueue([t('s1', '搜索歌曲1')], 0));
      expect(player.currentTrack?.id, 's1');
      expect(player.suspendedRecommendTrack?.id, 'r3');

      // 恢复：队列/下标/来源标记/续拉回调原样还原，快照清除
      unawaited(player.resumeRecommendQueue());
      expect(player.queueTag, PlayerService.recommendQueueTag);
      expect(player.currentIndex, 2);
      expect(player.currentTrack?.id, 'r3');
      expect(player.queueItems.map((e) => e.id), ['r1', 'r2', 'r3']);
      expect(player.hasSuspendedRecommend, isFalse);
      // 续拉回调一并还原：恢复后队尾续拉走的仍是推荐流的分页器
      final more = await player.onLoadMore!();
      expect(more.map((e) => e.id), ['r4'],
          reason: '恢复后队尾续拉应仍走推荐流的分页器');
      player.dispose();
    });

    testWidgets('非推荐来源之间互换不产生快照；无快照恢复是空操作',
        (tester) async {
      final player = await makePlayer();
      unawaited(player.playQueue([t('h1', '首页歌曲1')], 0));
      unawaited(player.playQueue([t('s1', '搜索歌曲1')], 0));
      expect(player.hasSuspendedRecommend, isFalse);
      final resumed = await player.resumeRecommendQueue();
      expect(resumed, isFalse);
      expect(player.currentTrack?.id, 's1', reason: '空恢复不应触碰当前队列');
      player.dispose();
    });

    testWidgets('新推荐会话建立后旧快照作废', (tester) async {
      final player = await makePlayer();
      unawaited(player.playQueue([t('r1', '推荐歌曲1')], 0,
          tag: PlayerService.recommendQueueTag));
      unawaited(player.playQueue([t('h1', '首页歌曲1')], 0));
      expect(player.hasSuspendedRecommend, isTrue);
      // 重新建推荐会话（刷新/开始刷推荐走的正是这条路）
      unawaited(player.playQueue([t('n1', '新推荐1')], 0,
          tag: PlayerService.recommendQueueTag));
      expect(player.hasSuspendedRecommend, isFalse);
      expect(player.currentTrack?.id, 'n1');
      player.dispose();
    });
  });

  testWidgets('壳层：全局只有一个 PlayerService 实例，mini 条控制与来源无关',
      (tester) async {
    usePhoneSurface(tester);
    final player = await makePlayer();
    final settings = player.settings;
    final library = player.library;
    final resolver = PlayResolver((id) async => fakeSeo(id));
    final downloads = DownloadService(resolver, settings);
    // 模拟「队列来自推荐流」的在播状态（状态落位方式与 playQueue 一致）
    player.queue.setQueue(
      [t('r1', '推荐歌曲1'), t('r2', '推荐歌曲2'), t('r3', '推荐歌曲3')],
      0,
    );
    player.queueTag = PlayerService.recommendQueueTag;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: library),
          ChangeNotifierProvider.value(value: downloads),
          ChangeNotifierProvider.value(value: player),
          Provider.value(value: resolver),
          Provider<QishuiService>.value(value: QishuiService()),
        ],
        child: const MaterialApp(home: AppShell()),
      ),
    );
    await pumpFrames(tester);

    // 首页 tab 上 mini 条显示的是推荐来源的当前曲目
    expect(find.byType(MiniPlayer), findsOneWidget);
    expect(
      find.descendant(
          of: find.byType(MiniPlayer), matching: find.text('推荐歌曲1')),
      findsOneWidget,
      reason: 'mini 条应反映全局当前曲目，与点播来源无关',
    );

    // 单实例：mini 条与首页拿到的是同一个 PlayerService 对象
    final fromMini = Provider.of<PlayerService>(
        tester.element(find.byType(MiniPlayer)),
        listen: false);
    final fromHome = Provider.of<PlayerService>(
        tester.element(find.byType(HomeScreen)),
        listen: false);
    expect(identical(fromMini, fromHome), isTrue);
    expect(identical(fromMini, player), isTrue);

    // mini 条的下一首控制的就是这条（推荐来源）队列
    await tester.tap(find.descendant(
        of: find.byType(MiniPlayer), matching: find.byIcon(Icons.skip_next)));
    await pumpFrames(tester);
    expect(player.currentIndex, 1);
    expect(
      find.descendant(
          of: find.byType(MiniPlayer), matching: find.text('推荐歌曲2')),
      findsOneWidget,
    );

    player.dispose();
  });

  testWidgets('推荐页提示页：有挂起会话时可从暂停处继续', (tester) async {
    usePhoneSurface(tester);
    final player = await makePlayer();
    final resolver = PlayResolver((id) async => fakeSeo(id));
    final rec = [t('r1', '推荐歌曲1'), t('r2', '推荐歌曲2'), t('r3', '推荐歌曲3')];
    unawaited(player.playQueue(rec, 0,
        tag: PlayerService.recommendQueueTag));
    unawaited(player.jumpTo(2));
    unawaited(player.playQueue([t('h1', '首页歌曲1')], 0));
    expect(player.hasSuspendedRecommend, isTrue);
    expect(player.currentTrack?.id, 'h1');

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: player),
          Provider.value(value: resolver),
          Provider<QishuiService>.value(value: QishuiService()),
        ],
        child: const MaterialApp(
            home: Scaffold(body: RecommendScreen(active: true))),
      ),
    );
    await pumpFrames(tester);

    // 提示页：不抢队列，但明确告知推荐暂停在哪首，并给出恢复入口
    expect(find.text('正在播放其他内容'), findsOneWidget);
    expect(find.textContaining('推荐流已暂停在《推荐歌曲3》'), findsOneWidget);
    expect(find.text('继续刷推荐'), findsOneWidget);
    expect(find.text('重新开始推荐'), findsOneWidget);

    await tester.tap(find.text('继续刷推荐'));
    await pumpFrames(tester);
    expect(player.queueTag, PlayerService.recommendQueueTag);
    expect(player.currentIndex, 2, reason: '应回到挂起时的下标而不是从头开始');
    expect(player.currentTrack?.id, 'r3');
    expect(player.hasSuspendedRecommend, isFalse);

    player.dispose();
  });
}
