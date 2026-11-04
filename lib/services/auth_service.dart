import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 官方登录会话（WebView 登录后收割的 Cookie）。
///
/// 安全口径（硬性）：
/// - Cookie 只存设备本地的安全存储（flutter_secure_storage），
///   不打日志、不进任何上报、不写普通文件；
/// - 只在请求官方域名（douyin.com / qishui.com 后缀，含
///   beta-luna.douyin.com、api.qishui.com、open.douyin.com）时附带，
///   媒体 CDN 等其他域名永不附带；
/// - 未登录时拦截器什么都不加，游客态请求与接入前逐字节一致。
///
/// 登录形态见 QISHUI_API.md §7.1：官方无托管登录页，WebView 加载
/// 抖音 Web 官方页（同一 passport 账号体系，官方扫码+短信 UI），
/// 登录成功后从 WebView Cookie 罐收割会话 Cookie，再由 [runSelfCheck]
/// 双探针验证会话是否被汽水接口接受（结论以真机实测为准）。
class StoredCookie {
  final String name;
  final String value;

  /// 归属域（已规范化：小写、无前导点），如 `douyin.com`
  final String domain;
  final String path;

  const StoredCookie({
    required this.name,
    required this.value,
    required this.domain,
    this.path = '/',
  });

  static String normalizeDomain(String raw) {
    var d = raw.trim().toLowerCase();
    if (d.startsWith('.')) d = d.substring(1);
    return d;
  }

  /// RFC 6265 域匹配简化版：host 等于域或为其子域
  bool appliesTo(String host) {
    final h = host.toLowerCase();
    return h == domain || h.endsWith('.$domain');
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'value': value,
        'domain': domain,
        'path': path,
      };

  factory StoredCookie.fromJson(Map<String, dynamic> json) => StoredCookie(
        name: '${json['name'] ?? ''}',
        value: '${json['value'] ?? ''}',
        domain: normalizeDomain('${json['domain'] ?? ''}'),
        path: '${json['path'] ?? '/'}',
      );
}

/// 安全键值存储抽象：生产实现走 flutter_secure_storage，
/// 单测用内存实现替换（平台通道不进测试）。
abstract class SecureKeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterSecureKeyValueStore implements SecureKeyValueStore {
  final FlutterSecureStorage _storage;

  FlutterSecureKeyValueStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// 自检单探针结果
enum SelfCheckOutcome { ok, rejected, riskControl, networkError, unknown }

class SelfCheckProbe {
  final String name;
  final SelfCheckOutcome outcome;

  /// 业务码（status_code / error_code），仅数字、无敏感信息，可展示
  final int? businessCode;
  final String detail;

  const SelfCheckProbe({
    required this.name,
    required this.outcome,
    this.businessCode,
    required this.detail,
  });
}

/// 登录后自检总体结论（三态如实 + 无法判定）
enum LoginVerdict { passed, sessionRejected, riskControl, unknown }

class LoginSelfCheckResult {
  final LoginVerdict verdict;
  final List<SelfCheckProbe> probes;
  final DateTime at;

  const LoginSelfCheckResult({
    required this.verdict,
    required this.probes,
    required this.at,
  });

  String get verdictLabel => switch (verdict) {
        LoginVerdict.passed => '通过：登录态已被汽水接口接受',
        LoginVerdict.sessionRejected => '仍未登录：汽水接口未接受该会话',
        LoginVerdict.riskControl => '被风控：接口返回版本/风控拦截',
        LoginVerdict.unknown => '未能判定：网络异常或未知返回',
      };
}

class AuthService extends ChangeNotifier {
  static const String storageKey = 'qinyin_auth_cookies_v1';

  /// 允许附带 Cookie 的官方域后缀（其子域一并覆盖）
  static const List<String> officialDomainSuffixes = ['douyin.com', 'qishui.com'];

  /// passport 会话 Cookie 名（出现任一即视为已登录）
  static const Set<String> sessionCookieNames = {
    'sessionid',
    'sessionid_ss',
    'sid_tt',
    'uid_tt',
    'uid_tt_ss',
  };

  final SecureKeyValueStore _store;
  final Dio _selfCheckDio;

