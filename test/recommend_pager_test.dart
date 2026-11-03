import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qinyin/models/models.dart';
import 'package:qinyin/services/qishui_service.dart';
import 'package:qinyin/services/recommend_pager.dart';

Map<String, dynamic> fixture(String name) =>
    (jsonDecode(File('test/fixtures/$name').readAsStringSync())
        as Map<String, dynamic>);

Track t(String id) => Track(id: id, name: '歌$id');

void main() {
  group('feed 响应解析（真实 fixture）', () {
    test('related fixture：items[].entity.track_wrapper 可解析', () {
      final tracks = QishuiService.parseFeedItems(fixture('related.json'));
      expect(tracks, isNotEmpty);
      expect(tracks.first.id, isNotEmpty);
      expect(tracks.first.name, isNotEmpty);
    });

    test('radio fixture：与 related 同形状可解析', () {
      final tracks = QishuiService.parseFeedItems(fixture('radio_tracks.json'));
      expect(tracks, isNotEmpty);
      expect(tracks.first.id, isNotEmpty);
    });

    test('platform fixture：车机开放平台 feed 字段映射（§15.3）', () {
      final tracks =
          QishuiService.parsePlatformItems(fixture('platform_feed.json'));
      expect(tracks.length, 3);
      final t0 = tracks.first;
      expect(t0.id, isNotEmpty);
      expect(t0.name, isNotEmpty);
      // 歌手在 related_info.artist_links、专辑在 album_link
      expect(t0.artists, isNotEmpty);
      expect(t0.artists.first.name, isNotEmpty);
      expect(t0.artists.first.id, isNotEmpty);
      expect(t0.albumId, isNotEmpty);
      expect(t0.albumName, isNotEmpty);
      // 封面在 display_info.cover_url，沿用拼装规则可出 URL
      expect(t0.coverUrl, isNotNull);
      expect(t0.coverUrl, contains(t0.cover!.uri));
      // 时长 base_info.duration_ms、统计 media_stats、制作团队 song_maker_team
      expect(t0.durationMs, greaterThan(0));
      expect(t0.countCollected, isNotNull);
      expect(t0.countComment, isNotNull);
      expect(t0.makers['composers'], isNotEmpty);
      // vid 与 full.bit_rates 元数据（含 lossless 档，仅元数据）
      expect(t0.vid, isNotEmpty);
      expect(t0.bitRates.map((b) => b.quality), contains('lossless'));
    });

    test('PlatformFeedService.commonParams：车机公共参数口径', () {
      final p = PlatformFeedService.commonParams('1234567890',
          timestampSeconds: 1700000000, nonce: 42);
      expect(p['aid'], '765213');
      expect(p['app_name'], 'byte_autoservice_lite');
      expect(p['device_id'], '1234567890');
      expect(p['did'], '1234567890');
      expect(p['iid'], '1234567890');
      expect(p['vehicle_id'], 'qishui-1234567890');
      expect(p['_timestamp'], '1700000000');
      expect(p['_nonce'], '42');
    });
  });

  group('RecommendPager 多源轮转/去重/枯竭', () {
    RecommendPager buildPager({
      List<Track> Function(String seed)? related,
      List<Track>? playlistTracks,
      List<Track> Function(String radioId, int call)? radio,
      List<String> radioIds = const ['r1'],
    }) {
      var radioCalls = 0;
      return RecommendPager(
        fetchRelated: (seed) async => related?.call(seed) ?? const [],
        fetchPlaylistList: (cursor) async =>
            (cursor == '0' ? [const Playlist(id: 'p1', title: '歌单')] : <Playlist>[], null, false),
        fetchPlaylistTracks: (id, {cursor}) async =>
            (const Playlist(id: 'p1', title: '歌单'), playlistTracks ?? const [], null),
        fetchRadioPage: (radioId, cursor) async {
          radioCalls++;
          return radio?.call(radioId, radioCalls) ?? const [];
        },
        radioIds: radioIds,
      );
    }

    test('三源轮转出曲且跨源去重', () async {
      final pager = buildPager(
        playlistTracks: [t('a'), t('b'), t('c')],
        radio: (id, call) => call == 1 ? [t('c'), t('d')] : const [], // c 与歌单重复
      );
      // 先给 related 一个种子：第一页先走 radio/playlist 攒曲
      final page1 = await pager.nextPage(target: 3);
      expect(page1.map((e) => e.id), containsAll(['a', 'b', 'c']));
      final page2 = await pager.nextPage(target: 3);
      final all = [...page1, ...page2].map((e) => e.id).toList();
      expect(all.toSet().length, all.length, reason: '会话内不重复');
      expect(all, contains('d'));
    });

    test('related 以末曲为种子链式调用', () async {
      final seeds = <String>[];
      final pager = buildPager(
        playlistTracks: [t('s0')],
        related: (seed) {
          seeds.add(seed);
          return [t('rel${seeds.length}')];
        },
        radioIds: const [],
      );
      await pager.nextPage(target: 1); // 歌单先出 s0 → 种子
      await pager.nextPage(target: 1);
      await pager.nextPage(target: 1);
      expect(seeds, isNotEmpty);
      expect(seeds.first, 's0');
    });

    test('三源全干 → 判定枯竭且后续返回空', () async {
      final pager = buildPager(playlistTracks: const [], radioIds: const []);
      final page = await pager.nextPage(target: 5);
      expect(page, isEmpty);
      expect(pager.hasMore, isFalse);
      expect(await pager.nextPage(), isEmpty);
    });

    test('平台主源优先：回退源不被调用', () async {
      var fallbackCalls = 0;
      final pager = RecommendPager(
        fetchPlatformPage: (cursor) async =>
            ([t('pf$cursor'), t('pf${cursor + 1}')], true),
        fetchRelated: (seed) async {
          fallbackCalls++;
          return const [];
        },
        fetchPlaylistList: (cursor) async {
          fallbackCalls++;
          return (<Playlist>[], null, false);
        },
        fetchPlaylistTracks: (id, {cursor}) async {
          fallbackCalls++;
          return (const Playlist(id: 'p', title: ''), <Track>[], null);
        },
        fetchRadioPage: (id, cursor) async {
          fallbackCalls++;
          return const [];
        },
        radioIds: const ['r1'],
      );
      final page = await pager.nextPage(target: 2);
      expect(page.map((e) => e.id), ['pf0', 'pf1']);
      expect(fallbackCalls, 0);
      expect(pager.usingFallback, isFalse);
      expect(pager.hasMore, isTrue);
    });

    test('平台主源 cursor 按原始条数偏移推进', () async {
      final cursors = <int>[];
      final pager = RecommendPager(
        fetchPlatformPage: (cursor) async {
          cursors.add(cursor);
          return (List.generate(20, (i) => t('c${cursor + i}')), true);
        },
        fetchRelated: (seed) async => const [],
        fetchPlaylistList: (cursor) async => (<Playlist>[], null, false),
        fetchPlaylistTracks: (id, {cursor}) async =>
            (const Playlist(id: 'p', title: ''), <Track>[], null),
        fetchRadioPage: (id, cursor) async => const [],
        radioIds: const [],
      );
      await pager.nextPage(target: 12);
      await pager.nextPage(target: 12); // 先吃 pending，之后再拉一页
      await pager.nextPage(target: 12);
      expect(cursors, [0, 20]);
    });

    test('平台主源报错 → 本会话回退三源出曲', () async {
      final pager = RecommendPager(
        fetchPlatformPage: (cursor) async => throw StateError('boom'),
        fetchRelated: (seed) async => const [],
        fetchPlaylistList: (cursor) async =>
            ([const Playlist(id: 'p1', title: '歌单')], null, false),
        fetchPlaylistTracks: (id, {cursor}) async =>
            (const Playlist(id: 'p1', title: '歌单'), [t('fb1'), t('fb2')], null),
        fetchRadioPage: (id, cursor) async => const [],
        radioIds: const [],
      );
      final page = await pager.nextPage(target: 2);
      expect(page.map((e) => e.id), containsAll(['fb1', 'fb2']));
      expect(pager.usingFallback, isTrue);
    });

    test('平台主源空批 → 回退；主源与回退都空才枯竭', () async {
      final pager = RecommendPager(
        fetchPlatformPage: (cursor) async => (const <Track>[], true),
        fetchRelated: (seed) async => const [],
        fetchPlaylistList: (cursor) async => (<Playlist>[], null, false),
        fetchPlaylistTracks: (id, {cursor}) async =>
            (const Playlist(id: 'p', title: ''), <Track>[], null),
        fetchRadioPage: (id, cursor) async => const [],
        radioIds: const [],
      );
      final page = await pager.nextPage(target: 5);
      expect(page, isEmpty);
      expect(pager.usingFallback, isTrue);
      expect(pager.hasMore, isFalse);
    });

    test('平台整批重复 3 次后切回退源', () async {
      var platformCalls = 0;
      final pager = RecommendPager(
        fetchPlatformPage: (cursor) async {
          platformCalls++;
          // 每次都回同一首（第一批是新的，之后整批重复）
          return ([t('same')], true);
        },
        fetchRelated: (seed) async => const [],
        fetchPlaylistList: (cursor) async =>
            ([const Playlist(id: 'p1', title: '歌单')], null, false),
        fetchPlaylistTracks: (id, {cursor}) async =>
            (const Playlist(id: 'p1', title: '歌单'), [t('fb')], null),
        fetchRadioPage: (id, cursor) async => const [],
        radioIds: const [],
      );
      final page1 = await pager.nextPage(target: 1);
      expect(page1.single.id, 'same');
      final page2 = await pager.nextPage(target: 1);
      expect(page2.single.id, 'fb');
      expect(platformCalls, 4); // 1 次成功 + 3 次整批重复后停用
      expect(pager.usingFallback, isTrue);
    });

    test('reset 后可重新出曲（换一批）', () async {
      var round = 0;
      final pager = RecommendPager(
        fetchRelated: (seed) async => [t('x$round')],
        fetchPlaylistList: (cursor) async =>
            ([const Playlist(id: 'p1', title: '歌单')], null, false),
        fetchPlaylistTracks: (id, {cursor}) async {
          round++;
          return (const Playlist(id: 'p1', title: '歌单'), [t('pl$round')], null);
        },
        fetchRadioPage: (id, cursor) async => const [],
        radioIds: const [],
      );
      final first = await pager.nextPage(target: 2);
      expect(first, isNotEmpty);
      pager.reset();
      expect(pager.hasMore, isTrue);
      expect(pager.seenCount, 0);
      final second = await pager.nextPage(target: 2);
      expect(second, isNotEmpty);
    });
  });
}
