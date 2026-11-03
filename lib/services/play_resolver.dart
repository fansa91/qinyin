import '../models/models.dart';
import 'lossless_cache.dart';

/// 无可播流（付费/受限曲目 seo 不下发 video_model 时）
class PlayUnavailable implements Exception {
  final String message;
  PlayUnavailable([this.message = '该曲目暂无游客可播音源']);
  @override
  String toString() => message;
}

/// 解析结果：一首歌定版的可播地址
class ResolvedPlay {
  final String trackId;
  final PlayStream stream;
  final int expireAt;

  /// 本地文件播放（无损解密产物）时非空，此时优先于 stream 的 URL
  final String? localPath;
  const ResolvedPlay({
    required this.trackId,
    required this.stream,
    required this.expireAt,
    this.localPath,
  });

  bool get isLocal => localPath != null && localPath!.isNotEmpty;
}

/// 播放解析：经 seo_track 取流，按设置音质选档，就近回落；
/// SeoTrack 按 expire_at 缓存（留 60s 余量），过期自动重拉。
/// 设置为无损且曲目带平台 B 路 lossless 时，走 [LosslessCache] 解密本地播。
class PlayResolver {
  final Future<SeoTrack> Function(String trackId) _fetchSeo;
  final LosslessCache? losslessCache;
  final Map<String, SeoTrack> _seoCache = {};
  final Map<String, Future<SeoTrack>> _inflight = {};

  PlayResolver(this._fetchSeo, {this.losslessCache});

  /// 音质回落顺序（就近原则）
  static List<String> fallbackOrder(String want) => switch (want) {
        'lossless' => const ['lossless', 'highest', 'higher', 'medium'],
        'highest' => const ['highest', 'higher', 'medium'],
        'medium' => const ['medium', 'higher', 'highest'],
        _ => const ['higher', 'highest', 'medium'],
      };

  /// 在流列表里按意愿音质选一档（纯函数，可测）
  static PlayStream? selectStream(List<PlayStream> streams, String want) {
    if (streams.isEmpty) return null;
    for (final q in fallbackOrder(want)) {
      for (final s in streams) {
        if (s.quality == q) return s;
      }
    }
    return streams.first;
  }

  Future<SeoTrack> seo(String trackId, {bool forceRefresh = false}) async {
    final cached = _seoCache[trackId];
    if (!forceRefresh && cached != null && !cached.isExpired(DateTime.now())) {
      return cached;
    }
    final running = _inflight[trackId];
    if (running != null && !forceRefresh) return running;
    final future = _fetchSeo(trackId).then((seo) {
      _seoCache[trackId] = seo;
      _inflight.remove(trackId);
      return seo;
    }).catchError((Object e) {
      _inflight.remove(trackId);
      throw e;
    });
    _inflight[trackId] = future;
    return future;
  }

  /// 已缓存的 seo（不触发网络），播放页展示歌词/评论用
  SeoTrack? cachedSeo(String trackId) => _seoCache[trackId];

  Future<ResolvedPlay> resolve(String trackId,
      {required String quality, bool forceRefresh = false}) async {
    final seoData = await seo(trackId, forceRefresh: forceRefresh);
    final stream = selectStream(seoData.streams, quality);
    if (stream == null) throw PlayUnavailable();
    return ResolvedPlay(
        trackId: trackId, stream: stream, expireAt: seoData.expireAt);
  }

  /// 预取：把 seo 拉进缓存（播放/下载/歌词都受益），失败静默
  Future<void> prefetch(String trackId) async {
    try {
      await seo(trackId);
    } catch (_) {
      // 预取失败静默，真正播放时会再试
    }
  }

  /// 备妥无损本地文件（下载与播放共用同一条解密链）。
  /// 曲目无平台无损档或无缓存组件时抛 [PlayUnavailable]；解密/下载失败抛原异常。
  Future<String> prepareLossless(
    Track track, {
    void Function(int received, int total)? onProgress,
  }) async {
    final stream = track.platformLossless;
    final cache = losslessCache;
    if (stream == null || cache == null) {
      throw PlayUnavailable('该曲目无平台无损音源');
    }
    return cache.prepare(
        trackId: track.id, stream: stream, onProgress: onProgress);
  }

  /// 以曲目对象解析（播放主入口）：无损选档逻辑在这里收口。
  ///
  /// quality == 'lossless' 时：曲目带平台无损档 → 下载解密走本地文件
  /// （开始动手前回调 [onLosslessPreparing] 供 UI 显示准备态）；
  /// 无档、或解密/下载失败 → 自动回落 seo 路（按 lossless 回落序，
  /// 实际取到的是 highest/higher/medium 里最高可用一档）。
  /// 其他音质与旧行为完全一致（seo 路）。
  Future<ResolvedPlay> resolveTrack(
    Track track, {
    required String quality,
    bool forceRefresh = false,
    void Function()? onLosslessPreparing,
  }) async {
    if (quality == 'lossless' && track.platformLossless != null) {
      try {
        onLosslessPreparing?.call();
        final path = await prepareLossless(track);
        return ResolvedPlay(
          trackId: track.id,
          stream: const PlayStream(
            quality: 'lossless',
            codecType: 'flac',
            mainUrl: '',
          ),
          expireAt: 0,
          localPath: path,
        );
      } catch (_) {
        // 无损链失败不许放不出声：回落 seo AAC 继续播
      }
    }
    return resolve(track.id, quality: quality, forceRefresh: forceRefresh);
  }
}
