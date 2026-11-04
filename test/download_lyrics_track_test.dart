// 下载标签补项（歌词 + 音轨号）落地验证：
// - 服务层端到端：真实 DownloadService + 本地 HTTP 服务器发真 M4A
//   （ffmpeg 编码的 fixture），落盘后用 Mp4Tagger 回读 ©lyr / trkn；
// - 接线：专辑页菜单下载把 (序号, 总数) 透传给 DownloadService，
//   普通列表（裸 TrackTile）不传——用记录型假 DownloadService 断言。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qinyin/models/models.dart';
import 'package:qinyin/screens/detail_screens.dart';
import 'package:qinyin/services/download_service.dart';
import 'package:qinyin/services/library_service.dart';
import 'package:qinyin/services/mp4_tagger.dart';
import 'package:qinyin/services/play_resolver.dart';
import 'package:qinyin/services/player_service.dart';
import 'package:qinyin/services/qishui_service.dart';
import 'package:qinyin/services/settings_service.dart';
import 'package:qinyin/widgets/track_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 与 seo fixture 同形状的 KRC 逐字歌词样本
const krcSample =
    '[60,1470]<0,350,0>不<400,340,0>敢<740,330,0>回<1120,350,0>看\n'
    '[2260,3270]<0,350,0>左<360,260,0>顾<620,160,0>右<780,200,0>盼';
const expectedLrc = '[00:00.06]不敢回看\n[00:02.26]左顾右盼';

// 整曲流（沿用 §17 样本比例：推算时长 ≈ 曲目时长，判定完整）
PlayStream fullStream(String url) => PlayStream(
      quality: 'higher',
      codecType: 'aac',
      bitrate: 129901,
      size: 4247000,
      mainUrl: url,
    );

/// 测试专用：强制 HttpClient 直连（绕过环境出口代理，仅本地服务器用）
class _DirectHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..findProxy = (_) => 'DIRECT';
}

