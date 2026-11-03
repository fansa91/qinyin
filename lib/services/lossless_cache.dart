import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import 'spade_decrypt.dart';

/// isolate 解密入口（顶层函数）：读加密体文件 → 解密 → 回传产物字节与扩展名
(Uint8List, String) _decryptJob((String, String) args) {
  final bytes = File(args.$1).readAsBytesSync();
  final out = decryptAudioBuffer(bytes, args.$2);
  return (out.bytes, out.extension);
}

/// 无损解密缓存：平台 B 路 lossless 是 CENC 加密体，不能直接播/存，
/// 必须整曲下载后解密成裸 FLAC。本缓存按 track_id 复用解密产物：
/// 命中直接返回本地文件；未命中才下载+解密。
///
/// 落盘在临时目录（系统可回收）：`<tmp>/qinyin_lossless/<track_id>.flac`。
/// 总量上限 [maxBytes]（默认 512MB），超限按文件 mtime 最旧先淘汰（LRU）。
class LosslessCache {
  final Dio _dio;
  final Future<Directory> Function() _dirProvider;
  final int maxBytes;

  /// 测试注入口：替换实际下载实现（url, savePath, onProgress）
  Future<void> Function(
      String url, String savePath, void Function(int, int)? onProgress)?
      downloadFileOverride;

  final Map<String, Future<String>> _inflight = {};

  LosslessCache({
    Dio? dio,
    Future<Directory> Function()? dirProvider,
    this.maxBytes = 512 * 1024 * 1024,
  })  : _dio = dio ?? Dio(),
        _dirProvider = dirProvider ?? _defaultDir;

  static Future<Directory> _defaultDir() async {
    final tmp = await getTemporaryDirectory();
    final d = Directory('${tmp.path}/qinyin_lossless');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<File?> _hitFile(String trackId) async {
    final dir = await _dirProvider();
    for (final ext in const ['.flac', '.m4a']) {
      final f = File('${dir.path}/$trackId$ext');
      if (await f.exists() && await f.length() > 0) return f;
    }
    return null;
  }

  /// 已缓存的解密产物路径（命中顺带刷新 mtime 供 LRU）；未命中返回 null
  Future<String?> cachedPath(String trackId) async {
    final f = await _hitFile(trackId);
    if (f == null) return null;
    try {
      await f.setLastModified(DateTime.now());
    } catch (_) {}
    return f.path;
  }

  /// 备妥一首无损曲目的本地文件：命中缓存免下载/解密；
  /// 否则下载加密体（主链失败走备链）→ isolate 解密 → 落盘并做容量淘汰。
  /// 任何失败抛异常，由调用方决定回落（播放）或报错（下载）。
  Future<String> prepare({
    required String trackId,
    required PlayStream stream,
    void Function(int received, int total)? onProgress,
  }) {
    final running = _inflight[trackId];
    if (running != null) return running;
    final future = _prepare(trackId, stream, onProgress).whenComplete(() {
      _inflight.remove(trackId);
    });
    _inflight[trackId] = future;
    return future;
  }

  Future<String> _prepare(
    String trackId,
    PlayStream stream,
    void Function(int received, int total)? onProgress,
  ) async {
    final hit = await _hitFile(trackId);
    if (hit != null) {
      try {
        await hit.setLastModified(DateTime.now());
      } catch (_) {}
      return hit.path;
    }
    final dir = await _dirProvider();
    final encFile = File('${dir.path}/$trackId.enc.part');
    if (await encFile.exists()) await encFile.delete();
    await _download(stream, encFile.path, onProgress);
    final hexKey = resolveAudioKey(stream.spadeA);
    final (bytes, ext) = await compute(_decryptJob, (encFile.path, hexKey));
    final tmpOut = File('${dir.path}/$trackId$ext.tmp');
    await tmpOut.writeAsBytes(bytes, flush: true);
    final outFile = File('${dir.path}/$trackId$ext');
    if (await outFile.exists()) await outFile.delete();
    await tmpOut.rename(outFile.path);
    if (await encFile.exists()) await encFile.delete();
    await _enforceCap(keepPath: outFile.path);
    return outFile.path;
  }

  Future<void> _download(
    PlayStream stream,
    String savePath,
    void Function(int received, int total)? onProgress,
  ) async {
    final override = downloadFileOverride;
    if (override != null) {
      await override(stream.mainUrl, savePath, onProgress);
      return;
    }
    try {
      await _dio.download(
        stream.mainUrl,
        savePath,
        onReceiveProgress: onProgress,
        options: Options(receiveTimeout: const Duration(minutes: 5)),
      );
    } catch (e) {
      if (stream.backupUrl.isEmpty) rethrow;
      await _dio.download(
        stream.backupUrl,
        savePath,
        onReceiveProgress: onProgress,
        options: Options(receiveTimeout: const Duration(minutes: 5)),
      );
    }
  }

  /// 容量淘汰入口（测试可见）：按当前目录状态执行一次淘汰检查
  @visibleForTesting
  Future<void> evictIfNeeded({required String keepPath}) =>
      _enforceCap(keepPath: keepPath);

  /// 容量淘汰：只统计成品（.flac/.m4a），按 mtime 旧→新删到不超上限
  Future<void> _enforceCap({required String keepPath}) async {
    try {
      final dir = await _dirProvider();
      final files = <File>[];
      var total = 0;
      await for (final e in dir.list()) {
        if (e is File && (e.path.endsWith('.flac') || e.path.endsWith('.m4a'))) {
          files.add(e);
          total += await e.length();
        }
      }
      if (total <= maxBytes) return;
      final stats = <File, DateTime>{};
      for (final f in files) {
        stats[f] = await f.lastModified();
      }
      files.sort((a, b) => stats[a]!.compareTo(stats[b]!));
      for (final f in files) {
        if (total <= maxBytes) break;
        if (f.path == keepPath) continue;
        final len = await f.length();
        await f.delete();
        total -= len;
      }
    } catch (_) {
      // 淘汰失败不影响本次产物可用
    }
  }
}
