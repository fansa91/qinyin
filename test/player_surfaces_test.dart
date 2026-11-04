// 播放面补强验收：
//
// - 专辑名：移动播放页与桌面播放页的曲目信息区都显示专辑名
//   （数据缺失时整行不渲染，不编造）；
// - MiniPlayer 时长：歌手行尾常驻总时长「歌手 · 3:33」（引擎
//   时长未就绪时退曲目元数据时长）；无时长数据时不拼占位；
// - 正在播放相关面补播放/暂停：桌面播放页「队列」表原本只有
//   点选跳播，表头补与全局状态同步的播放/暂停键。
//
// 手法与既有播放测试一致：假 resolver、平台 future 不完成，
// 断言只验 UI 状态呈现。
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
import 'package:qinyin/widgets/mini_player.dart';
import 'package:shared_preferences/shared_preferences.dart';

SeoTrack fakeSeo(Track track) => SeoTrack(
      track: track,
      lyricRaw: '',
      streams: const [
        PlayStream(
            quality: 'higher',
            codecType: 'aac',
            bitrate: 130000,
            mainUrl: 'https://cdn.example.com/x.m4a'),
      ],
      expireAt: 9999999999,
    );

Track song(String id, {String album = '专辑甲', int durationMs = 213000}) =>
    Track(
      id: id,
      name: '歌曲$id',
      artists: [ArtistRef(id: 'ar1', name: '歌手甲')],
      albumName: album,
      durationMs: durationMs,
    );

class Harness {
  late final SettingsService settings;
  late final LibraryService library;
  late final PlayResolver resolver;
  late final DownloadService downloads;
  late final PlayerService player;

  /// seo 返回与队列同一首（带专辑名），播放页 fullTrack 取 seo 侧
  Future<void> init(List<Track> queueTracks) async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService();
    await settings.init();
    library = LibraryService();
    await library.init();
    final byId = {for (final t in queueTracks) t.id: t};
    resolver = PlayResolver((id) async => fakeSeo(byId[id] ?? song(id)));
    downloads = DownloadService(resolver, settings);
    player = PlayerService(resolver, settings, library);
    unawaited(player.playQueue(queueTracks, 0));
  }

  Widget app(Widget home) => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: library),
          ChangeNotifierProvider.value(value: downloads),
          ChangeNotifierProvider.value(value: player),
          Provider.value(value: resolver),
        ],
        child: MaterialApp(home: home),
      );
}

Future<void> pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void useSurface(WidgetTester tester, Size logical, double dpr) {
  tester.view.physicalSize = logical * dpr;
  tester.view.devicePixelRatio = dpr;
  addTearDown(() => tester.view.reset());
}

void main() {
  testWidgets('MiniPlayer：歌手行常驻总时长（元数据时长）', (tester) async {
    useSurface(tester, const Size(390, 760), 3.0);
    final h = Harness();
    await h.init([song('m1')]);
    await tester.pumpWidget(h.app(const Scaffold(body: MiniPlayer())));
    await pumpFrames(tester);
    expect(find.text('歌手甲 · 3:33'), findsOneWidget,
        reason: '总时长拼在歌手行尾（213000ms → 3:33）');
    h.player.dispose();
  });

  testWidgets('MiniPlayer：无时长数据时不拼占位假数', (tester) async {
    useSurface(tester, const Size(390, 760), 3.0);
    final h = Harness();
    await h.init([song('m2', durationMs: 0)]);
    await tester.pumpWidget(h.app(const Scaffold(body: MiniPlayer())));
    await pumpFrames(tester);
    expect(find.text('歌手甲'), findsOneWidget);
    expect(find.textContaining('0:00'), findsNothing);
    h.player.dispose();
  });

  testWidgets('移动播放页：曲目信息区显示专辑名', (tester) async {
    useSurface(tester, const Size(390, 844), 3.0);
    final h = Harness();
    await h.init([song('p1'), song('p2')]);
    await tester.pumpWidget(h.app(const PlayerScreen()));
    await pumpFrames(tester);
    expect(find.text('专辑甲'), findsWidgets,
        reason: '歌手行下方专辑名行（AlbumLine）应出现');
    h.player.dispose();
  });

  testWidgets('桌面播放页：显示专辑名 + 队列表头有播放/暂停键', (tester) async {
    useSurface(tester, const Size(1600, 1000), 1.0);
    final h = Harness();
    await h.init([song('d1'), song('d2')]);
    await tester.pumpWidget(h.app(const DesktopPlayer()));
    await pumpFrames(tester);
    expect(find.text('专辑甲'), findsWidgets,
        reason: '桌面播放页曲目信息区应有专辑名行');
    // 打开队列表：表头应有「播放队列」与播放/暂停键（原来只有点选跳播）
    expect(find.byIcon(Icons.play_arrow), findsNothing,
        reason: '打开队列前桌面播放页本体无播放键（控制在壳层通栏）');
    await tester.tap(find.byTooltip('队列'));
    await pumpFrames(tester);
    expect(find.text('播放队列'), findsOneWidget);
    // 测试环境平台 play() 不完成、loading 恒 true，表头键图标为
    // 沙漏态——按 tooltip 定位这个与全局状态同步的切换键本身
    expect(find.byTooltip('播放'), findsOneWidget,
        reason: '队列表头补了播放/暂停键（未播放态 tooltip 为「播放」）');
    h.player.dispose();
  });
}
