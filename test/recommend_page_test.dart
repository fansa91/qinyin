// 推荐页五项修整验收（移动端）：
// 1) 顶部 SafeArea 已包（iPhone 状态栏重叠的代码级防线；真机 inset
//    观感待真机验，测试环境 viewPadding=0 只断言结构在位）；
// 2) 三键行（发现/播放/我的）已去掉；进度条 + 播放/暂停键移到
//    封面正下方（控制行），歌词页底部同置一份控制行；
// 3) 横向分页：初始停推荐流页，右滑进歌词页、左滑返回；纵向滑切歌
//    不被横向分页吞（歌词页上纵向滑同样切歌）；
// 4) 评论走遮盖式抽屉：≈50% 屏高浮层、底层页面原地不动、点遮罩关闭；
// 5) 壳层 mini 播放条在推荐页隐藏、其他页显示（无占位残留）。
//
// 手法与 fresh_player_swipe_test 一致：测试环境无音频插件，播放
// future 不完成，断言只验证 UI/手势/队列下标链；有界 pump 不 settle。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'fake_auth.dart';
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
import 'package:qinyin/widgets/cover_image.dart';
import 'package:qinyin/widgets/mini_player.dart';
import 'package:qinyin/widgets/seek_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

SeoTrack fakeSeo(String id) => SeoTrack(
      track: Track(
        id: id,
        name: '歌曲$id',
        durationMs: 213000,
        countCollected: 99,
        countComment: 128,
        countShared: 7,
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
      comments: const [
        SeoComment(
            id: 'c1', content: '这首太好听了', nickname: '听友甲', diggCount: 42),
      ],
    );

/// 有界推进帧：让 PageView 切页/抽屉动画在假时间里走完
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

Finder horizontalPager() => find.byWidgetPredicate(
      (w) => w is PageView && w.scrollDirection == Axis.horizontal,
      description: '横向分页',
    );

void main() {
  testWidgets('推荐页：SafeArea/SeekBar/横向歌词页/评论抽屉', (tester) async {
    usePhoneSurface(tester);
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    await settings.init();
    final library = LibraryService();
    await library.init();
    final resolver = PlayResolver((id) async => fakeSeo(id));
    final player = PlayerService(resolver, settings, library);
    // 会话隔离口径：推荐页展示的是推荐会话，用专用入口建会话
    // （状态同步落位；播放 future 在测试环境不完成，与既有口径同）
    unawaited(player.startRecommendSession(
      [
        Track(id: '1', name: '歌曲1'),
        Track(id: '2', name: '歌曲2'),
        Track(id: '3', name: '歌曲3'),
      ],
      0,
    ));

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: player),
          ChangeNotifierProvider.value(value: testAuthService),
          Provider.value(value: resolver),
          Provider<QishuiService>.value(value: QishuiService()),
        ],
        // 与真实壳层一致：推荐页挂在 Scaffold 之下（Material 祖先来自它）
        child: const MaterialApp(
            home: Scaffold(body: RecommendScreen(active: true))),
      ),
    );
    await pumpFrames(tester);

    // 1) 顶部安全区已包住整个推荐页
    expect(
      find.descendant(
          of: find.byType(RecommendScreen), matching: find.byType(SafeArea)),
      findsOneWidget,
      reason: '推荐页应整体包在 SafeArea 里防状态栏重叠',
    );

    // 2) 控制行在封面正下方：至少一条 SeekBar 紧贴大封面下缘、
    // 位于歌名之上（歌词页底部同置一份控制行，故按位置断言而非
    // 计数）；控制行带播放/暂停键；三键行（发现/我的）不存在
    final bigCover = find.byWidgetPredicate(
        (w) => w is CoverImage && (w.height ?? 0) > 100);
    expect(bigCover, findsWidgets);
    final coverRect = tester.getRect(bigCover.first);
    final titleRect = tester.getRect(find.text('歌曲1').first);
    final seekRects = find
        .byType(SeekBar)
        .evaluate()
        .map((e) => tester.getRect(find.byWidget(e.widget)))
        .toList();
    expect(
      seekRects.any((r) =>
          r.top >= coverRect.bottom - 2 && r.bottom <= titleRect.top + 2),
      isTrue,
      reason: '进度条应紧贴封面下方、歌名之上（封面下控制行；封面已改'
          '居中正方形后控制行仍按页宽排布，横向不再与封面同宽）',
    );
    expect(
      find.descendant(
        of: find.byType(RecommendScreen),
        matching: find.byWidgetPredicate((w) =>
            w is IconButton &&
            w.icon is Icon &&
            {Icons.play_arrow, Icons.pause, Icons.hourglass_top}
                .contains((w.icon as Icon).icon)),
      ),
      findsWidgets,
      reason: '控制行应带播放/暂停键（测试环境播放 future 不完成，'
          '图标可能停在加载态 hourglass）',
    );
    expect(
      find.descendant(
          of: find.byType(RecommendScreen), matching: find.text('发现')),
      findsNothing,
    );
    expect(
      find.descendant(
          of: find.byType(RecommendScreen), matching: find.text('我的')),
      findsNothing,
    );

    // 3) 横向分页初始停在推荐流页（page=1），歌词页在左侧
    final pager = tester.widget<PageView>(horizontalPager().first);
    expect(pager.controller?.page, 1, reason: '初始应停在推荐流页');

    // 右滑 → 歌词页（page=0），且不切歌
    await tester.fling(horizontalPager().first, const Offset(500, 0), 1200);
    await pumpFrames(tester);
    expect(tester.widget<PageView>(horizontalPager().first).controller?.page,
        0,
        reason: '右滑应进入歌词页');
    expect(player.currentIndex, 0, reason: '横向滑动不应切歌');
    expect(find.text('一行歌词'), findsWidgets,
        reason: '歌词页应展示当前曲歌词');

    // 歌词页上纵向滑 → 照常切下一首（纵向手势不被横向分页/歌词列表吞）
    await tester.fling(horizontalPager().first, const Offset(0, -600), 1400);
    await pumpFrames(tester);
    expect(player.currentIndex, 1, reason: '歌词页上上滑应切下一首');

    // 主推荐页上纵向滑回上一首
    await tester.fling(find.byType(PageView).first, const Offset(0, 600), 1400);
    await pumpFrames(tester);
    expect(player.currentIndex, 0, reason: '下滑应回到上一首');

    // 4) 评论抽屉（遮盖式）：先记下底层页头位置（锚点用副标题——
    // 移动页头已按用户点名去掉「推荐」标题字样，副标题仍在原位）
    final headerFinder = find.descendant(
        of: find.byType(RecommendScreen),
        matching: find.text('官方推荐流 · 游客版（登录后推荐更准）'));
    final headerPosBefore = tester.getTopLeft(headerFinder);
    await tester.tap(find
        .descendant(
            of: find.byType(RecommendScreen),
            matching: find.byIcon(Icons.mode_comment))
        .first);
    await pumpFrames(tester);
    expect(find.byType(CommentsList), findsOneWidget,
        reason: '点评论应打开评论抽屉');
    expect(find.text('这首太好听了'), findsOneWidget);
    // 高度约五成屏：抽屉顶边应落在屏高 38%–56% 区间（50% + 把手余量）
    final sheetRect = tester.getRect(find.byType(BottomSheet));
    final screenH = tester.view.physicalSize.height /
        tester.view.devicePixelRatio;
    expect(sheetRect.top, greaterThan(screenH * 0.38));
    expect(sheetRect.top, lessThan(screenH * 0.56));
    // 遮盖式语义：底层页面原地不动
    expect(tester.getTopLeft(headerFinder), headerPosBefore,
        reason: '抽屉打开时底层页面不应位移');
    // 点遮罩关闭
    await tester.tapAt(const Offset(195, 80));
    await pumpFrames(tester);
    expect(find.byType(CommentsList), findsNothing,
        reason: '点遮罩应关闭抽屉');

    player.dispose();
  });

  testWidgets('壳层：推荐页隐藏 mini 条，其他页显示', (tester) async {
    usePhoneSurface(tester);
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    await settings.init();
    final library = LibraryService();
    await library.init();
    final resolver = PlayResolver((id) async => fakeSeo(id));
    final downloads = DownloadService(resolver, settings);
    final player = PlayerService(resolver, settings, library);
    player.queue.setQueue([Track(id: '1', name: '歌曲1')], 0);

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

    // 首页（下标 0）：mini 条在
    expect(find.byType(MiniPlayer), findsOneWidget);

    // 切到推荐页（下标 1）：mini 条被摘掉（不是隐藏占位），导航栏还在
    await tester.tap(find.descendant(
        of: find.byType(NavigationBar), matching: find.text('推荐')));
    await pumpFrames(tester);
    expect(find.byType(MiniPlayer), findsNothing,
        reason: '推荐页自带播放面，mini 条应隐藏');
    expect(find.byType(NavigationBar), findsOneWidget);

    // 切回首页：mini 条恢复
    await tester.tap(find.descendant(
        of: find.byType(NavigationBar), matching: find.text('首页')));
    await pumpFrames(tester);
    expect(find.byType(MiniPlayer), findsOneWidget);

    player.dispose();
  });

  testWidgets('页头：移动形态无「推荐」标题、场景 chip 在原标题位（桌面形态不动）',
      (tester) async {
    Widget header({required bool expanded, String? sceneName}) =>
        MaterialApp(
          home: Scaffold(
            body: RecommendHeader(
              expanded: expanded,
              modes: const [FeedMode(name: 'DJ模式', sceneModeId: '7')],
              scene: sceneName == null
                  ? null
                  : FeedMode(name: sceneName, sceneModeId: '7'),
              refreshing: false,
              loadedListEnabled: true,
              onRefresh: () {},
              onShowLoadedList: () {},
              onSearch: () {},
              onPickScene: () {},
            ),
          ),
        );

    // 移动形态：「推荐」标题字样已去（find.text 整串匹配，副标题
    // 「官方推荐流…」是另一整串、不会误命中）；场景 chip 显示
    // 「默认推荐」且位于副标题之上（原标题位）
    await tester.pumpWidget(header(expanded: false));
    expect(find.text('推荐'), findsNothing);
    expect(find.text('默认推荐'), findsOneWidget);
    final chipRect = tester.getRect(find.text('默认推荐'));
    final subRect =
        tester.getRect(find.text('官方推荐流 · 游客版（登录后推荐更准）'));
    expect(chipRect.bottom <= subRect.top, isTrue,
        reason: '场景 chip 应占原标题位、在副标题之上');

    // 已选场景：chip 显示场景名
    await tester.pumpWidget(header(expanded: false, sceneName: 'DJ模式'));
    expect(find.text('DJ模式'), findsOneWidget);
    expect(find.text('推荐'), findsNothing);

    // 桌面形态回归（本批四修只限移动端）：标题在、chip 在副标题下方
    await tester.pumpWidget(header(expanded: true));
    expect(find.text('推荐'), findsOneWidget);
    expect(find.text('默认推荐'), findsOneWidget);
    final titleRect = tester.getRect(find.text('推荐'));
    final chipRectD = tester.getRect(find.text('默认推荐'));
    expect(titleRect.bottom <= chipRectD.top, isTrue,
        reason: '桌面页头保持原布局：标题在上、chip 在副标题下方');
  });

  testWidgets('推荐页 360/390：无溢出、封面正方形 1:1、歌词预览行已删',
      (tester) async {
    addTearDown(() => tester.view.reset());
    for (final logical in [const Size(360, 740), const Size(390, 844)]) {
      tester.view.physicalSize =
          Size(logical.width * 2, logical.height * 2);
      tester.view.devicePixelRatio = 2.0;
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService();
      await settings.init();
      final library = LibraryService();
      await library.init();
      final resolver = PlayResolver((id) async => fakeSeo(id));
      final player = PlayerService(resolver, settings, library);
      unawaited(player.startRecommendSession(
        [
          Track(id: '1', name: '歌曲1'),
          Track(id: '2', name: '歌曲2'),
        ],
        0,
      ));
      await tester.pumpWidget(
        MultiProvider(
          providers: [
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
      expect(tester.takeException(), isNull,
          reason: '$logical 宽下推荐页不应有溢出/框架异常');

      // 大封面为正方形（1:1），边长不超页宽（左右各 20 内边距）
      final bigCover = find.byWidgetPredicate(
          (w) => w is CoverImage && (w.height ?? 0) > 100);
      expect(bigCover, findsWidgets);
      final coverSize = tester.getSize(bigCover.first);
      expect((coverSize.width - coverSize.height).abs(), lessThan(0.5),
          reason: '封面宽高比应为 1:1（原定高全宽会压扁）');
      expect(coverSize.width, lessThanOrEqualTo(logical.width - 40 + 0.5));

      // 歌名上方的现行歌词预览行（带中文引号的整行）已删除
      expect(find.text('“一行歌词”'), findsNothing,
          reason: '歌词预览行应整体删除（歌词页里的歌词行不受影响）');

      player.dispose();
    }
  });
}
