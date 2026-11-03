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
