import '../models/models.dart';

/// 推荐流分页器（游客态 emulated 推荐流）。
///
/// 背景（2026-11-04 实测，见 QISHUI_API.md §14）：官方推荐流本体
/// `/luna/feed/song-tab` 游客被设备门拦截（1000006），无法直接使用；
/// 本分页器用三个游客可用的源组合出同形态的可持续曲目流：
/// 1. 相关歌曲 `/luna/media/related`：每批 6 首，种子邻域约 40–60 首后枯竭，
///    靠「末曲作新种子」链式换邻域续命；
/// 2. 发现歌单 discover/mix + playlist/detail：歌单池轮换、跨歌单几乎不重叠，
///    单歌单 5–60+ 首，是深度主力；
/// 3. 电台 feed/radio/tracks：12 个电台轮换，每批 6 首，单台小池轮换扩容。
///
/// 三源轮转拉取，会话内按 track id 去重；三个源一整轮都无新增才判定枯竭。
class RecommendPager {
  final Future<List<Track>> Function(String seedTrackId) fetchRelated;
  final Future<(List<Playlist>, String?, bool)> Function(String cursor)
      fetchPlaylistList;
  final Future<(Playlist, List<Track>, String?)> Function(String id,
      {String? cursor}) fetchPlaylistTracks;
  final Future<List<Track>> Function(String radioId, String cursor)
      fetchRadioPage;
  final List<String> radioIds;

  RecommendPager({
    required this.fetchRelated,
    required this.fetchPlaylistList,
    required this.fetchPlaylistTracks,
    required this.fetchRadioPage,
    required this.radioIds,
  });

  // 初始快照（prime 注入，reset 时恢复）
  List<Playlist> _initialPlaylists = const [];
  String? _initialMixCursor;
  bool _initialMixHasMore = false;

  final Set<String> _seen = {};
  final List<Track> _pending = [];
  final List<Playlist> _playlistBacklog = [];
  String? _mixCursor;
  bool _mixHasMore = false;
  bool _mixStarted = false;
  String? _seed;
  int _radioIndex = 0;
  final Map<String, int> _radioOffsets = {};
  int _turn = 0;
  bool _exhausted = false;

  bool get hasMore => !_exhausted;
  int get seenCount => _seen.length;

  /// 注入首页已拉到的歌单快照，避免重复请求第一页
  void prime({
    required List<Playlist> playlists,
    required String? mixCursor,
    required bool mixHasMore,
  }) {
    _initialPlaylists = List.of(playlists);
    _initialMixCursor = mixCursor;
    _initialMixHasMore = mixHasMore;
    _restoreMix();
  }

  void _restoreMix() {
    _playlistBacklog
      ..clear()
      ..addAll(_initialPlaylists);
    _mixCursor = _initialMixCursor;
    _mixHasMore = _initialMixHasMore;
    _mixStarted = _initialPlaylists.isNotEmpty || _initialMixCursor != null;
  }

  /// 下拉刷新：清掉去重与全部源状态（各源池子本身会轮换，刷新即新一批）
  void reset() {
    _seen.clear();
    _pending.clear();
    _seed = null;
    _radioIndex = 0;
    _radioOffsets.clear();
    _turn = 0;
    _exhausted = false;
    _restoreMix();
  }

  /// 取下一页（目标 [target] 首）；返回空且 [hasMore] 为 false 表示真到尽头
  Future<List<Track>> nextPage({int target = 12}) async {
    if (_exhausted) return const [];
    final out = <Track>[];
    var dryRounds = 0;
    while (out.length < target) {
      if (_pending.isEmpty) {
        final added = await _fillFromNextSource();
        if (added == 0) {
          dryRounds++;
          if (dryRounds >= 3) {
            _exhausted = true;
            break;
          }
          continue;
        }
        dryRounds = 0;
      }
      final take = (target - out.length).clamp(0, _pending.length);
      out.addAll(_pending.sublist(0, take));
      _pending.removeRange(0, take);
    }
    if (out.isNotEmpty) _seed = out.last.id;
    return out;
  }

  /// 轮转到下一个源拉一批进缓冲，返回新增（未见过）条数
  Future<int> _fillFromNextSource() async {
    final kind = _turn % 3;
    _turn++;
    try {
      final added = await switch (kind) {
        0 => _fillFromRelated(),
        1 => _fillFromPlaylist(),
        _ => _fillFromRadio(),
      };
      return added;
    } catch (_) {
      return 0; // 单源失败按无新增处理，靠其它源续命；整轮全失败才枯竭
    }
  }

  int _absorb(Iterable<Track> tracks) {
    var added = 0;
    for (final t in tracks) {
      if (t.id.isEmpty) continue;
      if (_seen.add(t.id)) {
        _pending.add(t);
        added++;
      }
    }
    return added;
  }

  Future<int> _fillFromRelated() async {
    final seed = _seed;
    if (seed == null) return 0;
    final batch = await fetchRelated(seed);
    if (batch.isNotEmpty) _seed = batch.last.id; // 链式换种子，不困在旧邻域
    return _absorb(batch);
  }

  Future<int> _fillFromPlaylist() async {
    if (_playlistBacklog.isEmpty) {
      if (!_mixStarted || _mixHasMore) {
        final (lists, next, hasMore) =
            await fetchPlaylistList(_mixCursor ?? '0');
        _mixStarted = true;
        _mixCursor = next;
        _mixHasMore = hasMore;
        final known = _playlistBacklog.map((p) => p.id).toSet();
        _playlistBacklog.addAll(lists.where((p) => known.add(p.id)));
      }
      if (_playlistBacklog.isEmpty) return 0;
    }
    final playlist = _playlistBacklog.removeAt(0);
    // 单歌单全量拉完（分页上限 12 页防极端大单）
    final all = <Track>[];
    String? cursor;
    for (var page = 0; page < 12; page++) {
      final (_, tracks, next) =
          await fetchPlaylistTracks(playlist.id, cursor: cursor);
      all.addAll(tracks);
      cursor = next;
      if (cursor == null || tracks.isEmpty) break;
    }
    return _absorb(all);
  }

  Future<int> _fillFromRadio() async {
    if (radioIds.isEmpty) return 0;
    final radioId = radioIds[_radioIndex % radioIds.length];
    _radioIndex++;
    final offset = _radioOffsets[radioId] ?? 0;
    final batch = await fetchRadioPage(radioId, '$offset');
    _radioOffsets[radioId] = offset + (batch.isEmpty ? 6 : batch.length);
    return _absorb(batch);
  }
}
