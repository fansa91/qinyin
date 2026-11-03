import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// 桌面端「在文件管理器中定位」：打开目录 / 选中文件。
///
/// 用系统命令分发（不引入插件）：Windows `explorer`、macOS `open`、
/// Linux `xdg-open`。移动端（Android/iOS）没有对应语义，[supported]
/// 为 false，UI 应隐藏相关动作；所有方法失败返回 false 交 UI 提示，
/// 不抛异常。
class FileReveal {
  /// 当前平台是否支持定位（仅桌面三端）。
  static bool get supported {
    if (kIsWeb) return false;
    try {
      return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    } catch (_) {
      return false;
    }
  }

  /// 打开目录本身。成功返回 true。
  static Future<bool> openDirectory(String dirPath) async {
    if (!supported || dirPath.isEmpty) return false;
    try {
      if (Platform.isWindows) {
        // explorer 成功打开时退出码也是 1，只能以「进程能启动」为准
        await Process.run('explorer', [dirPath]);
        return true;
      }
      if (Platform.isMacOS) {
        final r = await Process.run('open', [dirPath]);
        return r.exitCode == 0;
      }
      final r = await Process.run('xdg-open', [dirPath]);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// 在文件管理器中选中（高亮）某个文件。成功返回 true。
  /// Linux 没有通用的「选中文件」命令，回落为打开其所在目录。
  static Future<bool> revealFile(String filePath) async {
    if (!supported || filePath.isEmpty) return false;
    try {
      if (Platform.isWindows) {
        // /select, 与路径是同一个参数（逗号后不加空格、整体一个 argv）
        await Process.run('explorer', ['/select,$filePath']);
        return true;
      }
      if (Platform.isMacOS) {
        final r = await Process.run('open', ['-R', filePath]);
        return r.exitCode == 0;
      }
      return await openDirectory(p.dirname(filePath));
    } catch (_) {
      return false;
    }
  }
}
