import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/responsive.dart';
import '../core/utils.dart';
import '../models/models.dart';
import '../services/play_resolver.dart';
import '../services/player_service.dart';
import '../services/qishui_service.dart';
import '../services/recommend_pager.dart';
import '../services/settings_service.dart';
import '../widgets/cover_image.dart';
import '../widgets/fresh_pager.dart';
import '../widgets/seek_bar.dart';
import '../widgets/track_badges.dart';
import 'player_screen.dart';

/// 推荐：页面本体就是新鲜模式播放形态（定版样板图口径）。
///
/// 数据源（2026-11-04 实测，见 QISHUI_API.md §15）：官方推荐流经车机
/// 开放平台通道（open.douyin.com LunaOpenSDK）游客可直接取到，主源即它；
/// 平台源异常时自动回退 §14 的三源组合（相关歌曲 + 发现歌单 + 电台）。
/// 游客拿到的是未个性化版（官方自述「登录后推荐更准」），文案如实标注。
///
/// 形态：直接复用 [FreshPager]（与播放页同一份纵向 PageView + 队列推进
/// 实现），队列就是推荐流，队尾 loadMore 接 [RecommendPager]。
/// 单页内部再套一层横向分页：右滑进当前曲的歌词页、左滑回推荐流页；
/// 进度条与播放/暂停键在封面正下方（控制行），歌词页底部同置一份；
/// 点评论开遮盖式抽屉（浮层盖住本页、底层不动）。
/// 整个页面包在 SafeArea 里：本页是壳层里唯一没有 AppBar 的主页面，
/// 不包就会与 iPhone 状态栏时间重叠（用户实报）。
/// 桌面端（≥900）沿用现有双栏播放页 [DesktopPlayer]（embedded 形态），
/// 不强求滑动。
/// 页头带场景入口（车机 feed/mode 45 种场景）：点 chip 开网格选择层，
/// 选中后以该场景重建推荐流，选择持久化；清单拉取失败时入口缺席。
///
/// 进页衔接策略（会话隔离，用户定版）：
/// - 推荐会话已有内容 → 直接展示会话当前状态（曲目/下标/位置），
///   无论它是否正占用输出；
/// - 推荐会话为空、主会话有内容 → 提示页：不打断主会话，用户点
///   「开始刷推荐」才建推荐会话接管输出（主会话暂停存档）；
/// - 两边都空 → 首次切到本页时自动建推荐会话起播。
/// 推荐播放是独立会话：不唤起 MiniPlayer、不与主队列互相传递
/// （见 PlayerService 的会话隔离说明）。
class RecommendScreen extends StatefulWidget {
  /// 当前是否被选中展示（IndexedStack 下靠它感知「进入本页」）
  final bool active;
  const RecommendScreen({
    super.key,
    this.active = false,
  });

  @override
  State<RecommendScreen> createState() => _RecommendScreenState();
}

enum RecommendEnter { showPager, showGate, startQueue }

/// 进页决策（纯函数，可测）：会话隔离口径——
/// - 推荐会话自己已有内容（占用输出中或已预置/暂停）→ 直接展示
///   会话当前状态（showPager）；
/// - 推荐会话为空、主会话有内容 → 提示页（showGate）：不打断主
///   会话，用户点「开始刷推荐」才以推荐会话接管输出；
/// - 两边都空 → 首次进入自动建会话起播（startQueue）。
RecommendEnter decideRecommendEnter({
  required bool sessionHasContent,
  required bool mainHasContent,
}) {
  if (sessionHasContent) return RecommendEnter.showPager;
  if (mainHasContent) return RecommendEnter.showGate;
  return RecommendEnter.startQueue;
}

class _RecommendScreenState extends State<RecommendScreen> {
  final List<Track> _tracks = [];
  RecommendPager? _pager;
  Future<void>? _initFuture;
  String? _initError;
  bool _enterHandled = false;
  bool _starting = false;
  bool _startFailed = false;

  /// 车机平台服务（单例复用：令牌与场景清单都有会话缓存，别每次新建）
  PlatformFeedService? _platform;

