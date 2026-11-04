// 下载管理「清除已完成记录」验收（用户口径：只删记录、不删文件）：
//
// - 清除后已完成记录条目全部消失、落盘的记录键清空；
// - 已下载的歌曲文件仍在磁盘上（一个字节都不动）；
// - 记录清除后 isDownloaded/localPathFor 不再认这些文件（如实
//   口径：下载管理不再列出、播放不再优先走本地文件）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qinyin/models/models.dart';
import 'package:qinyin/services/download_service.dart';
import 'package:qinyin/services/play_resolver.dart';
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

void main() {
  test('clearCompletedRecords：记录清零、文件保留', () async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('qinyin_dl_clear_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final f1 = File('${dir.path}/a.m4a');
    await f1.writeAsBytes([1, 2, 3]);
    final f2 = File('${dir.path}/b.flac');
    await f2.writeAsBytes([4, 5, 6, 7]);

    final seedRecords = [
      DownloadRecord(
        trackId: 't1',
        title: '歌一',
        artist: '歌手一',
        path: f1.path,
        quality: 'higher',
        size: 3,
        createdAt: 1,
      ),
      DownloadRecord(
        trackId: 't2',
        title: '歌二',
        artist: '歌手二',
        path: f2.path,
        quality: 'lossless',
        size: 4,
        createdAt: 2,
      ),
    ];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'download_records',
      jsonEncode(seedRecords.map((r) => r.toJson()).toList()),
    );

    final settings = SettingsService();
    await settings.init();
    final resolver = PlayResolver((id) async => fakeSeo(id));
    final svc = DownloadService(resolver, settings);
    await svc.init();
    expect(svc.records.length, 2);
    expect(svc.isDownloaded('t1'), isTrue);
    expect(svc.localPathFor('t1'), f1.path);

    await svc.clearCompletedRecords();

    expect(svc.records, isEmpty, reason: '已完成记录条目全部清除');
    expect(prefs.getString('download_records'), '[]',
        reason: '记录落盘同步清空，重启后不会复活');
    expect(await f1.exists(), isTrue, reason: '文件保留：只删记录不删文件');
    expect(await f2.exists(), isTrue);
    expect(await f1.length(), 3);
    // 如实口径：记录没了之后不再认本地文件
    expect(svc.isDownloaded('t1'), isFalse);
    expect(svc.localPathFor('t1'), isNull);
  });

  test('clearCompletedRecords：无记录时为空操作', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    await settings.init();
    final resolver = PlayResolver((id) async => fakeSeo(id));
    final svc = DownloadService(resolver, settings);
    await svc.init();
    await svc.clearCompletedRecords();
    expect(svc.records, isEmpty);
  });
}
