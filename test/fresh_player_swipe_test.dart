// 新鲜模式播放页上下滑切歌（硬性验收项）：
// 纵向 PageView 承载队列，上滑=下一首、下滑=上一首，与按钮切歌共用
// PlayerService.next()/prev()/jumpTo → PlayQueue 推进逻辑。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qinyin/models/models.dart';
import 'package:qinyin/screens/player_screen.dart';
import 'package:qinyin/services/library_service.dart';
import 'package:qinyin/services/play_resolver.dart';
import 'package:qinyin/services/player_service.dart';
import 'package:qinyin/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

SeoTrack fakeSeo(String id) => SeoTrack(
      track: Track(id: id, name: '歌曲$id'),
      lyricRaw: '[0,3000]<0,500,0>一行歌词',
      streams: const [
        PlayStream(
            quality: 'higher',
            codecType: 'aac',
            bitrate: 130000,
            mainUrl: 'https://cdn.example.com/x.m4a'),
      ],
      expireAt: 9999999999,
    );

void main() {
  testWidgets('上滑切下一首、下滑切上一首（与队列推进共用）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    await settings.init();
    final library = LibraryService();
    await library.init();
    final resolver = PlayResolver((id) async => fakeSeo(id));
    final player = PlayerService(resolver, settings, library);
    addTearDown(player.dispose);

    await player.playQueue(
      [Track(id: '1', name: '歌曲1'), Track(id: '2', name: '歌曲2'), Track(id: '3', name: '歌曲3')],
      0,
    );
    expect(player.currentIndex, 0);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: library),
          ChangeNotifierProvider.value(value: player),
          Provider.value(value: resolver),
        ],
        child: const MaterialApp(home: FreshPlayer()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PageView), findsOneWidget);
    expect(find.text('歌曲1'), findsOneWidget);

    // 上滑 → 下一首
    await tester.fling(find.byType(PageView), const Offset(0, -500), 1200);
    await tester.pumpAndSettle();
    expect(player.currentIndex, 1, reason: '上滑应推进到下一首');
    expect(find.text('歌曲2'), findsOneWidget);

    // 再上滑 → 第三首
    await tester.fling(find.byType(PageView), const Offset(0, -500), 1200);
    await tester.pumpAndSettle();
    expect(player.currentIndex, 2);

    // 下滑 → 上一首
    await tester.fling(find.byType(PageView), const Offset(0, 500), 1200);
    await tester.pumpAndSettle();
    expect(player.currentIndex, 1, reason: '下滑应回到上一首');
    expect(find.text('歌曲2'), findsOneWidget);

    // 按钮切歌与滑动共用同一推进：next() 与上滑结果一致
    await player.next();
    expect(player.currentIndex, 2);
    await player.prev();
    expect(player.currentIndex, 1);
  });
}
