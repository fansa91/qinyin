import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qinyin/widgets/seek_bar.dart';

void main() {
  group('纯函数：显示比例与 seek 目标', () {
    test('无拖动时按位置流比例', () {
      expect(
        seekDisplayFraction(
          dragFraction: null,
          position: const Duration(seconds: 30),
          duration: const Duration(seconds: 120),
        ),
        0.25,
      );
    });

    test('拖动中拖动值优先于位置流（回跳根治点）', () {
      expect(
        seekDisplayFraction(
          dragFraction: 0.8,
          position: const Duration(seconds: 30), // 流里还是旧位置
          duration: const Duration(seconds: 120),
        ),
        0.8,
      );
    });

    test('时长未知时为 0，比例换算目标正确', () {
      expect(
        seekDisplayFraction(
          dragFraction: null,
          position: const Duration(seconds: 30),
          duration: Duration.zero,
        ),
        0,
      );
      expect(
        seekTargetForFraction(0.5, const Duration(seconds: 120)),
        const Duration(seconds: 60),
      );
      expect(seekTargetForFraction(2, const Duration(seconds: 120)),
          const Duration(seconds: 120));
    });
  });

  group('SeekBar 组件行为', () {
    testWidgets('拖动全程不 seek，松手才发一次且值为拖动目标', (tester) async {
      final seeks = <Duration>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SeekBar(
              position: const Duration(seconds: 10),
              duration: const Duration(seconds: 100),
              onSeek: seeks.add,
            ),
          ),
        ),
      );
      Slider slider() => tester.widget<Slider>(find.byType(Slider));
      expect(slider().value, closeTo(0.1, 0.001));

      // 模拟拖动到 50%：位置流仍停在 10s，滑块必须跟手停在 0.5
      slider().onChangeStart!(0.1);
      slider().onChanged!(0.5);
      await tester.pump();
      expect(slider().value, 0.5);
      expect(seeks, isEmpty);

      // 松手 → 恰好一次 seek 到 50s
      slider().onChangeEnd!(0.5);
      await tester.pump();
      expect(seeks, [const Duration(seconds: 50)]);
      // seek 未被位置流确认前，显示保持拖动值不回跳
      expect(slider().value, 0.5);
    });

    testWidgets('inlineTimes：时间数字在滑杆左右两端同行渲染', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SeekBar(
              position: const Duration(seconds: 10),
              duration: const Duration(seconds: 100),
              onSeek: (_) {},
              showTimes: true,
              inlineTimes: true,
            ),
          ),
        ),
      );
      expect(find.text('0:10'), findsOneWidget, reason: '左端=当前时间');
      expect(find.text('1:40'), findsOneWidget, reason: '右端=总时长');
      // 几何：左数字在滑杆左侧、右数字在滑杆右侧，且同一行（纵向重叠）
      final sliderRect = tester.getRect(find.byType(Slider));
      final leftRect = tester.getRect(find.text('0:10'));
      final rightRect = tester.getRect(find.text('1:40'));
      expect(leftRect.right, lessThanOrEqualTo(sliderRect.left));
      expect(rightRect.left, greaterThanOrEqualTo(sliderRect.right));
      expect(leftRect.center.dy, closeTo(sliderRect.center.dy, 24));
    });

    testWidgets('inlineTimes：左端数字随位置流更新', (tester) async {
      Widget app(Duration pos) => MaterialApp(
            home: Scaffold(
              body: SeekBar(
                position: pos,
                duration: const Duration(seconds: 213),
                onSeek: (_) {},
                showTimes: true,
                inlineTimes: true,
              ),
            ),
          );
      await tester.pumpWidget(app(Duration.zero));
      expect(find.text('0:00'), findsOneWidget);
      expect(find.text('3:33'), findsOneWidget);
      await tester.pumpWidget(app(const Duration(seconds: 83)));
      expect(find.text('1:23'), findsOneWidget,
          reason: '位置流推进后左端数字应实时跟随');
      expect(find.text('0:00'), findsNothing);
    });

    testWidgets('inlineTimes：时长未知时右端不摆假数', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SeekBar(
              position: const Duration(seconds: 10),
              duration: Duration.zero,
              onSeek: (_) {},
              showTimes: true,
              inlineTimes: true,
            ),
          ),
        ),
      );
      expect(find.text('0:10'), findsOneWidget, reason: '左端当前时间照常');
      expect(find.text('0:00'), findsNothing,
          reason: '右端不得用 0:00 冒充总时长');
    });

    testWidgets('位置流追上目标后交还控制', (tester) async {
      final seeks = <Duration>[];
      Widget app(Duration pos) => MaterialApp(
            home: Scaffold(
              body: SeekBar(
                position: pos,
                duration: const Duration(seconds: 100),
                onSeek: seeks.add,
              ),
            ),
          );
      await tester.pumpWidget(app(const Duration(seconds: 10)));
      final slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChangeStart!(0.1);
      slider.onChanged!(0.5);
      slider.onChangeEnd!(0.5);
      await tester.pump();
      // 播放器确认新位置（50s）→ 显示回到位置流口径（此刻恰好也是 0.5）
      await tester.pumpWidget(app(const Duration(seconds: 50)));
      expect(tester.widget<Slider>(find.byType(Slider)).value, 0.5);
      // 之后位置继续走，滑块跟随位置流
      await tester.pumpWidget(app(const Duration(seconds: 60)));
      expect(tester.widget<Slider>(find.byType(Slider)).value,
          closeTo(0.6, 0.001));
    });
  });
}
