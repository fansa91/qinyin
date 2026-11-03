import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

/// 本地自建歌单
class MyPlaylist {
  final String id;
  String name;
  List<Track> tracks;
  MyPlaylist({required this.id, required this.name, List<Track>? tracks})
      : tracks = tracks ?? <Track>[];

  factory MyPlaylist.fromJson(Map<String, dynamic> j) => MyPlaylist(
        id: '${j['id']}',
        name: '${j['name'] ?? ''}',
        tracks: ((j['tracks'] as List?) ?? const [])
            .map((e) => Track.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'tracks': tracks.map((t) => t.toJson()).toList(),
      };
}

/// 本地资料库：收藏/自建歌单/历史/续播进度/搜索历史。
/// 全部 SharedPreferences JSON 持久化（游客态无云端，本地即全部）。
class LibraryService extends ChangeNotifier {
  static const _kFavTracks = 'fav_tracks';
  static const _kFavPlaylists = 'fav_playlists';
  static const _kFavAlbums = 'fav_albums';
  static const _kMyPlaylists = 'my_playlists';
  static const _kHistory = 'history';
  static const _kProgress = 'progress';
  static const _kSearchHistory = 'search_history';

  static const int capTracks = 200;
  static const int capCollections = 100;
  static const int capHistory = 100;

  List<Track> _favTracks = [];
  List<Playlist> _favPlaylists = [];
  List<Album> _favAlbums = [];
  List<MyPlaylist> _myPlaylists = [];
  List<Track> _history = [];
  Map<String, Map<String, int>> _progress = {}; // trackId -> {pos, dur} 毫秒
  List<String> _searchHistory = [];

  List<Track> get favoriteTracks => List.unmodifiable(_favTracks);
  List<Playlist> get favoritePlaylists => List.unmodifiable(_favPlaylists);
  List<Album> get favoriteAlbums => List.unmodifiable(_favAlbums);
  List<MyPlaylist> get myPlaylists => List.unmodifiable(_myPlaylists);
  List<Track> get history => List.unmodifiable(_history);
  List<String> get searchHistory => List.unmodifiable(_searchHistory);

  bool isFavTrack(String id) => _favTracks.any((t) => t.id == id);
  bool isFavPlaylist(String id) => _favPlaylists.any((p) => p.id == id);
  bool isFavAlbum(String id) => _favAlbums.any((a) => a.id == id);

