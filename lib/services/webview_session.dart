import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 清除 WebView 侧的登录痕迹（Cookie 罐 + 网站数据）。
///
/// 退出登录时与 [AuthService.logout] 配套调用：AuthService 清的是
/// 安全存储里的会话副本，这里清的是 WebView 自己的罐子——不清的话
/// 下次打开登录页会直接带着旧会话。各平台支持度不一（Windows 的
/// WebStorageManager 可能不可用），全程吞错、尽力而为。
Future<void> clearWebViewSessionData() async {
  try {
    await CookieManager.instance().deleteAllCookies();
  } catch (_) {
    // 平台不支持时忽略：安全存储侧已清，实际会话以服务端为准
  }
  try {
    await WebStorageManager.instance().deleteAllData();
  } catch (_) {
    // 同上
  }
}
