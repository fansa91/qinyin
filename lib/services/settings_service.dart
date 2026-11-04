import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemePreset {
  final String name;
  final int seedValue;
  const ThemePreset(this.name, this.seedValue);
}

/// 设置：默认音质 / 下载 / 主题。SharedPreferences 持久化。
class SettingsService extends ChangeNotifier {
  static const _kQuality = 'default_quality';
  static const _kDownloadQuality = 'download_quality';
  static const _kThemeMode = 'theme_mode';
  static const _kDynamicColor = 'dynamic_color';
  static const _kSeed = 'theme_seed';
  static const _kDownloadDir = 'download_directory';
  static const _kFilenameFormat = 'download_filename_format';
  static const _kVolume = 'volume';

  static const List<String> qualityOptions = [
    'medium',
    'higher',
    'highest',
    'lossless',
  ];
  static String qualityLabel(String q) => switch (q) {
        'medium' => '标准 (AAC ≈66k)',
        'highest' => '最高 (AAC ≈258k)',
        'lossless' => '无损 (FLAC · 仅推荐流部分曲目提供)',
        _ => '高品质 (AAC ≈130k)',
      };

  static const List<ThemePreset> themePresets = [
    ThemePreset('汽水黄绿', 0xFF7ED957),
    ThemePreset('清新薄荷', 0xFF2FBF9B),
    ThemePreset('天空蓝', 0xFF4A90D9),
    ThemePreset('葡萄紫', 0xFF8E6BC8),
    ThemePreset('落日橙', 0xFFF08A3C),
    ThemePreset('玫瑰粉', 0xFFE86A92),
  ];
  static const int defaultSeedValue = 0xFF7ED957;
  static const String defaultFilenameFormat = '{artist} - {title}';

  String _quality = 'higher';

  /// 下载音质（与播放音质独立）；null = 未单独设置过，跟随播放音质
  /// （老用户无此键时的默认口径：下载沿用既有播放音质现状）。
  String? _downloadQuality;
  ThemeMode _themeMode = ThemeMode.system;
  bool _dynamicColor = true;
  int _seedValue = defaultSeedValue;
  String _downloadDirectory = '';
  String _filenameFormat = defaultFilenameFormat;
  double _volume = 1.0;

  String get defaultQuality => _quality;

  /// 下载实际使用的音质：单独设置过用设置值，否则跟随播放音质
  String get downloadQuality => _downloadQuality ?? _quality;

  /// 是否已单独设置过下载音质（设置页展示用）
  bool get hasDownloadQuality => _downloadQuality != null;
  ThemeMode get themeMode => _themeMode;
  bool get dynamicColor => _dynamicColor;
  int get seedValue => _seedValue;
  String get downloadDirectory => _downloadDirectory;
  String get filenameFormat => _filenameFormat;
  double get volume => _volume;

  Color? get seedColor =>
      _dynamicColor ? null : Color(_seedValue); // null 表示用系统动态色/默认种子
  Color get presetSeedColor => Color(_seedValue);

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _quality = prefs.getString(_kQuality) ?? 'higher';
    if (!qualityOptions.contains(_quality)) _quality = 'higher';
    final dq = prefs.getString(_kDownloadQuality);
    _downloadQuality = qualityOptions.contains(dq) ? dq : null;
    _themeMode = ThemeMode.values[prefs.getInt(_kThemeMode) ?? 0];
    _dynamicColor = prefs.getBool(_kDynamicColor) ?? true;
    _seedValue = prefs.getInt(_kSeed) ?? defaultSeedValue;
    _downloadDirectory = prefs.getString(_kDownloadDir) ?? '';
    _filenameFormat = prefs.getString(_kFilenameFormat) ?? defaultFilenameFormat;
    _volume = prefs.getDouble(_kVolume) ?? 1.0;
    notifyListeners();
  }

  Future<void> _save(String key, Object value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is String) await prefs.setString(key, value);
    if (value is bool) await prefs.setBool(key, value);
    if (value is int) await prefs.setInt(key, value);
    if (value is double) await prefs.setDouble(key, value);
  }

  Future<void> setQuality(String q) async {
    _quality = q;
    await _save(_kQuality, q);
    notifyListeners();
  }

  Future<void> setDownloadQuality(String q) async {
    _downloadQuality = q;
    await _save(_kDownloadQuality, q);
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    await _save(_kThemeMode, mode.index);
    notifyListeners();
  }

  Future<void> setDynamicColor(bool v) async {
    _dynamicColor = v;
    await _save(_kDynamicColor, v);
    notifyListeners();
  }

  Future<void> setSeed(int value) async {
    _seedValue = value;
    _dynamicColor = false;
    await _save(_kSeed, value);
    await _save(_kDynamicColor, false);
    notifyListeners();
  }

  Future<void> setDownloadDirectory(String dir) async {
    _downloadDirectory = dir;
    await _save(_kDownloadDir, dir);
    notifyListeners();
  }

  Future<void> setFilenameFormat(String f) async {
    _filenameFormat = f.trim().isEmpty ? defaultFilenameFormat : f.trim();
    await _save(_kFilenameFormat, _filenameFormat);
    notifyListeners();
  }

  Future<void> setVolume(double v) async {
    _volume = v;
    await _save(_kVolume, v);
    notifyListeners();
  }
}
