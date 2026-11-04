import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qinyin/services/qishui_service.dart';

Map<String, dynamic> fixture(String name) =>
    (jsonDecode(File('test/fixtures/$name').readAsStringSync())
        as Map<String, dynamic>);

class _FakeAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions options) handler;
  _FakeAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Map<String, dynamic> body, [int status = 200]) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

Map<String, dynamic> _searchOkBody() => {
      'err_no': 0,
      'data': {
        'result_groups': [
          {
            'id': 'tracks',
            'has_more': true,
            'next_cursor': 20,
            'data': [
              {
                'entity': {
                  'track': {
                    'base_info': {'id': '111', 'name': '测试歌', 'duration_ms': 123000},
                    'related_info': {
                      'artist_links': [
                        {'id': 'a1', 'name': '测试歌手'}
                      ],
                      'album_link': {'id': 'al1', 'name': '测试专辑'},
                    },
                    'display_info': <String, dynamic>{},
                    'media_stats': <String, dynamic>{},
                    'player_info': <String, dynamic>{},
                  }
                }
              }
            ],
          }
        ],
      },
    };

void main() {
  group('平台搜索响应解析（真实 fixture）', () {
    test('track fixture：组选取 + track_entity 字段映射', () {
      final body = fixture('platform_search_track.json');
      final (entities, hasMore, next) =
          PlatformFeedService.parseSearchGroup(body, 'track');
      expect(hasMore, isTrue);
      expect(next, '20');
      final tracks = PlatformFeedService.parseSearchTracks(entities);
      expect(tracks, isNotEmpty);
      final t0 = tracks.first;
      expect(t0.id, isNotEmpty);
      expect(t0.name, isNotEmpty);
      expect(t0.artists, isNotEmpty);
      expect(t0.durationMs, greaterThan(0));
      expect(t0.coverUrl, isNotNull);
    });

    test('artist fixture：base_info → ArtistHit（计数/头像）', () {
      final body = fixture('platform_search_artist.json');
      final (entities, _, _) =
          PlatformFeedService.parseSearchGroup(body, 'artist');
      final hits = PlatformFeedService.parseSearchArtists(entities);
      expect(hits, isNotEmpty);
      expect(hits.first.artist.name, isNotEmpty);
      expect(hits.first.countTracks, greaterThan(0));
      expect(hits.first.artist.avatar, isNotNull);
    });

    test('playlist fixture：游客态上游恒空（2026-11-04 实测）', () {
      final body = fixture('platform_search_playlist_empty.json');
      final (entities, hasMore, next) =
          PlatformFeedService.parseSearchGroup(body, 'playlist');
      expect(entities, isEmpty);
      expect(hasMore, isFalse);
      expect(next, isNull);
      expect(PlatformFeedService.parseSearchPlaylists(entities), isEmpty);
    });

    test('组选取：无同名组时退回第一组（GSQZ 口径）', () {
      final (entities, _, _) =
          PlatformFeedService.parseSearchGroup(_searchOkBody(), 'album');
      expect(entities, hasLength(1));
    });

    test('请求体：search_id 会话内固定、from_search_id 与之相同', () {
      final body = PlatformFeedService.searchBody(
        query: '周杰伦',
        type: 'track',
        cursor: '20',
        searchId: 'sid-1',
      );
      expect(body['q'], '周杰伦');
      expect(body['search_type'], 'track');
      expect(body['cursor'], '20');
      expect(body['search_id'], 'sid-1');
      expect(body['from_search_id'], 'sid-1');
    });
  });

  group('客户端令牌（假 Dio）', () {
    test('28001008 时刷新令牌并重试一次，第二次带新令牌', () async {
      var tokenCalls = 0;
      var searchCalls = 0;
      final tokensSeen = <String?>[];
      final dio = Dio();
      dio.httpClientAdapter = _FakeAdapter((options) async {
        if (options.uri.path.endsWith('/client/token/get/')) {
          tokenCalls++;
          return _json({
            'client_token': 'clt.token$tokenCalls',
            'err_no': 0,
            'expires_time': 9999999999,
          });
        }
        searchCalls++;
        tokensSeen.add(options.headers['access-token'] as String?);
        if (searchCalls == 1) {
          return _json({'err_no': 28001008, 'err_msg': 'token expired', 'data': {}});
        }
        return _json(_searchOkBody());
      });
      final svc = PlatformFeedService(deviceId: '123', dio: dio);
      final (tracks, hasMore, next) =
          await svc.searchTracks(query: 'x', searchId: 'sid');
      expect(tracks, hasLength(1));
      expect(tracks.first.name, '测试歌');
      expect(hasMore, isTrue);
      expect(next, '20');
      expect(searchCalls, 2);
      expect(tokenCalls, 2);
      expect(tokensSeen, ['clt.token1', 'clt.token2']);
    });

    test('令牌端点失败不阻塞：无令牌头照常搜索', () async {
      final tokensSeen = <String?>[];
      final dio = Dio();
      dio.httpClientAdapter = _FakeAdapter((options) async {
        if (options.uri.path.endsWith('/client/token/get/')) {
          return _json({'err_no': 500}, 500);
        }
        tokensSeen.add(options.headers['access-token'] as String?);
        return _json(_searchOkBody());
      });
      final svc = PlatformFeedService(deviceId: '123', dio: dio);
      final (tracks, _, _) = await svc.searchTracks(query: 'x', searchId: 'sid');
      expect(tracks, hasLength(1));
      expect(tokensSeen, [null]);
    });

    test('非 28001008 的 err_no 抛 StateError 且不重试', () async {
      var searchCalls = 0;
      final dio = Dio();
      dio.httpClientAdapter = _FakeAdapter((options) async {
        if (options.uri.path.endsWith('/client/token/get/')) {
          return _json({'client_token': 'clt.x', 'err_no': 0});
        }
        searchCalls++;
        return _json({'err_no': 28001035, 'err_msg': 'not found', 'data': {}});
      });
      final svc = PlatformFeedService(deviceId: '123', dio: dio);
      await expectLater(
        svc.searchTracks(query: 'x', searchId: 'sid'),
        throwsStateError,
      );
      expect(searchCalls, 1);
    });
  });
}
