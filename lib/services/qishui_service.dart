import 'dart:math';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  /// 车机开放平台推荐流响应（data.items[].entity.media）统一解析
  static List<Track> parsePlatformItems(Map<String, dynamic> body) {
    final data = (body['data'] as Map<String, dynamic>?) ?? const {};
    final tracks = <Track>[];
    for (final item in (data['items'] as List?) ?? const []) {
      if (item is! Map<String, dynamic>) continue;
      final entity = item['entity'] as Map<String, dynamic>?;
      final media = entity?['media'] as Map<String, dynamic>?;
      if (media == null) continue;
      final t = Track.fromPlatformMedia(media);
      if (t != null) tracks.add(t);
    }
    return tracks;
  }

  /// 搜索联想词（全文搜索走车机平台通道，见 PlatformFeedService.searchPage）
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

/// 官方推荐流 · 车机开放平台通道（open.douyin.com，LunaOpenSDK）。
///
/// 实测结论（2026-11-04，见 QISHUI_API.md §15）：App 本体 feed/song-tab
/// 游客被设备门拦截（§14），但车机开放平台同一条流无 token/无签名/无 Cookie
/// 即可取到（游客未个性化版，官方自述「登录后推荐更准」）。device_id 自造，
/// 首启随机生成并持久化，避免每次启动换号影响流的连续性/去重。
/// 注意：该通道 player_info 直链只下发 medium 一档，只作推荐数据源，
/// 播放仍走 [QishuiService.seoTrack] + PlayResolver。
class PlatformFeedService {
  static const String host = 'https://open.douyin.com';
  static const String feedPath = '/api/luna/v1/platform/feed/song-tab/';
  static const String searchPath = '/api/luna/v1/platform/search/';
  static const String tokenUrl =
      'https://open.qishui.com/api/luna/v1/platform/client/token/get/';
  static const String sdkUa = 'LunaOpenSDK/1.0.10';
  static const String _kDeviceId = 'platform_device_id';

  final Dio _dio;
  final String deviceId;

  /// 客户端令牌（公共读接口的 access-token 头）：实测形状为**顶层**
  /// client_token 字段（不在 data 里），见 QISHUI_API.md §16.1。
  /// 取不到不阻塞任何请求（feed/搜索裸调亦可通），只在 err_no 28001008
  /// （令牌过期）时丢弃重取并重试一次。
  String? _clientToken;
  Future<String?>? _tokenInFlight;

  PlatformFeedService({required this.deviceId, Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: host,
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
            ));

