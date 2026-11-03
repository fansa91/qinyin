import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'flac_tagger.dart' show MediaTags;

/// MP4（.m4a）标签写入：moov/udta/meta/ilst 原子（©nam/©ART/©alb/©day/covr），
/// 纯 Dart 原子级改写。
///
/// 偏移安全：重建 moov 后若 mdat 位于 moov 之后，mdat 绝对偏移随之变化，
/// 同步修正全部 stco/co64 条目（+delta）；moov 在 mdat 之后则偏移不变。
/// mdat 负载字节原样复制。已有 ilst 中我们写的键整体替换不叠加，其余
/// 条目保留。
/// 落盘安全口径与 FLAC 一致：临时文件 → 回读校验（标签可读 + 首个 chunk
/// 经 stco 定位与源一致）→ rename；失败保留原文件、返回 false。
class Mp4Tagger {
  static const _kTitle = '\u00A9nam';
  static const _kArtist = '\u00A9ART';
  static const _kAlbum = '\u00A9alb';
  static const _kDay = '\u00A9day';
  static const _kCover = 'covr';
  static const _ourKeys = {_kTitle, _kArtist, _kAlbum, _kDay, _kCover};
  static const _containers = {
    'moov',
    'trak',
    'mdia',
    'minf',
    'stbl',
    'udta',
    'ilst',
    'meta',
  };

  // ---------- box 树 ----------

  static String _typeOf(Uint8List b, int off) =>
      String.fromCharCodes(b.sublist(off, off + 4));

  static int _sizeOf(Uint8List b, int off, int limit) {
    final s32 = ByteData.sublistView(b, off, off + 4).getUint32(0);
    if (s32 == 1) {
      return ByteData.sublistView(b, off + 8, off + 16).getUint64(0);
    }
    if (s32 == 0) return limit - off;
    return s32;
  }

  static int _headerOf(Uint8List b, int off) {
    final s32 = ByteData.sublistView(b, off, off + 4).getUint32(0);
    return s32 == 1 ? 16 : 8;
  }

  /// 顶层原子表：(type, start, totalSize, headerSize)
  static List<({String type, int start, int size, int header})> _topLevel(
      Uint8List b) {
    final out = <({String type, int start, int size, int header})>[];
    var off = 0;
    while (off + 8 <= b.length) {
      final size = _sizeOf(b, off, b.length);
      if (size < 8 || off + size > b.length) break;
      out.add((
        type: _typeOf(b, off + 4),
        start: off,
        size: size,
        header: _headerOf(b, off),
      ));
      off += size;
    }
    return out;
  }

  static _Box _parseBox(Uint8List b, int start, int totalSize,
      {bool forceContainer = false}) {
    final header = _headerOf(b, start);
    final type = _typeOf(b, start + 4);
    final contentStart = start + header;
    final contentEnd = start + totalSize;
    if (_containers.contains(type) || forceContainer) {
      var childStart = contentStart;
      Uint8List? prefix;
      if (type == 'meta') {
        // full box：4 字节 version/flags 后才是子原子
        prefix = Uint8List.fromList(b.sublist(childStart, childStart + 4));
        childStart += 4;
      }
      final children = <_Box>[];
      var off = childStart;
      while (off + 8 <= contentEnd) {
        final sz = _sizeOf(b, off, contentEnd);
        if (sz < 8 || off + sz > contentEnd) break;
        // ilst 的条目盒（©nam 等）内容是 data 原子序列，按容器解析
        children.add(_parseBox(b, off, sz, forceContainer: type == 'ilst'));
        off += sz;
      }
      return _Box(type, children: children, prefix: prefix);
    }
    return _Box(type,
        leaf: Uint8List.fromList(b.sublist(contentStart, contentEnd)));
  }

  static Uint8List _serialize(_Box box) {
    final body = BytesBuilder();
    if (box.prefix != null) body.add(box.prefix!);
    if (box.children != null) {
      for (final c in box.children!) {
        body.add(_serialize(c));
      }
    } else {
      body.add(box.leaf!);
    }
    final content = body.toBytes();
    final total = 8 + content.length;
    final out = BytesBuilder();
    final sz = ByteData(4)..setUint32(0, total);
    out.add(sz.buffer.asUint8List());
    out.add(latin1.encode(box.type));
    out.add(content);
    return out.toBytes();
  }

  static _Box? _child(_Box box, String type) {
    for (final c in box.children ?? const <_Box>[]) {
      if (c.type == type) return c;
    }
    return null;
  }

