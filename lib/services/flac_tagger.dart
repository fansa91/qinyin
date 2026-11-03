import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 下载标签的统一字段载体（FLAC / M4A 共用）。
class MediaTags {
  final String title;
  final String artist;
  final String album;
  final String? date; // yyyy-MM-dd
  final Uint8List? coverBytes;

  /// 封面 MIME（image/jpeg / image/png / image/webp）；按字节嗅探得出，
  /// 与 coverBytes 同时有值或同时为空。
  final String? coverMime;
  const MediaTags({
    this.title = '',
    this.artist = '',
    this.album = '',
    this.date,
    this.coverBytes,
    this.coverMime,
  });

  bool get hasText =>
      title.isNotEmpty || artist.isNotEmpty || album.isNotEmpty || date != null;
}

/// 按魔数嗅探图片 MIME；不认识返回 null
String? sniffImageMime(Uint8List b) {
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47 &&
      b[4] == 0x0D &&
      b[5] == 0x0A &&
      b[6] == 0x1A &&
      b[7] == 0x0A) {
    return 'image/png';
  }
  if (b.length >= 12 &&
      b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && // RIFF
      b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
    // WEBP
    return 'image/webp';
  }
  return null;
}

class _FlacBlock {
  final int type;
  final Uint8List data;
  const _FlacBlock(this.type, this.data);
}

class _FlacParts {
  final Uint8List streamInfo;
  final List<_FlacBlock> others; // 不含 STREAMINFO / VORBIS_COMMENT / PICTURE
  final int audioStart;
  const _FlacParts(this.streamInfo, this.others, this.audioStart);
}

/// FLAC 标签写入（Vorbis Comment block 4 + PICTURE block 6），纯 Dart。
///
/// 块处理口径：STREAMINFO 原样保留且仍是第一块；已有的 VORBIS_COMMENT /
/// PICTURE 整体替换不叠加；其余块（SEEKTABLE / PADDING / APPLICATION 等）
/// 原样保留；音频帧数据字节级原样搬运。
/// 落盘安全口径：写临时文件 → 回读校验（魔数 / STREAMINFO 一致 / 音频段
/// 一致 / 标签可回读）→ rename 替换；任何失败保留原文件并返回 false。
class FlacTagger {
  static const _vendor = 'qinyin';

  static _FlacParts _parse(Uint8List bytes) {
    if (bytes.length < 8 ||
        bytes[0] != 0x66 || // f
        bytes[1] != 0x4C || // L
        bytes[2] != 0x61 || // a
        bytes[3] != 0x43) {
      // C
      throw const FormatException('不是 FLAC 文件（缺 fLaC 魔数）');
    }
    var offset = 4;
    Uint8List? streamInfo;
    final others = <_FlacBlock>[];
    while (true) {
      if (offset + 4 > bytes.length) {
        throw const FormatException('FLAC metadata 块截断');
      }
      final header = bytes[offset];
      final isLast = (header & 0x80) != 0;
      final type = header & 0x7F;
      final len =
          (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3];
      final start = offset + 4;
      if (start + len > bytes.length) {
        throw const FormatException('FLAC metadata 块越界');
      }
      final data = Uint8List.sublistView(bytes, start, start + len);
      if (type == 0) {
        streamInfo ??= Uint8List.fromList(data);
      } else if (type != 4 && type != 6) {
        others.add(_FlacBlock(type, Uint8List.fromList(data)));
      }
      offset = start + len;
      if (isLast) break;
    }
    if (streamInfo == null) {
      throw const FormatException('FLAC 缺 STREAMINFO 块');
    }
    return _FlacParts(streamInfo, others, offset);
  }

  static Uint8List _vorbisComment(MediaTags tags) {
    final fields = <String>[
      if (tags.title.isNotEmpty) 'TITLE=${tags.title}',
      if (tags.artist.isNotEmpty) 'ARTIST=${tags.artist}',
      if (tags.album.isNotEmpty) 'ALBUM=${tags.album}',
      if (tags.date != null && tags.date!.isNotEmpty) 'DATE=${tags.date}',
    ];
    final out = BytesBuilder();
    void u32le(int v) => out.add([
          v & 0xFF,
          (v >> 8) & 0xFF,
          (v >> 16) & 0xFF,
          (v >> 24) & 0xFF,
        ]);
    final vendor = utf8.encode(_vendor);
    u32le(vendor.length);
    out.add(vendor);
    u32le(fields.length);
    for (final f in fields) {
      final b = utf8.encode(f);
      u32le(b.length);
      out.add(b);
    }
    return out.toBytes();
  }

  static Uint8List _picture(MediaTags tags) {
    final mime = ascii.encode(tags.coverMime!);
    final data = tags.coverBytes!;
    final out = BytesBuilder();
    void u32be(int v) => out.add([
          (v >> 24) & 0xFF,
          (v >> 16) & 0xFF,
          (v >> 8) & 0xFF,
          v & 0xFF,
        ]);
    u32be(3); // picture type: front cover
    u32be(mime.length);
    out.add(mime);
    u32be(0); // description 为空
    u32be(0); // width
    u32be(0); // height
    u32be(0); // bits per pixel
    u32be(0); // colors
    u32be(data.length);
    out.add(data);
    return out.toBytes();
  }

