import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../core/responsive.dart';
import '../services/cache_service.dart';
import '../services/settings_service.dart';
import '../widgets/account_section.dart';

/// 设置：默认音质 / 下载（路径+文件名模板）/ 主题 / 关于
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final body = ListView(
      children: [
        const AccountSection(),
        const Divider(),
        const ListTile(
          title: Text('播放'),
          leading: Icon(Icons.play_circle_outline),
        ),
        ListTile(
          title: const Text('默认音质'),
          subtitle: Text(SettingsService.qualityLabel(settings.defaultQuality)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _pickQuality(
            context,
            title: '默认音质（播放）',
            value: settings.defaultQuality,
            onPick: settings.setQuality,
          ),
        ),
        const Divider(),
        const ListTile(
          title: Text('下载'),
          leading: Icon(Icons.download_outlined),
        ),
        ListTile(
          title: const Text('下载音质'),
          subtitle: Text(settings.hasDownloadQuality
              ? SettingsService.qualityLabel(settings.downloadQuality)
              : '跟随播放音质（${SettingsService.qualityLabel(settings.downloadQuality)}）'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _pickQuality(
            context,
            title: '下载音质',
            value: settings.downloadQuality,
            onPick: settings.setDownloadQuality,
          ),
        ),
        ListTile(
          title: const Text('下载路径'),
          subtitle: Text(settings.downloadDirectory.isEmpty
              ? '默认（应用文档目录/qinyin_downloads）'
              : settings.downloadDirectory),
          trailing: const Icon(Icons.folder_open),
          onTap: () async {
            final dir = await FilePicker.getDirectoryPath();
            if (dir != null) await settings.setDownloadDirectory(dir);
          },
        ),
        ListTile(
          title: const Text('下载文件名模板'),
          subtitle: Text(settings.filenameFormat),
          trailing: const Icon(Icons.edit_outlined),
          onTap: () => _editFormat(context, settings),
        ),
        const Divider(),
        const _CacheSection(),
        const Divider(),
        const ListTile(
          title: Text('外观'),
          leading: Icon(Icons.palette_outlined),
        ),
        ListTile(
          title: const Text('主题设置'),
          subtitle: const Text('动态取色 / 深浅色 / 种子色'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.pushNamed(context, '/theme'),
        ),
        const Divider(),
        const ListTile(
          title: Text('关于'),
          leading: Icon(Icons.info_outline),
        ),
        FutureBuilder<PackageInfo>(
          future: PackageInfo.fromPlatform(),
          builder: (context, snap) {
            final version = snap.data?.version ?? '';
            final build = snap.data?.buildNumber ?? '';
            return ListTile(
              title: const Text('沁音 Qinyin'),
              subtitle: Text(
                  '版本 ${version.isEmpty ? '—' : version}${build.isEmpty ? '' : ' ($build)'}\n汽水音乐游客态客户端 · 无全文搜索/无无损/无云功能'),
            );
          },
        ),
      ],
    );
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: isWide(context) ? ConstrainedCenter(child: body) : body,
    );
  }

  void _pickQuality(
    BuildContext context, {
    required String title,
    required String value,
    required Future<void> Function(String) onPick,
  }) {
    showModalBottomSheet<void>(
      context: context,
      constraints:
          const BoxConstraints(maxWidth: Breakpoints.menuSheetMaxWidth),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(title)),
            for (final q in SettingsService.qualityOptions)
              RadioListTile<String>(
                value: q,
                groupValue: value,
                title: Text(SettingsService.qualityLabel(q)),
                onChanged: (v) {
                  if (v != null) onPick(v);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _editFormat(
      BuildContext context, SettingsService settings) async {
    final controller = TextEditingController(text: settings.filenameFormat);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('下载文件名模板'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(controller: controller),
            const SizedBox(height: 8),
            const Text('占位符：{artist} {title} {album} {quality}\n扩展名：普通音质 .m4a，无损（FLAC）下载为 .flac',
                style: TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('保存')),
        ],
      ),
    );
    if (result != null) await settings.setFilenameFormat(result);
  }
}

/// 设置页「缓存」区：占用盘点（无损解密缓存 / 封面图片缓存 /
/// 临时文件残留三项，口径见 [CacheBreakdown]）+ 一键清理。
/// 清理只动缓存类数据：下载的歌曲、收藏、历史、设置一律不碰；
/// 清完无损再播会重新解密、封面重新拉取，行为不受影响。
class _CacheSection extends StatefulWidget {
  const _CacheSection();

  @override
  State<_CacheSection> createState() => _CacheSectionState();
}

class _CacheSectionState extends State<_CacheSection> {
  CacheBreakdown? _usage;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final cache = context.read<CacheService>();
    final usage = await cache.measure();
    if (mounted) setState(() => _usage = usage);
  }

  Future<void> _clear() async {
    if (_clearing) return;
    setState(() => _clearing = true);
    final cache = context.read<CacheService>();
    await cache.clearAll();
    // 内存图片缓存顺带释放（不落盘，不计入上面的占用数字）
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    final usage = await cache.measure();
    if (!mounted) return;
    setState(() {
      _usage = usage;
      _clearing = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('缓存已清理（下载的歌曲与收藏不受影响）')),
    );
  }

  static String _fmt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final usage = _usage;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const ListTile(
          title: Text('缓存'),
          leading: Icon(Icons.storage_outlined),
        ),
        if (usage == null)
          const ListTile(
            title: Text('缓存占用'),
            subtitle: Text('统计中…'),
          )
        else ...[
          ListTile(
            dense: true,
            title: const Text('无损解密缓存'),
            subtitle: const Text('上限 512 MB，超出自动清旧'),
            trailing: Text(_fmt(usage.losslessBytes)),
          ),
          ListTile(
            dense: true,
            title: const Text('封面图片缓存'),
            subtitle: const Text('上限 200 个 / 30 天，系统自动滚动'),
            trailing: Text(_fmt(usage.coverBytes)),
          ),
          ListTile(
            dense: true,
            title: const Text('临时文件残留'),
            subtitle: const Text('写标签/解密中断的孤儿临时件'),
            trailing: Text(_fmt(usage.tagTempBytes)),
          ),
          ListTile(
            dense: true,
            title: const Text('合计'),
            trailing: Text(
              _fmt(usage.totalBytes),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
        ListTile(
          title: const Text('清理缓存'),
          subtitle: const Text('只清缓存，不动下载的歌曲、收藏与设置'),
          trailing: _clearing
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.delete_sweep_outlined),
          onTap: _clearing ? null : _clear,
        ),
      ],
    );
  }
}

