import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import 'download_filename.dart';
import 'flac_tagger.dart';
import 'mp4_tagger.dart';
import 'play_resolver.dart';
import 'settings_service.dart';

class DownloadRecord {
  final String trackId;
  final String title;
  final String artist;
  final String path;
  final String quality;
  final int size;
  final int createdAt;

  /// 标签状态：tagged 已写 / failed 写失败（文件保留）/ untagged 未写
  /// （含旧记录缺省）。
  final String tagStatus;
  const DownloadRecord({
    required this.trackId,
    required this.title,
    required this.artist,
    required this.path,
    required this.quality,
    required this.size,
    required this.createdAt,
    this.tagStatus = 'untagged',
  });
  factory DownloadRecord.fromJson(Map<String, dynamic> j) => DownloadRecord(
        trackId: '${j['trackId']}',
        title: '${j['title'] ?? ''}',
        artist: '${j['artist'] ?? ''}',
        path: '${j['path'] ?? ''}',
        quality: '${j['quality'] ?? ''}',
        size: (j['size'] as num?)?.toInt() ?? 0,
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
        tagStatus: '${j['tagStatus'] ?? 'untagged'}',
      );
  Map<String, dynamic> toJson() => {
        'trackId': trackId,
        'title': title,
        'artist': artist,
        'path': path,
        'quality': quality,
        'size': size,
        'createdAt': createdAt,
        'tagStatus': tagStatus,
      };
}

class DownloadTask {
  final String trackId;
  double progress; // 0..1, -1 未知总量
  DownloadTask(this.trackId, this.progress);
}

/// 下载：流式拉所选音质直链落盘 .m4a（不转码），落盘后写 MP4 标签
/// （标题/歌手/专辑/日期/封面）；无损落盘 .flac 后写 Vorbis 标签。
/// 标签写失败保留原文件、只影响记录的标签状态，不算下载失败。
/// 下载前强制重解析，避免用过期签名链。
class DownloadService extends ChangeNotifier {
  final PlayResolver resolver;
  final SettingsService settings;
  final Dio _dio = Dio();
  static const _kRecords = 'download_records';

  List<DownloadRecord> _records = [];
  final Map<String, DownloadTask> _tasks = {};
  final Map<String, CancelToken> _cancels = {};

  DownloadService(this.resolver, this.settings);

  List<DownloadRecord> get records => List.unmodifiable(_records);
  Map<String, DownloadTask> get tasks => Map.unmodifiable(_tasks);
  bool isDownloading(String trackId) => _tasks.containsKey(trackId);
  bool isDownloaded(String trackId) =>
      _records.any((r) => r.trackId == trackId);
  String? localPathFor(String trackId) {
    final r = _records.where((e) => e.trackId == trackId).firstOrNull;
    if (r == null) return null;
    return File(r.path).existsSync() ? r.path : null;
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kRecords);
    if (raw != null && raw.isNotEmpty) {
      try {
        _records = (jsonDecode(raw) as List)
            .map((e) => DownloadRecord.fromJson(e as Map<String, dynamic>))
            .where((r) => File(r.path).existsSync())
            .toList();
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kRecords, jsonEncode(_records.map((r) => r.toJson()).toList()));
  }

