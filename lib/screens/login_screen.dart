import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';

/// 官方登录页入口：抖音 Web 官方页。
///
/// 为什么是 douyin.com：汽水音乐官方客户端没有托管登录页（PC 登录
/// 窗是本地页面 + ucenter SDK，见 QISHUI_API.md §7.1），账号体系本身
/// 就是抖音 passport——官方页内置的扫码（抖音 App 确认）+ 短信登录
/// 即同一套官方 UI。沁音不自绘任何登录表单、不接触密码/验证码，
/// 只在登录完成后从 WebView Cookie 罐收割会话 Cookie 存本机。
const String kOfficialLoginPageUrl = 'https://www.douyin.com/';

/// 收割时查询的官方站点（getCookies 按 URL 返回该站可见的 Cookie）
const List<String> _harvestUrls = [
  'https://www.douyin.com/',
  'https://api.qishui.com/',
];

enum _LoginPhase { browsing, checking, done }

/// WebView 登录页：官方页面登录 → 自动检测会话 Cookie → 保存并自检。
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  Timer? _pollTimer;
  _LoginPhase _phase = _LoginPhase.browsing;
  LoginSelfCheckResult? _result;
  int _progress = 0;
  bool _harvesting = false;

  @override
  void initState() {
    super.initState();
    // 轮询兜底：登录完成不一定有可识别的 URL 跳转，定时查 Cookie 罐
    _pollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _harvest(),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _harvest() async {
    if (_harvesting || _phase != _LoginPhase.browsing) return;
    _harvesting = true;
    try {
      final manager = CookieManager.instance();
      final harvested = <StoredCookie>[];
      for (final url in _harvestUrls) {
        final cookies = await manager.getCookies(url: WebUri(url));
        for (final c in cookies) {
          final domain = StoredCookie.normalizeDomain(
            c.domain ?? Uri.parse(url).host,
          );
          harvested.add(StoredCookie(
            name: c.name,
            value: '${c.value}',
            domain: domain,
            path: c.path ?? '/',
          ));
        }
      }
      if (!mounted) return;
      if (!AuthService.hasSessionCookie(harvested)) return;
      // 检测到会话 Cookie：保存 → 自检 → 展示结论
      setState(() => _phase = _LoginPhase.checking);
      final auth = context.read<AuthService>();
      await auth.saveCookies(harvested);
      final result = await auth.runSelfCheck();
      if (!mounted) return;
      setState(() {
        _phase = _LoginPhase.done;
        _result = result;
      });
    } catch (_) {
      // Cookie 罐读取失败（平台差异）时静默等下一轮轮询/手动检测
    } finally {
      _harvesting = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('登录')),
      body: Column(
        children: [
          const _LoginNotice(),
          if (_progress < 100)
            LinearProgressIndicator(
              value: _progress == 0 ? null : _progress / 100,
            ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest:
                  URLRequest(url: WebUri(kOfficialLoginPageUrl)),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                thirdPartyCookiesEnabled: true,
              ),
              onProgressChanged: (_, progress) {
                if (mounted) setState(() => _progress = progress);
              },
              onLoadStop: (_, _) => _harvest(),
              onUpdateVisitedHistory: (_, _, _) => _harvest(),
            ),
          ),
          if (_phase != _LoginPhase.browsing) _buildResultBar(context),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _phase == _LoginPhase.browsing
                          ? '在页面内点「登录」完成扫码或短信登录，本页会自动检测'
                          : '会话已保存到本机，可返回继续使用',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  if (_phase == _LoginPhase.browsing)
                    TextButton(
                      onPressed: _harvest,
                      child: const Text('我已登录，立即检测'),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: _phase == _LoginPhase.checking
          ? const Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 10),
                Text('已检测到登录，正在自检会话…'),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _result?.verdictLabel ?? '',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                for (final p in _result?.probes ?? const <SelfCheckProbe>[])
                  Text(
                    '${p.name}：${p.detail}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                const SizedBox(height: 4),
                Text(
                  '自检结论以本次请求为准；VIP 全曲/歌单同步等能力请在真机继续验证',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
    );
  }
}

/// 登录页顶部说明：官方页面口径 + Cookie 去向 + 风控一句提示
class _LoginNotice extends StatelessWidget {
  const _LoginNotice();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: const Text(
        '本页加载的是抖音官方登录页（汽水音乐同一账号体系），扫码与短信验证码'
        '都在官方页面内完成，沁音不接触你的密码与验证码。登录 Cookie 仅保存在'
        '本机安全存储、只发往官方域名。第三方客户端登录可能触发官方风控，'
        '建议先用小号验证。',
        style: TextStyle(fontSize: 12, height: 1.5),
      ),
    );
  }
}
