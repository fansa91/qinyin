import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qinyin/models/models.dart';

Map<String, dynamic> fixture(String name) =>
    (jsonDecode(File('test/fixtures/$name').readAsStringSync())
        as Map<String, dynamic>);

void main() {
  group('CoverArt 拼装（真实响应实测规则）', () {
    test('uri + 前缀 + template → -image.image', () {
      final c = CoverArt.fromJson({
        'uri': 'tos-cn-v-2774c002/abc',
        'urls': ['https://p3-luna.douyinpic.com/img/'],
        'template_prefix': 'tplv-b829550vbb',
      });
      expect(c.url(),
          'https://p3-luna.douyinpic.com/img/tos-cn-v-2774c002/abc~tplv-b829550vbb-image.image');
      expect(c.url(webp: true),
          'https://p3-luna.douyinpic.com/img/tos-cn-v-2774c002/abc~tplv-b829550vbb-15.webp');
    });
  });

  group('seo_track fixture 解析', () {
    late SeoTrack seo;
    setUp(() => seo = SeoTrack.fromJson(fixture('seo_track.json')));

    test('曲目基本信息与制作人', () {
      expect(seo.track.name, '小半');
      expect(seo.track.artists.first.name, '陈粒');
      expect(seo.track.durationMs, 297240);
      expect(seo.track.makers['composers'], contains('陈粒'));
      expect(seo.track.makers['lyricists'], contains('涂玲子'));
    });

    test('封面 URL 可拼装', () {
      expect(seo.track.coverUrl, contains('~tplv-b829550vbb-image.image'));
      expect(seo.track.coverUrl, startsWith('https://p3-luna.douyinpic.com/img/'));
    });

    test('可播流：medium + higher 两档 AAC 明文链', () {
      expect(seo.streams.map((s) => s.quality),
          containsAll(['medium', 'higher']));
      for (final s in seo.streams) {
        expect(s.mainUrl, startsWith('https://'));
        expect(s.codecType, 'aac');
      }
      expect(seo.expireAt, greaterThan(0));
      expect(seo.hasPlayable, isTrue);
    });

    test('歌词解析出 4 行且首行文本正确', () {
      final lines = seo.lyricLines;
      expect(lines.length, 4);
      expect(lines.first.text, '不敢回看');
      expect(lines.first.start, const Duration(milliseconds: 60));
    });

    test('评论与相关列表', () {
      expect(seo.comments, isNotEmpty);
      expect(seo.comments.first.content, isNotEmpty);
      expect(seo.comments.first.nickname, isNotEmpty);
      expect(seo.albumTracks.length, 2);
      expect(seo.chartTracks.length, 2);
    });
  });

  group('discover / mix / playlist fixture', () {
    test('discover 电台资源可解析', () {
      final body = fixture('discover.json');
      final blocks = body['blocks'] as List;
      final mixBlock = blocks.first as Map<String, dynamic>;
      final inner = mixBlock['inner_block'] as List;
      final radioBlock = inner.first as Map<String, dynamic>;
      final resource =
          (radioBlock['resources'] as List).first as Map<String, dynamic>;
      final radio = RadioStation.fromResource(resource);
      expect(radio, isNotNull);
      expect(radio!.title, '流行舞曲');
      expect(radio.coverUrl, contains('douyinpic.com'));
    });

    test('mix 歌单可解析', () {
      final body = fixture('discover_mix.json');
      final inner = body['inner_block'] as List;
      final block = inner.first as Map<String, dynamic>;
      final resource =
          (block['resources'] as List).first as Map<String, dynamic>;
      final playlist = Playlist.fromResource(resource);
      expect(playlist, isNotNull);
      expect(playlist!.id, isNotEmpty);
      expect(playlist.coverUrl, contains('~tplv-b829550vbb-image.image'));
    });

    test('playlist media_resources 里 track 可解析', () {
      final body = fixture('playlist.json');
      final mr = (body['media_resources'] as List).first as Map<String, dynamic>;
      final wrapper = (mr['entity'] as Map<String, dynamic>)['track_wrapper']
          as Map<String, dynamic>;
      final track = Track.fromWrapped(wrapper);
      expect(track, isNotNull);
      expect(track!.name, isNotEmpty);
      expect(track.durationMs, greaterThan(0));
      expect(body['next_cursor'], isNotNull);
    });
  });

  group('VIP 标识与音质档解析（第 7/10 项）', () {
    test('App 侧：label_info.only_vip_playable=true → VIP（seo 小半）', () {
      final seo = SeoTrack.fromJson(fixture('seo_track.json'));
      expect(seo.track.name, '小半');
      expect(seo.track.isVip, isTrue);
      // label_info.quality_map 含 lossless → 有无损版本
      expect(seo.track.topQuality, 'lossless');
    });

    test('App 侧：only_vip_playable 缺失 → 非 VIP（playlist Augenblick）', () {
      final body = fixture('playlist.json');
      final mr = (body['media_resources'] as List).first as Map<String, dynamic>;
      final wrapper = (mr['entity'] as Map<String, dynamic>)['track_wrapper']
          as Map<String, dynamic>;
      final track = Track.fromWrapped(wrapper)!;
      expect(track.name, 'Augenblick (Qntal Remix)');
      expect(track.isVip, isFalse);
      expect(track.topQuality, 'lossless');
    });

    test('App 侧：无 label_info 时按 bit_rates 取最高档', () {
      final t = Track.fromJson({
        'id': '1',
        'name': 'x',
        'bit_rates': [
          {'quality': 'medium', 'br': 1, 'size': 1},
          {'quality': 'higher', 'br': 2, 'size': 2},
        ],
      });
      expect(t.isVip, isFalse);
      expect(t.topQuality, 'higher');
      final empty = Track.fromJson({'id': '2', 'name': 'y'});
      expect(empty.topQuality, '');
    });

    test('平台侧：commerce_info.icon_info.type=svip → VIP，空 → 非 VIP', () {
      final body = fixture('platform_feed.json');
      final medias = <Map<String, dynamic>>[];
      void walk(dynamic o) {
        if (o is Map<String, dynamic>) {
          if (o['track_entity'] is Map<String, dynamic>) medias.add(o);
          for (final v in o.values) {
            walk(v);
          }
        } else if (o is List) {
          for (final v in o) {
            walk(v);
          }
        }
      }

      walk(body);
      expect(medias.length, 3);
      final tracks = medias.map(Track.fromPlatformMedia).whereType<Track>().toList();
      final byName = {for (final t in tracks) t.name: t};
      expect(byName['离人愁 - 女生版']!.isVip, isFalse);
      expect(byName['沦陷']!.isVip, isTrue);
      expect(byName['游京（滔滔江水）']!.isVip, isTrue);
      // 平台 bit_rates 含 lossless → 无损档
      expect(byName['离人愁 - 女生版']!.topQuality, 'lossless');
    });

    test('toJson/fromJson 往返保 VIP 与无损标记', () {
      final seo = SeoTrack.fromJson(fixture('seo_track.json'));
      final restored = Track.fromJson(seo.track.toJson());
      expect(restored.isVip, isTrue);
      expect(restored.topQuality, 'lossless');
    });
  });
}
