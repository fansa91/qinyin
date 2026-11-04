// 桌面端全局自适应验收（1280 宽为主，个别对照 compact）：
//
// - 首页：内容限宽 1200 居中，推荐歌单网格按卡片最大宽自动增列
//   （1280 → 首行 5 张；390 → 首行 2 张，与原 compact 一致）；
// - 搜索页：浏览区列表限宽 960；
// - 歌单详情：≥900 主从双栏（无 SliverAppBar 沉浸头，曲目列表
//   在左信息栏右侧）；390 仍是原沉浸头部形态；
// - 下载管理 / 设置 / 我的：内容限宽 800（表单类口径）；
// - 桌面播放页队列表弹层：宽屏下限宽 720，不全宽拉伸。
// 全部用例同时断言无框架异常（溢出会在 pump 后以 FlutterError
// 形式被 takeException 取到）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qinyin/models/models.dart';
import 'package:qinyin/screens/detail_screens.dart';
import 'package:qinyin/screens/downloads_screen.dart';
import 'package:qinyin/screens/home_screen.dart';
import 'package:qinyin/screens/library_screen.dart';
import 'package:qinyin/screens/player_screen.dart';
import 'package:qinyin/screens/search_screen.dart';
import 'package:qinyin/screens/settings_screen.dart';
import 'package:qinyin/services/cache_service.dart';
import 'package:qinyin/services/download_service.dart';
import 'package:qinyin/services/library_service.dart';
import 'package:qinyin/services/play_resolver.dart';
import 'package:qinyin/services/player_service.dart';
import 'package:qinyin/services/qishui_service.dart';
import 'package:qinyin/services/settings_service.dart';
import 'package:qinyin/widgets/track_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> fixture(String name) =>
    (jsonDecode(File('test/fixtures/$name').readAsStringSync())
        as Map<String, dynamic>);

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

/// 按路径回 JSON 的假 Dio 适配器（首页合成歌单 + 歌单详情 fixture）
class _JsonAdapter implements HttpClientAdapter {
  final Map<String, Map<String, dynamic>> byPath;
  _JsonAdapter(this.byPath);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = byPath[options.path];
    if (body == null) return ResponseBody.fromString('{}', 404);
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _playlistResource(int i) => {
      'resource_id': 'pl$i',
      'type': 'playlist',
      'entity': {
        'playlist': {'id': 'pl$i', 'title': '歌单$i', 'count_tracks': 10},
      },
    };

class Env {
  late final SettingsService settings;
  late final LibraryService library;
  late final PlayResolver resolver;
  late final DownloadService downloads;
  late final PlayerService player;
  late final QishuiService service;
  late final CacheService cache;
  late final Directory tmpDir;

  Future<void> init({bool withDownloadRecord = false}) async {
    SharedPreferences.setMockInitialValues({});
    // 临时目录同步建：testWidgets 在 FakeAsync 区里 await 真 IO
    // （createTemp 的 Future）会挂死，全程避开真异步 IO。
    tmpDir = Directory.systemTemp.createTempSync('qinyin_resp_test_');
    if (withDownloadRecord) {
      // DownloadService.init 会过滤掉文件不存在的记录，必须先
      // 把真实文件与指向它的记录一并备好
      final f = File('${tmpDir.path}/t1.m4a')..writeAsBytesSync([1, 2, 3]);
      final record = DownloadRecord(
        trackId: 't1',
        title: '已下载的歌',
        artist: '歌手甲',
        path: f.path,
        quality: 'higher',
        size: 3,
        createdAt: 1,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'download_records',
        jsonEncode([record.toJson()]),
      );
    }
    settings = SettingsService();
    await settings.init();
    library = LibraryService();
    await library.init();
    resolver = PlayResolver((id) async => fakeSeo(Track(id: id, name: '占位')));
    downloads = DownloadService(resolver, settings);
    await downloads.init();
    player = PlayerService(resolver, settings, library);
    final dio = Dio()
      ..httpClientAdapter = _JsonAdapter({
        '/luna/discover': {'blocks': <dynamic>[]},
        '/luna/discover/mix': {
          'has_more': false,
          'inner_block': [
            for (var i = 1; i <= 10; i++)
              {
                'type': 'discover_playlist',
                'resources': [_playlistResource(i)],
              },
          ],
        },
        '/luna/playlist/detail': fixture('playlist.json'),
      });
    service = QishuiService(dio: dio);
    cache = CacheService(
      tmpDirProvider: () async => tmpDir,
      downloadDirProvider: () async => tmpDir,
    );
  }

  Widget app(Widget home) => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: library),
          ChangeNotifierProvider.value(value: downloads),
          ChangeNotifierProvider.value(value: player),
          Provider.value(value: resolver),
          Provider.value(value: service),
          Provider.value(value: cache),
        ],
        child: MaterialApp(home: home),
      );

  void dispose() {
    player.dispose();
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

void useSurface(WidgetTester tester, Size logical) {
  tester.view.physicalSize = logical;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() => tester.view.reset());
}

