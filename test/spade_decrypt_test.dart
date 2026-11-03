// spade 解密器常驻测试：key 推导向量来自真实曲目的交叉验证
// （QISHUI_API.md §15.6：track 7446541749773076496，JS 参考实现与
// Dart 移植版整曲解密 SHA-256 逐字节一致，此处锁住 key 推导这一环）。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qinyin/services/spade_decrypt.dart';

void main() {
  group('spade_a → AES key 推导', () {
    test('真实样本向量与 JS 参考实现一致', () {
      const spadeA = 'nbwTy2+yP/p0sgjKRIEIz0KzEv5fhiTOaIMVz2m0FM9pgCGQkA==';
      const expected = '0aec9132ea44461f965ac036e4ccdbc9';
      expect(decryptSpadeA(spadeA), expected);
      expect(resolveAudioKey(spadeA), expected);
    });

    test('无效 spade_a：推导为空、resolve 抛 FormatException', () {
      expect(decryptSpadeA(''), '');
      expect(decryptSpadeA('!!!not-base64!!!'), '');
      expect(() => resolveAudioKey('invalid-spade-a'),
          throwsA(isA<FormatException>()));
    });

    test('isHexKey 口径', () {
      expect(isHexKey('0aec9132ea44461f965ac036e4ccdbc9'), isTrue);
      expect(isHexKey('0AEC9132EA44461F965AC036E4CCDBC9'), isTrue);
      expect(isHexKey('0aec9132'), isFalse);
      expect(isHexKey('zzec9132ea44461f965ac036e4ccdbc9'), isFalse);
    });
  });

  group('decryptAudioBuffer 入口校验', () {
    test('非法 hex key 直接抛 FormatException', () {
      expect(() => decryptAudioBuffer(Uint8List(0), 'nope'),
          throwsA(isA<FormatException>()));
    });

    test('合法 key 但容器结构无效 → 抛 FormatException（缺 moov）', () {
      expect(
        () => decryptAudioBuffer(
            Uint8List(0), '0aec9132ea44461f965ac036e4ccdbc9'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
