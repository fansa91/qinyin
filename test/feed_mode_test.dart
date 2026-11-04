// 场景模式验收（车机 feed/mode 45 种场景）：
// - 真实响应 fixture（已脱敏）解析出 45 项，id/名称/图标拼装正确；
// - 取流传参口径：songTabPage 带 scene=scene_mode_id（与不带场景
//   时对比；该口径已于 2026-11-04 实测与默认流零重叠）；
// - fetchFeedModes 会话内缓存（两次调用只发一次请求）；
// - 场景选择持久化往返；
// - RecommendPager 经带 scene 的主源闭包取流（切换场景=新分页器）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qinyin/models/models.dart';
import 'package:qinyin/services/qishui_service.dart';
import 'package:qinyin/services/recommend_pager.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> fixture(String name) => jsonDecode(
    File('test/fixtures/$name').readAsStringSync()) as Map<String, dynamic>;

/// 记录请求的假 Dio 适配器：按路径分发 canned 响应
class _RecordingAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final Map<String, dynamic> modesBody;
  final Map<String, dynamic> feedBody;
  _RecordingAdapter({required this.modesBody, required this.feedBody});

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    final body = options.path.contains('feed/mode')
        ? modesBody
        : options.path.contains('client/token')
            ? {'err_no': 0}
            : feedBody;
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json']
      },
    );
  }

  @override
  void close({bool force = false}) {}

  Iterable<RequestOptions> get feedRequests =>
      requests.where((r) => r.path.contains('song-tab'));
  Iterable<RequestOptions> get modeRequests =>
      requests.where((r) => r.path.contains('feed/mode'));
}

PlatformFeedService _serviceWith(_RecordingAdapter adapter) {
  final dio = Dio();
  dio.httpClientAdapter = adapter;
  return PlatformFeedService(deviceId: 'test-device', dio: dio);
}

void main() {
  group('parseFeedModes（真实响应 fixture）', () {
    test('解析出 45 个场景，关键场景 id 对位', () {
      final modes =
          PlatformFeedService.parseFeedModes(fixture('platform_feed_modes.json'));
      expect(modes.length, 45);
      final byName = {for (final m in modes) m.name: m};
      expect(byName['粤语']?.sceneModeId, '10');
      expect(byName['DJ模式']?.sceneModeId, '7');
      expect(byName['助眠模式']?.sceneModeId, '8');
      expect(byName['驾车']?.sceneModeId, '33');
      // 图标按既有封面拼装规则可出图
      final url = byName['粤语']?.cover.url();
      expect(url, isNotNull);
      expect(url, contains(byName['粤语']!.cover.uri));
    });

    test('无 scene_mode_id 的条目被过滤、重复 id 去重', () {
      final body = {
        'data': {
          'feed_mode_block': [
            {
              'title': '场景音乐',
              'feed_mode': [
                {
                  'entity': {
                    'feed_mode': {
                      'text': '甲',
                      'scene_mode': {'scene_mode_id': 1}
                    }
                  }
                },
                {
                  'entity': {
                    'feed_mode': {'text': '无场景id'}
                  }
                },
                {
                  'entity': {
                    'feed_mode': {
                      'text': '甲重',
                      'scene_mode': {'scene_mode_id': 1}
                    }
                  }
                },
              ]
            }
          ]
        }
      };
      final modes = PlatformFeedService.parseFeedModes(body);
      expect(modes.length, 1);
      expect(modes.single.name, '甲');
    });
  });

  group('场景取流传参', () {
    test('songTabPage 带 scene 参数；不带时无此参数', () async {
      final adapter = _RecordingAdapter(
        modesBody: fixture('platform_feed_modes.json'),
        feedBody: {
          'err_no': 0,
          'data': {'items': [], 'has_more': true}
        },
      );
      final svc = _serviceWith(adapter);
      await svc.songTabPage(0, sceneModeId: '10');
      await svc.songTabPage(0);
      final reqs = adapter.feedRequests.toList();
      expect(reqs.length, 2);
      expect(reqs[0].queryParameters['scene'], '10');
      expect(reqs[1].queryParameters.containsKey('scene'), isFalse);
    });

    test('fetchFeedModes 解析 45 项且会话内缓存', () async {
      final adapter = _RecordingAdapter(
        modesBody: fixture('platform_feed_modes.json'),
        feedBody: {
          'err_no': 0,
          'data': {'items': [], 'has_more': true}
        },
      );
      final svc = _serviceWith(adapter);
      final first = await svc.fetchFeedModes();
      final second = await svc.fetchFeedModes();
      expect(first.length, 45);
      expect(second.length, 45);
      expect(adapter.modeRequests.length, 1,
          reason: '第二次调用应命中会话缓存，不再发请求');
    });

    test('RecommendPager 经带 scene 的主源闭包取流', () async {
      final adapter = _RecordingAdapter(
        modesBody: fixture('platform_feed_modes.json'),
        feedBody: fixture('platform_feed.json'),
      );
      final svc = _serviceWith(adapter);
      final pager = RecommendPager(
        fetchPlatformPage: (cursor) =>
            svc.songTabPage(cursor, sceneModeId: '10'),
        fetchRelated: (_) async => const <Track>[],
        fetchPlaylistList: (_) async => (<Playlist>[], null, false),
        fetchPlaylistTracks: (_, {String? cursor}) async =>
            (const Playlist(id: 'p', title: 't'), <Track>[], null),
        fetchRadioPage: (_, _) async => const [],
        radioIds: const [],
      );
      final page = await pager.nextPage();
      expect(page, isNotEmpty, reason: '场景流应能经分页器取到曲目');
      expect(adapter.feedRequests.first.queryParameters['scene'], '10',
          reason: '分页器主源请求应带上 scene=10（粤语）');
    });
  });

  group('场景选择持久化', () {
    test('保存/读取/清除往返', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await PlatformFeedService.loadSavedScene(), isNull);
      await PlatformFeedService.saveScene(
          const FeedMode(name: '粤语', sceneModeId: '10'));
      final saved = await PlatformFeedService.loadSavedScene();
      expect(saved?.id, '10');
      expect(saved?.name, '粤语');
      await PlatformFeedService.saveScene(null);
      expect(await PlatformFeedService.loadSavedScene(), isNull);
    });
  });
}
