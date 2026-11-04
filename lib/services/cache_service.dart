import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';

/// 缓存占用盘点结果（字节）。三项互不重叠：
/// - [losslessBytes]：无损解密缓存整目录（成品 + 下载/解密中间件）；
/// - [coverBytes]：封面图片磁盘缓存整目录（flutter_cache_manager 默认
///   缓存，组件自带上限 200 个对象 / 30 天过期）；
/// - [tagTempBytes]：下载目录里写标签的临时件（*.qytag）残留。
class CacheBreakdown {
  final int losslessBytes;
  final int coverBytes;
  final int tagTempBytes;
  const CacheBreakdown({
    this.losslessBytes = 0,
    this.coverBytes = 0,
    this.tagTempBytes = 0,
  });

  int get totalBytes => losslessBytes + coverBytes + tagTempBytes;
}

/// 缓存清理机制：只动**缓存类**数据，用户资产（下载目录里的歌曲文件、
/// SharedPreferences 里的收藏/历史/设置/下载记录）一律不碰。
///
/// 盘点（磁盘上会积累的东西）：
/// 1. 无损解密缓存 `<tmp>/qinyin_lossless/`——本服务可测可清；成品有
///    512MB LRU 上限（LosslessCache._enforceCap，每次备曲后执行）；
///    中间件 `*.enc.part` / `*.tmp` 由启动清扫处理。
/// 2. 封面图片缓存 `<tmp>/libCachedImageData/`——CachedNetworkImage 的
///    flutter_cache_manager 默认缓存目录（与本服务共用同一临时目录
///    口径测算）；已有组件级上限（200 对象 / 30 天），清理走官方
///    emptyCache()。
/// 3. 写标签临时件 `*.qytag`——写标签中断（杀进程等）时可能残留在
///    **下载目录**里；后缀是本 App 独有约定，启动清扫只删这一种，
///    宁可少删不误删（下载未完成的半成品 .m4a 与成品同名，无从区分，
///    不在清扫范围）。
/// 4. 内存图片缓存不落盘，不计入占用；清理时由 UI 层顺带 evict。
class CacheService {
  static const String losslessDirName = 'qinyin_lossless';
  static const String coverCacheDirName = 'libCachedImageData';
  static const String tagTempSuffix = '.qytag';

  final Future<Directory> Function() _tmpDirProvider;
  final Future<Directory> Function()? _downloadDirProvider;
  final Future<void> Function() _clearCoverCache;

  CacheService({
    Future<Directory> Function()? tmpDirProvider,
    Future<Directory> Function()? downloadDirProvider,
    Future<void> Function()? clearCoverCache,
  })  : _tmpDirProvider = tmpDirProvider ?? getTemporaryDirectory,
        _downloadDirProvider = downloadDirProvider,
        _clearCoverCache =
            clearCoverCache ?? (() => DefaultCacheManager().emptyCache());

  Future<Directory> _losslessDir() async {
    final tmp = await _tmpDirProvider();
    return Directory('${tmp.path}/$losslessDirName');
  }

  Future<Directory> _coverDir() async {
    final tmp = await _tmpDirProvider();
    return Directory('${tmp.path}/$coverCacheDirName');
  }

  /// 递归汇总目录大小；目录不存在记 0；单个文件 stat 失败跳过不抛。
  static Future<int> dirSize(Directory dir) async {
    if (!await dir.exists()) return 0;
    var total = 0;
    try {
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            total += await e.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  /// 统计当前缓存占用（口径见 [CacheBreakdown]）
  Future<CacheBreakdown> measure() async {
    var tagTemp = 0;
    final dlProvider = _downloadDirProvider;
    if (dlProvider != null) {
      try {
        final dl = await dlProvider();
        if (await dl.exists()) {
          await for (final e in dl.list()) {
            if (e is File && e.path.endsWith(tagTempSuffix)) {
              try {
                tagTemp += await e.length();
              } catch (_) {}
            }
          }
        }
      } catch (_) {}
    }
    return CacheBreakdown(
      losslessBytes: await dirSize(await _losslessDir()),
      coverBytes: await dirSize(await _coverDir()),
      tagTempBytes: tagTemp,
    );
  }

  /// 一键清理全部缓存类数据：无损缓存整目录清空、封面缓存走
  /// emptyCache()、下载目录的 *.qytag 残留删除。
  /// 下载歌曲本体、下载记录、收藏/历史/设置都不动；清理后无损再播
  /// 会重新下载解密、封面会重新拉取，行为不受影响。
  Future<void> clearAll() async {
    // 1) 无损解密缓存：删目录内全部文件（目录本身保留）
    try {
      final dir = await _losslessDir();
      if (await dir.exists()) {
        await for (final e in dir.list()) {
          try {
            await e.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}
    // 2) 封面图片缓存：官方清理（清文件 + 索引库）
    try {
      await _clearCoverCache();
    } catch (_) {}
    // 3) 写标签临时残留
    await _deleteTagTemps();
  }

  /// 启动清扫（保守口径，只删无歧义的孤儿临时件）：
  /// - 无损缓存目录里的 `*.enc.part`（加密体下载中间件）与 `*.tmp`
  ///   （解密产物落盘中间件）——成品是 .flac/.m4a，不会误伤；
  /// - 下载目录里的 `*.qytag`（写标签临时件，本 App 独有后缀）。
  /// 返回删除的件数；全程吞错，绝不因清扫失败影响启动。
  Future<int> sweepOrphanTemps() async {
    var removed = 0;
    try {
      final dir = await _losslessDir();
      if (await dir.exists()) {
        await for (final e in dir.list()) {
          if (e is File &&
              (e.path.endsWith('.enc.part') || e.path.endsWith('.tmp'))) {
            try {
              await e.delete();
              removed++;
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    removed += await _deleteTagTemps();
    return removed;
  }

  Future<int> _deleteTagTemps() async {
    final dlProvider = _downloadDirProvider;
    if (dlProvider == null) return 0;
    var removed = 0;
    try {
      final dl = await dlProvider();
      if (!await dl.exists()) return 0;
      await for (final e in dl.list()) {
        if (e is File && e.path.endsWith(tagTempSuffix)) {
          try {
            await e.delete();
            removed++;
          } catch (_) {}
        }
      }
    } catch (_) {}
    return removed;
  }
}
