// 第 11 项：写标签失败做细——tagger 详细原因、文本/封面解耦、
// DownloadRecord.tagError 落盘往返。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qinyin/services/download_service.dart';
import 'package:qinyin/services/flac_tagger.dart';

const _cover = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]; // 假 JPEG 头

MediaTags _tags({bool withCover = true}) => MediaTags(
      title: '歌',
      artist: '手',
      album: '辑',
      date: '2024-01-01',
      coverBytes:
          withCover ? Uint8List.fromList(_cover) : null,
      coverMime: withCover ? 'image/jpeg' : null,
    );

void main() {
  group('applyDownloadTags 解耦逻辑（假 tagger）', () {
    Future<({bool ok, String? error})> okTagger(String p, MediaTags t) async =>
        (ok: true, error: null);

    test('全量成功 → tagged，无 error', () async {
      final r = await applyDownloadTags('x', _tags(), tagger: okTagger);
      expect(r.status, 'tagged');
      expect(r.error, '');
    });

    test('带封面失败、仅文本成功 → tagged_text 且原因指明封面', () async {
      Future<({bool ok, String? error})> coverFail(
          String p, MediaTags t) async {
        if (t.coverBytes != null) {
          return (ok: false, error: '自检失败：PICTURE 回读不一致');
        }
        return (ok: true, error: null);
      }

      final r = await applyDownloadTags('x', _tags(), tagger: coverFail);
      expect(r.status, 'tagged_text');
      expect(r.error, contains('封面写入失败'));
      expect(r.error, contains('PICTURE'));
    });

    test('恒失败 → failed 且带回最终原因原文', () async {
      Future<({bool ok, String? error})> alwaysFail(
              String p, MediaTags t) async =>
          (ok: false, error: '写临时文件失败：No space left on device');
      final r = await applyDownloadTags('x', _tags(), tagger: alwaysFail);
      expect(r.status, 'failed');
      expect(r.error, contains('No space left'));
    });

    test('无封面失败 → 不重试、直接 failed', () async {
      var calls = 0;
      Future<({bool ok, String? error})> counting(
          String p, MediaTags t) async {
        calls++;
        return (ok: false, error: '构建标签失败');
      }

      final r =
          await applyDownloadTags('x', _tags(withCover: false), tagger: counting);
      expect(r.status, 'failed');
      expect(calls, 1);
    });
  });

  group('FlacTagger.tagFileDetailed 原因回传（真实文件）', () {
    test('非 FLAC 输入 → ok=false 且原因含 fLaC 魔数说明', () async {
      final f = File('${Directory.systemTemp.path}/qy_not_flac.bin');
      await f.writeAsBytes([1, 2, 3, 4, 5, 6, 7, 8]);
      final r = await FlacTagger.tagFileDetailed(f.path, _tags());
      expect(r.ok, isFalse);
      expect(r.error, contains('fLaC'));
      // 原文件不毁
      expect(await f.readAsBytes(), [1, 2, 3, 4, 5, 6, 7, 8]);
      await f.delete();
    });

    test('源文件不存在 → ok=false 且原因指明读取失败', () async {
      final r = await FlacTagger.tagFileDetailed(
          '${Directory.systemTemp.path}/qy_missing_xyz.flac', _tags());
      expect(r.ok, isFalse);
      expect(r.error, contains('读取源文件失败'));
    });
  });

  group('DownloadRecord.tagError 落盘往返', () {
    test('toJson/fromJson 保留 tagStatus 与 tagError', () {
      final rec = DownloadRecord(
        trackId: '1',
        title: 't',
        artist: 'a',
        path: '/x.flac',
        quality: 'lossless',
        size: 10,
        createdAt: 1,
        tagStatus: 'tagged_text',
        tagError: '封面写入失败：自检失败',
      );
      final back = DownloadRecord.fromJson(rec.toJson());
      expect(back.tagStatus, 'tagged_text');
      expect(back.tagError, '封面写入失败：自检失败');
      expect(back.formatLabel, 'FLAC');
    });

    test('旧记录无 tagError 字段 → 缺省空串', () {
      final back = DownloadRecord.fromJson({
        'trackId': '1',
        'title': 't',
        'artist': 'a',
        'path': '/x.m4a',
        'quality': 'higher',
        'size': 1,
        'createdAt': 1,
        'tagStatus': 'failed',
      });
      expect(back.tagError, '');
      expect(back.formatLabel, 'M4A');
    });
  });
}
