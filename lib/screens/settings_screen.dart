import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../core/responsive.dart';
import '../services/settings_service.dart';

/// 设置：默认音质 / 下载（路径+文件名模板）/ 主题 / 关于
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final body = ListView(
      children: [
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
