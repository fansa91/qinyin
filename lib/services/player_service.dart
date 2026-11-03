import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'library_service.dart';
import 'play_queue.dart';
import 'play_resolver.dart';
import 'settings_service.dart';

/// 播放器：队列推进只有一处实现——按钮、上下滑手势、播完自动推进
/// 全部走 [next]/[prev]/[_onCompleted] → [PlayQueue] → [_playAt]。
class PlayerService extends ChangeNotifier {
  final PlayResolver resolver;
  final SettingsService settings;
  final LibraryService library;

  /// 下载服务注入后，本地已下载文件优先播放（由 main 接线）
  String? Function(String trackId)? localFileFor;

  /// 队列续拉回调（歌单等分页来源）：返回追加的曲目
  Future<List<Track>> Function()? onLoadMore;
  bool _loadingMore = false;

  final AudioPlayer _player = AudioPlayer();
  final PlayQueue queue = PlayQueue();

  bool _playing = false;
  bool _loading = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _error;
  SeoTrack? _currentSeo;
  String? _currentQuality;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<PlayerState>? _stateSub;
  int _playToken = 0;
  Timer? _progressTimer;

  PlayerService(this.resolver, this.settings, this.library) {
    _posSub = _player.onPositionChanged.listen((p) {
      _position = p;
      notifyListeners();
    });
    _durSub = _player.onDurationChanged.listen((d) {
      _duration = d;
      notifyListeners();
    });
    _stateSub = _player.onPlayerStateChanged.listen((s) {
      _playing = s == PlayerState.playing;
      notifyListeners();
    });
    _player.onPlayerComplete.listen((_) => _onCompleted());
    _progressTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final t = currentTrack;
      if (t != null && _playing) {
        library.saveProgress(t.id, _position, _duration);
      }
    });
  }

  Track? get currentTrack => queue.current;
  SeoTrack? get currentSeo => _currentSeo;
  bool get playing => _playing;
  bool get loading => _loading;
  bool get hasQueue => !queue.isEmpty;
  Duration get position => _position;
  Duration get duration => _duration;
  String? get error => _error;
  String? get currentQuality => _currentQuality;
  QueueLoopMode get mode => queue.mode;
  int get currentIndex => queue.index;
  List<Track> get queueItems => List.unmodifiable(queue.items);

  /// 从某个来源建队列并起播（点播即建队列，照官方 QueueLoader 模型）
  Future<void> playQueue(
    List<Track> tracks,
    int startIndex, {
    Future<List<Track>> Function()? loadMore,
  }) async {
    if (tracks.isEmpty) return;
    onLoadMore = loadMore;
    queue.setQueue(tracks, startIndex);
    await _playAt(queue.index);
  }

  Future<void> playTrack(Track track) => playQueue([track], 0);

  /// 跳到队列中某一首（列表点播、上下滑落点都走这里）
  Future<void> jumpTo(int index) async {
    if (queue.isEmpty || index == queue.index) return;
    queue.jumpTo(index);
    await _playAt(queue.index);
  }

  /// 手动下一首（按钮与上滑共用）
  Future<void> next() async {
    final target = queue.manualNext();
    if (target == null) return;
    await _playAt(target);
  }

  /// 手动上一首（按钮与下滑共用）
  Future<void> prev() async {
    final target = queue.manualPrev();
    if (target == null) return;
    await _playAt(target);
  }

  /// 播完自动推进：SINGLE 重播本曲，其余按队列模式算下一首
  Future<void> _onCompleted() async {
    final t = currentTrack;
    if (t != null) await library.clearProgress(t.id);
    final before = queue.index;
    final target = queue.autoNext();
    if (target == null) return;
    if (target == before && mode == QueueLoopMode.single) {
      // autoNext 已原地保持 index（单曲循环语义）：从头重播
      try {
        await _player.seek(Duration.zero);
        await _player.resume();
      } catch (_) {}
      return;
    }
    await _playAt(target);
  }

  Future<void> _playAt(int index) async {
    final track = queue.current;
    if (track == null) return;
    final token = ++_playToken;
    _loading = true;
    _error = null;
    _position = Duration.zero;
    _duration = Duration(milliseconds: track.durationMs);
    notifyListeners();
    unawaited(library.addHistory(track));
    try {
      final local = localFileFor?.call(track.id);
      if (local != null && local.isNotEmpty) {
        await _player.play(DeviceFileSource(local));
        _currentSeo = resolver.cachedSeo(track.id);
        _currentQuality = '本地文件';
      } else {
        final resolved = await resolver.resolve(
          track.id,
          quality: settings.defaultQuality,
        );
        if (token != _playToken) return;
        _currentSeo = resolver.cachedSeo(track.id);
        _currentQuality = resolved.stream.quality;
        final source = UrlSource(resolved.stream.mainUrl);
        try {
          await _player.play(source);
        } catch (_) {
          // 主链失效回落备用链
          if (resolved.stream.backupUrl.isNotEmpty) {
            await _player.play(UrlSource(resolved.stream.backupUrl));
          } else {
            rethrow;
          }
        }
      }
      if (token != _playToken) return;
      await _player.setVolume(settings.volume);
      // 续播：有保存进度且不在开头/结尾时恢复
      final saved = library.progressOf(track.id);
      if (saved != null && saved.pos > 5000 && saved.dur > 0 && saved.pos < saved.dur - 10000) {
        try {
          await _player.seek(Duration(milliseconds: saved.pos));
        } catch (_) {}
      }
      _loading = false;
      notifyListeners();
      _prefetchNext();
      _maybeLoadMore();
    } on PlayUnavailable catch (e) {
      if (token != _playToken) return;
      _loading = false;
      _error = e.message;
      notifyListeners();
    } catch (e) {
      if (token != _playToken) return;
      _loading = false;
      _error = '播放失败：$e';
      notifyListeners();
    }
  }

  /// 预取下一首（与手动 next 同一推进口径的 peek；随机模式不可预知则跳过）
  void _prefetchNext() {
    final peek = queue.peekManualNext();
    if (peek == null) return;
    final nextTrack = queue.items[peek];
    unawaited(resolver.prefetch(nextTrack.id));
  }

  /// 播到队尾附近触发续拉（简化版 loadMore）
  void _maybeLoadMore() {
    if (onLoadMore == null || _loadingMore) return;
    if (queue.index < queue.items.length - 2) return;
    _loadingMore = true;
    onLoadMore!().then((more) {
      if (more.isNotEmpty) {
        queue.append(more);
        notifyListeners();
      }
    }).catchError((_) {}).whenComplete(() => _loadingMore = false);
  }

  /// 队列尾部追加（详情页分页加载后同步进队列）
  void appendToQueue(List<Track> more) {
    queue.append(more);
    notifyListeners();
  }

  Future<void> toggle() async {
    try {
      if (_playing) {
        await _player.pause();
      } else {
        await _player.resume();
      }
    } catch (_) {}
  }

  Future<void> seek(Duration pos) async {
    try {
      await _player.seek(pos);
    } catch (_) {}
  }

  Future<void> setVolume(double v) async {
    await settings.setVolume(v);
    try {
      await _player.setVolume(v);
    } catch (_) {}
  }

  void cycleMode() {
    queue.mode = switch (queue.mode) {
      QueueLoopMode.list => QueueLoopMode.shuffle,
      QueueLoopMode.shuffle => QueueLoopMode.single,
      QueueLoopMode.single => QueueLoopMode.list,
    };
    notifyListeners();
  }

  void setMode(QueueLoopMode m) {
    queue.mode = m;
    notifyListeners();
  }

  /// 切换音质：重解析当前曲并保持进度
  Future<void> setQuality(String quality) async {
    await settings.setQuality(quality);
    final track = currentTrack;
    if (track == null) return;
    final pos = _position;
    final wasPlaying = _playing;
    try {
      final resolved = await resolver.resolve(track.id,
          quality: quality, forceRefresh: false);
      _currentSeo = resolver.cachedSeo(track.id);
      _currentQuality = resolved.stream.quality;
      await _player.play(UrlSource(resolved.stream.mainUrl));
      await _player.seek(pos);
      if (!wasPlaying) await _player.pause();
    } catch (e) {
      _error = '切换音质失败：$e';
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }
}
