import 'dart:convert';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;

/// spade / CENC 音频解密（纯 Dart 移植）。
///
/// 算法来源：QISHUI_API.md §10 交叉验证的第三方参考实现
/// （tools/qishui-api/src/audioDecryptor.js），2026-11-04 已用真实曲目
/// 与 JS 版整曲对拍（SHA-256 一致），记录见 §15.6。
/// 流程：spade_a → 字节变换得 32 位 hex = AES-128 key → 解析 MP4 的 senc
/// 逐 sample IV、AES-CTR 逐 sample 解密、剥加密 box、enca→mp4a、修 stco；
/// stsd 含 dfLa → 输出裸 FLAC，否则输出净化后的 m4a。

const _encryptedBoxTypes = {
  'senc', 'saio', 'saiz', 'sinf', 'schi', 'tenc', 'schm', 'frma',
};
const _containerBoxTypes = {'moov', 'trak', 'mdia', 'minf', 'stbl', 'stsd'};
const _maxSampleCount = 200000;
const _maxChunkCount = 200000;
const _maxStscEntryCount = 20000;

int _bitCount(int n) {
  var c = 0;
  var v = n;
  while (v != 0) {
    c += v & 1;
    v >>= 1;
  }
  return c;
}

int _decodeBase36(int codePoint) {
  if (codePoint >= 48 && codePoint <= 57) return codePoint - 48;
  if (codePoint >= 97 && codePoint <= 122) return codePoint - 97 + 10;
  return 0xFF;
}

Uint8List _decryptSpadeInner(Uint8List spadeKey) {
  final result = Uint8List(spadeKey.length);
  final buffer = Uint8List(2 + spadeKey.length);
  buffer[0] = 0xFA;
  buffer[1] = 0x55;
  buffer.setRange(2, 2 + spadeKey.length, spadeKey);
  for (var index = 0; index < result.length; index++) {
    var value = (spadeKey[index] ^ buffer[index]) - _bitCount(index) - 21;
    while (value < 0) {
      value += 0xFF;
    }
    result[index] = value;
  }
  return result;
}

String _decryptSpade(Uint8List spadeKeyBytes) {
  final len = spadeKeyBytes.length;
  if (len < 3) return '';
  final paddingLength = (spadeKeyBytes[0] ^ spadeKeyBytes[1] ^ spadeKeyBytes[2]) - 48;
  if (len < paddingLength + 2) return '';
  var end = len - paddingLength;
  if (end > len) end = len;
  if (end < 1) return '';
  final innerInput = Uint8List.sublistView(spadeKeyBytes, 1, end);
  final decodedBuffer = _decryptSpadeInner(innerInput);
  if (decodedBuffer.isEmpty) return '';
  final skipBytes = _decodeBase36(decodedBuffer[0]);
  final decodedMessageLength = len - paddingLength - 2;
  final endIndex = 1 + decodedMessageLength - skipBytes;
  if (endIndex > decodedBuffer.length || endIndex < 1) return '';
  return utf8.decode(
    Uint8List.sublistView(decodedBuffer, 1, endIndex),
    allowMalformed: true,
  );
}

/// spade_a（base64）→ hex key 字符串；失败返回空串
String decryptSpadeA(String spadeA) {
  try {
    var s = spadeA.trim().replaceAll('-', '+').replaceAll('_', '/');
    while (s.length % 4 != 0) {
      s += '=';
    }
    return _decryptSpade(base64.decode(s));
  } catch (_) {
    return '';
  }
}

bool isHexKey(String value) =>
    RegExp(r'^[a-f0-9]{32}$', caseSensitive: false).hasMatch(value.trim());

/// 由 spade_a 推导 AES-128 hex key；无效抛 FormatException
String resolveAudioKey(String spadeA) {
  final hexKey = decryptSpadeA(spadeA).trim();
  if (!isHexKey(hexKey)) {
    throw const FormatException('spade_a 无效，无法推导解密密钥');
  }
  return hexKey.toLowerCase();
}

