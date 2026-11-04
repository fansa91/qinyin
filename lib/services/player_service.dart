import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'library_service.dart';
import 'play_queue.dart';
import 'play_resolver.dart';
import 'settings_service.dart';

/// 播放会话：主会话（首页/搜索/详情/电台/我的/下载等一切普通来源）
/// 与推荐会话（推荐页专用）。物理上只有一个音频输出，同一时刻只有
/// 一个会话占用引擎；会话之间互不传递、互不接管（用户定版的隔离
/// 逻辑，取代早先的「推荐会话挂起/恢复」交接）。
enum PlayerSession { main, recommend }

/// 非活动会话的状态存档：曲目/下标/续拉回调/曲内位置。活动会话的
/// 状态直接活在引擎里（queue/position 等），切换输出时互换。
class _SessionStore {
  List<Track> items = [];
  int index = 0;
  Future<List<Track>> Function()? loadMore;
  Duration position = Duration.zero;
  bool hasContent = false;

  void clear() {
    items = [];
    index = 0;
    loadMore = null;
    position = Duration.zero;
    hasContent = false;
  }
}

/// 播放器：全 App 唯一的播放引擎（main.dart 构造一份、Provider
/// 全局注入；内部只有一个 AudioPlayer 实例）。
///
/// 会话隔离（用户定版）：播放入口按来源分两条——
/// - 主会话：[playQueue]/[jumpTo] 等既有入口，MiniPlayer 与播放页
///   绑定它；
/// - 推荐会话：[startRecommendSession] 等 recommend* 入口，只活在
///   推荐页里，它的曲目**永不出现在 MiniPlayer 上**，也不与主队列
///   互相交接。
/// 两侧谁开始播，另一侧暂停并把状态存进自己的 store，之后从存档
/// 处恢复（曲目/下标/位置原样）。队列推进实现只有一处：活动会话
/// 的按钮、上下滑手势、播完自动推进都走
/// [next]/[prev]/[_onCompleted] → [PlayQueue] → [_playAt]；
/// 非活动会话的 recommend* 控制只改它自己 store 的下标/位置，
/// 不触碰音频。
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

  /// 引擎当前队列的来源标记：推荐会话占用输出时为 'recommend'，
  /// 主会话时为 null（随会话切换同步，仅作展示/调试口径；
  /// 会话判断以 [activeSession] 为准）。
  String? queueTag;
  static const String recommendQueueTag = 'recommend';

  /// 当前占用引擎（音频输出）的会话；另一会话的状态在它的 store 里
  PlayerSession _activeSession = PlayerSession.main;
  final _mainStore = _SessionStore();
  final _recommendStore = _SessionStore();

  PlayerSession get activeSession => _activeSession;
  bool get recommendIsActive => _activeSession == PlayerSession.recommend;

  _SessionStore _storeOf(PlayerSession s) =>
      s == PlayerSession.main ? _mainStore : _recommendStore;

  /// 把引擎当前状态存入 [session] 的 store（切换输出前调用，同步落位）
  void _stashEngineInto(PlayerSession session) {
    final store = _storeOf(session);
    store.items = List.of(queue.items);
    store.index = queue.index;
    store.loadMore = onLoadMore;
    store.position = _position;
    store.hasContent = !queue.isEmpty;
  }

  /// 暂停引擎音频（不等待平台 future：状态切换先行落位，平台通道
  /// 本身按调用顺序执行，pause 必在后续 play 之前生效）
  void _pauseEngine() {
    unawaited(_player.pause().catchError((_) {}));
  }

  /// 把 [session] store 里的会话装入引擎并从存档下标起播（抢输出）。
  /// 调用方须保证 store 有内容、且当前活动会话已 stash + 暂停。
  Future<void> _activateFromStore(PlayerSession session) async {
    final store = _storeOf(session);
    _activeSession = session;
    queueTag = session == PlayerSession.recommend ? recommendQueueTag : null;
    onLoadMore = store.loadMore;
    queue.setQueue(List.of(store.items), store.index);
    final resumePos = store.position;
    store.clear();
    _currentSeo = null;
    _currentQuality = null;
    _error = null;
    notifyListeners();
    await _playAt(queue.index);
    // 会话内位置比历史续播进度更新，以它为准恢复
    if (resumePos > Duration.zero) {
      try {
        await _player.seek(resumePos);
      } catch (_) {}
    }
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

  // ── 会话视图（隔离口径）────────────────────────────────────────

  /// MiniPlayer 是否有内容可显示：只有**主会话**占用输出且有曲目
  /// 时才为 true。推荐会话占用输出时一律 false——它的曲目永不
  /// 出现在 mini 条上（各页一致）；主会话的曲目/下标在它的 store
  /// 里原样保留，但 mini 条在推荐占用期间按「无主队列内容」隐藏，
  /// 不拿推荐的进度冒充主会话状态（不误导）。
  bool get miniBarHasContent =>
      _activeSession == PlayerSession.main && currentTrack != null;

  /// 主会话视图（占用输出时即引擎本身，否则读主会话 store）
  bool get mainHasContent =>
      recommendIsActive ? _mainStore.hasContent : !queue.isEmpty;
  List<Track> get mainQueueItems =>
      recommendIsActive ? List.unmodifiable(_mainStore.items) : queueItems;
  int get mainCurrentIndex =>
      recommendIsActive ? _mainStore.index : currentIndex;
  Track? get mainCurrentTrack {
    final items = mainQueueItems;
    if (items.isEmpty) return null;
    return items[mainCurrentIndex.clamp(0, items.length - 1)];
  }

  /// 推荐会话视图（占用输出时即引擎本身，否则读推荐会话 store）
  bool get recommendHasContent =>
      recommendIsActive ? !queue.isEmpty : _recommendStore.hasContent;
  List<Track> get recommendQueueItems => recommendIsActive
      ? queueItems
      : List.unmodifiable(_recommendStore.items);
  int get recommendCurrentIndex =>
      recommendIsActive ? currentIndex : _recommendStore.index;
  Track? get recommendCurrentTrack {
    final items = recommendQueueItems;
    if (items.isEmpty) return null;
    return items[recommendCurrentIndex.clamp(0, items.length - 1)];
  }
  Duration get recommendPosition =>
      recommendIsActive ? position : _recommendStore.position;
  Duration get recommendDuration => recommendIsActive
      ? duration
      : Duration(milliseconds: recommendCurrentTrack?.durationMs ?? 0);
  bool get recommendPlaying => recommendIsActive && playing;
  bool get recommendLoading => recommendIsActive && loading;
  bool get recommendPreparingLossless =>
      recommendIsActive && preparingLossless;
  String? get recommendError => recommendIsActive ? error : null;
  String? get recommendQuality => recommendIsActive ? currentQuality : null;

  // ── 主会话入口 ────────────────────────────────────────────────

  /// 主会话建队列并起播（点播即建队列，照官方 QueueLoader 模型）。
  /// 首页/搜索/详情/电台/我的/下载的一切点播都走这里，只影响主
  /// 会话：推荐会话正占用输出时，先把它的状态原样存入推荐 store
  /// 并暂停，主会话接管输出；推荐会话内容分毫不动。
  /// [tag] 仅为兼容旧签名：传 recommendQueueTag 时转走推荐会话
  /// 入口（[startRecommendSession]），新代码不应再传。
  Future<void> playQueue(
    List<Track> tracks,
    int startIndex, {
    Future<List<Track>> Function()? loadMore,
    String? tag,
  }) async {
    if (tracks.isEmpty) return;
    if (tag == recommendQueueTag) {
      await startRecommendSession(tracks, startIndex, loadMore: loadMore);
      return;
    }
    if (recommendIsActive) {
      _stashEngineInto(PlayerSession.recommend);
      _activeSession = PlayerSession.main;
      _pauseEngine();
    }
    _mainStore.clear();
    onLoadMore = loadMore;
    queueTag = null;
    queue.setQueue(tracks, startIndex);
    notifyListeners();
    await _playAt(queue.index);
  }

  // ── 推荐会话入口（只活在推荐页，与主会话互不传递）────────────

  /// 以新曲目建立推荐会话并抢占输出起播：主会话状态原样存入主
  /// store 并暂停，之后主会话点播或推荐页再建会话才轮到它恢复。
  Future<void> startRecommendSession(
    List<Track> tracks,
    int startIndex, {
    Future<List<Track>> Function()? loadMore,
  }) async {
    if (tracks.isEmpty) return;
    if (!recommendIsActive) {
      _stashEngineInto(PlayerSession.main);
      _activeSession = PlayerSession.recommend;
      _pauseEngine();
    }
    _recommendStore.clear();
    onLoadMore = loadMore;
    queueTag = recommendQueueTag;
    queue.setQueue(tracks, startIndex);
    notifyListeners();
    await _playAt(queue.index);
  }

  /// 预置/替换推荐会话内容但不抢输出（主会话在播、用户在推荐页
  /// 改选场景时用）：推荐页据此展示新场景的流（暂停态），用户点
  /// 播放才由 [claimRecommendOutput] 接管输出。推荐会话正占用
  /// 输出时调用无意义（那种情况走 [startRecommendSession]），
  /// 直接忽略。
  void setRecommendSession(
    List<Track> tracks, {
    Future<List<Track>> Function()? loadMore,
  }) {
    if (recommendIsActive) return;
    _recommendStore.items = List.of(tracks);
    _recommendStore.index = 0;
    _recommendStore.loadMore = loadMore;
    _recommendStore.position = Duration.zero;
    _recommendStore.hasContent = tracks.isNotEmpty;
    notifyListeners();
  }

  /// 推荐会话抢回输出：主会话状态存入主 store 暂停，推荐会话从
  /// 存档下标/位置续播。已占用输出或会话为空时为空操作。
  Future<void> claimRecommendOutput() async {
    if (recommendIsActive || !_recommendStore.hasContent) return;
    _stashEngineInto(PlayerSession.main);
    _pauseEngine();
    await _activateFromStore(PlayerSession.recommend);
  }

  /// 推荐页播放/暂停键：占用输出时就是暂停/继续；未占用时抢回
  /// 输出从存档处续播。
  Future<void> toggleRecommend() async {
    if (recommendIsActive) {
      await toggle();
      return;
    }
    await claimRecommendOutput();
  }

  /// 推荐页下一首：占用输出走引擎推进；未占用只挪推荐 store 的
  /// 下标（到尾则经会话自己的续拉回调补页），不触碰音频与主会话。
  Future<void> recommendNext() async {
    if (recommendIsActive) {
      await next();
      return;
    }
    final s = _recommendStore;
    if (s.items.isEmpty) return;
    if (s.index < s.items.length - 1) {
      s.index++;
      s.position = Duration.zero;
      notifyListeners();
      return;
    }
    final loader = s.loadMore;
    if (loader == null) return;
    final more = await loader();
    if (more.isEmpty) return;
    s.items.addAll(more);
    s.index++;
    s.position = Duration.zero;
    notifyListeners();
  }

  /// 推荐页上一首（口径同 [recommendNext]）
  Future<void> recommendPrev() async {
    if (recommendIsActive) {
      await prev();
      return;
    }
    final s = _recommendStore;
    if (s.items.isEmpty || s.index <= 0) return;
    s.index--;
    s.position = Duration.zero;
    notifyListeners();
  }

  /// 推荐页跳到某首（纵向滑动落点/列表点选）：占用输出走引擎
  /// [jumpTo]；未占用只改推荐 store 下标。
  Future<void> recommendJumpTo(int index) async {
    if (recommendIsActive) {
      await jumpTo(index);
      return;
    }
    final s = _recommendStore;
    if (index < 0 || index >= s.items.length || index == s.index) return;
    s.index = index;
    s.position = Duration.zero;
    notifyListeners();
  }

  /// 推荐页拖动进度：占用输出走引擎 seek；未占用只记到推荐
  /// store，抢回输出时从该位置续播。
  Future<void> recommendSeek(Duration pos) async {
    if (recommendIsActive) {
      await seek(pos);
      return;
    }
    _recommendStore.position = pos;
    notifyListeners();
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
