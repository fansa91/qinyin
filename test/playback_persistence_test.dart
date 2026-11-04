// 全局持久化验收（播放状态跨重启恢复）：
//
// - 快照只存曲目元数据 + 下标 + 位置 + 循环模式（Track.toJson 口径），
//   不存播放直链；JSON 往返字段不丢（含专辑名/VIP 等元数据）；
// - 损坏/版本不兼容的存档静默丢弃回默认态，绝不抛；
// - 冷启动恢复：双会话状态装回（活动会话进引擎、非活动进 store），
//   保持暂停不自动出声；mini 条按会话隔离口径恢复显示；
// - 恢复态 seek 只改内存位置（引擎尚未装载声源）。
//
// 手法与 playback_isolation_test 一致：测试环境无音频插件，平台
// future 不完成，断言只验状态链。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:qinyin/models/models.dart';
import 'package:qinyin/services/library_service.dart';
import 'package:qinyin/services/play_queue.dart';
import 'package:qinyin/services/play_resolver.dart';
import 'package:qinyin/services/playback_state.dart';
import 'package:qinyin/services/player_service.dart';
import 'package:qinyin/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

SeoTrack fakeSeo(String id) => SeoTrack(
      track: Track(id: id, name: '歌曲$id', durationMs: 213000),
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

Track t(String id, String name, {String album = ''}) =>
    Track(id: id, name: name, albumName: album);

Future<PlayerService> makePlayer() async {
  final settings = SettingsService();
  await settings.init();
  final library = LibraryService();
  await library.init();
  final resolver = PlayResolver((id) async => fakeSeo(id));
  return PlayerService(resolver, settings, library);
}

void main() {
  group('PlaybackSnapshot 纯数据往返', () {
    test('encode → tryParse 字段不丢（下标/位置/模式/专辑名）', () {
      final snap = PlaybackSnapshot(
        active: 'recommend',
        mode: QueueLoopMode.shuffle,
        main: SessionSnapshot(
          items: [t('h1', '首页1', album: '专辑甲'), t('h2', '首页2')],
          index: 1,
          positionMs: 42000,
        ),
        recommend: SessionSnapshot(
          items: [t('r1', '推荐1')],
          index: 0,
          positionMs: 3000,
        ),
      );
      final back = PlaybackSnapshot.tryParse(snap.encode())!;
      expect(back.active, 'recommend');
      expect(back.mode, QueueLoopMode.shuffle);
      expect(back.main!.items.map((e) => e.id), ['h1', 'h2']);
      expect(back.main!.items.first.albumName, '专辑甲');
      expect(back.main!.index, 1);
      expect(back.main!.positionMs, 42000);
      expect(back.recommend!.items.single.id, 'r1');
      expect(back.recommend!.positionMs, 3000);
    });

    test('损坏/版本不兼容一律 null（静默丢弃口径）', () {
      expect(PlaybackSnapshot.tryParse(null), isNull);
      expect(PlaybackSnapshot.tryParse(''), isNull);
      expect(PlaybackSnapshot.tryParse('not json {{{'), isNull);
      expect(PlaybackSnapshot.tryParse(42), isNull);
      expect(PlaybackSnapshot.tryParse('{"v":2,"active":"main"}'), isNull);
      expect(
        PlaybackSnapshot.tryParse('{"v":1,"main":{"items":"bad"}}'),
        isNull,
      );
    });

    test('SessionSnapshot 解析：坏曲目跳过、下标收敛、负位置归零', () {
      final s = SessionSnapshot.fromJson({
        'items': [
          {'id': 'a', 'name': '甲'},
          'garbage',
          {'id': 'b', 'name': '乙'},
        ],
        'index': 99,
        'positionMs': -5,
      })!;
      expect(s.items.map((e) => e.id), ['a', 'b']);
      expect(s.index, 1);
      expect(s.positionMs, 0);
      expect(SessionSnapshot.fromJson('nope'), isNull);
      expect(SessionSnapshot.fromJson({'items': []}), isNull);
    });
  });

  group('PlayerService 恢复', () {
    testWidgets('恢复主会话：队列/下标/模式/位置装回，保持暂停', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final player = await makePlayer();
      final snap = PlaybackSnapshot(
        active: 'main',
        mode: QueueLoopMode.single,
        main: SessionSnapshot(
          items: [t('a', '甲'), t('b', '乙'), t('c', '丙')],
          index: 1,
          positionMs: 42000,
        ),
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('playback_state_v1', snap.encode());
      await player.restorePersisted();
      expect(player.hasQueue, isTrue);
      expect(player.currentIndex, 1);
      expect(player.currentTrack?.id, 'b');
      expect(player.mode, QueueLoopMode.single);
      expect(player.position, const Duration(seconds: 42));
      expect(player.playing, isFalse, reason: '恢复不自动出声');
      expect(player.miniBarHasContent, isTrue,
          reason: '主会话恢复后 mini 条恢复显示该曲目');
      // 恢复态 seek 只改内存位置（引擎未装载，不碰平台通道）
      await player.seek(const Duration(seconds: 10));
      expect(player.position, const Duration(seconds: 10));
      player.dispose();
    });

    testWidgets('恢复活动会话为推荐：主会话进 store，mini 条不显示',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final player = await makePlayer();
      final snap = PlaybackSnapshot(
        active: 'recommend',
        mode: QueueLoopMode.list,
        main: SessionSnapshot(
          items: [t('h1', '首页1'), t('h2', '首页2')],
          index: 1,
          positionMs: 5000,
        ),
        recommend: SessionSnapshot(
          items: [t('r1', '推荐1'), t('r2', '推荐2'), t('r3', '推荐3')],
          index: 2,
          positionMs: 61000,
        ),
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('playback_state_v1', snap.encode());
      await player.restorePersisted();
      expect(player.activeSession, PlayerSession.recommend);
      expect(player.recommendCurrentIndex, 2);
      expect(player.recommendCurrentTrack?.id, 'r3');
      expect(player.position, const Duration(seconds: 61));
      expect(player.mainQueueItems.map((e) => e.id), ['h1', 'h2']);
      expect(player.mainCurrentIndex, 1);
      expect(player.miniBarHasContent, isFalse,
          reason: '推荐占用输出时 mini 条隐藏（隔离口径），恢复后同理');
      expect(player.playing, isFalse);
      player.dispose();
    });

    testWidgets('服务级往返：点播+预置推荐 → 落盘 → 新实例恢复', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final p1 = await makePlayer();
      unawaited(p1.playQueue([t('h1', '首页1'), t('h2', '首页2')], 1));
      p1.setMode(QueueLoopMode.shuffle);
      p1.setRecommendSession([t('r1', '推荐1'), t('r2', '推荐2')]);
      await p1.persistPlaybackState();

      final p2 = await makePlayer();
      await p2.restorePersisted();
      expect(p2.mainQueueItems.map((e) => e.id), ['h1', 'h2']);
      expect(p2.mainCurrentIndex, 1);
      expect(p2.mode, QueueLoopMode.shuffle);
      expect(p2.recommendQueueItems.map((e) => e.id), ['r1', 'r2'],
          reason: '推荐会话（预置态）随全局快照一并恢复');
      expect(p2.recommendCurrentIndex, 0);
      expect(p2.playing, isFalse);
      p1.dispose();
      p2.dispose();
    });

    testWidgets('存档损坏：restorePersisted 静默回默认态', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final player = await makePlayer();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('playback_state_v1', '{{{garbage');
      await player.restorePersisted();
      expect(player.hasQueue, isFalse);
      expect(player.recommendHasContent, isFalse);
      player.dispose();
    });
  });
}
