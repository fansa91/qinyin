// 无损链路测试：平台 video_model 解析（含 preview 守卫）、选档/回落、
// 解密缓存命中与淘汰。解密算法本身的正确性由交叉验证锁定
// （QISHUI_API.md §15.6 + spade_decrypt_test 的真实 key 向量）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qinyin/models/models.dart';
import 'package:qinyin/services/lossless_cache.dart';
import 'package:qinyin/services/play_resolver.dart';

Map<String, dynamic> platformMedia({
  required bool withFull,
  required bool withPreview,
}) {
  Map<String, dynamic> vmInfo(List<Map<String, dynamic>> list) => {
        'video_model_info': {
          'video_model': jsonEncode({'video_list': list}),
        },
      };
  final losslessEntry = {
    'main_url': 'https://cdn/lossless.mp4',
    'encrypt_info': {'spade_a': 'SPADEKEY', 'kid': 'k1'},
    'video_meta': {
      'quality': 'lossless',
      'codec_type': 'flac',
      'bitrate': 900000,
      'size': 1000,
    },
  };
  final mediumEntry = {
    'main_url': 'https://cdn/medium.m4a',
    'video_meta': {
      'quality': 'medium',
      'codec_type': 'aac',
      'bitrate': 66000,
      'size': 100,
    },
  };
  return {
    'track_entity': {
      'base_info': {'id': '42', 'name': '测试曲', 'duration_ms': 200000},
      'related_info': {
        'artist_links': [
          {'id': '7', 'name': '歌手'}
        ],
        'album_link': {'id': '9', 'name': '专辑'},
      },
      'display_info': <String, dynamic>{},
      'media_stats': <String, dynamic>{},
      'player_info': {
        'vid': 'v1',
        'full': {
          'bit_rates': const [],
          if (withFull) ...vmInfo([mediumEntry, losslessEntry]),
        },
        'preview': {
          'bit_rates': const [],
          if (withPreview) ...vmInfo([losslessEntry]),
        },
      },
    },
  };
}

class FakeCache extends LosslessCache {
  FakeCache({this.result, this.error});
  final String? result;
  final Object? error;
  int calls = 0;
  @override
  Future<String> prepare({
    required String trackId,
    required PlayStream stream,
    void Function(int received, int total)? onProgress,
  }) async {
    calls++;
    if (error != null) throw error!;
    return result!;
  }
}

SeoTrack seoWith(String id, List<PlayStream> streams) => SeoTrack(
      track: Track(id: id, name: '歌$id'),
      streams: streams,
      expireAt: 9999999999,
    );

Track trackWithLossless() => Track.fromPlatformMedia(
      platformMedia(withFull: true, withPreview: false),
    )!;

