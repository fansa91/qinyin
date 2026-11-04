import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'library_service.dart';
import 'play_queue.dart';
import 'play_resolver.dart';
import 'settings_service.dart';

/// 播放器：全 App 唯一的播放引擎与当前队列持有者（main.dart 构造
/// 一份、Provider 全局注入；内部只有一个 AudioPlayer 实例）。
/// 所有来源（首页/搜索/详情/电台/我的/下载/推荐）的点播都汇入
/// [playQueue]/[jumpTo]，MiniPlayer 与各播放面订阅的都是这一份
/// 状态——不存在第二个播放器或第二条队列。队列推进也只有一处
/// 实现：按钮、上下滑手势、播完自动推进全部走
/// [next]/[prev]/[_onCompleted] → [PlayQueue] → [_playAt]。
/// 来源交接与推荐会话挂起/恢复见 [playQueue] 与 [resumeRecommendQueue]。
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
  bool _preparingLossless = false;

  /// 当前队列来源标记（推荐页建队时传 'recommend'，其余来源为 null）。
  /// 推荐页据此判断「队列已经是推荐流」还是「别的内容在播，不要打断」。
  String? queueTag;
  static const String recommendQueueTag = 'recommend';

  /// 被外部来源接管时挂起的推荐会话快照（队列 + 下标 + 续拉回调）。
  ///
  /// 推荐不是独立播放器：全 App 只有一个引擎、一条当前队列（见本类
  /// 顶部注释），推荐流同样活在这条队列里。用户中途去播首页/搜索等
  /// 其他来源，是正常交接——当前队列被新点播替换；但推荐会话不该
  /// 就此蒸发：替换前把队列与下标快照下来，推荐页就能从暂停处原样
  /// 恢复（[resumeRecommendQueue]），而不是每次都从第一首重建。
  /// 快照只存一份；新的推荐会话建立时清除，恢复后亦清除。
  List<Track>? _suspendedQueueItems;
  int _suspendedQueueIndex = 0;
  Future<List<Track>> Function()? _suspendedLoadMore;

  /// 是否有一份被挂起的推荐会话可恢复
  bool get hasSuspendedRecommend =>
      _suspendedQueueItems != null && _suspendedQueueItems!.isNotEmpty;

  /// 挂起的推荐会话停在的那首（供推荐页提示页展示「暂停在《X》」）
  Track? get suspendedRecommendTrack {
    final items = _suspendedQueueItems;
    if (items == null || items.isEmpty) return null;
    return items[_suspendedQueueIndex.clamp(0, items.length - 1)];
  }
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

  /// 正在下载+解密无损（耗时操作，UI 显示准备态，别让用户以为卡死）
  bool get preparingLossless => _preparingLossless;
  bool get hasQueue => !queue.isEmpty;
  Duration get position => _position;
  Duration get duration => _duration;
  String? get error => _error;
  String? get currentQuality => _currentQuality;
  QueueLoopMode get mode => queue.mode;
  int get currentIndex => queue.index;
  List<Track> get queueItems => List.unmodifiable(queue.items);

  /// 从某个来源建队列并起播（点播即建队列，照官方 QueueLoader 模型）
  ///
  /// 来源交接语义（全 App 统一）：无论点播来自首页/搜索/详情/电台/
  /// 我的/下载/推荐，进的都是这一条队列。当前队列是推荐流而新点播
  /// 不是时，先把推荐会话快照挂起（见 [_suspendedQueueItems]），
  /// 再干净换队——不残留第二份队列状态；新点播本身是推荐流时，
  /// 视为新会话建立，旧快照作废。
  Future<void> playQueue(
    List<Track> tracks,
    int startIndex, {
    Future<List<Track>> Function()? loadMore,
    String? tag,
  }) async {
    if (tracks.isEmpty) return;
    if (tag == recommendQueueTag) {
      _clearSuspendedRecommend();
    } else if (queueTag == recommendQueueTag && !queue.isEmpty) {
      _suspendedQueueItems = List.of(queue.items);
      _suspendedQueueIndex = queue.index;
      _suspendedLoadMore = onLoadMore;
    }
    onLoadMore = loadMore;
    queueTag = tag;
    queue.setQueue(tracks, startIndex);
    await _playAt(queue.index);
  }

  void _clearSuspendedRecommend() {
    _suspendedQueueItems = null;
    _suspendedQueueIndex = 0;
    _suspendedLoadMore = null;
  }

  /// 恢复被挂起的推荐会话：队列、下标、续拉回调原样还原并从挂起处
  /// 起播（曲内进度由 [_playAt] 的既有续播逻辑按已保存进度恢复）。
  /// 返回是否确有快照可恢复；无快照时不触碰当前队列。
  Future<bool> resumeRecommendQueue() async {
    final items = _suspendedQueueItems;
    if (items == null || items.isEmpty) return false;
    final index = _suspendedQueueIndex;
    final loadMore = _suspendedLoadMore;
    _clearSuspendedRecommend();
    onLoadMore = loadMore;
    queueTag = recommendQueueTag;
    queue.setQueue(items, index);
    await _playAt(queue.index);
    return true;
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
    _preparingLossless = false;
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
        final resolved = await resolver.resolveTrack(
          track,
          quality: settings.defaultQuality,
          onLosslessPreparing: () {
            if (token == _playToken) {
              _preparingLossless = true;
              notifyListeners();
            }
          },
        );
        if (token != _playToken) return;
        _preparingLossless = false;
        _currentSeo = resolver.cachedSeo(track.id);
        _currentQuality = resolved.stream.quality;
        if (resolved.isLocal) {
          // 无损解密产物：本地 FLAC 文件播放
          await _player.play(DeviceFileSource(resolved.localPath!));
        } else {
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
      _preparingLossless = false;
      _error = e.message;
      notifyListeners();
    } catch (e) {
      if (token != _playToken) return;
      _loading = false;
      _preparingLossless = false;
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
      final resolved = await resolver.resolveTrack(
        track,
        quality: quality,
        forceRefresh: false,
        onLosslessPreparing: () {
          _preparingLossless = true;
          notifyListeners();
        },
      );
      _preparingLossless = false;
      _currentSeo = resolver.cachedSeo(track.id);
      _currentQuality = resolved.stream.quality;
      if (resolved.isLocal) {
        await _player.play(DeviceFileSource(resolved.localPath!));
      } else {
        await _player.play(UrlSource(resolved.stream.mainUrl));
      }
      await _player.seek(pos);
      if (!wasPlaying) await _player.pause();
    } catch (e) {
      _preparingLossless = false;
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