Future<void> pumpFrames(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

/// 网格首行卡片数：按卡片左上角的纵坐标分组，取最上方一行的数量
int firstRowCount(WidgetTester tester, Finder cards) {
  final tops = <double, int>{};
  for (final e in cards.evaluate()) {
    final top = tester.getTopLeft(find.byWidget(e.widget)).dy;
    tops[top] = (tops[top] ?? 0) + 1;
  }
  if (tops.isEmpty) return 0;
  final firstTop = tops.keys.reduce((a, b) => a < b ? a : b);
  return tops[firstTop]!;
}

void main() {
  testWidgets('首页 1280：歌单网格首行 5 张、内容限宽不溢出', (tester) async {
    useSurface(tester, const Size(1280, 800));
    final env = Env();
    await env.init();
    // 首页是壳层页（生产环境由 AppShell 的 Scaffold 提供 Material），
    // 测试里同口径包一层 Scaffold
    await tester.pumpWidget(env.app(const Scaffold(body: HomeScreen())));
    await pumpFrames(tester);
    expect(tester.takeException(), isNull);
    final cards = find.byType(PlaylistCard);
    expect(cards, findsWidgets);
    expect(firstRowCount(tester, cards), 5,
        reason: '限宽 1200 内按卡片最大宽 230 自动增列 → 5 列');
    // 内容列居中：首张卡左缘应明显大于窗口左缘 0（被限宽约束）
    expect(tester.getTopLeft(cards.first).dx, greaterThan(30),
        reason: '1280 窗口下内容列宽 1200 居中，左右各留约 40');
    env.dispose();
  });

  testWidgets('首页 390：歌单网格首行 2 张（compact 不回归）', (tester) async {
    useSurface(tester, const Size(390, 844));
    final env = Env();
    await env.init();
    await tester.pumpWidget(env.app(const Scaffold(body: HomeScreen())));
    await pumpFrames(tester);
    expect(tester.takeException(), isNull);
    final cards = find.byType(PlaylistCard);
    expect(cards, findsWidgets);
    expect(firstRowCount(tester, cards), 2);
    env.dispose();
  });

  testWidgets('搜索页 1280：浏览区列表限宽 960', (tester) async {
    useSurface(tester, const Size(1280, 800));
    final env = Env();
    await env.init();
    await tester.pumpWidget(env.app(const SearchScreen()));
    await pumpFrames(tester);
    expect(tester.takeException(), isNull);
    final list = find.byType(ListView);
    expect(list, findsOneWidget);
    expect(tester.getSize(list).width, closeTo(960, 1));
    env.dispose();
  });

  testWidgets('歌单详情 1280：主从双栏（信息栏 + 右侧曲目列表）',
      (tester) async {
    useSurface(tester, const Size(1280, 800));
    final env = Env();
    await env.init();
    await tester.pumpWidget(env.app(const PlaylistDetailScreen(
      playlist: Playlist(id: 'pl1', title: '测试歌单'),
    )));
    await pumpFrames(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(SliverAppBar), findsNothing,
        reason: '宽屏双栏不用沉浸头部 SliverAppBar');
    final tiles = find.byType(TrackTile);
    expect(tiles, findsWidgets);
    expect(tester.getTopLeft(tiles.first).dx, greaterThanOrEqualTo(361),
        reason: '曲目列表在 360 信息栏 + 分隔线右侧');
    expect(find.text('播放全部 (2)'), findsOneWidget,
        reason: '播放全部在左侧信息栏里');
    env.dispose();
  });

  testWidgets('歌单详情 390：仍是沉浸头部形态（compact 不回归）',
      (tester) async {
    useSurface(tester, const Size(390, 844));
    final env = Env();
    await env.init();
    await tester.pumpWidget(env.app(const PlaylistDetailScreen(
      playlist: Playlist(id: 'pl1', title: '测试歌单'),
    )));
    await pumpFrames(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(SliverAppBar), findsOneWidget);
    env.dispose();
  });

  testWidgets('下载管理 1280：记录列表限宽 800', (tester) async {
    useSurface(tester, const Size(1280, 800));
    final env = Env();
    await env.init(withDownloadRecord: true);
    await tester.pumpWidget(env.app(const DownloadsScreen()));
    await pumpFrames(tester);
    expect(tester.takeException(), isNull);
    final tile = find.widgetWithText(ListTile, '已下载的歌');
    expect(tile, findsOneWidget);
    expect(tester.getSize(tile).width, closeTo(800, 1),
        reason: '表单类页面限宽 800 居中');
    env.dispose();
  });

  testWidgets('设置页 1280：列表限宽 800 不溢出', (tester) async {
    useSurface(tester, const Size(1280, 800));
    final env = Env();
    await env.init();
    await tester.pumpWidget(env.app(const SettingsScreen()));
    await pumpFrames(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('默认音质'), findsOneWidget);
    expect(tester.getSize(find.byType(ListView)).width, closeTo(800, 1));
    env.dispose();
  });

  testWidgets('我的 1280：页签内容限宽 800', (tester) async {
    useSurface(tester, const Size(1280, 800));
    final env = Env();
    await env.init();
    await tester.pumpWidget(env.app(const LibraryScreen()));
    await pumpFrames(tester);
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(TabBarView)).width, closeTo(800, 1));
    env.dispose();
  });

  testWidgets('桌面播放页 1280：队列表弹层限宽 720', (tester) async {
    useSurface(tester, const Size(1280, 800));
    final env = Env();
    await env.init();
    unawaited(env.player.playQueue([
      const Track(id: 'q1', name: '队列歌一'),
      const Track(id: 'q2', name: '队列歌二'),
    ], 0));
    await tester.pumpWidget(env.app(const DesktopPlayer()));
    await pumpFrames(tester);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('队列'));
    await pumpFrames(tester);
    expect(tester.takeException(), isNull);
    final header = find.widgetWithText(ListTile, '播放队列');
    expect(header, findsOneWidget);
    expect(tester.getSize(header).width, lessThanOrEqualTo(720),
        reason: '列表型弹层宽屏限宽 720，不全宽拉伸');
    env.dispose();
  });
}
