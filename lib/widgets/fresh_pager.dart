import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/play_queue.dart';
import '../services/player_service.dart';

/// 新鲜模式纵向滑动分页器（组件级复用：播放页 FreshPlayer 与推荐页共用）。
///
/// 机制（全 App 只有这一份实现）：
/// - 纵向 PageView 承载 PlayerService 的整条队列，一页一首；
/// - 用户滑动落点 onPageChanged → 与按钮完全相同的推进入口：
///   LIST/SINGLE 走 PlayerService.jumpTo（队列线性定位），
///   SHUFFLE 按滑动方向走 PlayerService.next()/prev()（随机/历史栈）；
/// - 反过来，按钮切歌、播完自动推进改变 currentIndex 时，
///   监听器把 PageView 同步动画到新下标（_syncGuard 防回环）。
/// 两种方向最终都汇入 PlayerService._playAt（含预取与队尾续拉）。
class FreshPager extends StatefulWidget {
  final Widget Function(BuildContext context, Track track, int index)
      pageBuilder;
  const FreshPager({super.key, required this.pageBuilder});

  @override
  State<FreshPager> createState() => _FreshPagerState();
}

class _FreshPagerState extends State<FreshPager> {
  PageController? _controller;
  PlayerService? _player;
  bool _syncGuard = false;
  int _lastIndex = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final player = context.read<PlayerService>();
    if (_player != player) {
      _player?.removeListener(_onPlayerChanged);
      _player = player;
      _lastIndex = player.currentIndex;
      _controller?.dispose();
      _controller = PageController(initialPage: player.currentIndex);
      player.addListener(_onPlayerChanged);
    }
  }

  @override
  void dispose() {
    _player?.removeListener(_onPlayerChanged);
    _controller?.dispose();
    super.dispose();
  }

  /// 播放器下标变化（按钮/自动推进）→ 同步 PageView
  void _onPlayerChanged() {
    final player = _player;
    final controller = _controller;
    if (player == null || controller == null || !controller.hasClients) return;
    final page = controller.page?.round();
    if (page != null && page != player.currentIndex) {
      _syncGuard = true;
      controller
          .animateToPage(
            player.currentIndex,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          )
          .whenComplete(() => _syncGuard = false);
    }
    if (mounted) setState(() => _lastIndex = player.currentIndex);
  }

  /// 用户滑动落点 → 队列推进（与按钮共用入口）
  Future<void> _onSwipe(int page) async {
    final player = _player;
    if (player == null || _syncGuard) return;
    if (page == player.currentIndex) return;
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
    if (!player.hasQueue) return const SizedBox.shrink();
    return PageView.builder(
      controller: _controller,
      scrollDirection: Axis.vertical,
      itemCount: player.queueItems.length,
      onPageChanged: _onSwipe,
      itemBuilder: (context, i) =>
          widget.pageBuilder(context, player.queueItems[i], i),
    );
  }
}
