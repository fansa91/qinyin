// 缓存清理机制验收（CacheService）：
// - 占用统计口径：无损缓存目录 + 封面缓存目录 + 下载目录 *.qytag；
// - 清理只动缓存：下载目录里的歌曲本体、其他文件一律保留；
// - 启动清扫只删无歧义孤儿临时件（*.enc.part / *.tmp / *.qytag），
//   无损成品与下载歌曲不误伤。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qinyin/services/cache_service.dart';

void main() {
  late Directory root;
  late Directory tmpDir;
  late Directory dlDir;
  late Directory losslessDir;
  late Directory coverDir;
  var coverCleared = false;

  Future<void> writeFile(Directory dir, String name, int bytes) async {
    final f = File('${dir.path}/$name');
    await f.create(recursive: true);
    await f.writeAsBytes(List.filled(bytes, 7));
  }

  CacheService makeService() => CacheService(
        tmpDirProvider: () async => tmpDir,
        downloadDirProvider: () async => dlDir,
        clearCoverCache: () async {
          coverCleared = true;
          // 模拟 DefaultCacheManager().emptyCache()：删封面缓存文件
          if (await coverDir.exists()) {
            await for (final e in coverDir.list()) {
              await e.delete(recursive: true);
            }
          }
        },
      );

  setUp(() async {
    coverCleared = false;
    root = await Directory.systemTemp.createTemp('qinyin_cache_test');
    tmpDir = Directory('${root.path}/tmp');
    dlDir = Directory('${root.path}/downloads');
    losslessDir = Directory('${tmpDir.path}/qinyin_lossless');
    coverDir = Directory('${tmpDir.path}/libCachedImageData');
    await losslessDir.create(recursive: true);
    await coverDir.create(recursive: true);
    await dlDir.create(recursive: true);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('measure：三项口径互不重叠地汇总', () async {
    await writeFile(losslessDir, 'a.flac', 1000);
    await writeFile(losslessDir, 'b.enc.part', 500);
    await writeFile(coverDir, 'img1', 300);
    await writeFile(dlDir, 'song.m4a', 9999); // 用户资产：不计入
    await writeFile(dlDir, 'song.m4a.qytag', 200);

    final usage = await makeService().measure();
    expect(usage.losslessBytes, 1500);
    expect(usage.coverBytes, 300);
    expect(usage.tagTempBytes, 200);
    expect(usage.totalBytes, 2000);
  });

  test('clearAll：只清缓存，下载歌曲与普通文件完好', () async {
    await writeFile(losslessDir, 'a.flac', 1000);
    await writeFile(losslessDir, 'b.enc.part', 500);
    await writeFile(coverDir, 'img1', 300);
    await writeFile(dlDir, 'song.m4a', 9999);
    await writeFile(dlDir, 'keep.txt', 10);
    await writeFile(dlDir, 'song.m4a.qytag', 200);

    await makeService().clearAll();

    expect(coverCleared, isTrue, reason: '封面缓存应走 emptyCache 清理');
    expect(await losslessDir.list().isEmpty, isTrue,
        reason: '无损缓存目录应清空（目录本身可保留）');
    expect(await File('${dlDir.path}/song.m4a').exists(), isTrue,
        reason: '下载的歌曲是用户资产，绝不能删');
    expect(await File('${dlDir.path}/keep.txt').exists(), isTrue);
    expect(await File('${dlDir.path}/song.m4a.qytag').exists(), isFalse,
        reason: '写标签临时件属于缓存残留，应被清掉');

    final after = await makeService().measure();
    expect(after.totalBytes, 0);
  });

  test('sweepOrphanTemps：只删孤儿临时件，成品与歌曲不误伤', () async {
    await writeFile(losslessDir, 'done.flac', 1000); // 无损成品：保留
    await writeFile(losslessDir, 'done.m4a', 800); // 保留
    await writeFile(losslessDir, 'x.enc.part', 100); // 删
    await writeFile(losslessDir, 'x.flac.tmp', 100); // 删
    await writeFile(dlDir, 'song.flac', 5000); // 用户资产：保留
    await writeFile(dlDir, 'song.flac.qytag', 50); // 删
    await writeFile(dlDir, 'notes.txt', 10); // 保留

    final removed = await makeService().sweepOrphanTemps();
    expect(removed, 3);
    expect(await File('${losslessDir.path}/done.flac').exists(), isTrue);
    expect(await File('${losslessDir.path}/done.m4a').exists(), isTrue);
    expect(await File('${losslessDir.path}/x.enc.part').exists(), isFalse);
    expect(await File('${losslessDir.path}/x.flac.tmp').exists(), isFalse);
    expect(await File('${dlDir.path}/song.flac').exists(), isTrue);
    expect(await File('${dlDir.path}/song.flac.qytag').exists(), isFalse);
    expect(await File('${dlDir.path}/notes.txt').exists(), isTrue);
  });

  test('无下载目录提供者时 measure/清扫不崩，标签项记 0', () async {
    await writeFile(losslessDir, 'a.flac', 100);
    final svc = CacheService(
      tmpDirProvider: () async => tmpDir,
      clearCoverCache: () async {},
    );
    final usage = await svc.measure();
    expect(usage.losslessBytes, 100);
    expect(usage.tagTempBytes, 0);
    expect(await svc.sweepOrphanTemps(), 0);
  });
}
