import 'dart:async';

import 'package:flutter/material.dart';

import '../core/utils.dart';

/// 进度条显示比例（纯函数，可测）：
/// 拖动中以拖动值优先——这是「拖不动/回跳」的根治点：旧实现把 Slider 的
/// value 直接绑播放位置流，拖动时流里尚未生效的旧位置不断把滑块拽回。
double seekDisplayFraction({
  required double? dragFraction,
  required Duration position,
  required Duration duration,
}) {
  if (dragFraction != null) return dragFraction.clamp(0, 1).toDouble();
  if (duration.inMilliseconds <= 0) return 0;
  return (position.inMilliseconds / duration.inMilliseconds)
      .clamp(0, 1)
      .toDouble();
}

/// 比例 → seek 目标位置（纯函数，可测）
Duration seekTargetForFraction(double fraction, Duration duration) {
  if (duration.inMilliseconds <= 0) return Duration.zero;
  return Duration(
      milliseconds: (fraction.clamp(0, 1) * duration.inMilliseconds).round());
}

/// 可操作进度条：拖动全程只更新本地显示，松手时才发一次 seek；
/// seek 发出后短暂保持拖动值，直到位置流追上目标附近再交还控制，
/// 避免松手瞬间滑块回跳。
class SeekBar extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onSeek;
  final bool showTimes;

  /// 时间数字与滑杆同行（左当前时间、右总时长，如
  /// 「1:23 ━━━ 3:33」）；false 时数字在滑杆下方一行两端
  /// （播放页/推荐页既有口径）。仅 [showTimes] 时生效。
  final bool inlineTimes;
  const SeekBar({
    super.key,
    required this.position,
    required this.duration,
    required this.onSeek,
    this.showTimes = false,
    this.inlineTimes = false,
  });

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _dragFraction;
  Duration? _pendingTarget;
  Timer? _pendingTimer;

  @override
  void didUpdateWidget(SeekBar old) {
    super.didUpdateWidget(old);
    // 位置流追上 seek 目标（1 秒容差）→ 交还控制给位置流
    final target = _pendingTarget;
    if (target != null &&
        (widget.position - target).abs() < const Duration(seconds: 1)) {
      _pendingTarget = null;
      _dragFraction = null;
      _pendingTimer?.cancel();
    }
  }

  @override
  void dispose() {
    _pendingTimer?.cancel();
    super.dispose();
  }

  void _endDrag(double value) {
    final target = seekTargetForFraction(value, widget.duration);
    setState(() {
      _pendingTarget = target;
      _dragFraction = value;
    });
    // 兜底：位置流迟迟不追上（seek 失败/无声源）时也别把滑块钉死
    _pendingTimer?.cancel();
    _pendingTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) {
        setState(() {
          _pendingTarget = null;
          _dragFraction = null;
        });
      }
    });
    widget.onSeek(target);
  }

  @override
  Widget build(BuildContext context) {
    final fraction = seekDisplayFraction(
      dragFraction: _dragFraction,
      position: widget.position,
      duration: widget.duration,
    );
    final slider = Slider(
      value: fraction,
      onChangeStart: (v) => setState(() {
        _pendingTimer?.cancel();
        _pendingTarget = null;
        _dragFraction = v;
      }),
      onChanged: (v) => setState(() => _dragFraction = v),
      onChangeEnd: _endDrag,
    );
    if (!widget.showTimes) return slider;
    final displayPos = _dragFraction != null
        ? seekTargetForFraction(_dragFraction!, widget.duration)
        : widget.position;
    final timeStyle = Theme.of(context).textTheme.bodySmall;
    if (widget.inlineTimes) {
      // 同行形态（桌面通栏）：左=当前时间（拖动时跟拖动目标走，
      // 与滑块同口径）、右=总时长；时长未知时右端不摆假数。
      return Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Text(formatDurationMs(displayPos.inMilliseconds),
                style: timeStyle),
          ),
          Expanded(child: slider),
          if (widget.duration.inMilliseconds > 0)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(formatDurationMs(widget.duration.inMilliseconds),
                  style: timeStyle),
            ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        slider,
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(formatDurationMs(displayPos.inMilliseconds),
                style: Theme.of(context).textTheme.bodySmall),
            Text(formatDurationMs(widget.duration.inMilliseconds),
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ],
    );
  }
}
