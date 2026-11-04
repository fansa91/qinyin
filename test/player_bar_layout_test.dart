// 播放条布局验收（壳层三档 + 桌面推荐页）：
// 1) compact/medium：MiniPlayer 是悬浮宽条（Positioned 浮于内容上、
//    两侧小边距 12、接近满宽、高度不变），内容区留等效底部避让；
// 2) expanded：通栏条保持布局式（不悬浮）；三档在推荐页都不显示；
// 3) 桌面推荐页（DesktopPlayer embedded）：队列入口只剩页头一个、
//    封面下有控制行（SeekBar + 播放键）、当前曲带音质/VIP 徽标、
//    顶部与页面同色（Scaffold 底色 == 整页顶色）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'fake_auth.dart';
import 'package:qinyin/core/utils.dart';
import 'package:qinyin/main.dart';
import 'package:qinyin/models/models.dart';
import 'package:qinyin/screens/player_screen.dart';
import 'package:qinyin/screens/recommend_screen.dart';
import 'package:qinyin/services/download_service.dart';
import 'package:qinyin/services/library_service.dart';
import 'package:qinyin/services/play_resolver.dart';
import 'package:qinyin/services/player_service.dart';
import 'package:qinyin/services/qishui_service.dart';
import 'package:qinyin/services/settings_service.dart';
import 'package:qinyin/widgets/mini_player.dart';
import 'package:qinyin/widgets/seek_bar.dart';
import 'package:qinyin/widgets/track_badges.dart';
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

Future<PlayerService> makePlayer() async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsService();
  await settings.init();
  final library = LibraryService();
  await library.init();
  final resolver = PlayResolver((id) async => fakeSeo(id));
  return PlayerService(resolver, settings, library);
}

Future<void> pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void useSurface(WidgetTester tester, double w, double h) {
  tester.view.physicalSize = Size(w, h);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() => tester.view.reset());
}

Widget shellApp(PlayerService player) {
  final resolver = PlayResolver((id) async => fakeSeo(id));
  return MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: player.settings),
      ChangeNotifierProvider.value(value: player.library),
      ChangeNotifierProvider.value(
          value: DownloadService(resolver, player.settings)),
      ChangeNotifierProvider.value(value: player),
      ChangeNotifierProvider.value(value: testAuthService),
      Provider.value(value: resolver),
      Provider<QishuiService>.value(value: QishuiService()),
    ],
    child: const MaterialApp(home: AppShell()),
  );
}

