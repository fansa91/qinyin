// MP4（m4a）标签写入测试：合成小 MP4 验证 ilst 往返、已有 ilst 替换
// 不叠加、moov 在头/在尾两种布局下 stco 偏移都正确指向 mdat 负载。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qinyin/services/flac_tagger.dart' show MediaTags, sniffImageMime;
import 'package:qinyin/services/mp4_tagger.dart';

Uint8List box(String type, List<int> content) {
  final total = 8 + content.length;
  return Uint8List.fromList([
    (total >> 24) & 0xFF,
    (total >> 16) & 0xFF,
    (total >> 8) & 0xFF,
    total & 0xFF,
    ...type.codeUnits,
    ...content,
  ]);
}

Uint8List fullBox(String type, List<int> content) =>
    box(type, [0, 0, 0, 0, ...content]);

/// 合成最小可解析 MP4：
/// - ftyp(isom)
/// - mdat（96B 可辨识负载）
/// - moov: mvhd 占位 + trak(mdia(minf(stbl(stco→负载起点, stsz, stsc, stts 占位))))
/// stco 先填占位，两遍组装后回填真实偏移。
Uint8List syntheticMp4({required bool moovFirst, List<int>? extraMoov}) {
  final payload = List<int>.generate(96, (i) => (i * 3 + 11) & 0xFF);
  final ftyp = box('ftyp', [...'isom'.codeUnits, 0, 0, 0, 0, ...'isom'.codeUnits]);
  final mdat = box('mdat', payload);

  Uint8List buildMoov(int chunkOffset) {
    final stco = fullBox('stco', [
      0, 0, 0, 1, // entry_count
      (chunkOffset >> 24) & 0xFF,
      (chunkOffset >> 16) & 0xFF,
      (chunkOffset >> 8) & 0xFF,
      chunkOffset & 0xFF,
    ]);
    final stbl = box('stbl', [...stco, ...box('stsz', List.filled(12, 0))]);
    final mdia = box('mdia', [
      ...box('minf', [...stbl]),
    ]);
    final trak = box('trak', [...mdia]);
    return box('moov', [
      ...fullBox('mvhd', List.filled(100, 0)),
      ...trak,
      ...?extraMoov,
    ]);
  }

  // 第一遍量 moov 长度，再算 chunk 偏移回填
  var moov = buildMoov(0);
  final chunkOffset =
      moovFirst ? ftyp.length + moov.length + 8 : ftyp.length + 8;
  moov = buildMoov(chunkOffset);
  return Uint8List.fromList([
    ...ftyp,
    if (moovFirst) ...moov,
    ...mdat,
    if (!moovFirst) ...moov,
  ]);
}

/// 带旧 ilst 的 moov 片段（旧标题 + 一个我们不写的 ©too 条目，须保留）
List<int> moovWithOldIlst() {
  Uint8List dataAtom(int type, List<int> payload) => box('data', [
        (type >> 24) & 0xFF,
        (type >> 16) & 0xFF,
        (type >> 8) & 0xFF,
        type & 0xFF,
        0, 0, 0, 0,
        ...payload,
      ]);
  Uint8List item(String key, String value) =>
      box(key, [...dataAtom(1, value.codeUnits)]);
  final ilst = box('ilst', [
    ...item('\u00A9nam', 'Old Title'),
    ...item('\u00A9too', 'keepme'),
  ]);
  final hdlr = box('hdlr', [
    0, 0, 0, 0, 0, 0, 0, 0,
    ...'mdir'.codeUnits,
    ...List.filled(12, 0),
    0,
  ]);
  final meta = fullBox('meta', [...hdlr, ...ilst]);
  final udta = box('udta', [...meta]);
  return udta;
}

Uint8List payloadOf(Uint8List mp4) {
  // 定位 mdat 并取其负载
  var off = 0;
  while (off + 8 <= mp4.length) {
    final size = ByteData.sublistView(mp4, off, off + 4).getUint32(0);
    final type = String.fromCharCodes(mp4.sublist(off + 4, off + 8));
    if (type == 'mdat') return Uint8List.sublistView(mp4, off + 8, off + size);
    off += size;
  }
  throw StateError('no mdat');
}

