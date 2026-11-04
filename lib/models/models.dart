import 'dart:convert';

/// 封面图结构（url_cover / url_avatar / cover_url_list 元素通用）。
///
/// 拼装规则已实测（2026-11-03 真实响应验活）：
/// `{urls[0]}{uri}~{template_prefix}-image.image` → 200 image/png；
/// 另有 `-15.webp` 变体（200 image/webp，体积更小，列表用）。
class CoverArt {
  final String uri;
  final List<String> urls;
  final String? templatePrefix;

  const CoverArt({required this.uri, required this.urls, this.templatePrefix});

  /// urls 本身就是完整 URL 时（如抖音头像 need_complete_url），直接取第一条
  bool get isCompleteUrl =>
      urls.isNotEmpty && (urls.first.contains('?') || templatePrefix == null) && uri.isEmpty;

  String? url({bool webp = false}) {
    if (urls.isEmpty) return null;
    if (uri.isEmpty) return urls.first;
    final prefix = urls.first;
    // 头像类：urls 已是完整图片地址（带路径后缀），直接用
    if (prefix.endsWith('.jpeg') || prefix.endsWith('.jpg') || prefix.endsWith('.png')) {
      return prefix;
    }
    final tp = templatePrefix;
    if (tp == null || tp.isEmpty) return '$prefix$uri';
    return webp ? '$prefix$uri~$tp-15.webp' : '$prefix$uri~$tp-image.image';
  }

  factory CoverArt.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const CoverArt(uri: '', urls: []);
    return CoverArt(
      uri: (json['uri'] ?? '') as String,
      urls: ((json['urls'] as List?) ?? const []).map((e) => '$e').toList(),
      templatePrefix: json['template_prefix'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'uri': uri,
        'urls': urls,
        if (templatePrefix != null) 'template_prefix': templatePrefix,
      };

  static CoverArt? maybe(Map<String, dynamic>? json) {
    if (json == null) return null;
    final c = CoverArt.fromJson(json);
    return (c.uri.isEmpty && c.urls.isEmpty) ? null : c;
  }
}

String _str(dynamic v) => v == null ? '' : '$v';
int _int(dynamic v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);

/// 由 bit_rates 元数据取最高档（highest > higher > medium）；无则 ''
String _topFromBitRates(List<BitRate> bitRates) {
  var top = '';
  for (final b in bitRates) {
    if (b.quality == 'highest') return 'highest';
    if (b.quality == 'higher') top = 'higher';
    if (b.quality == 'medium' && top.isEmpty) top = 'medium';
  }
  return top;
}

/// 平台侧最高音质档：full.bit_rates 或 video_model 流含 lossless 即无损，
/// 否则按 bit_rates 最高档
String _platformTopQuality(
    Map<String, dynamic> full, List<PlayStream> streams) {
  final bitRates = ((full['bit_rates'] as List?) ?? const [])
      .map((e) => BitRate.fromJson(e as Map<String, dynamic>))
      .toList();
  if (bitRates.any((b) => b.quality == 'lossless') ||
      streams.any((s) => s.quality == 'lossless')) {
    return 'lossless';
  }
  return _topFromBitRates(bitRates);
}

/// 音质档（曲目 bit_rates 元数据）
class BitRate {
  final String quality; // medium / higher / highest
  final int br;
  final int size;
  const BitRate({required this.quality, required this.br, required this.size});
  factory BitRate.fromJson(Map<String, dynamic> j) => BitRate(
        quality: _str(j['quality']),
        br: _int(j['br']),
        size: _int(j['size']),
      );
  Map<String, dynamic> toJson() => {'quality': quality, 'br': br, 'size': size};
}

class ArtistRef {
  final String id;
  final String name;
  final CoverArt? avatar;
  const ArtistRef({required this.id, required this.name, this.avatar});
  factory ArtistRef.fromJson(Map<String, dynamic> j) => ArtistRef(
        id: _str(j['id']),
        name: _str(j['name'] ?? j['simple_display_name']),
        avatar: CoverArt.maybe(j['url_avatar'] as Map<String, dynamic>?),
      );
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (avatar != null) 'url_avatar': avatar!.toJson(),
      };
}

