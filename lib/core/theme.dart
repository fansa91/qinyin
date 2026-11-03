import 'package:flutter/material.dart';

/// 沁音默认种子色：汽水系清新黄绿
const Color kDefaultSeed = Color(0xFF7ED957);

/// 构建全局 M3 主题：只用 ColorScheme.fromSeed 生成令牌，
/// 不手搓颜色体系；组件样式尽量走 M3 默认。
ThemeData buildTheme({required Brightness brightness, Color? seedColor}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: seedColor ?? kDefaultSeed,
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      elevation: 0,
      centerTitle: false,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainer,
      indicatorColor: scheme.secondaryContainer,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
        );
      }),
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerHigh,
      margin: EdgeInsets.zero,
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 0.5,
      space: 0,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      hintStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