/// 主题设置：动态取色开关、深浅模式、种子色预设
class ThemeSettingsScreen extends StatelessWidget {
  const ThemeSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final body = ListView(
      children: [
        SwitchListTile(
          title: const Text('动态取色'),
          subtitle: const Text('跟随系统壁纸取色（不支持时用种子色）'),
          value: settings.dynamicColor,
          onChanged: settings.setDynamicColor,
        ),
        const ListTile(title: Text('深浅色')),
        for (final (mode, label) in [
          (ThemeMode.system, '跟随系统'),
          (ThemeMode.light, '浅色'),
          (ThemeMode.dark, '深色'),
        ])
          RadioListTile<ThemeMode>(
            value: mode,
            groupValue: settings.themeMode,
            title: Text(label),
            onChanged: (v) {
              if (v != null) settings.setThemeMode(v);
            },
          ),
        const ListTile(title: Text('种子色（关动态取色时生效）')),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final preset in SettingsService.themePresets)
                InkWell(
                  onTap: () => settings.setSeed(preset.seedValue),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircleAvatar(
                        backgroundColor: Color(preset.seedValue),
                        radius: 22,
                        child: settings.seedValue == preset.seedValue &&
                                !settings.dynamicColor
                            ? const Icon(Icons.check, color: Colors.white)
                            : null,
                      ),
                      const SizedBox(height: 4),
                      Text(preset.name,
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
    return Scaffold(
      appBar: AppBar(title: const Text('主题设置')),
      body: isWide(context) ? ConstrainedCenter(child: body) : body,
    );
  }
}