/// 平台搜索的歌手结果：基础信息 + 曲目/专辑数（列表副标题用）
class ArtistHit {
  final ArtistRef artist;
  final int countTracks;
  final int countAlbums;
  const ArtistHit({
    required this.artist,
    this.countTracks = 0,
    this.countAlbums = 0,
  });

  /// 平台搜索 entity.artist.base_info（name/url_avatar 与 ArtistRef.fromJson 同口径）
  static ArtistHit? fromPlatformBaseInfo(Map<String, dynamic> base) {
    final ref = ArtistRef.fromJson(base);
    if (ref.id.isEmpty) return null;
    return ArtistHit(
      artist: ref,
      countTracks: _int(base['count_tracks']),
      countAlbums: _int(base['count_albums']),
    );
  }
}

/// 曲目（列表/详情各接口的 track 对象形状统一到这里）
class Track {
  final String id;
  final String name;
  final List<ArtistRef> artists;
  final String albumId;
  final String albumName;
  final int releaseDate; // 专辑发行时间（epoch 秒，0=未知；下载写标签用）
  final CoverArt? cover;
  final int durationMs;
  final String vid;
  final List<BitRate> bitRates;
  final int? countCollected;
  final int? countComment;
  final int? countShared;

  /// 该曲数据可得的最高音质档（列表音质徽标用；''=数据未带任何音质信息，
  /// 不显示徽标）。取值口径：
  /// - 'lossless'：App 侧 label_info.quality_map 含 lossless 或
  ///   quality_only_vip_can_play 含 lossless（该曲有无损版本）；
  ///   平台侧 bit_rates / platformStreams 含 lossless；
  /// - 否则取 bit_rates 里的最高档（highest > higher > medium）。
  final String topQuality;

  /// VIP/付费曲目（官方客户端同款判定，列表显示 VIP 徽标）：
  /// - App 侧：label_info.only_vip_playable == true（字段缺失=非 VIP，
  ///   仅无损/下载受限的普通曲目不带此字段）；
  /// - 平台侧：commerce_info.icon_info.type 非空（如 'svip'，即官方
  ///   渲染徽标用的字段本身），或 playable_condition 含 membership_type。
  final bool isVip;
  final String? coverColorHex; // colors.cover_gradient_effect_color[0].rgb
  final Map<String, List<String>> makers; // composers/lyricists/...

  /// 车机平台通道 full 版 video_model 的流列表（B 路，含加密无损档）。
  /// 只来自推荐流条目的 player_info.full；preview（~60s 试听）不收录，
  /// 绝不作整曲源。其他来源的曲目为空——无损只对这批曲目可用。
  /// 不进 toJson（会话级数据，落盘收藏/历史不携带）。
  final List<PlayStream> platformStreams;

  const Track({
    required this.id,
    required this.name,
    this.artists = const [],
    this.albumId = '',
    this.albumName = '',
    this.releaseDate = 0,
    this.cover,
    this.durationMs = 0,
    this.vid = '',
    this.bitRates = const [],
    this.countCollected,
    this.countComment,
    this.countShared,
    this.topQuality = '',
    this.isVip = false,
    this.coverColorHex,
    this.makers = const {},
    this.platformStreams = const [],
  });

  String get artistNames => artists.map((a) => a.name).join(' / ');

