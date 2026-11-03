import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import 'download_filename.dart';
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
  const DownloadRecord({
    required this.trackId,
    required this.title,
    required this.artist,
    required this.path,
    required this.quality,
    required this.size,
    required this.createdAt,
  });
  factory DownloadRecord.fromJson(Map<String, dynamic> j) => DownloadRecord(
        trackId: '${j['trackId']}',
        title: '${j['title'] ?? ''}',
        artist: '${j['artist'] ?? ''}',
        path: '${j['path'] ?? ''}',
        quality: '${j['quality'] ?? ''}',
        size: (j['size'] as num?)?.toInt() ?? 0,
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
      );
  Map<String, dynamic> toJson() => {
        'trackId': trackId,
        'title': title,
        'artist': artist,
        'path': path,
        'quality': quality,
        'size': size,
        'createdAt': createdAt,
      };
}

class DownloadTask {
  final String trackId;
  double progress; // 0..1, -1 未知总量
  DownloadTask(this.trackId, this.progress);
}

/// 下载：流式拉所选音质直链落盘 .m4a（不转码、不写标签，M4A 如实标注）。
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
    final size = await File(path).length();
    final record = DownloadRecord(
      trackId: track.id,
      title: track.name,
      artist: track.artistNames,
      path: path,
      quality: resolved.stream.quality,
      size: size,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    _records = [record, ..._records.where((r) => r.trackId != track.id)];
    _tasks.remove(track.id);
    _cancels.remove(track.id);
    await _persist();
    notifyListeners();
    return record;
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