  List<StoredCookie> _cookies = const [];
  LoginSelfCheckResult? _lastSelfCheck;

  AuthService({required SecureKeyValueStore store, Dio? selfCheckDio})
      : _store = store,
        _selfCheckDio = selfCheckDio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
            )) {
    attachCookies(_selfCheckDio);
  }

  List<StoredCookie> get cookies => List.unmodifiable(_cookies);

  bool get isLoggedIn => hasSessionCookie(_cookies);

  LoginSelfCheckResult? get lastSelfCheck => _lastSelfCheck;

  static bool hasSessionCookie(List<StoredCookie> cookies) => cookies.any(
      (c) => sessionCookieNames.contains(c.name) && c.value.isNotEmpty);

  static bool isOfficialHost(String host) {
    final h = host.toLowerCase();
    return officialDomainSuffixes.any((s) => h == s || h.endsWith('.$s'));
  }

  /// 启动时从安全存储恢复会话；损坏数据静默丢弃回未登录态
  Future<void> init() async {
    try {
      final raw = await _store.read(storageKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        _cookies = decoded
            .whereType<Map<String, dynamic>>()
            .map(StoredCookie.fromJson)
            .where((c) => c.name.isNotEmpty && c.domain.isNotEmpty)
            .toList();
      }
    } catch (_) {
      _cookies = const [];
    }
  }

  /// 保存 WebView 收割的 Cookie：同 (name, domain, path) 覆盖，
  /// 空值视为删除（服务端清 Cookie 的惯例写法）。
  Future<void> saveCookies(List<StoredCookie> harvested) async {
    final merged = <String, StoredCookie>{
      for (final c in _cookies) '${c.name}|${c.domain}|${c.path}': c,
    };
    for (final c in harvested) {
      final key = '${c.name}|${c.domain}|${c.path}';
      if (c.value.isEmpty) {
        merged.remove(key);
      } else {
        merged[key] = c;
      }
    }
    _cookies = merged.values.toList();
    await _persist();
    notifyListeners();
  }

  /// 退出登录：清安全存储 + 内存态（WebView 侧 Cookie 罐由 UI 层
  /// 再调 clearWebViewSessionData 清除，两边都清才算退干净）。
  Future<void> logout() async {
    _cookies = const [];
    _lastSelfCheck = null;
    try {
      await _store.delete(storageKey);
    } catch (_) {
      // 存储删除失败不阻塞退出：内存态已清，重启后至多恢复旧会话，
      // 用户可再次退出。
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    final raw = jsonEncode(_cookies.map((c) => c.toJson()).toList());
    await _store.write(storageKey, raw);
  }

  /// 某 URL 应附带的 Cookie 头；未登录/不匹配/非官方域一律 null
  String? cookieHeaderFor(Uri uri) {
    if (_cookies.isEmpty) return null;
    if (!isOfficialHost(uri.host)) return null;
    final matched = _cookies.where((c) => c.appliesTo(uri.host)).toList();
    if (matched.isEmpty) return null;
    return matched.map((c) => '${c.name}=${c.value}').join('; ');
  }

  /// 给业务 Dio 装 Cookie 拦截器：仅官方域、仅未登录时无操作，
  /// 且不覆盖请求已自带的 Cookie 头。
  void attachCookies(Dio dio) {
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        final header = cookieHeaderFor(options.uri);
        if (header != null && options.headers['Cookie'] == null) {
          options.headers['Cookie'] = header;
        }
        handler.next(options);
      },
    ));
  }

  // ---------------------------------------------------------------------------
  // 登录后自检：双探针（passport 会话有效性 + 汽水接口是否接受）
  // ---------------------------------------------------------------------------

  /// passport `account/info/v2` 返回解释（纯函数，单测钉死）：
  /// message=success 视为会话有效；其余按未接受处理并带回业务码。
  static SelfCheckProbe interpretAccountInfo(Map<String, dynamic> body) {
    final message = '${body['message'] ?? ''}';
    final data = body['data'];
    if (message == 'success' && data is Map) {
      return const SelfCheckProbe(
        name: 'Passport 会话',
        outcome: SelfCheckOutcome.ok,
        detail: 'account/info 返回 success，会话有效',
      );
    }
    final code = data is Map ? data['error_code'] as int? : null;
    return SelfCheckProbe(
      name: 'Passport 会话',
      outcome: SelfCheckOutcome.rejected,
      businessCode: code,
      detail: 'account/info 未返回 success（message=$message）',
    );
  }

  /// `/luna/feed/live-tab` 返回解释（纯函数，单测钉死）：
  /// 游客基线为 1000016「登录状态已失效」（QISHUI_API.md §14/§16 实测）；
  /// 0 = 登录态被接受；1000062 = 版本/风控拦截。
  static SelfCheckProbe interpretLiveTab(Map<String, dynamic> body) {
    final code = (body['status_code'] as num?)?.toInt();
    return switch (code) {
      0 => const SelfCheckProbe(
          name: '汽水登录态接口',
          outcome: SelfCheckOutcome.ok,
          businessCode: 0,
          detail: 'live-tab 返回 0，登录态已被接受',
        ),
      1000016 => const SelfCheckProbe(
          name: '汽水登录态接口',
          outcome: SelfCheckOutcome.rejected,
          businessCode: 1000016,
          detail: 'live-tab 返回 1000016「登录状态已失效」，会话未被接受',
        ),
      1000062 => const SelfCheckProbe(
          name: '汽水登录态接口',
          outcome: SelfCheckOutcome.riskControl,
          businessCode: 1000062,
          detail: 'live-tab 返回 1000062，版本/风控拦截',
        ),
      _ => SelfCheckProbe(
          name: '汽水登录态接口',
          outcome: SelfCheckOutcome.unknown,
          businessCode: code,
          detail: 'live-tab 返回未知 status_code=$code',
        ),
    };
  }

  /// 跑一遍自检并保存结果（登录成功后由登录页自动触发，
  /// 设置页可手动重跑）。总体结论以 live-tab 探针为准。
  Future<LoginSelfCheckResult> runSelfCheck() async {
    final probes = <SelfCheckProbe>[];

    try {
      final resp = await _selfCheckDio.get<dynamic>(
        'https://api.qishui.com/passport/account/info/v2/',
        queryParameters: const {'aid': '386088'},
      );
      final body = (resp.data as Map).cast<String, dynamic>();
      probes.add(interpretAccountInfo(body));
    } on DioException catch (e) {
      probes.add(SelfCheckProbe(
        name: 'Passport 会话',
        outcome: SelfCheckOutcome.networkError,
        detail: '请求失败：${e.type.name}',
      ));
    } catch (_) {
      probes.add(const SelfCheckProbe(
        name: 'Passport 会话',
        outcome: SelfCheckOutcome.unknown,
        detail: '返回无法解析',
      ));
    }

    SelfCheckProbe liveProbe;
    try {
      final resp = await _selfCheckDio.post<dynamic>(
        'https://beta-luna.douyin.com/luna/feed/live-tab',
        data: const <String, dynamic>{},
        options: Options(headers: {
          'User-Agent': 'Luna/19.1.0 Android',
          'Content-Type': 'application/json; charset=utf-8',
        }),
      );
      final body = (resp.data as Map).cast<String, dynamic>();
      liveProbe = interpretLiveTab(body);
    } on DioException catch (e) {
      liveProbe = SelfCheckProbe(
        name: '汽水登录态接口',
        outcome: SelfCheckOutcome.networkError,
        detail: '请求失败：${e.type.name}',
      );
    } catch (_) {
      liveProbe = const SelfCheckProbe(
        name: '汽水登录态接口',
        outcome: SelfCheckOutcome.unknown,
        detail: '返回无法解析',
      );
    }
    probes.add(liveProbe);

    final verdict = switch (liveProbe.outcome) {
      SelfCheckOutcome.ok => LoginVerdict.passed,
      SelfCheckOutcome.rejected => LoginVerdict.sessionRejected,
      SelfCheckOutcome.riskControl => LoginVerdict.riskControl,
      _ => LoginVerdict.unknown,
    };
    final result = LoginSelfCheckResult(
      verdict: verdict,
      probes: probes,
      at: DateTime.now(),
    );
    _lastSelfCheck = result;
    notifyListeners();
    return result;
  }
}