void main() {
  group('DownloadService 落盘标签：歌词 + 音轨号（真 M4A 端到端）', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    late HttpServer server;
    late Directory tmp;
    late String baseUrl;
    late Uint8List m4aBytes;

    setUpAll(() async {
      HttpOverrides.global = _DirectHttpOverrides();
      m4aBytes = await File('test/fixtures/sample.m4a').readAsBytes();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUrl = 'http://${server.address.host}:${server.port}';
      server.listen((req) {
        req.response
          ..statusCode = 200
          ..add(m4aBytes)
          ..close();
      });
      tmp = await Directory.systemTemp.createTemp('qinyin_lyr_dl_test');
    });
    tearDownAll(() async {
      HttpOverrides.global = null;
      await server.close(force: true);
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<DownloadService> makeService({String lyricRaw = krcSample}) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService();
      await settings.init();
      await settings.setDownloadDirectory(tmp.path);
      final resolver = PlayResolver((id) async => SeoTrack(
            track: Track(id: id, name: '占位', durationMs: 261560),
            lyricRaw: lyricRaw,
            streams: [fullStream('$baseUrl/x.m4a')],
            expireAt: 9999999999,
          ));
      final svc = DownloadService(resolver, settings);
      await svc.init();
      return svc;
    }

    Track song(String id) => Track(
          id: id,
          name: '山海',
          artists: const [ArtistRef(id: 'a1', name: '郭顶')],
          albumName: '专辑甲',
          durationMs: 261560,
        );

    test('专辑语境（传序号/总数）→ 落盘含 ©lyr 与 trkn(3,12)，状态 tagged',
        () async {
      final svc = await makeService();
      final record =
          await svc.download(song('dl-album'), trackNumber: 3, trackTotal: 12);
      expect(record.tagStatus, 'tagged', reason: record.tagError);
      final read = Mp4Tagger.readTags(await File(record.path).readAsBytes());
      expect(read['©lyr'], expectedLrc);
      expect(read['trkn'], (3, 12));
      expect(read['©nam'], '山海');
    });

    test('非专辑语境（不传参）→ 有歌词、无 trkn（列表序号不冒充音轨号）',
        () async {
      final svc = await makeService();
      final record = await svc.download(song('dl-plain'));
      expect(record.tagStatus, 'tagged', reason: record.tagError);
      final read = Mp4Tagger.readTags(await File(record.path).readAsBytes());
      expect(read['©lyr'], expectedLrc);
      expect(read.containsKey('trkn'), isFalse);
    });

    test('seo 无歌词 → 跳过 ©lyr，其余标签照常、状态 tagged', () async {
      final svc = await makeService(lyricRaw: '');
      final record =
          await svc.download(song('dl-nolyr'), trackNumber: 1, trackTotal: 2);
      expect(record.tagStatus, 'tagged', reason: record.tagError);
      final read = Mp4Tagger.readTags(await File(record.path).readAsBytes());
      expect(read.containsKey('©lyr'), isFalse);
      expect(read['©nam'], '山海');
      expect(read['trkn'], (1, 2));
    });
  });

  group('接线：专辑页传音轨号、普通列表不传', () {
    testWidgets('专辑页第 2 首菜单下载 → (trackNumber=2, trackTotal=3)',
        (tester) async {
      final env = await _WiringEnv.create();
      await tester.pumpWidget(env.app(
        const AlbumDetailScreen(album: Album(id: 'alb1', name: '测试专辑')),
      ));
      await _pumpUntil(tester, () => find.text('曲二').evaluate().isNotEmpty);
      expect(find.text('曲三'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.more_vert).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载'));
      await tester.pumpAndSettle();

      expect(env.downloads.calls, [
        (id: 't2', trackNumber: 2, trackTotal: 3),
      ]);
      env.player.dispose(); // 停掉进度心跳定时器（与既有 widget 测试同口径）
    });

    testWidgets('裸 TrackTile（非专辑列表）菜单下载 → 不传音轨号',
        (tester) async {
      final env = await _WiringEnv.create();
      const track = Track(id: 'solo', name: '单曲', durationMs: 1000);
      await tester.pumpWidget(env.app(
        const Scaffold(body: TrackTile(track: track)),
      ));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载'));
      await tester.pumpAndSettle();

      expect(env.downloads.calls, [
        (id: 'solo', trackNumber: null, trackTotal: null),
      ]);
      env.player.dispose();
    });
  });
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() cond, {
  int maxPumps = 30,
}) async {
  for (var i = 0; i < maxPumps && !cond(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 记录型 DownloadService：只记 download() 入参，不真下载
class _RecordingDownloads extends DownloadService {
  final calls = <({String id, int? trackNumber, int? trackTotal})>[];
  _RecordingDownloads(super.resolver, super.settings);

  @override
  Future<DownloadRecord> download(
    Track track, {
    int? trackNumber,
    int? trackTotal,
  }) async {
    calls.add(
        (id: track.id, trackNumber: trackNumber, trackTotal: trackTotal));
    return DownloadRecord(
      trackId: track.id,
      title: track.name,
      artist: track.artistNames,
      path: '/nonexistent/${track.id}.m4a',
      quality: 'higher',
      size: 0,
      createdAt: 0,
    );
  }
}

/// 按路径回 JSON 的假 Dio 适配器（专辑详情用）
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

class _WiringEnv {
  final SettingsService settings;
  final LibraryService library;
  final PlayerService player;
  final _RecordingDownloads downloads;
  final QishuiService service;
  _WiringEnv._(
      this.settings, this.library, this.player, this.downloads, this.service);

  static Future<_WiringEnv> create() async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    await settings.init();
    final library = LibraryService();
    await library.init();
    final resolver = PlayResolver((id) async => SeoTrack(
          track: Track(id: id, name: '占位'),
          expireAt: 9999999999,
        ));
    final downloads = _RecordingDownloads(resolver, settings);
    final player = PlayerService(resolver, settings, library);
    Map<String, dynamic> trackJson(String id, String name) => {
          'id': id,
          'name': name,
          'duration': 200000,
          'artists': [
            {'id': 'ar1', 'name': '歌手甲'},
          ],
          'album': {'id': 'alb1', 'name': '测试专辑'},
        };
    final dio = Dio()
      ..httpClientAdapter = _JsonAdapter({
        '/luna/albums/alb1': {
          'album_info': {'id': 'alb1', 'name': '测试专辑', 'count_tracks': 3},
          'tracks': [
            trackJson('t1', '曲一'),
            trackJson('t2', '曲二'),
            trackJson('t3', '曲三'),
          ],
        },
      });
    return _WiringEnv._(
        settings, library, player, downloads, QishuiService(dio: dio));
  }

  Widget app(Widget home) => MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<LibraryService>.value(value: library),
          ChangeNotifierProvider<PlayerService>.value(value: player),
          ChangeNotifierProvider<DownloadService>.value(value: downloads),
          Provider<QishuiService>.value(value: service),
        ],
        child: MaterialApp(home: home),
      );
}
