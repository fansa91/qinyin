import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/playback_shortcuts.dart';
import 'core/responsive.dart';
import 'core/theme.dart';
import 'screens/downloads_screen.dart';
import 'screens/home_screen.dart';
import 'screens/library_screen.dart';
import 'screens/player_screen.dart';
import 'screens/recommend_screen.dart';
import 'screens/search_screen.dart';
import 'screens/settings_screen.dart';
import 'services/cache_service.dart';
import 'services/download_service.dart';
import 'services/library_service.dart';
import 'services/lossless_cache.dart';
import 'services/play_resolver.dart';
import 'services/player_service.dart';
import 'services/qishui_service.dart';
import 'services/settings_service.dart';
import 'widgets/mini_player.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = SettingsService();
  await settings.init();
  final library = LibraryService();
  await library.init();
  final service = QishuiService();
  final resolver = PlayResolver(
    service.seoTrack,
    losslessCache: LosslessCache(),
  );
  final downloads = DownloadService(resolver, settings);
  await downloads.init();
  final cache = CacheService(downloadDirProvider: downloads.downloadDirectory);
  // 启动清扫孤儿临时件（无损解密中间件 + 写标签 .qytag 残留）：保守
  // 后缀口径、内部全程吞错，不阻塞启动、不碰用户文件。
  unawaited(cache.sweepOrphanTemps());
  final player = PlayerService(resolver, settings, library);
  player.localFileFor = downloads.localPathFor;
  // 系统动态取色：启动时取一次系统调色板主色作种子（取不到则回落默认种子）
  Color? systemSeed;
  try {
    final palette = await DynamicColorPlugin.getCorePalette();
    if (palette != null) {
      systemSeed = Color(palette.primary.get(40));
    }
  } catch (_) {
    systemSeed = null;
  }
  runApp(
    QinyinApp(
      settings: settings,
      library: library,
      service: service,
      resolver: resolver,
      downloads: downloads,
      player: player,
      cache: cache,
      systemSeed: systemSeed,
    ),
  );
}

class QinyinApp extends StatelessWidget {
  final SettingsService settings;
  final LibraryService library;
  final QishuiService service;
  final PlayResolver resolver;
  final DownloadService downloads;
  final PlayerService player;
  final CacheService cache;
  final Color? systemSeed;