  // ---------- ilst 构造 / 读取 ----------

  static _Box _dataAtom(int dataType, List<int> payload) {
    final content = BytesBuilder()
      ..add((ByteData(4)..setUint32(0, dataType)).buffer.asUint8List())
      ..add([0, 0, 0, 0]) // locale
      ..add(payload);
    return _Box('data', leaf: content.toBytes());
  }

  static _Box _textItem(String key, String value) =>
      _Box(key, children: [_dataAtom(1, utf8.encode(value))]);

  static List<_Box> _ourItems(MediaTags tags) {
    return [
      if (tags.title.isNotEmpty) _textItem(_kTitle, tags.title),
      if (tags.artist.isNotEmpty) _textItem(_kArtist, tags.artist),
      if (tags.album.isNotEmpty) _textItem(_kAlbum, tags.album),
      if (tags.date != null && tags.date!.isNotEmpty)
        _textItem(_kDay, tags.date!),
      if (tags.coverBytes != null &&
          (tags.coverMime == 'image/jpeg' || tags.coverMime == 'image/png'))
        _Box(_kCover, children: [
          _dataAtom(tags.coverMime == 'image/png' ? 14 : 13,
              tags.coverBytes!.toList()),
        ]),
    ];
  }

  static _Box _newMeta() {
    final hdlr = _Box('hdlr',
        leaf: Uint8List.fromList([
          0, 0, 0, 0, // version/flags
          0, 0, 0, 0, // pre_defined
          0x6D, 0x64, 0x69, 0x72, // 'mdir'
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // reserved
          0, // name（空串 NUL 结尾）
        ]));
    return _Box('meta',
        prefix: Uint8List.fromList([0, 0, 0, 0]),
        children: [hdlr, _Box('ilst', children: [])]);
  }

  /// 定位 ilst：优先 moov/udta/meta/ilst，其次 moov/meta/ilst；
  /// 都没有则在 moov 下新建 udta>meta>ilst。返回 ilst box 本体。
  static _Box _locateOrCreateIlst(_Box moov) {
    final udta = _child(moov, 'udta');
    if (udta != null) {
      final meta = _child(udta, 'meta');
      if (meta != null) {
        final ilst = _child(meta, 'ilst');
        if (ilst != null) return ilst;
        final created = _Box('ilst', children: []);
        meta.children!.add(created);
        return created;
      }
    }
    final metaDirect = _child(moov, 'meta');
    if (metaDirect != null) {
      final ilst = _child(metaDirect, 'ilst');
      if (ilst != null) return ilst;
      final created = _Box('ilst', children: []);
      metaDirect.children!.add(created);
      return created;
    }
    final newUdta = udta ?? _Box('udta', children: []);
    if (udta == null) moov.children!.add(newUdta);
    final meta = _newMeta();
    newUdta.children!.add(meta);
    return _child(meta, 'ilst')!;
  }

  static void _patchChunkOffsets(_Box box, int delta) {
    if (box.children != null) {
      for (final c in box.children!) {
        _patchChunkOffsets(c, delta);
      }
      return;
    }
    if (box.type != 'stco' && box.type != 'co64') return;
    final data = ByteData.sublistView(box.leaf!);
    final count = data.getUint32(4);
    if (box.type == 'stco') {
      for (var i = 0; i < count; i++) {
        data.setUint32(8 + i * 4, data.getUint32(8 + i * 4) + delta);
      }
    } else {
      for (var i = 0; i < count; i++) {
        data.setUint64(8 + i * 8, data.getUint64(8 + i * 8) + delta);
      }
    }
  }

  static int? _firstChunkOffset(_Box box) {
    if (box.children != null) {
      for (final c in box.children!) {
        final v = _firstChunkOffset(c);
        if (v != null) return v;
      }
      return null;
    }
    if (box.type == 'stco' && box.leaf!.length >= 12) {
      return ByteData.sublistView(box.leaf!).getUint32(8);
    }
    if (box.type == 'co64' && box.leaf!.length >= 16) {
      return ByteData.sublistView(box.leaf!).getUint64(8);
    }
    return null;
  }

