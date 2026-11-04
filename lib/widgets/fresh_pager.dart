import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/play_queue.dart';
import '../services/player_service.dart';

/// 新鲜模式纵向滑动分页器（组件级复用：播放页 FreshPlayer 与推荐页共用）。
///
/// 机制（全 App 只有这一份实现）：
/// - 纵向 PageView 承载当前会话的整条队列，一页一首；
/// - 用户滑动落点 onPageChanged → 与按钮完全相同的推进入口：
///   LIST/SINGLE 走 jumpTo（队列线性定位），SHUFFLE 按滑动方向走
///   next()/prev()（随机/历史栈）；
/// - 反过来，按钮切歌、播完自动推进改变当前下标时，监听器把
///   PageView 同步动画到新下标（_syncGuard 防回环）。
/// [session] 决定绑定哪套会话视图：main（缺省，播放页）走引擎的
/// queueItems/currentIndex/jumpTo/next/prev；recommend（推荐页）走
/// PlayerService 的推荐会话视图与 recommend* 入口——推荐会话未
/// 占用输出时滑动只挪它自己 store 的下标，不触碰音频。
class FreshPager extends StatefulWidget {
  final Widget Function(BuildContext context, Track track, int index)
      pageBuilder;
  final PlayerSession session;
  const FreshPager({
    super.key,
    required this.pageBuilder,
    this.session = PlayerSession.main,
  });

  @override
  State<FreshPager> createState() => _FreshPagerState();
}

class _FreshPagerState extends State<FreshPager> {
  PageController? _controller;
  PlayerService? _player;
  bool _syncGuard = false;
  int _lastIndex = 0;

  bool get _isRecommend => widget.session == PlayerSession.recommend;

  int _indexOf(PlayerService p) =>
      _isRecommend ? p.recommendCurrentIndex : p.currentIndex;

  List<Track> _itemsOf(PlayerService p) =>
      _isRecommend ? p.recommendQueueItems : p.queueItems;

  bool _hasContent(PlayerService p) =>
      _isRecommend ? p.recommendHasContent : p.hasQueue;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final player = context.read<PlayerService>();
    if (_player != player) {
      _player?.removeListener(_onPlayerChanged);
      _player = player;
      _lastIndex = _indexOf(player);
      _controller?.dispose();
      _controller = PageController(initialPage: _indexOf(player));
      player.addListener(_onPlayerChanged);
    }
  }

  @override
  void dispose() {
    _player?.removeListener(_onPlayerChanged);
    _controller?.dispose();
    super.dispose();
  }

  /// 会话下标变化（按钮/自动推进/滑动落点）→ 同步 PageView
  void _onPlayerChanged() {
    final player = _player;
    final controller = _controller;
    if (player == null || controller == null || !controller.hasClients) return;
    final index = _indexOf(player);
    final page = controller.page?.round();
    if (page != null && page != index) {
      _syncGuard = true;
      controller
          .animateToPage(
            index,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          )
          .whenComplete(() => _syncGuard = false);
    }
    if (mounted) setState(() => _lastIndex = index);
  }

  /// 用户滑动落点 → 会话推进（与按钮共用入口）
  Future<void> _onSwipe(int page) async {
    final player = _player;
    if (player == null || _syncGuard) return;
    if (page == _indexOf(player)) return;
    if (_isRecommend) {
      // 推荐会话：占用输出且随机模式时按方向走引擎推进；其余情况
      // 线性定位（未占用输出时只挪推荐 store 下标，不出声）
      if (player.recommendIsActive &&
          player.mode == QueueLoopMode.shuffle) {
        if (page > _lastIndex) {
          await player.recommendNext();
        } else {
          await player.recommendPrev();
        }
        _onPlayerChanged();
      } else {
        await player.recommendJumpTo(page);
      }
      _lastIndex = _indexOf(player);
      return;
    }
    if (player.mode == QueueLoopMode.shuffle) {
      if (page > _lastIndex) {
        await player.next();
      } else {
        await player.prev();
      }
      _onPlayerChanged();
    } else {
      await player.jumpTo(page);
    }
    _lastIndex = player.currentIndex;
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    if (!_hasContent(player)) return const SizedBox.shrink();
    final items = _itemsOf(player);
    return PageView.builder(
      controller: _controller,
      scrollDirection: Axis.vertical,
      itemCount: items.length,
      onPageChanged: _onSwipe,
      itemBuilder: (context, i) => widget.pageBuilder(context, items[i], i),
    );
  }
}
