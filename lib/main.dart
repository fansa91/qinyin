import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/responsive.dart';
import 'core/theme.dart';
import 'screens/downloads_screen.dart';
import 'screens/home_screen.dart';
import 'screens/library_screen.dart';
import 'screens/player_screen.dart';
import 'screens/search_screen.dart';
import 'screens/settings_screen.dart';
import 'services/download_service.dart';
import 'services/library_service.dart';
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
  final resolver = PlayResolver(service.seoTrack);
  final downloads = DownloadService(resolver, settings);
  await downloads.init();
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
  final Color? systemSeed;

  const QinyinApp({
    super.key,
    required this.settings,
    required this.library,
    required this.service,
    required this.resolver,
    required this.downloads,
    required this.player,
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
        Provider.value(value: service),
        Provider.value(value: resolver),
      ],
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, _) {
          final seed = settings.dynamicColor
              ? (systemSeed ?? settings.seedColor)
              : settings.presetSeedColor;
          return MaterialApp(
            title: '沁音',
            debugShowCheckedModeBanner: false,
            theme: buildTheme(brightness: Brightness.light, seedColor: seed),
            darkTheme:
                buildTheme(brightness: Brightness.dark, seedColor: seed),
            themeMode: settings.themeMode,
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
  int _currentIndex = 0; // 0 首页 1 下载 2 我的

  List<Widget> get _pages => const [
        HomeScreen(),
        DownloadsScreen(),
        LibraryScreen(),
      ];

  void _openPlayer() {
    if (context.read<PlayerService>().hasQueue) {
      Navigator.pushNamed(context, '/player');
    }
  }

  @override
  Widget build(BuildContext context) {
    final wc = windowClassOf(context);
    if (wc == WindowClass.expanded) return _buildExpanded();
    if (wc == WindowClass.medium) return _buildMedium();
    return _buildCompact();
  }

  Widget _buildCompact() {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: IndexedStack(index: _currentIndex, children: _pages),
          ),
          MiniPlayer(onTapCover: _openPlayer),
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
      body: Column(
        children: [
          Expanded(
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
                        icon: Icon(Icons.home_outlined), label: Text('首页')),
                    NavigationRailDestination(
                        icon: Icon(Icons.download_outlined),
                        label: Text('下载')),
                    NavigationRailDestination(
                        icon: Icon(Icons.person_outline), label: Text('我的')),
                  ],
                ),
                const VerticalDivider(thickness: 1, width: 1),
                Expanded(
                  child: IndexedStack(index: _currentIndex, children: _pages),
                ),
              ],
            ),
          ),
          MiniPlayer(onTapCover: _openPlayer, fullBar: true),
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
                Container(
                  width: 232,
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
                              child: Icon(Icons.music_note,
                                  color: scheme.onPrimaryContainer),
                            ),
                            const SizedBox(width: 10),
                            Text('沁音',
                                style: Theme.of(context).textTheme.titleLarge),
                          ],
                        ),
                      ),
                      _SideItem(
                        icon: Icons.recommend_outlined,
                        label: '推荐',
                        selected: _currentIndex == 0,
                        onTap: () => setState(() => _currentIndex = 0),
                      ),
                      _SideItem(
                        icon: Icons.explore_outlined,
                        label: '发现',
                        selected: false,
                        onTap: () => setState(() => _currentIndex = 0),
                      ),
                      const _SideHeader('我的音乐'),
                      _SideItem(
                        icon: Icons.favorite_border,
                        label: '我喜欢的音乐',
                        selected: false,
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => const LibraryScreen(initialTab: 0),
                          ),
                        ),
                      ),
                      _SideItem(
                        icon: Icons.history,
                        label: '历史播放',
                        selected: false,
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => const LibraryScreen(initialTab: 3),
                          ),
                        ),
                      ),
                      _SideItem(
                        icon: Icons.download_outlined,
                        label: '下载管理',
                        selected: _currentIndex == 1,
                        onTap: () => setState(() => _currentIndex = 1),
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
                          child: Text('暂无（在「我的」中新建）',
                              style: TextStyle(fontSize: 12)),
                        ),
                      const _SideHeader('收藏的歌单和专辑'),
                      _SideItem(
                        icon: Icons.collections_bookmark_outlined,
                        label: '我的收藏',
                        selected: false,
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => const LibraryScreen(initialTab: 1),
                          ),
                        ),
                      ),
                      const Divider(height: 24),
                      _SideItem(
                        icon: Icons.settings_outlined,
                        label: '设置',
                        selected: false,
                        onTap: () => Navigator.pushNamed(context, '/settings'),
                      ),
                    ],
                  ),
                ),
                const VerticalDivider(thickness: 1, width: 1),
                Expanded(
                  child: IndexedStack(index: _currentIndex, children: _pages),
                ),
              ],
            ),
          ),
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

