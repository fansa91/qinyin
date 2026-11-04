import 'package:flutter_test/flutter_test.dart';
import 'package:qinyin/models/models.dart';

void main() {
  test('KRC 逐字格式：剥标签留纯文本与时间', () {
    const raw =
        '[60,1470]<0,350,0>不<400,340,0>敢<740,330,0>回<1120,350,0>看\n'
        '[2260,3270]<0,350,0>左<360,260,0>顾';
    final lines = parseLyric(raw);
    expect(lines.length, 2);
    expect(lines[0].text, '不敢回看');
    expect(lines[0].start.inMilliseconds, 60);
    expect(lines[0].duration.inMilliseconds, 1470);
    expect(lines[1].text, '左顾');
  });

  test('普通 LRC 兼容', () {
    final lines = parseLyric('[00:12.50]你好世界\n[01:02.00]第二行');
    expect(lines.length, 2);
    expect(lines[0].start.inMilliseconds, 12500);
    expect(lines[1].text, '第二行');
  });

  test('元信息行跳过，高亮下标计算', () {
    final lines = parseLyric('[ti:歌名]\n[0,1000]<0,1,0>甲\n[5000,1000]<0,1,0>乙');
    expect(lines.length, 2);
    expect(lyricIndexAt(lines, const Duration(milliseconds: 300)), 0);
    expect(lyricIndexAt(lines, const Duration(milliseconds: 6000)), 1);
    expect(lyricIndexAt(lines, const Duration(milliseconds: -1)), -1);
  });

  group('lyricToLrcText（写标签用）', () {
    test('KRC 逐字 → 行级 LRC：剥逐字标记、保留行时间戳', () {
      const raw =
          '[60,1470]<0,350,0>不<400,340,0>敢<740,330,0>回<1120,350,0>看\n'
          '[2260,3270]<0,350,0>左<360,260,0>顾<620,160,0>右<780,200,0>盼';
      expect(lyricToLrcText(raw), '[00:00.06]不敢回看\n[00:02.26]左顾右盼');
    });

    test('真实 seo 样本形状（含 [ti:] 元信息行）→ 元信息不进 LRC', () {
      const raw = '[ti:某歌]\n[10940,4350]<0,350,0>偷<200,190,0>偷\n'
          '[62000,1000]<0,1,0>尾';
      expect(lyricToLrcText(raw), '[00:10.94]偷偷\n[01:02.00]尾');
    });

    test('已是 LRC → 规范化（厘秒两位、按时间重排）', () {
      expect(lyricToLrcText('[01:02.50]后\n[00:12.34]先'),
          '[00:12.34]先\n[01:02.50]后');
    });

    test('纯文本歌词 → 原样返回，不编造时间戳', () {
      expect(lyricToLrcText('  第一行歌词\n第二行歌词  '), '第一行歌词\n第二行歌词');
    });

    test('空歌词 → 空串', () {
      expect(lyricToLrcText(''), '');
      expect(lyricToLrcText('   \n '), '');
    });
  });
}