  /// 纯函数：给 MP4 字节流写入标签，返回新字节流（不合规输入抛
  /// FormatException）。
  static Uint8List buildTaggedMp4(Uint8List src, MediaTags tags) {
    final top = _topLevel(src);
    final moovIdx = top.indexWhere((a) => a.type == 'moov');
    if (moovIdx < 0) throw const FormatException('MP4 缺 moov 原子');
    final moovAtom = top[moovIdx];
    final moov = _parseBox(src, moovAtom.start, moovAtom.size);
    final ilst = _locateOrCreateIlst(moov);
    ilst.children!
        .removeWhere((item) => _ourKeys.contains(item.type));
    ilst.children!.addAll(_ourItems(tags));
    var newMoov = _serialize(moov);
    final delta = newMoov.length - moovAtom.size;
    if (delta != 0 &&
        top.any((a) => a.type == 'mdat' && a.start > moovAtom.start)) {
      // mdat 在 moov 之后：chunk 绝对偏移要随 moov 尺寸变化平移
      _patchChunkOffsets(moov, delta);
      newMoov = _serialize(moov);
    }
    final out = BytesBuilder();
    for (var i = 0; i < top.length; i++) {
      if (i == moovIdx) {
        out.add(newMoov);
      } else {
        out.add(Uint8List.sublistView(src, top[i].start, top[i].start + top[i].size));
      }
    }
    // 顶层表之外的尾部残余（若有）原样保留
    final covered = top.isEmpty ? 0 : top.last.start + top.last.size;
    if (covered < src.length) {
      out.add(Uint8List.sublistView(src, covered));
    }
    return out.toBytes();
  }

  /// 回读 ilst（供校验与单测）：文本键→字符串，covr→字节数；无 ilst 返回空表
  static Map<String, Object> readTags(Uint8List bytes) {
    final out = <String, Object>{};
    try {
      final top = _topLevel(bytes);
      final moovAtom = top.where((a) => a.type == 'moov').firstOrNull;
      if (moovAtom == null) return out;
      final moov = _parseBox(bytes, moovAtom.start, moovAtom.size);
      _Box? ilst;
      final udta = _child(moov, 'udta');
      final meta = (udta != null ? _child(udta, 'meta') : null) ??
          _child(moov, 'meta');
      if (meta != null) ilst = _child(meta, 'ilst');
      if (ilst == null) return out;
      for (final item in ilst.children ?? const <_Box>[]) {
        final data = _child(item, 'data');
        if (data == null || data.leaf == null || data.leaf!.length < 8) {
          continue;
        }
        final type = ByteData.sublistView(data.leaf!).getUint32(0);
        final payload = Uint8List.sublistView(data.leaf!, 8);
        if (item.type == _kCover) {
          out[item.type] = payload.length;
        } else if (type == 1) {
          out[item.type] = utf8.decode(payload, allowMalformed: true);
        }
      }
      return out;
    } catch (_) {
      return out;
    }
  }

  /// 经首个 stco/co64 条目取出首 chunk 的前 n 字节（偏移正确性校验用；
  /// n 远小于真实 chunk 大小，确保落在音频负载内）
  static Uint8List? firstChunkSample(Uint8List bytes, [int n = 64]) {
    try {
      final top = _topLevel(bytes);
      final moovAtom = top.where((a) => a.type == 'moov').firstOrNull;
      if (moovAtom == null) return null;
      final moov = _parseBox(bytes, moovAtom.start, moovAtom.size);
      final off = _firstChunkOffset(moov);
      if (off == null || off >= bytes.length) return null;
      final end = (off + n).clamp(0, bytes.length);
      return Uint8List.sublistView(bytes, off, end);
    } catch (_) {
      return null;
    }
  }

  /// 给文件写标签：成功返回 true；失败保留原文件、返回 false（不抛）。
  static Future<bool> tagFile(String path, MediaTags tags) async {
    final tmp = File('$path.qytag');
    try {
      final src = await File(path).readAsBytes();
      final tagged = buildTaggedMp4(src, tags);
      // 校验：标签回读一致 + stco 定位到的首 chunk 与源一致（偏移没写坏）
      final read = readTags(tagged);
      if (tags.title.isNotEmpty && read[_kTitle] != tags.title) return false;
      if (tags.artist.isNotEmpty && read[_kArtist] != tags.artist) {
        return false;
      }
      final before = firstChunkSample(src);
      final after = firstChunkSample(tagged);
      if (before == null || after == null || before.length != after.length) {
        return false;
      }
      for (var i = 0; i < before.length; i++) {
        if (before[i] != after[i]) return false;
      }
      await tmp.writeAsBytes(tagged, flush: true);
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
}

class _Box {
  final String type;
  Uint8List? leaf;
  List<_Box>? children;
  Uint8List? prefix; // full box 的 version/flags（meta）
  _Box(this.type, {this.leaf, this.children, this.prefix});
}