  /// 标签用发行日期（yyyy-MM-dd，按 +08:00 日历日——平台的 release_date
  /// 是东八区零点 epoch）；未知返回 null
  String? get dateTag {
    if (releaseDate <= 0) return null;
    final d = DateTime.fromMillisecondsSinceEpoch(releaseDate * 1000,
        isUtc: true).add(const Duration(hours: 8));
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  String? get coverUrl => cover?.url();
  String? get coverUrlSmall => cover?.url(webp: true);

  /// 平台无损档（需 spade 解密）；没有返回 null
  PlayStream? get platformLossless {
    for (final s in platformStreams) {
      if (s.quality == 'lossless' && s.spadeA.isNotEmpty) return s;
    }
    return null;
  }

  factory Track.fromJson(Map<String, dynamic> j) {
    final album = (j['album'] as Map<String, dynamic>?) ?? const {};
    CoverArt? cover = CoverArt.maybe(j['url_player_bg'] as Map<String, dynamic>?) ??
        CoverArt.maybe(album['url_cover'] as Map<String, dynamic>?);
    final stats = (j['stats'] as Map<String, dynamic>?) ?? const {};
    final colors = (j['colors'] as Map<String, dynamic>?) ?? const {};
    String? colorHex;
    final grads = colors['cover_gradient_effect_color'] as List?;
    if (grads != null && grads.isNotEmpty) {
      colorHex = (grads.first as Map<String, dynamic>)['rgb'] as String?;
    }
    final makers = <String, List<String>>{};
    final team = j['song_maker_team'] as Map<String, dynamic>?;
    if (team != null) {
      for (final e in team.entries) {
        final list = e.value as List?;
        if (list != null) {
          makers[e.key] = list
              .map((x) => _str((x as Map<String, dynamic>)['name']))
              .where((s) => s.isNotEmpty)
              .toList();
        }
      }
    }
    final bitRates = ((j['bit_rates'] as List?) ?? const [])
        .map((e) => BitRate.fromJson(e as Map<String, dynamic>))
        .toList();
    final labelInfo = (j['label_info'] as Map<String, dynamic>?) ?? const {};
    final qualityMap =
        (labelInfo['quality_map'] as Map<String, dynamic>?) ?? const {};
    final vipCanPlay = ((labelInfo['quality_only_vip_can_play'] as List?) ??
            const [])
        .map((e) => '$e')
        .toList();
    final hasLossless = bitRates.any((b) => b.quality == 'lossless') ||
        qualityMap.containsKey('lossless') ||
        vipCanPlay.contains('lossless');
    return Track(
      id: _str(j['id']),
      name: _str(j['name']),
      artists: ((j['artists'] as List?) ?? const [])
          .map((e) => ArtistRef.fromJson(e as Map<String, dynamic>))
          .toList(),
      albumId: _str(album['id']),
      albumName: _str(album['name']),
      releaseDate: _int(album['release_date']),
      cover: cover,
      durationMs: _int(j['duration']),
      vid: _str(j['vid']),
      bitRates: bitRates,
      countCollected: stats['count_collected'] == null ? null : _int(stats['count_collected']),
      countComment: stats['count_comment'] == null ? null : _int(stats['count_comment']),
      countShared: stats['count_shared'] == null ? null : _int(stats['count_shared']),
      topQuality: hasLossless ? 'lossless' : _topFromBitRates(bitRates),
      isVip: labelInfo['only_vip_playable'] == true,
      coverColorHex: colorHex,
      makers: makers,
    );
  }

  /// 车机开放平台推荐流 items[].entity.media 的解析（结构实测见 QISHUI_API.md §15.3）：
  /// base_info 只有歌名/时长/制作团队；歌手在 related_info.artist_links、
  /// 专辑在 related_info.album_link、封面在 display_info.cover_url、
  /// 统计在 media_stats、音质元数据在 player_info.full.bit_rates。
  static Track? fromPlatformMedia(Map<String, dynamic> media) {
    final te = media['track_entity'] as Map<String, dynamic>?;
    if (te == null) return null;
    final base = (te['base_info'] as Map<String, dynamic>?) ?? const {};
    final id = _str(base['id']);
    if (id.isEmpty) return null;
    final related = (te['related_info'] as Map<String, dynamic>?) ?? const {};
    final albumLink = (related['album_link'] as Map<String, dynamic>?) ?? const {};
    final display = (te['display_info'] as Map<String, dynamic>?) ?? const {};
    final stats = (te['media_stats'] as Map<String, dynamic>?) ?? const {};
    final player = (te['player_info'] as Map<String, dynamic>?) ?? const {};
    final full = (player['full'] as Map<String, dynamic>?) ?? const {};
    final makers = <String, List<String>>{};
    final team = base['song_maker_team'] as Map<String, dynamic>?;
    if (team != null) {
      for (final e in team.entries) {
        final list = e.value as List?;
        if (list != null) {
          makers[e.key] = list
              .map((x) => _str((x as Map<String, dynamic>)['name']))
              .where((s) => s.isNotEmpty)
              .toList();
        }
      }
    }
    String? colorHex;
    final colors = (display['colors'] as Map<String, dynamic>?) ?? const {};
    final grads = colors['cover_gradient_effect_color'] as List?;
    if (grads != null && grads.isNotEmpty) {
      colorHex = (grads.first as Map<String, dynamic>)['rgb'] as String?;
    }
    // B 路无损数据源：只取 full 版内嵌 video_model（preview 是试听子集，
    // 结构上就不给整曲，绝不能混入）；解析失败视为空
    final fullVmi =
        (full['video_model_info'] as Map<String, dynamic>?) ?? const {};
    final fullVmRaw = fullVmi['video_model'];
    final platformStreams = fullVmRaw is String
        ? parseVideoModelStreams(fullVmRaw)
        : const <PlayStream>[];
    // VIP 判定：commerce_info.icon_info.type 是官方渲染徽标的字段本身
    // （'svip' 等非空即付费曲）；playable_condition 含 membership_type 兜底
    final commerce = (te['commerce_info'] as Map<String, dynamic>?) ?? const {};
    final iconType =
        _str((commerce['icon_info'] as Map<String, dynamic>?)?['type']);
    final isVip = iconType.isNotEmpty ||
        _str(commerce['playable_condition']).contains('membership_type');
    return Track(
      id: id,
      name: _str(base['name']),
      artists: ((related['artist_links'] as List?) ?? const [])
          .map((e) => ArtistRef.fromJson(e as Map<String, dynamic>))
          .toList(),
      albumId: _str(albumLink['id']),
      albumName: _str(albumLink['name']),
      releaseDate: _int(albumLink['release_date']),
      cover: CoverArt.maybe(display['cover_url'] as Map<String, dynamic>?),
      durationMs: _int(base['duration_ms']),
      vid: _str(player['vid']),
      bitRates: ((full['bit_rates'] as List?) ?? const [])
          .map((e) => BitRate.fromJson(e as Map<String, dynamic>))
          .toList(),
      countCollected:
          stats['count_collected'] == null ? null : _int(stats['count_collected']),
      countComment:
          stats['count_comment'] == null ? null : _int(stats['count_comment']),
      countShared: stats['count_shared'] == null ? null : _int(stats['count_shared']),
      topQuality: _platformTopQuality(full, platformStreams),
      isVip: isVip,
      coverColorHex: colorHex,
      makers: makers,
      platformStreams: platformStreams,
    );
  }

  /// 列表接口里 track 常被包一层：{track:{...}} 或 entity.track_wrapper.track
  static Track? fromWrapped(dynamic node) {
    if (node is! Map<String, dynamic>) return null;
    Map<String, dynamic>? t;
    if (node['track'] is Map<String, dynamic>) {
      t = node['track'] as Map<String, dynamic>;
    } else if (node['id'] != null && node['name'] != null) {
      t = node;
    }
    if (t == null || _str(t['id']).isEmpty) return null;
    return Track.fromJson(t);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'artists': artists.map((a) => a.toJson()).toList(),
        'album': {
          'id': albumId,
          'name': albumName,
          if (releaseDate > 0) 'release_date': releaseDate,
          if (cover != null) 'url_cover': cover!.toJson()
        },
        'duration': durationMs,
        'vid': vid,
        'bit_rates': bitRates.map((b) => b.toJson()).toList(),
        'stats': {
          if (countCollected != null) 'count_collected': countCollected,
          if (countComment != null) 'count_comment': countComment,
          if (countShared != null) 'count_shared': countShared,
        },
        // 收藏/历史落盘往返保 VIP 与无损标记（fromJson 读同一字段恢复）
        if (isVip || topQuality == 'lossless')
          'label_info': {
            if (isVip) 'only_vip_playable': true,
            if (topQuality == 'lossless')
              'quality_only_vip_can_play': ['lossless'],
          },
      };

  @override
  bool operator ==(Object other) => other is Track && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

class Album {
  final String id;
  final String name;
  final CoverArt? cover;
  final List<ArtistRef> artists;
  final int countTracks;
  final int releaseDate; // epoch 秒
  const Album({
    required this.id,
    required this.name,
    this.cover,
    this.artists = const [],
    this.countTracks = 0,
    this.releaseDate = 0,
  });
  String get artistNames => artists.map((a) => a.name).join(' / ');
  String? get coverUrl => cover?.url();
  factory Album.fromJson(Map<String, dynamic> j) => Album(
        id: _str(j['id']),
        name: _str(j['name']),
        cover: CoverArt.maybe(j['url_cover'] as Map<String, dynamic>?),
        artists: ((j['artists'] as List?) ?? const [])
            .map((e) => ArtistRef.fromJson(e as Map<String, dynamic>))
            .toList(),
        countTracks: _int(j['count_tracks']),
        releaseDate: _int(j['release_date']),
      );
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (cover != null) 'url_cover': cover!.toJson(),
        'artists': artists.map((a) => a.toJson()).toList(),
        'count_tracks': countTracks,
        'release_date': releaseDate,
      };
  @override
  bool operator ==(Object other) => other is Album && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

class Playlist {
  final String id;
  final String title;
  final CoverArt? cover;
  final String desc;
  final int countTracks;
  final int countCollected;
  const Playlist({
    required this.id,
    required this.title,
    this.cover,
    this.desc = '',
    this.countTracks = 0,
    this.countCollected = 0,
  });
  String? get coverUrl => cover?.url();
  factory Playlist.fromJson(Map<String, dynamic> j) {
    final stats = (j['stats'] as Map<String, dynamic>?) ?? const {};
    return Playlist(
      id: _str(j['id']),
      title: _str(j['title']),
      cover: CoverArt.maybe(j['url_cover'] as Map<String, dynamic>?),
      desc: _str(j['desc']),
      countTracks: _int(j['count_tracks']),
      countCollected: _int(stats['count_collected']),
    );
  }

  /// discover/mix 资源：{resource_id, type, entity:{playlist:{...}}} 或 style 形态
  static Playlist? fromResource(Map<String, dynamic> r) {
    final entity = r['entity'] as Map<String, dynamic>?;
    final p = entity?['playlist'] as Map<String, dynamic>?;
    if (p != null) return Playlist.fromJson(p);
    final style = r['style'] as Map<String, dynamic>?;
    if (style != null && _str(r['resource_id']).isNotEmpty) {
      final covers = style['cover_url_list'] as List?;
      return Playlist(
        id: _str(r['resource_id']),
        title: _str(style['title'] ?? r['title']),
        desc: _str(style['desc']),
        cover: covers != null && covers.isNotEmpty
            ? CoverArt.fromJson(covers.first as Map<String, dynamic>)
            : null,
      );
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        if (cover != null) 'url_cover': cover!.toJson(),
        'desc': desc,
        'count_tracks': countTracks,
        'stats': {'count_collected': countCollected},
      };
  @override
  bool operator ==(Object other) => other is Playlist && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

class RadioStation {
  final String id;
  final String title;
  final String desc;
  final CoverArt? cover;
  const RadioStation({required this.id, required this.title, this.desc = '', this.cover});
  String? get coverUrl => cover?.url();
  static RadioStation? fromResource(Map<String, dynamic> r) {
    final style = r['style'] as Map<String, dynamic>?;
    final id = _str(r['resource_id']);
    if (id.isEmpty) return null;
    final covers = style?['cover_url_list'] as List?;
    return RadioStation(
      id: id,
      title: _str(style?['title'] ?? r['title']),
      desc: _str(style?['desc']),
      cover: covers != null && covers.isNotEmpty
          ? CoverArt.fromJson(covers.first as Map<String, dynamic>)
          : null,
    );
  }
}

/// 歌词行（KRC 逐字格式解析后）
class LyricLine {
  final Duration start;
  final Duration duration;
  final String text;
  const LyricLine({required this.start, required this.duration, required this.text});
}

/// 解析汽水歌词：官方为 KRC 风格逐字格式
/// `[60,1470]<0,350,0>不<400,340,0>敢...` 每行一段；
/// 同时兼容普通 LRC `[mm:ss.xx]文本` 与纯文本行。
List<LyricLine> parseLyric(String raw) {
  final lines = <LyricLine>[];
  final krcHead = RegExp(r'^\[(\d+),(\d+)\]');
  final tag = RegExp(r'<[^>]*>');
  final lrcHead = RegExp(r'^\[(\d+):(\d+)(?:\.(\d+))?\]');
  for (final rawLine in raw.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    final km = krcHead.firstMatch(line);
    if (km != null) {
      final text = line.substring(km.end).replaceAll(tag, '');
      lines.add(LyricLine(
        start: Duration(milliseconds: int.parse(km.group(1)!)),
        duration: Duration(milliseconds: int.parse(km.group(2)!)),
        text: text,
      ));
      continue;
    }
    final lm = lrcHead.firstMatch(line);
    if (lm != null) {
      final ms = int.parse(lm.group(1)!) * 60000 +
          int.parse(lm.group(2)!) * 1000 +
          ((int.tryParse(lm.group(3) ?? '0') ?? 0) * 10);
      lines.add(LyricLine(
        start: Duration(milliseconds: ms),
        duration: const Duration(seconds: 3),
        text: line.substring(lm.end),
      ));
      continue;
    }
    // 元信息行如 [ti:...] 跳过；其余纯文本保留
    if (line.startsWith('[') && line.contains(':') && line.contains(']')) continue;
    lines.add(LyricLine(
      start: Duration(milliseconds: lines.length * 3000),
      duration: const Duration(seconds: 3),
      text: line,
    ));
  }
  lines.sort((a, b) => a.start.compareTo(b.start));
  return lines;
}

/// 当前应高亮的歌词行下标（-1 表示尚未开始）
int lyricIndexAt(List<LyricLine> lines, Duration pos) {
  var idx = -1;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].start <= pos) {
      idx = i;
    } else {
      break;
    }
  }
  return idx;
}

class SeoComment {
  final String id;
  final String content;
  final int diggCount;
  final int timeCreated;
  final String nickname;
  const SeoComment({
    required this.id,
    required this.content,
    this.diggCount = 0,
    this.timeCreated = 0,
    this.nickname = '',
  });
  factory SeoComment.fromJson(Map<String, dynamic> j) => SeoComment(
        id: _str(j['id']),
        content: _str(j['content']),
        diggCount: _int(j['count_digged']),
        timeCreated: _int(j['time_created']),
        nickname: _str((j['user'] as Map<String, dynamic>?)?['nickname']),
      );
}

/// video_model 里的一档可播流
class PlayStream {
  final String quality;
  final String codecType;
  final int bitrate;
  final int size;
  final String mainUrl;
  final String backupUrl;

