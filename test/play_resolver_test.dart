import 'package:flutter_test/flutter_test.dart';
import 'package:qinyin/models/models.dart';
import 'package:qinyin/services/play_resolver.dart';

PlayStream s(String q, int br) =>
    PlayStream(quality: q, codecType: 'aac', bitrate: br, mainUrl: 'https://cdn/$q.m4a');

SeoTrack fakeSeo(String id, {int expireAt = 9999999999}) => SeoTrack(
      track: Track(id: id, name: '歌$id'),
      streams: [s('medium', 66000), s('higher', 130000)],
      expireAt: expireAt,
    );

void main() {
  group('选档与回落', () {
    test('有目标档直接选', () {
      final streams = [s('medium', 1), s('higher', 2), s('highest', 3)];
      expect(PlayResolver.selectStream(streams, 'higher')!.bitrate, 2);
    });
    test('想 highest 缺档 → 回落 higher', () {
      final streams = [s('medium', 1), s('higher', 2)];
      expect(PlayResolver.selectStream(streams, 'highest')!.quality, 'higher');
    });
    test('想 medium 缺档 → 就近 higher', () {
      final streams = [s('higher', 2), s('highest', 3)];
      expect(PlayResolver.selectStream(streams, 'medium')!.quality, 'higher');
    });
    test('无流返回 null（付费/受限）', () {
      expect(PlayResolver.selectStream(const [], 'higher'), isNull);
    });
    test('resolve 无流抛 PlayUnavailable', () async {
      final resolver = PlayResolver(
          (id) async => SeoTrack(track: Track(id: id, name: 'x')));
      expect(
        () => resolver.resolve('1', quality: 'higher'),
        throwsA(isA<PlayUnavailable>()),
      );
    });
  });

  group('缓存与过期', () {
    test('未过期复用缓存，fetcher 只调一次', () async {
      var calls = 0;
      final resolver = PlayResolver((id) async {
        calls++;
        return fakeSeo(id);
      });
      await resolver.resolve('1', quality: 'higher');
      await resolver.resolve('1', quality: 'medium');
      expect(calls, 1);
    });

    test('已过期（expire_at 已过）重新拉取', () async {
      var calls = 0;
      final resolver = PlayResolver((id) async {
        calls++;
        return fakeSeo(id, expireAt: 1000); // 1970 年，早已过期
      });
      await resolver.seo('1');
      await resolver.seo('1');
      expect(calls, 2);
    });

    test('forceRefresh 绕过缓存（下载前重解析用）', () async {
      var calls = 0;
      final resolver = PlayResolver((id) async {
        calls++;
        return fakeSeo(id);
      });
      await resolver.resolve('1', quality: 'higher');
      await resolver.resolve('1', quality: 'higher', forceRefresh: true);
      expect(calls, 2);
    });
  });
}