  Future<Directory> _downloadDir() async {
    final custom = settings.downloadDirectory;
    if (custom.isNotEmpty) {
      final d = Directory(custom);
      if (!await d.exists()) await d.create(recursive: true);
      return d;
    }
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/qinyin_downloads');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 下载一首；已下过同音质直接返回既有记录。
  Future<DownloadRecord> download(Track track) async {
    final quality = settings.defaultQuality;
    final existing = _records.where((r) => r.trackId == track.id).firstOrNull;
    // 无损优先分支：设置选了无损且该曲带平台无损档 → 解密后落盘 FLAC。
    // 放在通用早返回之前，避免已下过 m4a 时误把 m4a 记录当无损交付。
    if (quality == 'lossless' && track.platformLossless != null) {
      if (existing != null &&
          existing.quality == 'lossless' &&
          localPathFor(track.id) != null) {
        return existing;
      }
      return _downloadLossless(track);
    }
    if (existing != null && existing.quality == quality ||
        existing != null && localPathFor(track.id) != null) {
      return existing;
    }
    if (_tasks.containsKey(track.id)) {
      throw StateError('正在下载中');
    }
    // 下载前重解析（链接 24h 过期）
    final resolved =
        await resolver.resolve(track.id, quality: quality, forceRefresh: true);
    final dir = await _downloadDir();
    final base = renderDownloadFilename(
      settings.filenameFormat,
      artist: track.artistNames,
      title: track.name,
      album: track.albumName,
      quality: resolved.stream.quality,
    );
    final path = await uniqueM4aPath(dir.path, base);
    final token = CancelToken();
    _cancels[track.id] = token;
    _tasks[track.id] = DownloadTask(track.id, 0);
    notifyListeners();
    try {
      await _dio.download(
        resolved.stream.mainUrl,
        path,
        cancelToken: token,
        onReceiveProgress: (received, total) {
          final task = _tasks[track.id];
          if (task != null) {
            task.progress = total > 0 ? received / total : -1;
            notifyListeners();
          }
        },
      );
    } catch (e) {
      final f = File(path);
      if (await f.exists()) await f.delete();
      _tasks.remove(track.id);
      _cancels.remove(track.id);
      notifyListeners();
      rethrow;
    }
    final tagOk = await Mp4Tagger.tagFile(path, await _buildTags(track));
    final size = await File(path).length();
    final record = DownloadRecord(
      trackId: track.id,
      title: track.name,
      artist: track.artistNames,
      path: path,
      quality: resolved.stream.quality,
      size: size,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      tagStatus: tagOk ? 'tagged' : 'failed',
    );
    _records = [record, ..._records.where((r) => r.trackId != track.id)];
    _tasks.remove(track.id);
    _cancels.remove(track.id);
    await _persist();
    notifyListeners();
    return record;
  }

  /// 组装一首曲目的下载标签：文字字段来自 Track；封面取较大图字节并
  /// 嗅探 MIME，取图失败则只写文字字段（不算失败）。
  Future<MediaTags> _buildTags(Track track) async {
    Uint8List? cover;
    String? mime;
    final url = track.coverUrl;
    if (url != null && url.isNotEmpty) {
      try {
        final resp = await _dio.get<List<int>>(
          url,
          options: Options(responseType: ResponseType.bytes),
        );
        final bytes = Uint8List.fromList(resp.data ?? const []);
        final sniffed = sniffImageMime(bytes);
        if (sniffed != null) {
          cover = bytes;
          mime = sniffed;
        }
      } catch (_) {
        // 封面拿不到就只写文字字段
      }
    }
    return MediaTags(
      title: track.name,
      artist: track.artistNames,
      album: track.albumName,
      date: track.dateTag,
      coverBytes: cover,
      coverMime: mime,
    );
  }

  /// 无损下载：经与播放共用的解密链备妥本地 FLAC（缓存命中时秒下），
  /// 再按文件名模板复制进下载目录落盘 .flac，落盘后写 Vorbis 标签
  /// （只写下载副本，不碰解密缓存文件）。
  /// 解密/下载失败抛异常（不静默回落 m4a，避免名实不符）。
  Future<DownloadRecord> _downloadLossless(Track track) async {
    if (_tasks.containsKey(track.id)) {
      throw StateError('正在下载中');
    }
    _tasks[track.id] = DownloadTask(track.id, 0);
    notifyListeners();
    try {
      final flacPath = await resolver.prepareLossless(
        track,
        onProgress: (received, total) {
          final task = _tasks[track.id];
          if (task != null) {
            task.progress = total > 0 ? received / total : -1;
            notifyListeners();
          }
        },
      );
      final dir = await _downloadDir();
      final base = renderDownloadFilename(
        settings.filenameFormat,
        artist: track.artistNames,
        title: track.name,
        album: track.albumName,
        quality: 'lossless',
      );
      final dest = await uniqueFlacPath(dir.path, base);
      await File(flacPath).copy(dest);
      final tagOk = await FlacTagger.tagFile(dest, await _buildTags(track));
      final size = await File(dest).length();
      final record = DownloadRecord(
        trackId: track.id,
        title: track.name,
        artist: track.artistNames,
        path: dest,
        quality: 'lossless',
        size: size,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        tagStatus: tagOk ? 'tagged' : 'failed',
      );
      _records = [record, ..._records.where((r) => r.trackId != track.id)];
      _tasks.remove(track.id);
      await _persist();
      notifyListeners();
      return record;
    } catch (e) {
      _tasks.remove(track.id);
      notifyListeners();
      rethrow;
    }
  }

  void cancel(String trackId) {
    _cancels[trackId]?.cancel('用户取消');
  }

  Future<void> deleteRecords(Iterable<String> trackIds) async {
    final ids = trackIds.toSet();
    for (final r in _records.where((r) => ids.contains(r.trackId))) {
      final f = File(r.path);
      if (await f.exists()) await f.delete();
    }
    _records = _records.where((r) => !ids.contains(r.trackId)).toList();
    await _persist();
    notifyListeners();
  }
}