  /// CENC 加密档的 spade_a（平台 B 路每档自带；明文流为空串）
  final String spadeA;
  const PlayStream({
    required this.quality,
    this.codecType = '',
    this.bitrate = 0,
    this.size = 0,
    required this.mainUrl,
    this.backupUrl = '',
    this.spadeA = '',
  });

  bool get isEncrypted => spadeA.isNotEmpty;
}

/// 解析内嵌 video_model JSON 串 → 流列表（seo 与平台通道共用同一形状）
List<PlayStream> parseVideoModelStreams(String raw) {
  if (raw.isEmpty) return const [];
  try {
    final vm = jsonDecode(raw) as Map<String, dynamic>;
    final streams = <PlayStream>[];
    for (final v in (vm['video_list'] as List?) ?? const []) {
      final item = v as Map<String, dynamic>;
      final meta = (item['video_meta'] as Map<String, dynamic>?) ?? const {};
      final mainUrl = _str(item['main_url']);
      if (mainUrl.isEmpty) continue;
      final enc = (item['encrypt_info'] as Map<String, dynamic>?) ?? const {};
      streams.add(PlayStream(
        quality: _str(meta['quality']),
        codecType: _str(meta['codec_type']),
        bitrate: _int(meta['bitrate']),
        size: _int(meta['size']),
        mainUrl: mainUrl,
        backupUrl: _str(item['backup_url']),
        spadeA: _str(enc['spade_a']),
      ));
    }
    return streams;
  } catch (_) {
    return const [];
  }
}

/// seo_track 一次拿齐的播放页数据
class SeoTrack {
  final Track track;
  final String lyricRaw;
  final List<PlayStream> streams;
  final int expireAt; // epoch 秒
  final List<SeoComment> comments;
  final List<Track> albumTracks;
  final List<Track> artistTracks;
  final List<Track> chartTracks;

