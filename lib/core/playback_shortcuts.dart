import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 桌面播放快捷键意图（应用级 Shortcuts/Actions 接线在 main.dart）。
///
/// 键位：← 上一首 / → 下一首 / 空格 播放·暂停；系统媒体键
/// （mediaPlayPause / mediaTrackNext / mediaTrackPrevious 等）一并映射——
/// 能到达 Flutter 的平台即生效（Windows 上媒体键多被系统截获，到达不了
/// 应用层时只有应用内键位可用）。
///
/// 避让原理（框架焦点链天然保证，不另做判断）：应用级 Shortcuts 位于
/// 焦点链最外层，事件先经焦点控件处理——文本框里的空格/方向键被
/// EditableText 吞掉、按钮聚焦时空格走按钮自身的激活、Slider 聚焦时
/// 方向键调滑块，都不会漏到这里触发切歌/暂停。
class NextTrackIntent extends Intent {
  const NextTrackIntent();
}

class PrevTrackIntent extends Intent {
  const PrevTrackIntent();
}

class TogglePlayIntent extends Intent {
  const TogglePlayIntent();
}

/// 快捷键映射（纯数据，可测）
Map<ShortcutActivator, Intent> playbackShortcutActivators() => {
      const SingleActivator(LogicalKeyboardKey.arrowLeft):
          const PrevTrackIntent(),
      const SingleActivator(LogicalKeyboardKey.arrowRight):
          const NextTrackIntent(),
      const SingleActivator(LogicalKeyboardKey.space):
          const TogglePlayIntent(),
      const SingleActivator(LogicalKeyboardKey.mediaPlayPause):
          const TogglePlayIntent(),
      const SingleActivator(LogicalKeyboardKey.mediaPlay):
          const TogglePlayIntent(),
      const SingleActivator(LogicalKeyboardKey.mediaPause):
          const TogglePlayIntent(),
      const SingleActivator(LogicalKeyboardKey.mediaTrackNext):
          const NextTrackIntent(),
      const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious):
          const PrevTrackIntent(),
    };
