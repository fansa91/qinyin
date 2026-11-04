import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/webview_session.dart';

/// 退出登录统一流程：确认 → 清安全存储会话 → 清 WebView Cookie 罐。
/// 两处不清干净的话，下次打开登录页会带着旧会话「秒登录」，
/// 或业务请求继续带已退出的 Cookie。
Future<void> confirmAndLogout(BuildContext context) async {
  final auth = context.read<AuthService>();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('退出登录'),
      content: const Text('将清除保存在本机的登录会话 Cookie，并退出当前账号。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('退出'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  await auth.logout();
  await clearWebViewSessionData();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('已退出登录')),
  );
}

String _fmtTime(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// 设置页「账号」区：登录态展示 + 登录/退出入口 + 登录自检结果。
class AccountSection extends StatefulWidget {
  const AccountSection({super.key});

  @override
  State<AccountSection> createState() => _AccountSectionState();
}

class _AccountSectionState extends State<AccountSection> {
  bool _checking = false;

  Future<void> _runSelfCheck() async {
    if (_checking) return;
    setState(() => _checking = true);
    await context.read<AuthService>().runSelfCheck();
    if (mounted) setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final check = auth.lastSelfCheck;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const ListTile(
          title: Text('账号'),
          leading: Icon(Icons.account_circle_outlined),
        ),
        ListTile(
          title: Text(auth.isLoggedIn ? '已登录' : '未登录'),
          subtitle: Text(auth.isLoggedIn
              ? '会话 Cookie 保存在本机安全存储，仅发往官方域名'
              : '当前为游客态；登录使用官方页面，Cookie 只存本机'),
        ),
        if (!auth.isLoggedIn)
          ListTile(
            title: const Text('登录'),
            subtitle: const Text('扫码 / 短信（官方页面，建议使用小号验证）'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.pushNamed(context, '/login'),
          )
        else ...[
          ListTile(
            title: const Text('登录自检'),
            subtitle: Text(check == null
                ? '尚未自检'
                : '${check.verdictLabel}（${_fmtTime(check.at)}）'),
            trailing: _checking
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : TextButton(
                    onPressed: _runSelfCheck,
                    child: const Text('重新自检'),
                  ),
          ),
          if (check != null)
            for (final p in check.probes)
              ListTile(
                dense: true,
                title: Text(p.name),
                subtitle: Text(p.detail),
              ),
          ListTile(
            title: const Text('退出登录'),
            subtitle: const Text('清除本机会话 Cookie 与 WebView 登录痕迹'),
            trailing: const Icon(Icons.logout),
            onTap: () => confirmAndLogout(context),
          ),
        ],
      ],
    );
  }
}

/// 「我的」页顶部 slim 账号行：状态 + 登录/退出快捷入口
/// （完整说明与自检在设置页「账号」区）。
class AccountBar extends StatelessWidget {
  const AccountBar({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    return ListTile(
      dense: true,
      leading: Icon(
        auth.isLoggedIn
            ? Icons.verified_user_outlined
            : Icons.account_circle_outlined,
      ),
      title: Text(auth.isLoggedIn ? '已登录' : '未登录'),
      subtitle: Text(
        auth.isLoggedIn ? '会话保存在本机 · 详情见设置' : '游客态 · 登录后可验证登录态能力',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: auth.isLoggedIn
          ? TextButton(
              onPressed: () => confirmAndLogout(context),
              child: const Text('退出'),
            )
          : FilledButton.tonal(
              onPressed: () => Navigator.pushNamed(context, '/login'),
              child: const Text('登录'),
            ),
    );
  }
}
