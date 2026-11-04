// FLAC 标签写入测试：合成小 FLAC（fLaC + STREAMINFO + 假帧）验证
// 写入→回读往返、已有标签块替换不叠加、音频段字节级不变、失败不毁原文件。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qinyin/services/flac_tagger.dart';

Uint8List blockBytes(int type, List<int> data, {bool last = false}) {
  return Uint8List.fromList([
    (last ? 0x80 : 0) | type,
    (data.length >> 16) & 0xFF,
    (data.length >> 8) & 0xFF,
    data.length & 0xFF,
    ...data,
  ]);
}

/// 最小 FLAC：STREAMINFO（34B 可辨识填充）+ 假音频帧
Uint8List syntheticFlac({List<Uint8List> extraBlocks = const []}) {
  final streamInfo = List<int>.generate(34, (i) => i + 1);
  final frames = List<int>.generate(512, (i) => (i * 7) & 0xFF);
  final blocks = <Uint8List>[
    blockBytes(0, streamInfo),
    ...extraBlocks,
  ];
  final out = BytesBuilder()..add([0x66, 0x4C, 0x61, 0x43]);
  for (var i = 0; i < blocks.length; i++) {
    final b = Uint8List.fromList(blocks[i]);
    if (i == blocks.length - 1) b[0] |= 0x80;
    out.add(b);
  }
  out.add(frames);
  return out.toBytes();
}