  List<Map<String, dynamic>> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final v = jsonDecode(raw);
      if (v is List) return v.cast<Map<String, dynamic>>();
    } catch (_) {}
    return const [];
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _favTracks = _decode(prefs.getString(_kFavTracks))
        .map(Track.fromJson)
        .toList();
    _favPlaylists = _decode(prefs.getString(_kFavPlaylists))
        .map(Playlist.fromJson)
        .toList();
    _favAlbums =
        _decode(prefs.getString(_kFavAlbums)).map(Album.fromJson).toList();
    _myPlaylists = _decode(prefs.getString(_kMyPlaylists))
        .map(MyPlaylist.fromJson)
        .toList();
    _history =
        _decode(prefs.getString(_kHistory)).map(Track.fromJson).toList();
    _searchHistory = prefs.getStringList(_kSearchHistory) ?? [];
    final rawProgress = prefs.getString(_kProgress);
    if (rawProgress != null && rawProgress.isNotEmpty) {
      try {
        final map = (jsonDecode(rawProgress) as Map).cast<String, dynamic>();
        _progress = map.map((k, v) => MapEntry(
            k, (v as Map).map((a, b) => MapEntry('$a', (b as num).toInt()))));
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> _persist(String key, List<Map<String, dynamic>> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(list));
  }

  Future<void> toggleFavTrack(Track track) async {
    if (isFavTrack(track.id)) {
      _favTracks.removeWhere((t) => t.id == track.id);
    } else {
      _favTracks = [track, ..._favTracks].take(capTracks).toList();
    }
    await _persist(_kFavTracks, _favTracks.map((t) => t.toJson()).toList());
    notifyListeners();
  }

  Future<void> toggleFavPlaylist(Playlist playlist) async {
    if (isFavPlaylist(playlist.id)) {
      _favPlaylists.removeWhere((p) => p.id == playlist.id);
    } else {
      _favPlaylists =
          [playlist, ..._favPlaylists].take(capCollections).toList();
    }
    await _persist(
        _kFavPlaylists, _favPlaylists.map((p) => p.toJson()).toList());
    notifyListeners();
  }

  Future<void> toggleFavAlbum(Album album) async {
    if (isFavAlbum(album.id)) {
      _favAlbums.removeWhere((a) => a.id == album.id);
    } else {
      _favAlbums = [album, ..._favAlbums].take(capCollections).toList();
    }
    await _persist(_kFavAlbums, _favAlbums.map((a) => a.toJson()).toList());
    notifyListeners();
  }

  Future<MyPlaylist> createPlaylist(String name) async {
    final p = MyPlaylist(
      id: 'local${DateTime.now().millisecondsSinceEpoch}',
      name: name.trim().isEmpty ? '未命名歌单' : name.trim(),
    );
    _myPlaylists = [p, ..._myPlaylists];
    await _persistMy();
    notifyListeners();
    return p;
  }

  Future<void> deletePlaylist(String id) async {
    _myPlaylists.removeWhere((p) => p.id == id);
    await _persistMy();
    notifyListeners();
  }

  Future<void> addToPlaylist(String playlistId, Track track) async {
    final p = _myPlaylists.where((e) => e.id == playlistId).firstOrNull;
    if (p == null) return;
    if (p.tracks.any((t) => t.id == track.id)) return;
    p.tracks.add(track);
    await _persistMy();
    notifyListeners();
  }

  Future<void> removeFromPlaylist(String playlistId, String trackId) async {
    final p = _myPlaylists.where((e) => e.id == playlistId).firstOrNull;
    if (p == null) return;
    p.tracks.removeWhere((t) => t.id == trackId);
    await _persistMy();
    notifyListeners();
  }

  Future<void> _persistMy() => _persist(
      _kMyPlaylists, _myPlaylists.map((p) => p.toJson()).toList());

  Future<void> addHistory(Track track) async {
    _history = [
      track,
      ..._history.where((t) => t.id != track.id),
    ].take(capHistory).toList();
    await _persist(_kHistory, _history.map((t) => t.toJson()).toList());
    notifyListeners();
  }

  Future<void> clearHistory() async {
    _history = [];
    await _persist(_kHistory, const []);
    notifyListeners();
  }

  ({int pos, int dur})? progressOf(String trackId) {
    final p = _progress[trackId];
    if (p == null) return null;
    return (pos: p['pos'] ?? 0, dur: p['dur'] ?? 0);
  }

  Future<void> saveProgress(String trackId, Duration pos, Duration dur) async {
    if (trackId.isEmpty) return;
    _progress[trackId] = {
      'pos': pos.inMilliseconds,
      'dur': dur.inMilliseconds,
    };
    if (_progress.length > capTracks) {
      _progress.remove(_progress.keys.first);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kProgress, jsonEncode(_progress));
  }

  Future<void> clearProgress(String trackId) async {
    _progress.remove(trackId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kProgress, jsonEncode(_progress));
  }

  Future<void> addSearchHistory(String q) async {
    final kw = q.trim();
    if (kw.isEmpty) return;
    _searchHistory = [kw, ..._searchHistory.where((e) => e != kw)]
        .take(20)
        .toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kSearchHistory, _searchHistory);
    notifyListeners();
  }

  Future<void> clearSearchHistory() async {
    _searchHistory = [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kSearchHistory, const []);
    notifyListeners();
  }
}