void main() {
  testWidgets('compact：mini 条悬浮宽条（两侧 12、导航上方 12、内容避让）',
      (tester) async {
    useSurface(tester, 390, 844);
    final player = await makePlayer();
    unawaited(player.playQueue([Track(id: 'h1', name: '首页歌曲1')], 0));
    await tester.pumpWidget(shellApp(player));
    await pumpFrames(tester);

    final mini = find.byType(MiniPlayer);
    expect(mini, findsOneWidget);
    // 悬浮：由 Positioned 定位（不在布局流里）
    expect(
      find.ancestor(of: mini, matching: find.byType(Positioned)),
      findsOneWidget,
      reason: 'compact 悬浮条应由 Positioned 浮于内容之上',
    );
    final miniRect = tester.getRect(mini);
    // 宽条：接近满宽，两侧各 12
    expect(miniRect.left, closeTo(12, 0.6));
    expect(miniRect.right, closeTo(390 - 12, 0.6));
    // 位于底部导航栏上方 12
    final navRect = tester.getRect(find.byType(NavigationBar));
    expect(navRect.top - miniRect.bottom, closeTo(12, 0.6));
    // 高度保持既有 mini 条高度（实测 ≈68，不压扁）
    expect(miniRect.height, closeTo(68, 3));
    // 内容避让：页面区（IndexedStack）底部不被悬浮条盖住
    final stackRect = tester.getRect(find.byType(IndexedStack).first);
    expect(stackRect.bottom, lessThanOrEqualTo(miniRect.top - 4),
        reason: '内容区底部应留出避让，滑到底不被悬浮条遮住');
    player.dispose();
  });

  testWidgets('medium：mini 条同为悬浮（避开左侧导航轨）', (tester) async {
    useSurface(tester, 700, 1000);
    final player = await makePlayer();
    unawaited(player.playQueue([Track(id: 'h1', name: '首页歌曲1')], 0));
    await tester.pumpWidget(shellApp(player));
    await pumpFrames(tester);

    final mini = find.byType(MiniPlayer);
    expect(mini, findsOneWidget);
    expect(
      find.ancestor(of: mini, matching: find.byType(Positioned)),
      findsOneWidget,
    );
    final miniRect = tester.getRect(mini);
    expect(miniRect.left, closeTo(93, 1), reason: '应避开 NavigationRail(80+1) 再留 12');
    expect(miniRect.right, closeTo(700 - 12, 0.6));
    player.dispose();
  });

  testWidgets('expanded：通栏条布局式不悬浮；推荐页三档统一隐藏',
      (tester) async {
    useSurface(tester, 1280, 800);
    final player = await makePlayer();
    unawaited(player.playQueue([Track(id: 'h1', name: '首页歌曲1')], 0));
    await tester.pumpWidget(shellApp(player));
    await pumpFrames(tester);

    final mini = find.byType(MiniPlayer);
    expect(mini, findsOneWidget);
    expect(
      find.ancestor(of: mini, matching: find.byType(Positioned)),
      findsNothing,
      reason: '桌面通栏条保持布局式，不悬浮',
    );

    // 切到推荐页：播放条整棵摘除（不是隐藏占位）
    await tester.tap(find.widgetWithText(ListTile, '推荐'));
    await pumpFrames(tester);
    expect(find.byType(MiniPlayer), findsNothing,
        reason: '桌面端推荐页同样不显示播放条（用户定版）');

    // 切回发现：恢复
    await tester.tap(find.widgetWithText(ListTile, '发现'));
    await pumpFrames(tester);
    expect(find.byType(MiniPlayer), findsOneWidget);
    player.dispose();
  });

  testWidgets('桌面推荐页：队列入口只剩一个、封面下控制行、徽标、顶部同色',
      (tester) async {
    useSurface(tester, 1280, 800);
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    await settings.init();
    final library = LibraryService();
    await library.init();
    // seo 曲目与会话曲目同标志：_playAt 完成后展示以 seo 曲目为准，
    // 两边都带 VIP/音质/取色，断言不依赖哪份先落位
    final resolver = PlayResolver((id) async => SeoTrack(
          track: Track(
            id: id,
            name: '歌曲$id',
            durationMs: 213000,
            topQuality: 'lossless',
            isVip: true,
            coverColorHex: 'FF8800',
          ),
          lyricRaw: '[0,3000]<0,500,0>一行歌词',
          streams: const [
            PlayStream(
                quality: 'higher',
                codecType: 'aac',
                bitrate: 130000,
                mainUrl: 'https://cdn.example.com/x.m4a'),
          ],
          expireAt: 9999999999,
        ));
    final player = PlayerService(resolver, settings, library);
    const vipTrack = Track(
      id: 'v1',
      name: 'VIP歌曲',
      topQuality: 'lossless',
      isVip: true,
      coverColorHex: 'FF8800',
    );
    unawaited(player.startRecommendSession([vipTrack], 0));

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: library),
          ChangeNotifierProvider.value(
              value: DownloadService(resolver, settings)),
          ChangeNotifierProvider.value(value: player),
          ChangeNotifierProvider.value(value: testAuthService),
          Provider.value(value: resolver),
          Provider<QishuiService>.value(value: QishuiService()),
        ],
        child: const MaterialApp(
            home: Scaffold(body: RecommendScreen(active: true))),
      ),
    );
    await pumpFrames(tester);

    expect(find.byType(DesktopPlayer), findsOneWidget);
    // 队列/列表入口去重：整页只剩页头一个（DesktopPlayer 的已隐藏）
    expect(
      find.descendant(
          of: find.byType(RecommendScreen),
          matching: find.byIcon(Icons.queue_music)),
      findsOneWidget,
      reason: '桌面推荐页的队列入口应只剩页头「已加载列表」一个',
    );
    // 封面下方控制行：SeekBar + 播放键在 DesktopPlayer 内
    expect(
      find.descendant(
          of: find.byType(DesktopPlayer), matching: find.byType(SeekBar)),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: find.byType(DesktopPlayer),
          matching: find.byIcon(Icons.skip_next)),
      findsOneWidget,
    );
    // 当前曲徽标：音质 + VIP（与移动端 TrackTile 同一套组件）
    expect(
      find.descendant(
          of: find.byType(DesktopPlayer), matching: find.byType(VipBadge)),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: find.byType(DesktopPlayer),
          matching: find.byType(QualityBadge)),
      findsOneWidget,
    );
    // 顶部同色：推荐页外层底色 == DesktopPlayer 的 Scaffold 底色
    // == 页面顶色公式（当前会话曲目封面取色）
    final ctx = tester.element(find.byType(RecommendScreen));
    final expected = recommendPageTopColor(ctx, vipTrack);
    final scaffold = tester.widget<Scaffold>(
      find.descendant(
          of: find.byType(DesktopPlayer), matching: find.byType(Scaffold)),
    );
    expect(scaffold.backgroundColor, expected,
        reason: '桌面推荐页上方区域应与页面顶色一致，无色块分界');
    player.dispose();
  });
}
