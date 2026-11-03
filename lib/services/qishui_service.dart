import 'package:dio/dio.dart';

import '../models/models.dart';

/// 汽水音乐游客态接口（host: beta-luna.douyin.com）。
///
/// 全部接口已于 2026-11-03 实测游客可通（无 Cookie、无签名头）：
/// POST /luna/* 用 App UA；GET 用普通 Web UA。
class QishuiService {
  static const String host = 'https://beta-luna.douyin.com';
  static const String appUa = 'Luna/19.1.0 Android';
  static const String webUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36';

  final Dio _dio;

  QishuiService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: host,
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
            ));

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> data) async {
    final resp = await _dio.post<dynamic>(
      path,
      data: data,
      options: Options(headers: {
        'User-Agent': appUa,
        'Content-Type': 'application/json; charset=utf-8',
      }),
    );
    return (resp.data as Map).cast<String, dynamic>();
  }

  Future<Map<String, dynamic>> _get(String path, Map<String, dynamic> query) async {
    final resp = await _dio.get<dynamic>(
      path,
      queryParameters: query,
      options: Options(headers: {'User-Agent': webUa}),
    );
    return (resp.data as Map).cast<String, dynamic>();
  }

  /// 首页发现：discover 给电台块，discover/mix 给推荐歌单
  Future<HomeFeed> homeFeed() async {
    final discover = await _post('/luna/discover', const {});
    final radios = <RadioStation>[];
    void walkBlocks(dynamic blocks) {
      if (blocks is! List) return;
      for (final b in blocks) {
        if (b is! Map<String, dynamic>) continue;
        if (b['type'] == 'discover_radio') {
          final resources = b['resources'] as List?;
          if (resources != null && resources.isNotEmpty) {
            final r = RadioStation.fromResource(
                resources.first as Map<String, dynamic>);
            if (r != null) radios.add(r);
          }
        }
        walkBlocks(b['inner_block']);
      }
    }

    walkBlocks(discover['blocks']);
    final mix = await discoverMix();
    return HomeFeed(
      radios: radios,
      playlists: mix.$1,
      mixCursor: mix.$2,
      mixHasMore: mix.$3,
    );
  }

  /// 推荐歌单分页 → (歌单, nextCursor, hasMore)
  Future<(List<Playlist>, String?, bool)> discoverMix({String cursor = '0'}) async {
    final body = await _post('/luna/discover/mix', {'cursor': cursor, 'count': 10});
    final playlists = <Playlist>[];
    final inner = body['inner_block'] as List?;
    if (inner != null) {
      for (final b in inner) {
        if (b is! Map<String, dynamic>) continue;
        final resources = b['resources'] as List?;
        if (resources != null && resources.isNotEmpty) {
          final p = Playlist.fromResource(resources.first as Map<String, dynamic>);
          if (p != null) playlists.add(p);
        } else if (b['type'] == 'discover_playlist') {
          final p = Playlist.fromResource(b);
          if (p != null) playlists.add(p);
        }
      }
    }
    final next = body['next_cursor'];
    return (playlists, next == null ? null : '$next', body['has_more'] == true);
  }

  /// 歌单详情 → (歌单, 曲目, nextCursor)
  Future<(Playlist, List<Track>, String?)> playlistDetail(String id,
      {String? cursor}) async {
    final body = await _post('/luna/playlist/detail', {
      'playlist_id': id,
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
    });
    final playlist =
        Playlist.fromJson((body['playlist'] as Map<String, dynamic>?) ?? const {});
    final tracks = <Track>[];
    for (final mr in (body['media_resources'] as List?) ?? const []) {
      if (mr is! Map<String, dynamic>) continue;
      final entity = mr['entity'] as Map<String, dynamic>?;
      final wrapper = entity?['track_wrapper'] as Map<String, dynamic>?;
      final t = Track.fromWrapped(wrapper ?? mr);
      if (t != null) tracks.add(t);
    }
    final next = body['next_cursor'];
    return (playlist, tracks, next == null ? null : '$next');
  }

  /// 专辑详情 → (专辑, 曲目)（接口一次全量返回）
  Future<(Album, List<Track>)> albumDetail(String id) async {
    final body = await _get('/luna/albums/$id', const {});
    final album =
        Album.fromJson((body['album_info'] as Map<String, dynamic>?) ?? const {});
    final tracks = ((body['tracks'] as List?) ?? const [])
        .map((e) => Track.fromWrapped(e) ??
            (e is Map<String, dynamic> && e['id'] != null ? Track.fromJson(e) : null))
        .whereType<Track>()
        .toList();
    return (album, tracks);
  }

  /// 歌手页 → (歌手, 热门歌曲, 热门专辑)
  Future<(ArtistRef, List<Track>, List<Album>)> artistDetail(String id) async {
    final body = await _get('/luna/artists/$id', const {});
    final info = (body['artist_info'] as Map<String, dynamic>?) ?? const {};
    final artist = ArtistRef.fromJson(info);
    final tracks = ((body['hot_tracks'] as List?) ?? const [])
        .map((e) => Track.fromWrapped(e) ??
            (e is Map<String, dynamic> && e['id'] != null ? Track.fromJson(e) : null))
        .whereType<Track>()
        .toList();
    final albums = ((body['hot_albums'] as List?) ?? const [])
        .map((e) => e is Map<String, dynamic> ? Album.fromJson(e) : null)
        .whereType<Album>()
        .toList();
    return (artist, tracks, albums);
  }

  /// 电台曲目（一次取 30 首；响应无 cursor 字段，不做假分页）
  Future<List<Track>> radioTracks(String radioId) => radioTracksPage(radioId, '0');

  /// 电台曲目分页：实测（2026-11-04）服务端每批固定回 6 首、has_more 恒 true、
  /// 无 next_cursor；cursor 传已取条数（offset）可继续取到后续批次，
  /// 但单电台池子是轮换小池（约 20 首量级后新增明显变少），靠多电台轮换扩容。
  Future<List<Track>> radioTracksPage(String radioId, String cursor) async {
    final body = await _post('/luna/feed/radio/tracks', {
      'radio_id': radioId,
      'cursor': cursor,
      'count': 30,
    });
    return parseFeedItems(body);
  }

  /// 相关歌曲（官方 SearchOneTrackQueueLoader 续队列同款接口）：
  /// 实测游客可用，每批固定 6 首、has_more 恒 true、无 cursor；
  /// 种子相关性弱（近似「种子邻域随机池」，单种子邻域约 40–60 首后枯竭），
  /// 靠链式换种子 + 与歌单/电台多源组合续命。
  Future<List<Track>> relatedTracks(String seedTrackId) async {
    final body = await _post('/luna/media/related', {'track_id': seedTrackId});
    return parseFeedItems(body);
  }

  /// feed 类响应（items[].entity.track_wrapper.track）统一解析
  static List<Track> parseFeedItems(Map<String, dynamic> body) {
    final tracks = <Track>[];
    for (final item in (body['items'] as List?) ?? const []) {
      if (item is! Map<String, dynamic>) continue;
      final entity = item['entity'] as Map<String, dynamic>?;
      final wrapper = entity?['track_wrapper'] as Map<String, dynamic>?;
      final t = Track.fromWrapped(wrapper ?? item);
      if (t != null) tracks.add(t);
    }
    return tracks;
  }

  /// 搜索联想词（全文搜索游客被服务端掏空，本 App 不提供假结果）
  Future<List<String>> sug(String q) async {
    if (q.trim().isEmpty) return const [];
    final body = await _get('/luna/sug', {
      'q': q,
      'sug_scene': 'search',
      'sug_search_id': 'qinyin${DateTime.now().millisecondsSinceEpoch}',
    });
    final out = <String>[];
    for (final s in (body['sugs'] as List?) ?? const []) {
      if (s is Map<String, dynamic>) {
        final w = s['word'] ?? s['content'] ?? s['title'];
        if (w != null && '$w'.isNotEmpty) out.add('$w');
      } else if (s is String && s.isNotEmpty) {
        out.add(s);
      }
    }
    return out;
  }

  /// 播放页一发：曲目详情 + 歌词 + 可播流 + 评论 + 相关列表
  Future<SeoTrack> seoTrack(String trackId) async {
    final body = await _get('/luna/h5/seo_track', {
      'track_id': trackId,
      'device_platform': 'web',
    });
    return SeoTrack.fromJson(body);
  }
}