Uint8List _hexToBytes(String hex) {
  final out = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

int _u32(Uint8List d, int off) {
  if (off < 0 || off + 4 > d.length) {
    throw const FormatException('音频容器结构无效');
  }
  return ByteData.sublistView(d, off, off + 4).getUint32(0, Endian.big);
}

Uint8List _u32Bytes(int v) {
  final b = Uint8List(4);
  ByteData.sublistView(b).setUint32(0, v, Endian.big);
  return b;
}

String _ascii(Uint8List d, int start, int end) =>
    String.fromCharCodes(d.sublist(start, end));

class _Box {
  final int offset;
  final int size;
  final String type;
  final Uint8List data; // box 头（8B）之后的内容
  const _Box(this.offset, this.size, this.type, this.data);
}

_Box? _findBox(Uint8List d, String boxType, [int offset = 0, int? end]) {
  final searchEnd = end ?? d.length;
  var position = offset;
  while (position < searchEnd) {
    if (position + 8 > searchEnd) break;
    final boxSize = _u32(d, position);
    if (boxSize == 0 || boxSize > searchEnd - position || boxSize < 8) break;
    if (_ascii(d, position + 4, position + 8) == boxType) {
      return _Box(position, boxSize, boxType,
          Uint8List.sublistView(d, position + 8, position + boxSize));
    }
    position += boxSize;
  }
  return null;
}

_Box _requireBox(_Box? box, String name) {
  if (box == null) throw FormatException('音频容器缺少 $name box');
  return box;
}

List<int> _parseStsz(Uint8List stszData) {
  final sampleSize = _u32(stszData, 4);
  final sampleCount = _u32(stszData, 8);
  if (sampleCount > _maxSampleCount) {
    throw const FormatException('音频样本数量超过限制');
  }
  if (sampleSize != 0) return List.filled(sampleCount, sampleSize);
  if (12 + sampleCount * 4 > stszData.length) {
    throw const FormatException('stsz box 样本大小数据不完整');
  }
  return [
    for (var i = 0; i < sampleCount; i++) _u32(stszData, 12 + i * 4),
  ];
}

class _StscEntry {
  final int firstChunk;
  final int samplesPerChunk;
  const _StscEntry(this.firstChunk, this.samplesPerChunk);
}

List<_StscEntry> _parseStsc(Uint8List stscData) {
  final entryCount = _u32(stscData, 4);
  if (entryCount > _maxStscEntryCount) {
    throw const FormatException('stsc entry 数量超过限制');
  }
  if (8 + entryCount * 12 > stscData.length) {
    throw const FormatException('stsc box 数据不完整');
  }
  return [
    for (var i = 0; i < entryCount; i++)
      _StscEntry(_u32(stscData, 8 + i * 12), _u32(stscData, 8 + i * 12 + 4)),
  ];
}

/// senc 逐 sample IV（8B → 补零至 16B）
List<Uint8List> _parseSenc(Uint8List sencData) {
  final sampleCount = _u32(sencData, 4);
  if (sampleCount > _maxSampleCount) {
    throw const FormatException('senc 样本数量超过限制');
  }
  if (8 + sampleCount * 8 > sencData.length) {
    throw const FormatException('senc box IV 数据不完整');
  }
  final ivs = <Uint8List>[];
  var position = 8;
  for (var i = 0; i < sampleCount; i++) {
    final iv = Uint8List(16);
    iv.setRange(0, 8, sencData, position);
    ivs.add(iv);
    position += 8;
  }
  return ivs;
}

List<int> _calculateChunkOffsets(
  List<int> sampleSizes,
  List<_StscEntry> stscEntries,
  int chunkCount,
  int baseOffset,
) {
  final offsets = <int>[];
  var currentOffset = baseOffset;
  var sampleIndex = 0;
  for (var chunkIndex = 1; chunkIndex <= chunkCount; chunkIndex++) {
    offsets.add(currentOffset);
    var samplesPerChunk = 0;
    for (var e = 0; e < stscEntries.length; e++) {
      final cur = stscEntries[e];
      final next = e + 1 < stscEntries.length ? stscEntries[e + 1] : null;
      if (chunkIndex >= cur.firstChunk &&
          (next == null || chunkIndex < next.firstChunk)) {
        samplesPerChunk = cur.samplesPerChunk;
        break;
      }
    }
    for (var s = 0; s < samplesPerChunk; s++) {
      if (sampleIndex < sampleSizes.length) {
        currentOffset += sampleSizes[sampleIndex];
      }
      sampleIndex++;
    }
  }
  return offsets;
}

Uint8List _updateStco(Uint8List stcoData, List<int> offsets) {
  final chunkCount = _u32(stcoData, 4);
  if (offsets.length < chunkCount) {
    throw const FormatException('stco 偏移数量不足');
  }
  final out = BytesBuilder();
  out.add(Uint8List.sublistView(stcoData, 0, 8));
  for (var i = 0; i < chunkCount; i++) {
    out.add(_u32Bytes(offsets[i]));
  }
  return out.toBytes();
}

class _TreeContext {
  final List<int> sampleSizes;
  final List<_StscEntry> stscEntries;
  final int chunkCount;
  const _TreeContext(this.sampleSizes, this.stscEntries, this.chunkCount);
}

Uint8List _processBoxTree(
  Uint8List d,
  int offset,
  int size,
  int newMdatOffset,
  _TreeContext context,
) {
  final out = BytesBuilder();
  var position = offset + 8;
  final end = offset + size;
  while (position < end) {
    if (position + 8 > end) {
      out.add(Uint8List.sublistView(d, position, end));
      break;
    }
    final boxSize = _u32(d, position);
    if (boxSize < 8 || boxSize > end - position) {
      out.add(Uint8List.sublistView(d, position, end));
      break;
    }
    final type = _ascii(d, position + 4, position + 8);
    if (_encryptedBoxTypes.contains(type)) {
      position += boxSize;
      continue;
    }
    if (type == 'enca') {
      final inner = _processBoxTree(d, position, boxSize, newMdatOffset, context);
      out.add(_u32Bytes(inner.length + 8));
      out.add(ascii.encode('mp4a'));
      out.add(inner);
      position += boxSize;
      continue;
    }
    if (type == 'stco') {
      final offsets = _calculateChunkOffsets(
          context.sampleSizes, context.stscEntries, context.chunkCount, newMdatOffset);
      final body = _updateStco(
          Uint8List.sublistView(d, position + 8, position + boxSize), offsets);
      out.add(_u32Bytes(body.length + 8));
      out.add(ascii.encode('stco'));
      out.add(body);
      position += boxSize;
      continue;
    }
    if (_containerBoxTypes.contains(type)) {
      final inner = _processBoxTree(d, position, boxSize, newMdatOffset, context);
      out.add(_u32Bytes(inner.length + 8));
      out.add(ascii.encode(type));
      out.add(inner);
      position += boxSize;
      continue;
    }
    out.add(Uint8List.sublistView(d, position, position + boxSize));
    position += boxSize;
  }
  return out.toBytes();
}

/// 在 stsd 中扫描 dfLa box，返回其内容（FLAC 元数据块）
Uint8List? scanFlacMetadata(Uint8List stsdData) {
  for (var index = 4; index + 4 <= stsdData.length; index++) {
    if (stsdData[index] == 0x64 && // d
        stsdData[index + 1] == 0x66 && // f
        stsdData[index + 2] == 0x4C && // L
        stsdData[index + 3] == 0x61) {
      // a
      final boxSize = _u32(stsdData, index - 4);
      if (boxSize >= 8 && index - 4 + boxSize <= stsdData.length) {
        return Uint8List.sublistView(stsdData, index + 4, index - 4 + boxSize);
      }
    }
  }
  return null;
}

Uint8List _decryptSample(Uint8List sample, Uint8List keyBytes, Uint8List iv) {
  final encrypter = enc.Encrypter(
    enc.AES(enc.Key(keyBytes), mode: enc.AESMode.sic, padding: null),
  );
  return Uint8List.fromList(
    encrypter.decryptBytes(enc.Encrypted(sample), iv: enc.IV(iv)),
  );
}

/// 解密结果：字节 + 扩展名（.flac / .m4a）
typedef DecryptedAudio = ({Uint8List bytes, String extension, int sampleCount});

/// CENC 加密音频（MP4 容器）→ 明文音频。与 JS 参考实现逐字节对齐。
DecryptedAudio decryptAudioBuffer(Uint8List input, String hexKey) {
  if (!isHexKey(hexKey)) {
    throw const FormatException('hex_key 必须是 32 位十六进制 AES-128 密钥');
  }
  final d = input;
  final keyBytes = _hexToBytes(hexKey.trim().toLowerCase());

  final ftyp = _findBox(d, 'ftyp');
  final moov = _requireBox(_findBox(d, 'moov'), 'moov');
  final trak = _requireBox(
      _findBox(d, 'trak', moov.offset + 8, moov.offset + moov.size), 'trak');
  final mdia = _requireBox(
      _findBox(d, 'mdia', trak.offset + 8, trak.offset + trak.size), 'mdia');
  final minf = _requireBox(
      _findBox(d, 'minf', mdia.offset + 8, mdia.offset + mdia.size), 'minf');
  final stbl = _requireBox(
      _findBox(d, 'stbl', minf.offset + 8, minf.offset + minf.size), 'stbl');
  final stsd = _requireBox(
      _findBox(d, 'stsd', stbl.offset + 8, stbl.offset + stbl.size), 'stsd');
  final stsz = _requireBox(
      _findBox(d, 'stsz', stbl.offset + 8, stbl.offset + stbl.size), 'stsz');
  final stsc = _requireBox(
      _findBox(d, 'stsc', stbl.offset + 8, stbl.offset + stbl.size), 'stsc');
  final stco = _requireBox(
      _findBox(d, 'stco', stbl.offset + 8, stbl.offset + stbl.size), 'stco');
  final mdat = _requireBox(_findBox(d, 'mdat'), 'mdat');

  var sencBox = _findBox(d, 'senc', stbl.offset + 8, stbl.offset + stbl.size);
  sencBox ??= _findBox(d, 'senc', moov.offset + 8, moov.offset + moov.size);
  final senc = _requireBox(sencBox, 'senc');

  final sampleSizes = _parseStsz(stsz.data);
  final stscEntries = _parseStsc(stsc.data);
  final chunkCount = _u32(stco.data, 4);
  if (chunkCount > _maxChunkCount) {
    throw const FormatException('音频 chunk 数量超过限制');
  }
  if (8 + chunkCount * 4 > stco.data.length) {
    throw const FormatException('stco box 数据不完整');
  }
  final ivs = _parseSenc(senc.data);
  if (ivs.length < sampleSizes.length) {
    throw const FormatException('senc IV 数量少于样本数量');
  }
  final payloadSize = sampleSizes.fold<int>(0, (a, b) => a + b);
  if (payloadSize > mdat.size - 8) {
    throw const FormatException('样本总大小超过 mdat 数据范围');
  }

  final decrypted = <Uint8List>[];
  var sampleOffset = mdat.offset + 8;
  for (var i = 0; i < sampleSizes.length; i++) {
    final size = sampleSizes[i];
    if (sampleOffset + size > d.length) {
      throw const FormatException('音频样本数据不完整');
    }
    decrypted.add(_decryptSample(
      Uint8List.sublistView(d, sampleOffset, sampleOffset + size),
      keyBytes,
      ivs[i],
    ));
    sampleOffset += size;
  }

  final flacMeta = scanFlacMetadata(stsd.data);
  if (flacMeta != null) {
    final out = BytesBuilder();
    out.add(ascii.encode('fLaC'));
    out.add(flacMeta.length > 4
        ? Uint8List.sublistView(flacMeta, 4)
        : flacMeta);
    for (final s in decrypted) {
      out.add(s);
    }
    return (
      bytes: out.toBytes(),
      extension: '.flac',
      sampleCount: sampleSizes.length,
    );
  }

  final context = _TreeContext(sampleSizes, stscEntries, chunkCount);
  final ftypSize = ftyp?.size ?? 0;
  final dummyMoov = _processBoxTree(d, moov.offset, moov.size, 0, context);
  final newMdatOffset = ftypSize + dummyMoov.length + 16;
  final cleanMoovData =
      _processBoxTree(d, moov.offset, moov.size, newMdatOffset, context);
  final out = BytesBuilder();
  if (ftyp != null) {
    out.add(Uint8List.sublistView(d, ftyp.offset, ftyp.offset + ftyp.size));
  }
  out.add(_u32Bytes(cleanMoovData.length + 8));
  out.add(ascii.encode('moov'));
  out.add(cleanMoovData);
  final mdatData = BytesBuilder();
  for (final s in decrypted) {
    mdatData.add(s);
  }
  final mdatBytes = mdatData.toBytes();
  out.add(_u32Bytes(mdatBytes.length + 8));
  out.add(ascii.encode('mdat'));
  out.add(mdatBytes);
  return (
    bytes: out.toBytes(),
    extension: '.m4a',
    sampleCount: sampleSizes.length,
  );
}