  const SeoTrack({
    required this.track,
    this.lyricRaw = '',
    this.streams = const [],
    this.expireAt = 0,
    this.comments = const [],
    this.albumTracks = const [],
    this.artistTracks = const [],
    this.chartTracks = const [],
  });

  List<LyricLine> get lyricLines => parseLyric(lyricRaw);
  bool get hasPlayable => streams.isNotEmpty;
  bool isExpired(DateTime now, {int skewSeconds = 60}) =>
      expireAt > 0 && now.millisecondsSinceEpoch ~/ 1000 >= expireAt - skewSeconds;

  static List<Track> _wrappedList(dynamic v) {
    if (v is! List) return const [];
    return v.map((e) => Track.fromWrapped(e)).whereType<Track>().toList();
  }

  factory SeoTrack.fromJson(Map<String, dynamic> body) {
    final seoTrack = (body['seo_track'] as Map<String, dynamic>?) ?? const {};
    final trackJson = (seoTrack['track'] as Map<String, dynamic>?) ?? const {};
    final player = (body['track_player'] as Map<String, dynamic>?) ?? const {};
    final vmRaw = player['video_model'];
    final streams =
        vmRaw is String ? parseVideoModelStreams(vmRaw) : const <PlayStream>[];
    final commentsJson = body['comments'] as Map<String, dynamic>?;
    return SeoTrack(
      track: Track.fromJson(trackJson),
      lyricRaw: _str((body['lyric'] as Map<String, dynamic>?)?['content']),
      streams: streams,
      expireAt: _int(player['expire_at']),
      comments: ((commentsJson?['comments'] as List?) ?? const [])
          .map((e) => SeoComment.fromJson(e as Map<String, dynamic>))
          .toList(),
      albumTracks: _wrappedList(body['album_tracks']),
      artistTracks: _wrappedList(body['artist_tracks']),
      chartTracks: _wrappedList(body['chart_tracks']),
    );
  }
}

/// 首页发现数据（discover 电台 + discover/mix 歌单）
class HomeFeed {
  final List<RadioStation> radios;
  final List<Playlist> playlists;
  final String? mixCursor;
  final bool mixHasMore;
  const HomeFeed({
    this.radios = const [],
    this.playlists = const [],
    this.mixCursor,
    this.mixHasMore = false,
  });
}
