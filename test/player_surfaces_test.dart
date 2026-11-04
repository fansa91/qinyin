// 播放面补强验收：
//
// - 专辑名：与歌手名拼成同一行「歌手 · 专辑」显示（移动/桌面
//   播放页同一口径；专辑数据缺失时该行只显示歌手名，不编造）；
// - MiniPlayer 时长：歌手行尾常驻总时长「歌手 · 3:33」（引擎
//   时长未就绪时退曲目元数据时长）；无时长数据时不拼占位；
// - 桌面通栏 MiniPlayer：副行只要「歌手 · 专辑」不拼时长
//   （移动悬浮条不变，用户本轮明确仅桌面端；时长改由通栏
//   进度条左右两端同行呈现的当前时间/总时长数字承担）；
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
import 'package:qinyin/widgets/cover_image.dart';
import 'package:qinyin/widgets/mini_player.dart';
import 'package:qinyin/widgets/seek_bar.dart';
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

  testWidgets('桌面通栏 MiniPlayer：副行只有「歌手 · 专辑」、不含时长',
      (tester) async {
    useSurface(tester, const Size(1280, 800), 1.0);
    final h = Harness();
    await h.init([song('w1')]);
    await tester.pumpWidget(
        h.app(const Scaffold(body: MiniPlayer(fullBar: true))));
    await pumpFrames(tester);
    expect(find.text('歌手甲 · 专辑甲'), findsOneWidget,
        reason: '桌面通栏专辑名拼在歌手名旁边（用户更正口径）');
    expect(find.text('歌手甲 · 专辑甲 · 3:33'), findsNothing,
        reason: '副行不再拼时长——时长由进度条右端数字承担');
    // 进度条两端时间数字：左=当前时间、右=总时长（独立 Text）
    expect(find.text('0:00'), findsOneWidget, reason: '进度条左端当前时间');
    expect(find.text('3:33'), findsOneWidget, reason: '进度条右端总时长');
    h.player.dispose();
  });

  testWidgets('桌面通栏 MiniPlayer：无专辑时副行只有歌手名', (tester) async {
    useSurface(tester, const Size(1280, 800), 1.0);
    final h = Harness();
    await h.init([song('w2', album: '')]);
    await tester.pumpWidget(
        h.app(const Scaffold(body: MiniPlayer(fullBar: true))));
    await pumpFrames(tester);
    expect(find.text('歌手甲'), findsOneWidget,
        reason: '专辑为空则副行只剩歌手名，不留分隔符、也不拼时长');
    h.player.dispose();
  });

  testWidgets('桌面通栏 MiniPlayer：无时长数据时进度右端不摆假数',
      (tester) async {
    useSurface(tester, const Size(1280, 800), 1.0);
    final h = Harness();
    await h.init([song('w3', durationMs: 0)]);
    await tester.pumpWidget(
        h.app(const Scaffold(body: MiniPlayer(fullBar: true))));
    await pumpFrames(tester);
    expect(find.text('歌手甲 · 专辑甲'), findsOneWidget,
        reason: '副行口径与时长无关，仍是「歌手 · 专辑」');
    expect(find.text('3:33'), findsNothing);
    expect(find.text('0:00'), findsOneWidget,
        reason: '只有进度条左端当前时间一个 0:00，右端不冒充总时长');
    h.player.dispose();
  });

  testWidgets('桌面通栏 MiniPlayer：窄桌面窗（900）无溢出', (tester) async {
    useSurface(tester, const Size(900, 700), 1.0);
    final h = Harness();
    await h.init([song('w4'), song('w5')]);
    await tester.pumpWidget(
        h.app(const Scaffold(body: MiniPlayer(fullBar: true))));
    await pumpFrames(tester);
    expect(tester.takeException(), isNull,
        reason: '900 宽桌面窗下通栏条（含两端时间数字）不得溢出');
    h.player.dispose();
  });

  testWidgets('移动播放页：专辑名与歌手名拼成一行', (tester) async {
    useSurface(tester, const Size(390, 844), 3.0);
    final h = Harness();
    await h.init([song('p1'), song('p2')]);
    await tester.pumpWidget(h.app(const PlayerScreen()));
    await pumpFrames(tester);
    expect(find.text('歌手甲 · 专辑甲'), findsWidgets,
        reason: '专辑名拼在歌手名同一行（「歌手 · 专辑」），不再独占一行');
    expect(find.text('专辑甲'), findsNothing,
        reason: '不应再有独立成行的专辑名');
    h.player.dispose();
  });

  testWidgets('新鲜播放页 360 宽：无溢出、无标题字样、封面正方形',
      (tester) async {
    useSurface(tester, const Size(360, 740), 1.0);
    final h = Harness();
    // 大计数让计数/操作行在窄宽下达到真实长度（溢出实报场景）
    const big = Track(
      id: 'big1',
      name: '长名字歌曲长名字歌曲',
      artists: [ArtistRef(id: 'ar1', name: '歌手甲')],
      albumName: '专辑甲',
      durationMs: 213000,
      countCollected: 1234567,
      countComment: 987654,
      countShared: 456789,
    );
    await h.init([big, song('big2')]);
    await tester.pumpWidget(h.app(const PlayerScreen()));
    await pumpFrames(tester);
    expect(tester.takeException(), isNull,
        reason: '360 窄宽下计数/操作行不得溢出（RenderFlex overflow）');
    expect(find.text('新鲜模式'), findsNothing,
        reason: '头部「新鲜模式」字样已按用户实报删除');
    // 封面正方形：CoverImage 的宽高相等（不再全宽×定高被压扁）
    final coverSize = tester.getSize(find.byType(CoverImage).first);
    expect(coverSize.width, closeTo(coverSize.height, 0.5),
        reason: '封面应按正方形原始比例呈现');
    h.player.dispose();
  });

  testWidgets('新鲜播放页底部：上/下/列表三键齐全，无「发现/我的」',
      (tester) async {
    useSurface(tester, const Size(390, 844), 1.0);
    final h = Harness();
    await h.init([song('b1'), song('b2'), song('b3')]);
    await tester.pumpWidget(h.app(const PlayerScreen()));
    await pumpFrames(tester);
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.skip_previous), findsWidgets,
        reason: '底部行应有上一首键');
    expect(find.byIcon(Icons.skip_next), findsWidgets,
        reason: '底部行应有下一首键');
    expect(find.byTooltip('播放队列'), findsWidgets,
        reason: '底部行应有打开队列的列表键');
    expect(find.text('发现'), findsNothing,
        reason: '原底部「发现」键已按用户实报去掉');
    expect(find.text('我的'), findsNothing,
        reason: '原底部「我的」键已按用户实报去掉');
    h.player.dispose();
  });

  testWidgets('新鲜播放页 390 宽：计数行贴底（与进度条间距收紧）',
      (tester) async {
    useSurface(tester, const Size(390, 844), 1.0);
    final h = Harness();
    await h.init([song('t1'), song('t2')]);
    await tester.pumpWidget(h.app(const PlayerScreen()));
    await pumpFrames(tester);
    expect(tester.takeException(), isNull);
    // 操作行（分享图标所在行）底部与进度条顶部的间距：钉底后只剩
    // 页内固定 8px 上下间隙，远小于原贴顶布局的整页空白
    final shareRect = tester.getRect(find.byIcon(Icons.share_outlined));
    final seekRect = tester.getRect(find.byType(SeekBar));
    expect(seekRect.top - shareRect.bottom, lessThan(40),
        reason: '计数/操作行应钉在本页底部，不留大片空白');
    h.player.dispose();
  });

  testWidgets('桌面播放页：显示专辑名 + 队列表头有播放/暂停键', (tester) async {
    useSurface(tester, const Size(1600, 1000), 1.0);
    final h = Harness();
    await h.init([song('d1'), song('d2')]);
    await tester.pumpWidget(h.app(const DesktopPlayer()));
    await pumpFrames(tester);
    expect(find.text('歌手甲 · 专辑甲'), findsWidgets,
        reason: '桌面播放页专辑名拼在歌手名同一行，不再独占一行');
    expect(find.text('专辑甲'), findsNothing,
        reason: '不应再有独立成行的专辑名');
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