  /// 首启随机生成 19 位数字 device_id 并持久化，之后一直复用
  static Future<String> loadOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_kDeviceId);
    if (saved != null && saved.isNotEmpty) return saved;
    final rnd = Random();
    final id = '7${List.generate(18, (_) => rnd.nextInt(10)).join()}';
    await prefs.setString(_kDeviceId, id);
    return id;
  }

  /// 车机 SDK 公共参数（固定值 + 设备号 + 时间戳/nonce），纯函数便于单测
  static Map<String, String> commonParams(
    String deviceId, {
    required int timestampSeconds,
    required int nonce,
  }) =>
      {
        'aid': '765213',
        'app_id': '765213',
        'app_name': 'byte_autoservice_lite',
        'version_code': '100010',
        'version_name': '1.0.10',
        'channel': 'bydSong',
        'sdk_aid': '753999',
        'caller_name': 'luna_open_sdk',
        'sdk_version_code': '100000100',
        'sdk_version_name': '0.0.1',
        'sdk_channel': 'Test',
        'vehicle_type': 'BYD',
        'device_brand': 'BYD',
        'device_type': 'BYD',
        'device_platform': 'android',
        'resolution': '1920x1080',
        'os_version': '13',
        'ac': 'wifi',
        'device_id': deviceId,
        'did': deviceId,
        'iid': deviceId,
        'vehicle_id': 'qishui-$deviceId',
        '_timestamp': '$timestampSeconds',
        '_nonce': '$nonce',
      };

  /// 推荐流分页 → (曲目, hasMore)；cursor 为偏移量（首页 0，之后 += 本页条数），
  /// 响应无 next_cursor 字段。err_no 非 0 时抛 StateError 供上层回退。
  Future<(List<Track>, bool)> songTabPage(int cursor, {int count = 20}) async {
    final resp = await _dio.get<dynamic>(
      feedPath,
      queryParameters: {
        ...commonParams(
          deviceId,
          timestampSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          nonce: Random().nextInt(1000000000),
        ),
        'cursor': '$cursor',
        'cnt': '$count',
        'count': '$count',
      },
      options: Options(headers: {'User-Agent': sdkUa}),
    );
    final body = (resp.data as Map).cast<String, dynamic>();
    final errNo = body['err_no'];
    if (errNo != null && errNo != 0) {
      throw StateError('platform feed err_no=$errNo ${body['err_msg'] ?? ''}');
    }
    final data = (body['data'] as Map<String, dynamic>?) ?? const {};
    return (QishuiService.parsePlatformItems(body), data['has_more'] == true);
  }

  Map<String, String> _params() => commonParams(
        deviceId,
        timestampSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        nonce: Random().nextInt(1000000000),
      );

  /// 尽力取客户端令牌：成功缓存并复用，失败返回 null（不抛、不阻塞）。
  /// 响应形状（2026-11-04 实测）：{client_token: "clt.…", err_no: 0,
  /// expires_time: <远未来>}——client_token 在顶层，data 里没有。
  Future<String?> clientToken() {
    if (_clientToken != null) return Future.value(_clientToken);
    return _tokenInFlight ??= () async {
      try {
        final resp = await _dio.get<dynamic>(
          tokenUrl,
          queryParameters: {..._params(), 'trigger_type': 'cold_start'},
          options: Options(headers: {'User-Agent': sdkUa}),
        );
        final body = (resp.data as Map).cast<String, dynamic>();
        final token = body['client_token'];
        if (body['err_no'] == 0 && token is String && token.isNotEmpty) {
          _clientToken = token;
          return token;
        }
        return null;
      } catch (_) {
        return null;
      } finally {
        _tokenInFlight = null;
      }
    }();
  }

  /// 平台搜索一页原始组数据 → (entity 列表, hasMore, nextCursor)。
  /// 组选取照 GSQZ 口径：优先 id == "${type}s" 的组，没有时退回第一组。
  static (List<Map<String, dynamic>>, bool, String?) parseSearchGroup(
    Map<String, dynamic> body,
    String type,
  ) {
    final data = (body['data'] as Map<String, dynamic>?) ?? const {};
    final groups = (data['result_groups'] as List?) ?? const [];
    Map<String, dynamic>? group;
    for (final g in groups) {
      if (g is Map<String, dynamic> && g['id'] == '${type}s') {
        group = g;
        break;
      }
    }
    group ??= groups.isNotEmpty && groups.first is Map<String, dynamic>
        ? groups.first as Map<String, dynamic>
        : null;
    if (group == null) return (const [], false, null);
    final entities = <Map<String, dynamic>>[];
    for (final item in (group['data'] as List?) ?? const []) {
      if (item is! Map<String, dynamic>) continue;
      final entity = item['entity'] as Map<String, dynamic>?;
      if (entity != null) entities.add(entity);
    }
    final next = group['next_cursor'];
    return (
      entities,
      group['has_more'] == true,
      next == null ? null : '$next',
    );
  }

  /// 平台搜索 entity 列表 → 曲目（entity.track 就是 feed 同款 track_entity）
  static List<Track> parseSearchTracks(List<Map<String, dynamic>> entities) {
    final tracks = <Track>[];
    for (final e in entities) {
      final track = e['track'] as Map<String, dynamic>?;
      if (track == null) continue;
      final t = Track.fromPlatformMedia({'track_entity': track});
      if (t != null) tracks.add(t);
    }
    return tracks;
  }

  /// 平台搜索 entity 列表 → 歌单（entity.playlist 与 App 侧歌单同形状）
  static List<Playlist> parseSearchPlaylists(
      List<Map<String, dynamic>> entities) {
    final playlists = <Playlist>[];
    for (final e in entities) {
      final p = e['playlist'] as Map<String, dynamic>?;
      if (p == null || p.isEmpty) continue;
      final playlist = Playlist.fromJson(p);
      if (playlist.id.isNotEmpty && playlist.title.isNotEmpty) {
        playlists.add(playlist);
      }
    }
    return playlists;
  }

  /// 平台搜索 entity 列表 → 歌手（entity.artist.base_info）
  static List<ArtistHit> parseSearchArtists(
      List<Map<String, dynamic>> entities) {
    final artists = <ArtistHit>[];
    for (final e in entities) {
      final a = e['artist'] as Map<String, dynamic>?;
      final base = a?['base_info'] as Map<String, dynamic>?;
      if (base == null) continue;
      final hit = ArtistHit.fromPlatformBaseInfo(base);
      if (hit != null) artists.add(hit);
    }
    return artists;
  }

  /// 搜索请求体（纯函数便于单测）：search_id 在一次搜索会话内固定，
  /// 由调用方生成并在翻页时复用；换关键词必须换新的。
  static Map<String, dynamic> searchBody({
    required String query,
    required String type,
    required String cursor,
    required String searchId,
  }) =>
      {
        'q': query,
        'cursor': cursor,
        'search_id': searchId,
        'from_search_id': searchId,
        'search_method': 'input',
        'search_type': type,
        'search_scene': 'normal',
        'scene_name': 'search',
        'ab_param': '',
        'last_viewed_media': <String, dynamic>{},
        'common_params': <String, dynamic>{},
      };

  static String newSearchId() {
    final rnd = Random();
    String hex(int n) =>
        List.generate(n, (_) => rnd.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-${hex(4)}-${hex(12)}';
  }

  /// 平台搜索一页 → (entity 列表, hasMore, nextCursor)。
  /// [type] 为 'track' / 'playlist' / 'artist'（均已实测，见 §16；
  /// 其中 playlist 游客态当前上游恒空——err_no=0、result_groups=[]）。
  /// err_no 28001008（令牌过期）时刷新令牌重试一次；其余 err_no 抛
  /// StateError 供上层走失败态。
  Future<(List<Map<String, dynamic>>, bool, String?)> searchPage({
    required String query,
    required String type,
    required String searchId,
    String cursor = '0',
  }) async {
    for (var attempt = 0; ; attempt++) {
      final token = await clientToken();
      final headers = <String, dynamic>{'User-Agent': sdkUa};
      if (token != null) headers['access-token'] = token;
      final resp = await _dio.post<dynamic>(
        searchPath,
        queryParameters: _params(),
        data: searchBody(
          query: query,
          type: type,
          cursor: cursor,
          searchId: searchId,
        ),
        options: Options(headers: headers),
      );
      final body = (resp.data as Map).cast<String, dynamic>();
      final errNo = body['err_no'];
      if (errNo == 28001008 && attempt == 0) {
        _clientToken = null; // 令牌过期：丢弃，下轮重取后重试一次
        continue;
      }
      if (errNo != null && errNo != 0) {
        throw StateError('platform search err_no=$errNo ${body['err_msg'] ?? ''}');
      }
      return parseSearchGroup(body, type);
    }
  }

  Future<(List<Track>, bool, String?)> searchTracks({
    required String query,
    required String searchId,
    String cursor = '0',
  }) async {
    final (entities, hasMore, next) = await searchPage(
        query: query, type: 'track', searchId: searchId, cursor: cursor);
    return (parseSearchTracks(entities), hasMore, next);
  }

  Future<(List<Playlist>, bool, String?)> searchPlaylists({
    required String query,
    required String searchId,
    String cursor = '0',
  }) async {
    final (entities, hasMore, next) = await searchPage(
        query: query, type: 'playlist', searchId: searchId, cursor: cursor);
    return (parseSearchPlaylists(entities), hasMore, next);
  }

  Future<(List<ArtistHit>, bool, String?)> searchArtists({
    required String query,
    required String searchId,
    String cursor = '0',
  }) async {
    final (entities, hasMore, next) = await searchPage(
        query: query, type: 'artist', searchId: searchId, cursor: cursor);
    return (parseSearchArtists(entities), hasMore, next);
  }
}