  /// 场景清单：null = 尚未拉到（入口不显示）；拉取失败保持 null，
  /// 场景入口优雅隐藏，默认流不受影响。
  List<FeedMode>? _modes;

  /// 当前选定场景（null = 默认推荐）；进页时从持久化恢复。
  FeedMode? _scene;

  Future<PlatformFeedService> _platformService() async {
    final existing = _platform;
    if (existing != null) return existing;
    final deviceId = await PlatformFeedService.loadOrCreateDeviceId();
    return _platform = PlatformFeedService(deviceId: deviceId);
  }

  @override
  void initState() {
    super.initState();
    _initFuture = _init();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) _onEnter();
    });
  }

  @override
  void didUpdateWidget(RecommendScreen old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      _enterHandled = false;
      _onEnter();
    }
    if (!widget.active) _enterHandled = false;
  }

  /// 构造一个全新的分页器（初始构造与「刷新换一批」共用同一条路，
  /// 保证刷新是真重建而不是假动作）。主源取流闭包带上当前场景
  /// （[_scene]），切换场景 = 以新场景重建分页器重拉。
  Future<RecommendPager> _createPager() async {
    final service = context.read<QishuiService>();
    // 主源（车机开放平台官方推荐流）不依赖 homeFeed：
    // homeFeed 只为回退源提供电台与歌单快照，失败时单独兜底为空
    final platform = await _platformService();
    HomeFeed? feed;
    try {
      feed = await service.homeFeed();
    } catch (_) {
      feed = null;
    }
    return RecommendPager(
      fetchPlatformPage: (cursor) =>
          platform.songTabPage(cursor, sceneModeId: _scene?.sceneModeId),
      fetchRelated: service.relatedTracks,
      fetchPlaylistList: (cursor) => service.discoverMix(cursor: cursor),
      fetchPlaylistTracks: (id, {cursor}) =>
          service.playlistDetail(id, cursor: cursor),
      fetchRadioPage: service.radioTracksPage,
      radioIds: feed?.radios.map((r) => r.id).toList() ?? const [],
    )..prime(
        playlists: feed?.playlists ?? const [],
        mixCursor: feed?.mixCursor,
        mixHasMore: feed?.mixHasMore ?? false,
      );
  }

  Future<void> _init() async {
    try {
      // 先恢复上次选定的场景（持久化），分页器一出生就带场景
      final saved = await PlatformFeedService.loadSavedScene();
      if (saved != null) {
        _scene = FeedMode(name: saved.name, sceneModeId: saved.id);
      }
      _pager = await _createPager();
      if (mounted) setState(() => _initError = null);
      _loadModes();
    } catch (e) {
      if (mounted) setState(() => _initError = '加载失败，请检查网络');
    }
  }

  /// 拉场景清单（失败静默：入口不显示即可，默认流不受影响）
  Future<void> _loadModes() async {
    try {
      final platform = await _platformService();
      final modes = await platform.fetchFeedModes();
      if (!mounted || modes.isEmpty) return;
      setState(() {
        _modes = modes;
        // 持久化恢复的场景只有 id+名，对齐到清单里的完整条目（带图标）
        final scene = _scene;
        if (scene != null) {
          for (final m in modes) {
            if (m.sceneModeId == scene.sceneModeId) _scene = m;
          }
        }
      });
    } catch (_) {
      // 场景入口优雅缺席，不提示、不影响推荐流
    }
  }

  bool _refreshing = false;

  /// 以当前场景新建分页器并拉第一批，成功才写入 [_pager]/[_tracks]；
  /// 失败两者保持原样、返回 false（刷新与切场景共用，保证都是真重建）。
  Future<bool> _loadFirstPage() async {
    try {
      final pager = await _createPager();
      var first = await pager.nextPage();
      // 空批但还有后续时多翻两页，避免把空列表当新一批交付
      for (var i = 0; i < 2 && first.isEmpty && pager.hasMore; i++) {
        first = await pager.nextPage();
      }
      if (first.isEmpty) return false;
      _pager = pager;
      _tracks
        ..clear()
        ..addAll(first);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 刷新换一批：重新拉第一批，成功才换推荐会话；失败保留当前
  /// 会话与已加载列表不动，只提示。刷新是用户在推荐页的显式动作，
  /// 按隔离语义以新一批接管**推荐会话**（主会话只被暂停存档，
  /// 内容不受影响）。
  Future<void> _refresh() async {
    if (_refreshing || _starting) return;
    _refreshing = true;
    if (mounted) setState(() {});
    try {
      final ok = await _loadFirstPage();
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('刷新失败，已保留当前内容')),
        );
        return;
      }
      await context.read<PlayerService>().startRecommendSession(
            List.of(_tracks),
            0,
            loadMore: _fetchNext,
          );
    } finally {
      _refreshing = false;
      if (mounted) setState(() {});
    }
  }

  /// 切换场景（null = 回默认推荐）：持久化选择后按隔离语义走——
  /// 推荐会话正占用输出、或主会话无内容时，直接以新场景重建推荐
  /// 会话并起播；主会话正在占用输出时**不抢输出**，只把推荐会话
  /// 的内容换成新场景的流（暂停态展示），用户在推荐页点播放才
  /// 接管输出、主会话暂停存档。
  Future<void> _applyScene(FeedMode? mode) async {
    if (_refreshing || _starting) return;
    if (mode?.sceneModeId == _scene?.sceneModeId) return;
    _refreshing = true;
    _scene = mode;
    if (mounted) setState(() {});
    try {
      await PlatformFeedService.saveScene(mode);
      final ok = await _loadFirstPage();
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('场景切换失败，已保留当前内容')),
        );
        return;
      }
      final player = context.read<PlayerService>();
      if (player.recommendIsActive || !player.mainHasContent) {
        await player.startRecommendSession(
          List.of(_tracks),
          0,
          loadMore: _fetchNext,
        );
      } else {
        player.setRecommendSession(List.of(_tracks), loadMore: _fetchNext);
      }
    } finally {
      _refreshing = false;
      if (mounted) setState(() {});
    }
  }

  /// 页面与推荐会话共用同一个分页器：会话续拉（占用输出时走
  /// PlayerService 的队尾续拉；未占用时走推荐 store 的续拉）
  /// 回来的曲目同步进已加载列表，刷着听、听着刷是同一条流。
  Future<List<Track>> _fetchNext() async {
    final pager = _pager;
    if (pager == null) return const [];
    final more = await pager.nextPage();
    if (more.isNotEmpty) _tracks.addAll(more);
    return more;
  }

  RecommendEnter _decide(PlayerService player) => decideRecommendEnter(
        sessionHasContent: player.recommendHasContent,
        mainHasContent: player.mainHasContent,
      );

  void _onEnter() {
    if (_enterHandled) return;
    _enterHandled = true;
    final player = context.read<PlayerService>();
    if (_decide(player) == RecommendEnter.startQueue) {
      _startQueue();
    }
  }

  /// 以推荐流建队列并起播。force=true 为提示页按钮的显式接管
  /// （允许覆盖正在播的其他来源）；自动进入时若中途有别的曲目开始播，
  /// 临门一脚再查一次，变卦就放弃接管、让提示页接手。
  Future<void> _startQueue({bool force = false}) async {
    if (_starting) return;
    _starting = true;
    if (mounted) setState(() => _startFailed = false);
    try {
      await _initFuture;
      if (!mounted) return;
      if (_pager == null) {
        if (mounted) setState(() => _startFailed = true);
        return;
      }
      if (_tracks.isEmpty) {
        await _fetchNext();
        if (!mounted) return;
      }
      if (_tracks.isEmpty && !_pager!.hasMore) {
        if (mounted) setState(() => _startFailed = true);
        return;
      }
      final player = context.read<PlayerService>();
      if (!force && _decide(player) != RecommendEnter.startQueue) return;
      // 隔离口径：建的是推荐会话自己的队列，不动主队列
      await player.startRecommendSession(
        List.of(_tracks),
        0,
        loadMore: _fetchNext,
      );
    } catch (_) {
      if (mounted) setState(() => _startFailed = true);
    } finally {
      _starting = false;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final enter = _decide(player);
    final Widget content;
    if (enter == RecommendEnter.showPager) {
      if (isExpanded(context)) {
        // 桌面双栏播放形态之上保留推荐页头（刷新/列表/搜索入口不丢）；
        // embedded 口径：壳层通栏条在本页隐藏，控制行在 DesktopPlayer
        // 封面下方，队列入口只留页头这一个
        content = Column(
          children: [
            _header(context),
            const Expanded(child: DesktopPlayer(embedded: true)),
          ],
        );
      } else {
        content = _buildSwipe(context);
      }
    } else if (enter == RecommendEnter.showGate) {
      content = _buildGate(context, player);
    } else if (_initError != null || _startFailed) {
      // startQueue 分支：自动建队失败重试
      content = _buildError(context);
    } else {
      // startQueue 分支：自动建队进行中
      content = _buildLoading(context);
    }
    // 顶部安全区：本页无 AppBar，header 与右侧页指示点等贴边元素都要
    // 让开状态栏/刘海（iPhone 上 header 曾与状态栏时间重叠，用户实报）。
    // bottom 不包：页面下缘贴的是壳层导航栏而非屏幕边缘，导航栏自理
    // 底部 inset，包了反而多出一条空白。
    // 整页底色垫「页面顶色」（当前推荐会话曲目的封面取色 55% 混
    // 页面底色，与新鲜页渐变顶端同一公式）：状态栏区/header 一带
    // 与页面正文同色、无色块分界；切歌换封面时此处与正文顶端
    // 同步变色。桌面分支同口径（DesktopPlayer embedded 内部同色）。
    return Container(
      color: recommendPageTopColor(context, player.recommendCurrentTrack),
      child: SafeArea(bottom: false, child: content),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 8, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('推荐',
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 2),
                Text(
                  '官方推荐流 · 游客版（登录后推荐更准）',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                // 场景入口：清单拉到才出现（失败优雅缺席）；chip 上
                // 显示当前场景名，未选时为「默认推荐」
                if (_modes != null && _modes!.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  InputChip(
                    avatar: const Icon(Icons.auto_awesome, size: 16),
                    label: Text(_scene?.name ?? '默认推荐'),
                    onPressed: _refreshing ? null : _showScenePicker,
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: '刷新推荐（换一批）',
            icon: _refreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: _refreshing ? null : _refresh,
          ),
          IconButton(
            tooltip: '已加载列表',
            icon: const Icon(Icons.queue_music),
            onPressed: _tracks.isEmpty ? null : () => _showLoadedList(context),
          ),
          IconButton(
            tooltip: '搜索',
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.pushNamed(context, '/search'),
          ),
        ],
      ),
    );
  }

  Widget _buildSwipe(BuildContext context) {
    final player = context.watch<PlayerService>();
    final column = Column(
      children: [
        _header(context),
        Expanded(
          child: Stack(
            children: [
              FreshPager(
                // 绑定推荐会话视图（隔离）：页面/下标/切歌都只动
                // 推荐会话自己，不读主队列
                session: PlayerSession.recommend,
                pageBuilder: (context, track, i) => _RecommendFreshPage(
                  track: track,
                  index: i,
                ),
              ),
              // 右侧页指示点（窗口化：以当前页为中心最多 9 个）
              Positioned(
                right: 6,
                top: 0,
                bottom: 0,
                child: Center(child: _pageDots(player)),
              ),
            ],
          ),
        ),
      ],
    );
    // medium 档（600–899）自适应：竖滑页是手机形态，整列（含页头）
    // 居中限宽，不把封面与控件横向拉满；≥900 走 DesktopPlayer
    // 双栏、compact 逐字不变。
    if (!isWide(context)) return column;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: Breakpoints.paneMaxWidth),
        child: column,
      ),
    );
  }

  Widget _pageDots(PlayerService player) {
    final total = player.recommendQueueItems.length;
    if (total < 2) return const SizedBox.shrink();
    const window = 9;
    var start = player.recommendCurrentIndex - window ~/ 2;
    if (start < 0) start = 0;
    if (start + window > total) start = (total - window).clamp(0, total);
    final count = total - start > window ? window : total - start;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var k = 0; k < count; k++)
          Container(
            width: (start + k) == player.recommendCurrentIndex ? 7 : 5,
            height: (start + k) == player.recommendCurrentIndex ? 7 : 5,
            margin: const EdgeInsets.symmetric(vertical: 3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: (start + k) == player.recommendCurrentIndex
                  ? scheme.primary
                  : scheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
          ),
      ],
    );
  }

  Widget _buildGate(BuildContext context, PlayerService player) {
    // 会话隔离：推荐会话为空、主会话有内容时才到这里。推荐有自己
    // 独立的会话，不存在「恢复主队列里的推荐会话」——点开始后以
    // 推荐会话接管输出，主会话暂停并原样保留（回首页点播即恢复）。
    final t = player.mainCurrentTrack;
    return Column(
      children: [
        _header(context),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.music_note,
                      size: 44,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 14),
                  const Text('正在播放其他内容', style: TextStyle(fontSize: 16)),
                  const SizedBox(height: 6),
                  if (t != null)
                    Text(
                      '《${t.name}》- ${t.artistNames}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  const SizedBox(height: 6),
                  const Text(
                    '推荐有独立的播放会话：开始后当前播放暂停存档，'
                    '推荐曲目只在推荐页里播，不会出现在迷你播放条上',
                    style: TextStyle(fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed:
                        _starting ? null : () => _startQueue(force: true),
                    icon: _starting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_arrow),
                    label: const Text('开始刷推荐'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLoading(BuildContext context) {
    return Column(
      children: [
        _header(context),
        const Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 14),
                Text('正在准备推荐流…'),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildError(BuildContext context) {
    return Column(
      children: [
        _header(context),
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('推荐流加载失败，请检查网络'),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () {
                    setState(() {
                      _initError = null;
                      _startFailed = false;
                    });
                    if (_pager == null) {
                      _initFuture = _init();
                    }
                    _startQueue();
                  },
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 场景选择层：网格（图标 + 名称），首项「默认推荐」清场景。
  /// 选中即走 [_applyScene]（持久化 + 按 gate/接管语义重建）。
  void _showScenePicker() {
    final modes = _modes;
    if (modes == null || modes.isEmpty) return;
    // 宽屏下弹层限宽居中（不再全宽拉伸），网格列数随窗口宽增列
    final windowWidth = MediaQuery.sizeOf(context).width;
    final columns = windowWidth >= Breakpoints.expanded
        ? 5
        : windowWidth >= Breakpoints.medium
            ? 4
            : 3;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: Breakpoints.sheetMaxWidth),
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.7,
          child: Column(
            children: [
              const ListTile(title: Text('场景音乐')),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.82,
                  ),
                  itemCount: modes.length + 1,
                  itemBuilder: (_, i) {
                    if (i == 0) {
                      return _SceneTile(
                        label: '默认推荐',
                        icon: Icons.recommend_outlined,
                        selected: _scene == null,
                        onTap: () {
                          Navigator.pop(ctx);
                          _applyScene(null);
                        },
                      );
                    }
                    final mode = modes[i - 1];
                    return _SceneTile(
                      label: mode.name,
                      cover: mode.cover,
                      selected: _scene?.sceneModeId == mode.sceneModeId,
                      onTap: () {
                        Navigator.pop(ctx);
                        _applyScene(mode);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showLoadedList(BuildContext context) {
    final player = context.read<PlayerService>();
    // 列表内容以推荐会话为准（隔离口径：不读主队列）；点选走
    // recommendJumpTo——会话占用输出时切歌出声，未占用时只挪
    // 会话下标。徽标与移动端 TrackTile 同一套（音质 + VIP）。
    showModalBottomSheet<void>(
      context: context,
      constraints: const BoxConstraints(maxWidth: Breakpoints.sheetMaxWidth),
      builder: (ctx) => SafeArea(
        // ListenableBuilder 让表头播放/暂停键与选中态随推荐会话
        // 状态实时同步
        child: ListenableBuilder(
          listenable: player,
          builder: (ctx, _) {
            final items = player.recommendQueueItems;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: const Text('已加载的推荐曲目'),
                  // 列表页原本没有暂停入口：表头补推荐会话的播放/
                  // 暂停键（占用输出时暂停/续播，未占用时抢回输出
                  // 续播——toggleRecommend 既有语义）
                  trailing: IconButton.filled(
                    tooltip: player.recommendPlaying ? '暂停' : '播放',
                    icon: Icon(
                      player.recommendLoading
                          ? Icons.hourglass_top
                          : player.recommendPlaying
                              ? Icons.pause
                              : Icons.play_arrow,
                    ),
                    onPressed:
                        items.isEmpty ? null : player.toggleRecommend,
                  ),
                ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: items.length,
                    itemBuilder: (_, i) {
                      final t = items[i];
                      return ListTile(
                        leading:
                            CoverImage(cover: t.cover, width: 40, height: 40),
                        title: Row(
                          children: [
                            Flexible(
                              child: Text(t.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                            ),
                            if (t.topQuality.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              QualityBadge(topQuality: t.topQuality),
                            ],
                            if (t.isVip) ...[
                              const SizedBox(width: 6),
                              const VipBadge(),
                            ],
                          ],
                        ),
                        subtitle: Text(t.artistNames,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        selected: i == player.recommendCurrentIndex,
                        onTap: () {
                          player.recommendJumpTo(i);
                          Navigator.pop(ctx);
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 推荐页的新鲜模式单页（按定版样板图）：大封面（右上角实际音质芯片）、
/// 封面正下方控制行（可拖 SeekBar + 播放/暂停键）、歌名/歌手、
/// 一行当前歌词、只读互动计数排。
///
/// 页面内部再分横向两页（横向 PageView，初始停在推荐流页）：
/// - 右滑 → 左侧的歌词页（当前曲歌词，同步滚动沿用播放页 [LyricList]）；
/// - 左滑 → 回推荐流页。
/// 横向分页只吃横向拖动，纵向手势仍归外层 FreshPager 切歌（歌词列表
/// 禁用手动滚动也是为此，见 [LyricList] 口径），两边互不吞手势。
/// 评论不切页不开新页：点计数开遮盖式抽屉，浮层盖在本页之上。
class _RecommendFreshPage extends StatefulWidget {
  final Track track;
  final int index;
  const _RecommendFreshPage({
    required this.track,
    required this.index,
  });

  @override
  State<_RecommendFreshPage> createState() => _RecommendFreshPageState();
}

class _RecommendFreshPageState extends State<_RecommendFreshPage> {
  /// 横向分页：0 歌词页（在左）、1 推荐流页（初始停靠页）
  late final PageController _hController = PageController(initialPage: 1);

  @override
  void dispose() {
    _hController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final resolver = context.read<PlayResolver>();
    // 隔离口径：当前页判定与 seo 都按推荐会话读——会话未占用输出
    // 时引擎里是主会话的状态，绝不能拿来冒充推荐曲目的
    final isCurrent = player.recommendCurrentIndex == widget.index;
    final seo = isCurrent && player.recommendIsActive
        ? player.currentSeo ?? resolver.cachedSeo(widget.track.id)
        : resolver.cachedSeo(widget.track.id);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            // 顶端用实色顶色（与推荐页顶部/header 同一公式同色，
            // 无缝衔接；视觉与原半透明取色叠底色完全一致）
            recommendPageTopColor(context, widget.track),
            Theme.of(context).scaffoldBackgroundColor,
          ],
        ),
      ),
      child: FutureBuilder<SeoTrack>(
        future: seo != null ? Future.value(seo) : resolver.seo(widget.track.id),
        builder: (context, snap) => _content(context, snap.data, isCurrent),
      ),
    );
  }

  Widget _content(BuildContext context, SeoTrack? seo, bool isCurrent) {
    final player = context.watch<PlayerService>();
    final scheme = Theme.of(context).colorScheme;
    final fullTrack = seo?.track ?? widget.track;
    final lines = seo?.lyricLines ?? const <LyricLine>[];
    final lineIndex =
        isCurrent ? lyricIndexAt(lines, player.recommendPosition) : -1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: PageView(
              controller: _hController,
              children: [
                _lyricsPane(context, lines, lineIndex, isCurrent),
                _mainPane(context, seo, fullTrack, lines, lineIndex, isCurrent),
              ],
            ),
          ),
          if (player.recommendError != null && isCurrent)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(player.recommendError!,
                  style: TextStyle(color: scheme.error, fontSize: 12)),
            ),
        ],
      ),
    );
  }

  /// 控制行（进度条 + 播放/暂停键）：定在封面正下方——主页面在封面
  /// 之下、歌词页同理置其底部（右滑进歌词页时控制不丢）。
  /// 仅当前曲页是活控件，且全程绑定推荐会话：SeekBar 用会话的
  /// 位置/时长，播放键走 toggleRecommend（未占用输出时抢回输出
  /// 续播）；非当前页用等高占位，避免翻页时版面上下跳动。
  Widget _controlRow(BuildContext context, {required bool live}) {
    if (!live) return const SizedBox(height: 76);
    final player = context.watch<PlayerService>();
    return Row(
      children: [
        Expanded(
          child: SeekBar(
            position: player.recommendPosition,
            duration: player.recommendDuration,
            onSeek: player.recommendSeek,
            showTimes: true,
          ),
        ),
        const SizedBox(width: 4),
        IconButton.filled(
          iconSize: 26,
          icon: Icon(player.recommendLoading
              ? Icons.hourglass_top
              : player.recommendPlaying
                  ? Icons.pause
                  : Icons.play_arrow),
          onPressed: player.toggleRecommend,
        ),
      ],
    );
  }

  /// 推荐流页（横向分页右侧页）：封面/歌名/歌手/计数排/下一首露出条。
  Widget _mainPane(
    BuildContext context,
    SeoTrack? seo,
    Track fullTrack,
    List<LyricLine> lines,
    int lineIndex,
    bool isCurrent,
  ) {
    final player = context.watch<PlayerService>();
    final scheme = Theme.of(context).colorScheme;
    final currentLyric = lines.isEmpty
        ? ''
        : lines[(lineIndex < 0 ? 0 : lineIndex).clamp(0, lines.length - 1)]
            .text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
          children: [
            GestureDetector(
              onTap: seo == null
                  ? null
                  : () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => LyricsScreen(seo: seo),
                        ),
                      ),
              child: CoverImage(
                cover: fullTrack.cover,
                width: double.infinity,
                height: MediaQuery.sizeOf(context).height * 0.34,
                radius: 16,
                small: false,
              ),
            ),
            if (isCurrent)
              Positioned(
                top: 10,
                right: 10,
                child: _qualityChip(context, player),
              ),
          ],
        ),
        const SizedBox(height: 10),
        // 封面正下方控制行：进度条（可拖）+ 播放/暂停键
        _controlRow(context, live: isCurrent),
        const SizedBox(height: 8),
        SizedBox(
          height: 20,
          child: currentLyric.isEmpty
              ? null
              : Text(
                  '“$currentLyric”',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
        ),
        const SizedBox(height: 6),
        Text(
          fullTrack.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 4),
        // 歌手 · 专辑拼成一行（专辑不独占行；缺专辑时只显示歌手）
        Text(
          artistAlbumText(fullTrack),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 14),
        // 互动计数（平台/seo 真数字，只读展示，不做假互动）；
        // 评论计数可点：开遮盖式评论抽屉（见 _showComments）
        Row(
          children: [
            _ReadStat(
              icon: Icons.favorite,
              label: formatCount(fullTrack.countCollected ?? 0),
            ),
            const SizedBox(width: 26),
            _ReadStat(
              icon: Icons.mode_comment,
              label: formatCount(fullTrack.countComment ?? 0),
              onTap: seo == null ? null : () => _showComments(context, seo),
            ),
            const SizedBox(width: 26),
            _ReadStat(
              icon: Icons.share,
              label: formatCount(fullTrack.countShared ?? 0),
            ),
          ],
        ),
        // 「下一首」露出条已整体删除（用户点名）：上下滑切歌不变，
        // 只是不再预告下一首；其占位 Spacer 一并去掉，计数排即末行。
      ],
    );
  }

  /// 歌词页（横向分页左侧页）：与播放页共用同一份 [LyricList]
  /// （当前行高亮 + 同步自动滚动）；禁手动滚动，纵向手势留给外层切歌。
  /// 底部同置控制行：右滑进歌词页后进度/播放暂停够得着（与主页面的
  /// 封面下控制行同一组件、同一行为）。
  Widget _lyricsPane(BuildContext context, List<LyricLine> lines,
      int lineIndex, bool isCurrent) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.lyrics_outlined, size: 18, color: scheme.primary),
            const SizedBox(width: 6),
            Text('歌词', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            Text(
              '左滑回推荐',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: LyricList(
            lines: lines,
            currentIndex: lineIndex,
            userScrollable: false,
          ),
        ),
        const SizedBox(height: 8),
        _controlRow(context, live: isCurrent),
      ],
    );
  }

  /// 评论抽屉（遮盖式）：showModalBottomSheet 是独立浮层路由，盖在
  /// 推荐页之上——底层页面只被遮罩压暗，不位移、不挤压。高度取
  /// 约五成屏高（≈50%，用户定版口径），带拖动把手，可下拉关闭、
  /// 点遮罩关闭。评论内容复用共享只读 [CommentsList]。
  void _showComments(BuildContext context, SeoTrack seo) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: Breakpoints.sheetMaxWidth),
      builder: (ctx) => SizedBox(
        height: MediaQuery.sizeOf(ctx).height * 0.5,
        child: SafeArea(
          top: false,
          child: CommentsList(comments: seo.comments),
        ),
      ),
    );
  }
  /// 右上角音质芯片：只显示推荐会话当前曲实际在播的档（会话视图
  /// 口径：未占用输出时 recommendQuality 为 null、芯片不显示），
  /// 准备无损时显示准备态，绝不按设置值虚报
  Widget _qualityChip(BuildContext context, PlayerService player) {
    final scheme = Theme.of(context).colorScheme;
    final String text;
    if (player.recommendPreparingLossless) {
      text = '无损准备中';
    } else if (player.recommendQuality == 'lossless') {
      text = '无损 FLAC';
    } else if (player.recommendQuality != null &&
        SettingsService.qualityOptions.contains(player.recommendQuality)) {
      text = SettingsService.qualityLabel(player.recommendQuality!)
          .split('(')
          .first
          .trim();
    } else {
      return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (player.recommendPreparingLossless)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          Text(text,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.onPrimaryContainer)),
        ],
      ),
    );
  }
}

/// 场景选择网格里的一格：图标（场景图或默认项图标）+ 名称，
/// 选中态描边 + 右上角勾。
class _SceneTile extends StatelessWidget {
  final String label;
  final CoverArt? cover;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  const _SceneTile({
    required this.label,
    this.cover,
    this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                if (cover != null)
                  CoverImage(cover: cover!, width: 52, height: 52, radius: 10)
                else
                  Icon(icon ?? Icons.music_note,
                      size: 40, color: scheme.primary),
                if (selected)
                  Positioned(
                    right: -6,
                    top: -6,
                    child: Icon(Icons.check_circle,
                        size: 18, color: scheme.primary),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight:
                        selected ? FontWeight.w700 : FontWeight.normal,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReadStat extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _ReadStat({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20, color: scheme.primary),
        const SizedBox(width: 5),
        Text(label, style: Theme.of(context).textTheme.titleSmall),
      ],
    );
    if (onTap == null) return row;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: row,
      ),
    );
  }
}