  /// 纯函数：把 tags 写进 FLAC 字节流，返回新字节流（不合规输入抛
  /// FormatException）。音频段与 STREAMINFO 字节级不变。
  static Uint8List buildTaggedFlac(Uint8List src, MediaTags tags) {
    final parts = _parse(src);
    final blocks = <_FlacBlock>[
      _FlacBlock(0, parts.streamInfo),
      ...parts.others,
      _FlacBlock(4, _vorbisComment(tags)),
      if (tags.coverBytes != null && tags.coverMime != null)
        _FlacBlock(6, _picture(tags)),
    ];
    final out = BytesBuilder();
    out.add([0x66, 0x4C, 0x61, 0x43]); // fLaC
    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      final isLast = i == blocks.length - 1;
      out.add([
        (isLast ? 0x80 : 0) | b.type,
        (b.data.length >> 16) & 0xFF,
        (b.data.length >> 8) & 0xFF,
        b.data.length & 0xFF,
      ]);
      out.add(b.data);
    }
    out.add(Uint8List.sublistView(src, parts.audioStart));
    return out.toBytes();
  }

  /// 回读标签（供校验与单测）：返回字段表与封面字节数；非 FLAC 返回 null
  static ({Map<String, String> fields, int pictureBytes})? readTags(
      Uint8List bytes) {
    try {
      if (bytes.length < 8 || bytes[0] != 0x66) return null;
      var offset = 4;
      Map<String, String>? fields;
      var pictureBytes = 0;
      while (offset + 4 <= bytes.length) {
        final header = bytes[offset];
        final isLast = (header & 0x80) != 0;
        final type = header & 0x7F;
        final len = (bytes[offset + 1] << 16) |
            (bytes[offset + 2] << 8) |
            bytes[offset + 3];
        final start = offset + 4;
        if (start + len > bytes.length) return null;
        if (type == 4) {
          fields = _parseVorbisComment(
              Uint8List.sublistView(bytes, start, start + len));
        } else if (type == 6) {
          pictureBytes = _pictureDataLength(
              Uint8List.sublistView(bytes, start, start + len));
        }
        offset = start + len;
        if (isLast) break;
      }
      if (fields == null && pictureBytes == 0) return null;
      return (fields: fields ?? const {}, pictureBytes: pictureBytes);
    } catch (_) {
      return null;
    }
  }

  static Map<String, String> _parseVorbisComment(Uint8List d) {
    final out = <String, String>{};
    var p = 0;
    int u32le() {
      final v = d[p] | (d[p + 1] << 8) | (d[p + 2] << 16) | (d[p + 3] << 24);
      p += 4;
      return v;
    }

    final vendorLen = u32le();
    p += vendorLen;
    final count = u32le();
    for (var i = 0; i < count; i++) {
      final len = u32le();
      final s = utf8.decode(Uint8List.sublistView(d, p, p + len));
      p += len;
      final eq = s.indexOf('=');
      if (eq > 0) out[s.substring(0, eq).toUpperCase()] = s.substring(eq + 1);
    }
    return out;
  }

  static int _pictureDataLength(Uint8List d) {
    var p = 0;
    int u32be() {
      final v = (d[p] << 24) | (d[p + 1] << 16) | (d[p + 2] << 8) | d[p + 3];
      p += 4;
      return v;
    }

    u32be(); // type
    final mimeLen = u32be();
    p += mimeLen;
    final descLen = u32be();
    p += descLen;
    u32be();
    u32be();
    u32be();
    u32be(); // w/h/depth/colors
    return u32be();
  }

  /// 音频段（首个 metadata 块之后）在文件中的起始偏移；非 FLAC 返回 -1
  static int audioStartOffset(Uint8List bytes) {
    try {
      return _parse(bytes).audioStart;
    } catch (_) {
      return -1;
    }
  }

  /// 给文件写标签：成功返回 true；失败保留原文件、返回 false（不抛）。
  static Future<bool> tagFile(String path, MediaTags tags) async {
    final tmp = File('$path.qytag');
    try {
      final src = await File(path).readAsBytes();
      final tagged = buildTaggedFlac(src, tags);
      // 落盘前自检：STREAMINFO 与音频段必须与源逐字节一致，标签可回读
      final srcParts = _parse(src);
      final newParts = _parse(tagged);
      if (!_bytesEqual(srcParts.streamInfo, newParts.streamInfo)) return false;
      if (src.length - srcParts.audioStart !=
          tagged.length - newParts.audioStart) {
        return false;
      }
      for (var i = 0; i < src.length - srcParts.audioStart; i++) {
        if (src[srcParts.audioStart + i] != tagged[newParts.audioStart + i]) {
          return false;
        }
      }
      final read = readTags(tagged);
      if (read == null) return false;
      if (tags.title.isNotEmpty && read.fields['TITLE'] != tags.title) {
        return false;
      }
      await tmp.writeAsBytes(tagged, flush: true);
      // 校验临时文件可读且大小相符后再替换
      if (await tmp.length() != tagged.length) return false;
      try {
        await tmp.rename(path);
      } on FileSystemException {
        final dest = File(path);
        if (await dest.exists()) await dest.delete();
        await tmp.rename(path);
      }
      return true;
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      return false;
    }
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