void main() {
  group('平台 video_model 解析', () {
    test('full 版解析出流列表与无损档', () {
      final t = trackWithLossless();
      expect(t.platformStreams.length, 2);
      expect(t.platformLossless, isNotNull);
      expect(t.platformLossless!.quality, 'lossless');
      expect(t.platformLossless!.spadeA, 'SPADEKEY');
    });

    test('只有 preview（试听）时绝不收录为整曲源', () {
      final t = Track.fromPlatformMedia(
        platformMedia(withFull: false, withPreview: true),
      )!;
      expect(t.platformStreams, isEmpty);
      expect(t.platformLossless, isNull);
    });
  });

  group('resolveTrack 无损选档与回落', () {
    Future<SeoTrack> seoFetcher(String id) async => seoWith(id, const [
          PlayStream(
              quality: 'higher',
              codecType: 'aac',
              bitrate: 130000,
              mainUrl: 'https://cdn/h.m4a'),
        ]);

    test('有无损档且缓存备妥 → 本地 FLAC 播放', () async {
      final cache = FakeCache(result: '/tmp/42.flac');
      final resolver = PlayResolver(seoFetcher, losslessCache: cache);
      var preparing = false;
      final r = await resolver.resolveTrack(
        trackWithLossless(),
        quality: 'lossless',
        onLosslessPreparing: () => preparing = true,
      );
      expect(preparing, isTrue);
      expect(cache.calls, 1);
      expect(r.isLocal, isTrue);
      expect(r.localPath, '/tmp/42.flac');
      expect(r.stream.quality, 'lossless');
    });

    test('解密/下载失败 → 自动回落 seo AAC（不许放不出声）', () async {
      final cache = FakeCache(error: StateError('网络挂了'));
      final resolver = PlayResolver(seoFetcher, losslessCache: cache);
      final r = await resolver.resolveTrack(
        trackWithLossless(),
        quality: 'lossless',
      );
      expect(r.isLocal, isFalse);
      expect(r.stream.quality, 'higher'); // lossless 回落序：highest 缺 → higher
    });

    test('无平台无损档 → 直接 seo 回落，不触发准备回调', () async {
      final cache = FakeCache(result: '/tmp/x.flac');
      final resolver = PlayResolver(seoFetcher, losslessCache: cache);
      var preparing = false;
      final r = await resolver.resolveTrack(
        Track(id: '5', name: '普通曲'),
        quality: 'lossless',
        onLosslessPreparing: () => preparing = true,
      );
      expect(preparing, isFalse);
      expect(cache.calls, 0);
      expect(r.stream.quality, 'higher');
    });

    test('非无损音质走原 seo 路，行为不变', () async {
      final resolver = PlayResolver(seoFetcher, losslessCache: FakeCache(result: '/tmp/x'));
      final r = await resolver.resolveTrack(
        trackWithLossless(),
        quality: 'higher',
      );
      expect(r.isLocal, isFalse);
      expect(r.stream.quality, 'higher');
    });

    test('prepareLossless 无档抛 PlayUnavailable（下载侧据此报错）', () async {
      final resolver = PlayResolver(seoFetcher, losslessCache: FakeCache(result: '/tmp/x'));
      expect(
        () => resolver.prepareLossless(Track(id: '5', name: '普通曲')),
        throwsA(isA<PlayUnavailable>()),
      );
    });
  });

  group('LosslessCache', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('lossless_test');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('命中缓存直接返回，不触发下载', () async {
      await File('${tmp.path}/42.flac').writeAsBytes([1, 2, 3]);
      var downloads = 0;
      final cache = LosslessCache(dirProvider: () async => tmp);
      cache.downloadFileOverride = (url, path, progress) async {
        downloads++;
        throw StateError('不该被调用');
      };
      final stream = PlayStream(
        quality: 'lossless',
        mainUrl: 'https://cdn/x',
        spadeA: 'whatever',
      );
      final p = await cache.prepare(trackId: '42', stream: stream);
      expect(p, '${tmp.path}/42.flac');
      expect(downloads, 0);
    });

    test('未命中且下载产物不是合法加密体 → 解密抛错（不落成品）', () async {
      final cache = LosslessCache(dirProvider: () async => tmp);
      cache.downloadFileOverride = (url, path, progress) async {
        await File(path).writeAsBytes([0, 0, 0, 0]);
      };
      final stream = PlayStream(
        quality: 'lossless',
        mainUrl: 'https://cdn/x',
        spadeA: 'nbwTy2+yP/p0sgjKRIEIz0KzEv5fhiTOaIMVz2m0FM9pgCGQkA==',
      );
      await expectLater(
        cache.prepare(trackId: '43', stream: stream),
        throwsA(anything),
      );
      expect(await File('${tmp.path}/43.flac').exists(), isFalse);
    });

    test('容量淘汰：超上限删最旧、保留指定文件', () async {
      final old1 = File('${tmp.path}/old1.flac');
      final old2 = File('${tmp.path}/old2.flac');
      final keep = File('${tmp.path}/keep.flac');
      await old1.writeAsBytes(List.filled(60, 1));
      await old2.writeAsBytes(List.filled(60, 2));
      await keep.writeAsBytes(List.filled(60, 3));
      await old1.setLastModified(DateTime(2020));
      await old2.setLastModified(DateTime(2021));
      await keep.setLastModified(DateTime(2022));
      final cache = LosslessCache(dirProvider: () async => tmp, maxBytes: 100);
      await cache.evictIfNeeded(keepPath: keep.path);
      expect(await old1.exists(), isFalse);
      expect(await old2.exists(), isFalse);
      expect(await keep.exists(), isTrue);
    });
  });
}