/// 自带旧标签的 FLAC（旧 VORBIS_COMMENT + 旧 PICTURE + 一个 SEEKTABLE）
Uint8List flacWithOldTags() {
  final oldComment = BytesBuilder();
  void u32le(BytesBuilder b, int v) => b.add(
      [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  final vendor = 'oldvendor'.codeUnits;
  u32le(oldComment, vendor.length);
  oldComment.add(vendor);
  u32le(oldComment, 1);
  final fBytes = <int>[
    ...'TITLE='.codeUnits,
    0xE6, 0x97, 0xA7, 0xE6, 0xA0, 0x87, 0xE9, 0xA2, 0x98, // 旧标题（UTF-8）
  ];
  u32le(oldComment, fBytes.length);
  oldComment.add(fBytes);
  final oldPicture = <int>[
    0, 0, 0, 3, // type
    0, 0, 0, 10, ...'image/jpeg'.codeUnits, // mime
    0, 0, 0, 0, // desc
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // w/h/depth/colors
    0, 0, 0, 4, 1, 2, 3, 4, // data
  ];
  return syntheticFlac(extraBlocks: [
    blockBytes(4, oldComment.toBytes()),
    blockBytes(6, oldPicture),
    blockBytes(3, [9, 9, 9, 9]), // SEEKTABLE（须保留）
  ]);
}

int countBlocks(Uint8List flac, int type) {
  var offset = 4;
  var n = 0;
  while (offset + 4 <= flac.length) {
    final header = flac[offset];
    final isLast = (header & 0x80) != 0;
    final t = header & 0x7F;
    final len =
        (flac[offset + 1] << 16) | (flac[offset + 2] << 8) | flac[offset + 3];
    if (t == type) n++;
    offset += 4 + len;
    if (isLast) break;
  }
  return n;
}

Uint8List audioOf(Uint8List flac) {
  final start = FlacTagger.audioStartOffset(flac);
  return Uint8List.sublistView(flac, start);
}

void main() {
  final pngCover = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    ...List<int>.generate(64, (i) => i),
  ]);
  const tags = MediaTags(
    title: '新歌名',
    artist: '歌手甲 / 歌手乙',
    album: '专辑名',
    date: '2022-03-02',
  );

  test('写入→回读往返：四字段 + 封面，STREAMINFO 与音频段不变', () {
    final src = syntheticFlac();
    final tagged = FlacTagger.buildTaggedFlac(
        src,
        MediaTags(
          title: tags.title,
          artist: tags.artist,
          album: tags.album,
          date: tags.date,
          coverBytes: pngCover,
          coverMime: 'image/png',
        ));
    final read = FlacTagger.readTags(tagged)!;
    expect(read.fields['TITLE'], '新歌名');
    expect(read.fields['ARTIST'], '歌手甲 / 歌手乙');
    expect(read.fields['ALBUM'], '专辑名');
    expect(read.fields['DATE'], '2022-03-02');
    expect(read.pictureBytes, pngCover.length);
    // STREAMINFO 仍是第一块且内容不变；音频段逐字节一致
    final srcStart = FlacTagger.audioStartOffset(src);
    expect(tagged[4] & 0x7F, 0);
    expect(
      Uint8List.sublistView(tagged, 8, 8 + 34),
      Uint8List.sublistView(src, 8, 8 + 34),
    );
    expect(audioOf(tagged), audioOf(src));
    expect(srcStart, greaterThan(0));
  });

  test('已有标签块时替换不叠加；其余块保留', () {
    final src = flacWithOldTags();
    final tagged = FlacTagger.buildTaggedFlac(
        src,
        MediaTags(
          title: '新标题',
          artist: '新歌手',
          coverBytes: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 5, 6]),
          coverMime: 'image/jpeg',
        ));
    expect(countBlocks(tagged, 4), 1, reason: 'VORBIS_COMMENT 只能有一块');
    expect(countBlocks(tagged, 6), 1, reason: 'PICTURE 只能有一块');
    expect(countBlocks(tagged, 3), 1, reason: 'SEEKTABLE 应保留');
    final read = FlacTagger.readTags(tagged)!;
    expect(read.fields['TITLE'], '新标题');
    expect(read.fields['ARTIST'], '新歌手');
    expect(read.pictureBytes, 6);
    expect(audioOf(tagged), audioOf(src));
  });

  test('封面缺失时只写文字字段，不生成 PICTURE 块', () {
    final tagged = FlacTagger.buildTaggedFlac(syntheticFlac(), tags);
    expect(countBlocks(tagged, 6), 0);
    expect(FlacTagger.readTags(tagged)!.fields['TITLE'], '新歌名');
  });

  test('歌词 + 音轨号：LYRICS / TRACKNUMBER / TOTALTRACKS 写入并回读', () {
    const lrc = '[00:00.06]不敢回看\n[00:02.26]左顾右盼';
    final tagged = FlacTagger.buildTaggedFlac(
        syntheticFlac(),
        MediaTags(
          title: tags.title,
          artist: tags.artist,
          album: tags.album,
          date: tags.date,
          lyrics: lrc,
          trackNumber: 3,
          trackTotal: 12,
        ));
    final read = FlacTagger.readTags(tagged)!;
    expect(read.fields['LYRICS'], lrc);
    expect(read.fields['TRACKNUMBER'], '3');
    expect(read.fields['TOTALTRACKS'], '12');
    expect(read.fields['TITLE'], '新歌名');
    expect(audioOf(tagged), audioOf(syntheticFlac()));
  });

  test('无歌词/无音轨号参数 → 文件里无此三字段', () {
    final tagged = FlacTagger.buildTaggedFlac(syntheticFlac(), tags);
    final read = FlacTagger.readTags(tagged)!;
    expect(read.fields.containsKey('LYRICS'), isFalse);
    expect(read.fields.containsKey('TRACKNUMBER'), isFalse);
    expect(read.fields.containsKey('TOTALTRACKS'), isFalse);
  });

  test('tagFile 落盘：歌词+音轨号回读一致（自检通过才算 ok）', () async {
    final dir = await Directory.systemTemp.createTemp('flac_tag_lyr');
    addTearDown(() => dir.delete(recursive: true));
    final f = File('${dir.path}/t.flac');
    await f.writeAsBytes(syntheticFlac());
    final r = await FlacTagger.tagFileDetailed(
        f.path,
        const MediaTags(
          title: '歌',
          lyrics: '[00:01.00]词',
          trackNumber: 2,
          trackTotal: 9,
        ));
    expect(r.ok, isTrue, reason: r.error ?? '');
    final read = FlacTagger.readTags(await f.readAsBytes())!;
    expect(read.fields['LYRICS'], '[00:01.00]词');
    expect(read.fields['TRACKNUMBER'], '2');
    expect(read.fields['TOTALTRACKS'], '9');
  });

  test('非 FLAC 输入抛 FormatException', () {
    expect(
      () => FlacTagger.buildTaggedFlac(
          Uint8List.fromList('not audio'.codeUnits), tags),
      throwsFormatException,
    );
  });

  test('tagFile 落盘往返；坏文件返回 false 且原文件不毁', () async {
    final dir = await Directory.systemTemp.createTemp('flac_tag_test');
    addTearDown(() => dir.delete(recursive: true));
    final f = File('${dir.path}/ok.flac');
    await f.writeAsBytes(syntheticFlac());
    final ok = await FlacTagger.tagFile(
        f.path,
        MediaTags(
          title: '落盘标题',
          artist: '歌手',
          album: '专辑',
          date: '2020-01-01',
          coverBytes: pngCover,
          coverMime: 'image/png',
        ));
    expect(ok, isTrue);
    final read = FlacTagger.readTags(await f.readAsBytes())!;
    expect(read.fields['TITLE'], '落盘标题');
    expect(read.pictureBytes, pngCover.length);

    final bad = File('${dir.path}/bad.flac');
    final badBytes = Uint8List.fromList('garbage'.codeUnits);
    await bad.writeAsBytes(badBytes);
    expect(await FlacTagger.tagFile(bad.path, tags), isFalse);
    expect(await bad.readAsBytes(), badBytes, reason: '失败必须保留原文件');
  });

  test('嗅探图片 MIME', () {
    expect(sniffImageMime(pngCover), 'image/png');
    expect(
        sniffImageMime(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])),
        'image/jpeg');
    expect(sniffImageMime(Uint8List.fromList([1, 2, 3])), isNull);
  });
}