  const QinyinApp({
    super.key,
    required this.settings,
    required this.library,
    required this.service,
    required this.resolver,
    required this.downloads,
    required this.player,
    required this.cache,
    this.systemSeed,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: library),
        ChangeNotifierProvider.value(value: downloads),
        ChangeNotifierProvider.value(value: player),
        Provider.value(value: cache),
        Provider.value(value: service),
        Provider.value(value: resolver),
      ],
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, _) {
          final seed = settings.dynamicColor
              ? (systemSeed ?? settings.seedColor)
              : settings.presetSeedColor;
          final isDesktop = switch (defaultTargetPlatform) {
            TargetPlatform.windows ||
            TargetPlatform.macOS ||
            TargetPlatform.linux => true,
            _ => false,
          };
          return MaterialApp(
            title: '沁音',
            debugShowCheckedModeBanner: false,
            theme: buildTheme(brightness: Brightness.light, seedColor: seed),
            darkTheme: buildTheme(brightness: Brightness.dark, seedColor: seed),
            themeMode: settings.themeMode,
            // 桌面键盘切歌/播放暂停（见 playback_shortcuts.dart 的避让说明）：
            // 叠加在默认快捷键之上，移动端不装。
            shortcuts: isDesktop
                ? {
                    ...WidgetsApp.defaultShortcuts,
                    ...playbackShortcutActivators(),
                  }
                : null,
            actions: isDesktop
                ? {
                    ...WidgetsApp.defaultActions,
                    NextTrackIntent: CallbackAction<NextTrackIntent>(
                      onInvoke: (_) => player.next(),
                    ),
                    PrevTrackIntent: CallbackAction<PrevTrackIntent>(
                      onInvoke: (_) => player.prev(),
                    ),
                    TogglePlayIntent: CallbackAction<TogglePlayIntent>(
                      onInvoke: (_) => player.toggle(),
                    ),
                  }
                : null,
            home: const AppShell(),
            routes: {
              '/player': (_) => const PlayerScreen(),
              '/search': (_) => const SearchScreen(),
              '/settings': (_) => const SettingsScreen(),
              '/theme': (_) => const ThemeSettingsScreen(),
            },
          );
        },
      ),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _currentIndex = 0; // 0 首页 1 推荐 2 下载 3 我的

  /// 「我的」嵌入页的目标页签（0 收藏歌曲 1 收藏歌单/专辑 3 历史播放）：
  /// 桌面侧栏三入口（我喜欢的音乐 / 我的收藏 / 历史播放）不再跳独立页，
  /// 改为切到主框架「我的」页并定位到对应页签，与其他主页面同一形态。
  int _libraryTab = 0;

  void _goLibrary(int tab) {
    setState(() {
      _libraryTab = tab;
      _currentIndex = 3;
    });
  }

  List<Widget> get _pages => [
    const HomeScreen(),
    RecommendScreen(active: _currentIndex == 1),
    const DownloadsScreen(),
    LibraryScreen(
      // 页签变化时重建 DefaultTabController 使 initialTab 生效
      key: ValueKey('library-$_libraryTab'),
      initialTab: _libraryTab,
    ),
  ];

  void _openPlayer() {
    if (context.read<PlayerService>().hasQueue) {
      Navigator.pushNamed(context, '/player');
    }
  }

  @override
  Widget build(BuildContext context) {
    final wc = windowClassOf(context);
    final Widget child;
    if (wc == WindowClass.expanded) {
      child = _buildExpanded();
    } else if (wc == WindowClass.medium) {
      child = _buildMedium();
    } else {
      child = _buildCompact();
    }
    // 桌面快捷键需要焦点链有落点：壳层先天 autofocus，用户点击控件后
    // 焦点自然转移（输入框/按钮/Slider 的避让由焦点链顺序保证）。
    return Focus(autofocus: true, child: child);
  }

  /// 推荐页（下标 1）自带完整播放面（封面下控制行 + 队列推进），
  /// 再叠一条播放条纯属重复 → **三档壳层统一**在该页隐藏播放条
  /// （用户定版：桌面端同样隐藏，桌面推荐页的控制靠 DesktopPlayer
  /// 内嵌的封面下控制行）。隐藏时直接不进树，无占位残留。
  bool get _showMiniPlayer => _currentIndex != 1;

  /// 移动壳层悬浮播放条的横向边距（宽条形态：接近满宽、两侧小边距）
  static const double _floatingBarMargin = 12;

  /// 悬浮条占位避让：页面内容区底部留白，须 ≥ 条高 + 下边距 + 呼吸间隙，
  /// 保证列表滑到底不被悬浮条遮住关键行。compact 条高实测约 68
  /// （文本列/按钮列高于封面 44，主导行高 + 上下 padding 16 + 进度
  /// 线 2）；medium 的 fullBar 另加顶部 SeekBar（Slider 约 48，
  /// 总高约 116）。
  static const double _compactBarClearance = 94;
  static const double _mediumBarClearance = 140;

  /// 内容区底部避让包装：只在「mini 条真有内容（主会话占用输出且
  /// 有曲目）且本页要显示播放条」时留白（Selector 只盯这个布尔，
  /// 不随进度通知重建整页；推荐会话占用输出时 mini 条隐藏、无留白）。
  Widget _pagesWithClearance({required double clearance}) {
    return Selector<PlayerService, bool>(
      selector: (_, p) => p.miniBarHasContent,
      builder: (context, hasTrack, child) => Padding(
        padding: EdgeInsets.only(
          bottom: _showMiniPlayer && hasTrack ? clearance : 0,
        ),
        child: child,
      ),
      child: IndexedStack(index: _currentIndex, children: _pages),
    );
  }

  Widget _buildCompact() {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: _pagesWithClearance(clearance: _compactBarClearance),
          ),
          if (_showMiniPlayer)
            Positioned(
              left: _floatingBarMargin,
              right: _floatingBarMargin,
              bottom: _floatingBarMargin,
              child: MiniPlayer(onTapCover: _openPlayer, floating: true),
            ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(Icons.recommend_outlined),
            selectedIcon: Icon(Icons.recommend),
            label: '推荐',
          ),
          NavigationDestination(
            icon: Icon(Icons.download_outlined),
            selectedIcon: Icon(Icons.download),
            label: '下载',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: '我的',
          ),
        ],
      ),
    );
  }

  Widget _buildMedium() {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: Row(
              children: [
                NavigationRail(
                  selectedIndex: _currentIndex,
                  onDestinationSelected: (i) =>
                      setState(() => _currentIndex = i),
                  labelType: NavigationRailLabelType.all,
                  leading: const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: CircleAvatar(child: Icon(Icons.music_note)),
                  ),
                  destinations: const [
                    NavigationRailDestination(
                      icon: Icon(Icons.home_outlined),
                      label: Text('首页'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.recommend_outlined),
                      label: Text('推荐'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.download_outlined),
                      label: Text('下载'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.person_outline),
                      label: Text('我的'),
                    ),
                  ],
                ),
                const VerticalDivider(thickness: 1, width: 1),
                Expanded(
                  child: _pagesWithClearance(clearance: _mediumBarClearance),
                ),
              ],
            ),
          ),
          if (_showMiniPlayer)
            Positioned(
              // 避开左侧 NavigationRail（宽 80 + 分隔线 1），只浮在内容区上方
              left: 81 + _floatingBarMargin,
              right: _floatingBarMargin,
              bottom: _floatingBarMargin,
              child: MiniPlayer(
                onTapCover: _openPlayer,
                fullBar: true,
                floating: true,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildExpanded() {
    final library = context.watch<LibraryService>();
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                SizedBox(
                  width: 232,
                  // 底色由 Material 承载而非 ColoredBox：侧栏 ListTile
                  // 的 ink/选中底需要画在最近的 Material 上，夹一层
                  // ColoredBox 会触发框架断言且水波纹不可见
                  child: Material(
                    color: scheme.surfaceContainerLow,
                    child: ListView(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 4, 16, 16),
                          child: Row(
                            children: [
                              CircleAvatar(
                                backgroundColor: scheme.primaryContainer,
                                child: Icon(
                                  Icons.music_note,
                                  color: scheme.onPrimaryContainer,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                '沁音',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ],
                          ),
                        ),
                        _SideItem(
                          icon: Icons.recommend_outlined,
                          label: '推荐',
                          selected: _currentIndex == 1,
                          onTap: () => setState(() => _currentIndex = 1),
                        ),
                        _SideItem(
                          icon: Icons.explore_outlined,
                          label: '发现',
                          selected: _currentIndex == 0,
                          onTap: () => setState(() => _currentIndex = 0),
                        ),
                        const _SideHeader('我的音乐'),
                        _SideItem(
                          icon: Icons.favorite_border,
                          label: '我喜欢的音乐',
                          selected: _currentIndex == 3 && _libraryTab == 0,
                          onTap: () => _goLibrary(0),
                        ),
                        _SideItem(
                          icon: Icons.history,
                          label: '历史播放',
                          selected: _currentIndex == 3 && _libraryTab == 3,
                          onTap: () => _goLibrary(3),
                        ),
                        _SideItem(
                          icon: Icons.download_outlined,
                          label: '下载管理',
                          selected: _currentIndex == 2,
                          onTap: () => setState(() => _currentIndex = 2),
                        ),
                        const _SideHeader('创建的歌单'),
                        for (final p in library.myPlaylists)
                          _SideItem(
                            icon: Icons.queue_music,
                            label: p.name,
                            selected: false,
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    LocalPlaylistScreen(playlistId: p.id),
                              ),
                            ),
                          ),
                        if (library.myPlaylists.isEmpty)
                          const Padding(
                            padding: EdgeInsets.fromLTRB(20, 2, 16, 2),
                            child: Text(
                              '暂无（在「我的」中新建）',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        const _SideHeader('收藏的歌单和专辑'),
                        _SideItem(
                          icon: Icons.collections_bookmark_outlined,
                          label: '我的收藏',
                          selected: _currentIndex == 3 && _libraryTab == 1,
                          onTap: () => _goLibrary(1),
                        ),
                        const Divider(height: 24),
                        _SideItem(
                          icon: Icons.settings_outlined,
                          label: '设置',
                          selected: false,
                          onTap: () =>
                              Navigator.pushNamed(context, '/settings'),
                        ),
                      ],
                    ),
                  ),
                ),
                const VerticalDivider(thickness: 1, width: 1),
                Expanded(
                  child: IndexedStack(index: _currentIndex, children: _pages),
                ),
              ],
            ),
          ),
          // 桌面通栏条保持布局式（不悬浮）；推荐页隐藏（三档统一口径，
          // 见 _showMiniPlayer）。
          if (_showMiniPlayer)
            MiniPlayer(onTapCover: _openPlayer, fullBar: true),
        ],
      ),
    );
  }
}

class _SideHeader extends StatelessWidget {
  final String text;
  const _SideHeader(this.text);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 16, 6),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _SideItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _SideItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
      child: ListTile(
        dense: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        leading: Icon(icon, size: 20),
        title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        selected: selected,
        onTap: onTap,
      ),
    );
  }
}
