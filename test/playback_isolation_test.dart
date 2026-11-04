// 播放会话隔离验收（用户定版，取代早先的「挂起/恢复交接」语义）：
//
// - 全 App 仍只有一个播放引擎（一个 PlayerService、一个
//   AudioPlayer），但播放入口按来源分主/推荐两个会话；
// - 推荐会话的曲目永不出现在 MiniPlayer 上：推荐占用输出时
//   miniBarHasContent=false，mini 条按「无主队列内容」隐藏；
// - 两侧互不传递/接管：主队列点播只影响主会话（推荐会话的曲目/
//   下标/续拉回调原样保留在它自己的 store 里），推荐会话点播
//   同理不动主会话；谁开始播，另一侧暂停存档，之后从存档恢复；
// - 跨 tab 回推荐页，会话状态（曲目/下标）还在。
//
// 测试手法与既有播放测试一致：测试环境无音频插件，_playAt 的
// 平台 future 不完成，因此点播调用不 await 其播放部分——会话
// 状态在各入口里同步落位，断言只验状态链。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'fake_auth.dart';
import 'package:qinyin/main.dart';
import 'package:qinyin/models/models.dart';
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
  group('PlayerService 会话隔离', () {
    testWidgets('主队列点播不改变推荐会话；推荐抢回输出不改变主队列',
        (tester) async {
      final player = await makePlayer();
      final rec = [t('r1', '推荐歌曲1'), t('r2', '推荐歌曲2'), t('r3', '推荐歌曲3')];
      Future<List<Track>> loader() async => [t('r4', '推荐歌曲4')];

      // 建推荐会话并切到第 3 首
      unawaited(player.startRecommendSession(rec, 0, loadMore: loader));
      unawaited(player.recommendJumpTo(2));
      expect(player.activeSession, PlayerSession.recommend);
      expect(player.recommendCurrentIndex, 2);
      expect(player.recommendCurrentTrack?.id, 'r3');
      // 推荐占用输出期间：mini 条无内容（推荐曲目不上 mini 条）
      expect(player.miniBarHasContent, isFalse);

      // 首页点播：只影响主会话，推荐会话原样保留在自己 store 里
      final home = [t('h1', '首页歌曲1'), t('h2', '首页歌曲2')];
      unawaited(player.playQueue(home, 1));
      expect(player.activeSession, PlayerSession.main);
      expect(player.currentTrack?.id, 'h2');
      expect(player.miniBarHasContent, isTrue);
      expect(player.recommendQueueItems.map((e) => e.id), ['r1', 'r2', 'r3'],
          reason: '主队列点播不改变推荐会话曲目');
      expect(player.recommendCurrentIndex, 2,
          reason: '主队列点播不改变推荐会话下标');
      expect(player.recommendCurrentTrack?.id, 'r3');

      // 未占用输出时，推荐页切歌只挪推荐会话下标，不触碰主会话
      unawaited(player.recommendJumpTo(0));
      expect(player.recommendCurrentIndex, 0);
      expect(player.currentTrack?.id, 'h2', reason: '主会话当前曲目不受影响');
      expect(player.activeSession, PlayerSession.main);
      unawaited(player.recommendJumpTo(2));

      // 推荐会话抢回输出：从存档下标续播，主队列原样保留
      unawaited(player.claimRecommendOutput());
      expect(player.activeSession, PlayerSession.recommend);
      expect(player.currentTrack?.id, 'r3');
      expect(player.currentIndex, 2);
      expect(player.mainQueueItems.map((e) => e.id), ['h1', 'h2'],
          reason: '推荐抢回输出不改变主队列曲目');
      expect(player.mainCurrentIndex, 1, reason: '主队列下标原样保留');
      expect(player.mainCurrentTrack?.id, 'h2');
      // 续拉回调随会话一并恢复：队尾续拉仍走推荐流的分页器
      final more = await player.onLoadMore!();
      expect(more.map((e) => e.id), ['r4']);
      player.dispose();
    });

    testWidgets('推荐会话点播不改变主队列（先有主队列的情形）',
        (tester) async {
      final player = await makePlayer();
      unawaited(player.playQueue([t('h1', '首页歌曲1'), t('h2', '首页歌曲2')], 1));
      expect(player.currentTrack?.id, 'h2');

      unawaited(player.startRecommendSession([t('r1', '推荐歌曲1')], 0));
      expect(player.activeSession, PlayerSession.recommend);
      expect(player.currentTrack?.id, 'r1');
      expect(player.mainQueueItems.map((e) => e.id), ['h1', 'h2']);
      expect(player.mainCurrentIndex, 1);
      expect(player.mainCurrentTrack?.id, 'h2');
      expect(player.miniBarHasContent, isFalse,
          reason: '推荐占用输出时 mini 条按无主队列内容处理');

      // 主会话再点播（新内容）→ 推荐会话仍在
      unawaited(player.playQueue([t('s1', '搜索歌曲1')], 0));
      expect(player.currentTrack?.id, 's1');
      expect(player.recommendCurrentTrack?.id, 'r1');
      expect(player.recommendHasContent, isTrue);
      player.dispose();
    });

    testWidgets('setRecommendSession 只预置不抢输出，toggleRecommend 才接管',
        (tester) async {
      final player = await makePlayer();
      unawaited(player.playQueue([t('h1', '首页歌曲1')], 0));
      player.setRecommendSession([t('r1', '推荐歌曲1'), t('r2', '推荐歌曲2')]);
      // 预置后：输出仍属主会话，推荐会话以暂停态待命
      expect(player.activeSession, PlayerSession.main);
      expect(player.currentTrack?.id, 'h1');
      expect(player.recommendHasContent, isTrue);
      expect(player.recommendCurrentTrack?.id, 'r1');
      expect(player.recommendPlaying, isFalse);

      unawaited(player.toggleRecommend());
      expect(player.activeSession, PlayerSession.recommend);
      expect(player.currentTrack?.id, 'r1');
      expect(player.mainCurrentTrack?.id, 'h1',
          reason: '主会话被暂停存档，内容不丢');
      player.dispose();
    });
  });

  testWidgets('壳层：MiniPlayer 只显示主会话曲目，推荐占用时隐藏',
      (tester) async {
    usePhoneSurface(tester);
    final player = await makePlayer();
    final settings = player.settings;
    final library = player.library;
    final resolver = PlayResolver((id) async => fakeSeo(id));
    final downloads = DownloadService(resolver, settings);
    unawaited(player.playQueue([t('h1', '首页歌曲1')], 0));

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: library),
          ChangeNotifierProvider.value(value: downloads),
          ChangeNotifierProvider.value(value: player),
          ChangeNotifierProvider.value(value: testAuthService),
          Provider.value(value: resolver),
          Provider<QishuiService>.value(value: QishuiService()),
        ],
        child: const MaterialApp(home: AppShell()),
      ),
    );
    await pumpFrames(tester);

    // 主会话在播：首页 tab 的 mini 条显示主会话曲目
    expect(
      find.descendant(
          of: find.byType(MiniPlayer), matching: find.text('首页歌曲1')),
      findsOneWidget,
    );

    // 推荐会话开始播：mini 条在任何页面都不显示推荐曲目（整体隐藏）
    unawaited(player.startRecommendSession([t('r1', '推荐歌曲1')], 0));
    await pumpFrames(tester);
    expect(find.text('推荐歌曲1'), findsNothing,
        reason: '推荐曲目不应出现在首页（含 mini 条）上');
    expect(tester.getSize(find.byType(MiniPlayer)).height, 0,
        reason: '推荐占用输出时 mini 条按无主队列内容隐藏');

    // 主会话再点播：mini 条恢复，显示的是新的主会话曲目
    unawaited(player.playQueue([t('h2', '首页歌曲2')], 0));
    await pumpFrames(tester);
    expect(
      find.descendant(
          of: find.byType(MiniPlayer), matching: find.text('首页歌曲2')),
      findsOneWidget,
    );

    player.dispose();
  });

  testWidgets('跨 tab 回推荐页：会话曲目与下标还在', (tester) async {
    usePhoneSurface(tester);
    final player = await makePlayer();
    final settings = player.settings;
    final library = player.library;
    final resolver = PlayResolver((id) async => fakeSeo(id));
    final downloads = DownloadService(resolver, settings);
    unawaited(player.startRecommendSession(
      [t('1', '歌曲1'), t('2', '歌曲2'), t('3', '歌曲3')],
      0,
    ));
    unawaited(player.recommendJumpTo(1));
    expect(player.recommendCurrentIndex, 1);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: library),
          ChangeNotifierProvider.value(value: downloads),
          ChangeNotifierProvider.value(value: player),
          ChangeNotifierProvider.value(value: testAuthService),
          Provider.value(value: resolver),
          Provider<QishuiService>.value(value: QishuiService()),
        ],
        child: const MaterialApp(home: AppShell()),
      ),
    );
    await pumpFrames(tester);

    // 切到推荐页：展示会话当前状态（第 2 首）
    await tester.tap(find.descendant(
        of: find.byType(NavigationBar), matching: find.text('推荐')));
    await pumpFrames(tester);
    expect(player.recommendCurrentIndex, 1);
    expect(find.text('歌曲2'), findsWidgets,
        reason: '推荐页应展示离开时那首（会话第 2 首）');

    // 离开再回来：下标与曲目不变（会话只活在推荐页自己手里）
    await tester.tap(find.descendant(
        of: find.byType(NavigationBar), matching: find.text('首页')));
    await pumpFrames(tester);
    await tester.tap(find.descendant(
        of: find.byType(NavigationBar), matching: find.text('推荐')));
    await pumpFrames(tester);
    expect(player.recommendCurrentIndex, 1);
    expect(player.recommendCurrentTrack?.id, '2');
    expect(find.text('歌曲2'), findsWidgets);

    player.dispose();
  });
}
