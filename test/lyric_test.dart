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
}