void main() {
  final jpegCover = Uint8List.fromList(
      [0xFF, 0xD8, 0xFF, 0xE0, ...List<int>.generate(48, (i) => i)]);
  final tags = MediaTags(
    title: '标题A',
    artist: '歌手B',
    album: '专辑C',
    date: '2016-07-26',
    coverBytes: jpegCover,
    coverMime: 'image/jpeg',
  );

  for (final moovFirst in [true, false]) {
    final layout = moovFirst ? 'moov 在 mdat 前' : 'moov 在 mdat 后';
    test('往返（$layout）：四字段+封面，stco 仍指向原负载', () {
      final src = syntheticMp4(moovFirst: moovFirst);
      final beforeChunk = Mp4Tagger.firstChunkSample(src);
      final tagged = Mp4Tagger.buildTaggedMp4(src, tags);
      final read = Mp4Tagger.readTags(tagged);
      expect(read['\u00A9nam'], '标题A');
      expect(read['\u00A9ART'], '歌手B');
      expect(read['\u00A9alb'], '专辑C');
      expect(read['\u00A9day'], '2016-07-26');
      expect(read['covr'], jpegCover.length);
      // mdat 负载逐字节不变，且 stco 定位到的首 chunk 与写前一致
      expect(payloadOf(tagged), payloadOf(src));
      expect(Mp4Tagger.firstChunkSample(tagged), beforeChunk);
    });
  }

  test('已有 ilst 时：我们的键替换不叠加，其他条目保留', () {
    final src = syntheticMp4(moovFirst: false, extraMoov: moovWithOldIlst());
    final tagged = Mp4Tagger.buildTaggedMp4(src, tags);
    final read = Mp4Tagger.readTags(tagged);
    expect(read['\u00A9nam'], '标题A', reason: '旧标题应被替换');
    expect(read['\u00A9too'], 'keepme', reason: '无关条目应保留');
    // ©nam 条目只能出现一次：直接数原始字节里的 ©nam 盒型标记
    var count = 0;
    for (var i = 0; i + 4 <= tagged.length; i++) {
      if (tagged[i] == 0xA9 &&
          tagged[i + 1] == 0x6E &&
          tagged[i + 2] == 0x61 &&
          tagged[i + 3] == 0x6D) {
        count++;
      }
    }
    expect(count, 1, reason: 'ilst 里 ©nam 条目只能有一份');
    expect(Mp4Tagger.firstChunkSample(tagged), Mp4Tagger.firstChunkSample(src));
  });

  test('封面缺失时只写文字；webp 封面不进 covr（MP4 只认 jpeg/png）', () {
    final src = syntheticMp4(moovFirst: true);
    final tagged = Mp4Tagger.buildTaggedMp4(
        src,
        const MediaTags(
          title: '只有文字',
          coverBytes: null,
        ));
    final read = Mp4Tagger.readTags(tagged);
    expect(read['\u00A9nam'], '只有文字');
    expect(read.containsKey('covr'), isFalse);

    final webp = Uint8List.fromList([
      ...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBP'.codeUnits, 1, 2, 3,
    ]);
    expect(sniffImageMime(webp), 'image/webp');
    final tagged2 = Mp4Tagger.buildTaggedMp4(
        src,
        MediaTags(title: 'x', coverBytes: webp, coverMime: 'image/webp'));
    expect(Mp4Tagger.readTags(tagged2).containsKey('covr'), isFalse);
  });

  test('非 MP4 输入抛 FormatException；tagFile 失败不毁原文件', () async {
    expect(
      () => Mp4Tagger.buildTaggedMp4(
          Uint8List.fromList('junk'.codeUnits), tags),
      throwsFormatException,
    );
    final dir = await Directory.systemTemp.createTemp('mp4_tag_test');
    addTearDown(() => dir.delete(recursive: true));
    final f = File('${dir.path}/ok.m4a');
    await f.writeAsBytes(syntheticMp4(moovFirst: true));
    expect(await Mp4Tagger.tagFile(f.path, tags), isTrue);
    expect(Mp4Tagger.readTags(await f.readAsBytes())['\u00A9nam'], '标题A');

    final bad = File('${dir.path}/bad.m4a');
    final junk = Uint8List.fromList(List.filled(64, 7));
    await bad.writeAsBytes(junk);
    expect(await Mp4Tagger.tagFile(bad.path, tags), isFalse);
    expect(await bad.readAsBytes(), junk);
  });
}
