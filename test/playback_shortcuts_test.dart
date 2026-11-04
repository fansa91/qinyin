import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qinyin/core/playback_shortcuts.dart';

void main() {
  group('桌面播放快捷键映射', () {
    final map = playbackShortcutActivators();

    test('←/→ 切歌，空格 播放暂停', () {
      expect(
        map[const SingleActivator(LogicalKeyboardKey.arrowLeft)],
        isA<PrevTrackIntent>(),
      );
      expect(
        map[const SingleActivator(LogicalKeyboardKey.arrowRight)],
        isA<NextTrackIntent>(),
      );
      expect(
        map[const SingleActivator(LogicalKeyboardKey.space)],
        isA<TogglePlayIntent>(),
      );
    });

    test('系统媒体键一并映射', () {
      expect(
        map[const SingleActivator(LogicalKeyboardKey.mediaPlayPause)],
        isA<TogglePlayIntent>(),
      );
      expect(
        map[const SingleActivator(LogicalKeyboardKey.mediaTrackNext)],
        isA<NextTrackIntent>(),
      );
      expect(
        map[const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious)],
        isA<PrevTrackIntent>(),
      );
    });

    test('无修饰键要求（裸键触发，不抢 Ctrl 组合）', () {
      expect(
        map[const SingleActivator(LogicalKeyboardKey.arrowRight,
            control: true)],
        isNull,
      );
    });
  });
}
