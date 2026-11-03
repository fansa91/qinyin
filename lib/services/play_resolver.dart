import '../models/models.dart';

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
  const ResolvedPlay(
      {required this.trackId, required this.stream, required this.expireAt});
}

/// 播放解析：经 seo_track 取流，按设置音质选档，就近回落；
/// SeoTrack 按 expire_at 缓存（留 60s 余量），过期自动重拉。
class PlayResolver {
  final Future<SeoTrack> Function(String trackId) _fetchSeo;
  final Map<String, SeoTrack> _seoCache = {};
  final Map<String, Future<SeoTrack>> _inflight = {};

  PlayResolver(this._fetchSeo);

  /// 音质回落顺序（就近原则）
  static List<String> fallbackOrder(String want) => switch (want) {
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
}
