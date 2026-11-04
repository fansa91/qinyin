import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qinyin/services/auth_service.dart';

class MemoryStore implements SecureKeyValueStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// 按 URL 路由返回固定 JSON 的捕获适配器（记录最后一次请求头）
class RoutingAdapter implements HttpClientAdapter {
  final Map<String, Map<String, dynamic>> byUrlPart;
  RequestOptions? lastOptions;

  RoutingAdapter(this.byUrlPart);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;
    final url = options.uri.toString();
    for (final entry in byUrlPart.entries) {
      if (url.contains(entry.key)) {
        return ResponseBody.fromString(
          jsonEncode(entry.value),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json; charset=utf-8'],
          },
        );
      }
    }
    // 未匹配路由回 200 空体：本适配器只关心请求头/固定响应，
    // 回 404 会触发 Dio 默认状态校验抛错、掩盖断言
    return ResponseBody.fromString('{}', 200);
  }

  @override
  void close({bool force = false}) {}
}

StoredCookie sessionCookie({
  String domain = 'douyin.com',
  String value = 'sess-abc',
}) =>
    StoredCookie(name: 'sessionid', value: value, domain: domain);

void main() {
  group('会话存储', () {
    test('空存储 init 后未登录', () async {
      final auth = AuthService(store: MemoryStore());
      await auth.init();
      expect(auth.isLoggedIn, isFalse);
      expect(auth.cookies, isEmpty);
    });

    test('saveCookies 后登录态成立且持久化往返', () async {
      final store = MemoryStore();
      final auth = AuthService(store: store);
      await auth.init();
      await auth.saveCookies([sessionCookie()]);
      expect(auth.isLoggedIn, isTrue);
      expect(store.data.containsKey(AuthService.storageKey), isTrue);

      // 新实例同存储恢复（模拟重启）
      final restored = AuthService(store: store);
      await restored.init();
      expect(restored.isLoggedIn, isTrue);
      expect(restored.cookies.single.name, 'sessionid');
    });

    test('logout 清存储与内存态', () async {
      final store = MemoryStore();
      final auth = AuthService(store: store);
      await auth.saveCookies([sessionCookie()]);
      await auth.logout();
      expect(auth.isLoggedIn, isFalse);
      expect(store.data.containsKey(AuthService.storageKey), isFalse);
    });

    test('存储损坏时 init 静默回落未登录', () async {
      final store = MemoryStore()
        ..data[AuthService.storageKey] = 'not-json{{{';
      final auth = AuthService(store: store);
      await auth.init();
      expect(auth.isLoggedIn, isFalse);
    });

    test('saveCookies 空值删除同名 Cookie', () async {
      final auth = AuthService(store: MemoryStore());
      await auth.saveCookies([sessionCookie()]);
      expect(auth.isLoggedIn, isTrue);
      await auth.saveCookies([sessionCookie(value: '')]);
      expect(auth.isLoggedIn, isFalse);
    });
  });

  group('Cookie 域匹配与请求头', () {
    Future<AuthService> loggedIn() async {
      final auth = AuthService(store: MemoryStore());
      await auth.saveCookies([
        sessionCookie(),
        const StoredCookie(
          name: 'passport_csrf_token',
          value: 'csrf-1',
          domain: 'qishui.com',
        ),
      ]);
      return auth;
    }

    test('官方子域命中、非官方域不命中', () async {
      final auth = await loggedIn();
      expect(
        auth.cookieHeaderFor(Uri.parse('https://beta-luna.douyin.com/luna/x')),
        contains('sessionid=sess-abc'),
      );
      expect(
        auth.cookieHeaderFor(Uri.parse('https://open.douyin.com/api/x')),
        contains('sessionid=sess-abc'),
      );
      expect(
        auth.cookieHeaderFor(Uri.parse('https://api.qishui.com/passport/x')),
        contains('passport_csrf_token=csrf-1'),
      );
      // 媒体 CDN 等非官方域永不附带
      expect(
        auth.cookieHeaderFor(Uri.parse('https://v11-luna.douyinvod.com/x')),
        isNull,
      );
      expect(
        auth.cookieHeaderFor(Uri.parse('https://evil-douyin.com/x')),
        isNull,
      );
      expect(
        auth.cookieHeaderFor(Uri.parse('https://example.com/x')),
        isNull,
      );
    });

    test('未登录时一律 null（游客态零影响）', () async {
      final auth = AuthService(store: MemoryStore());
      await auth.init();
      expect(
        auth.cookieHeaderFor(Uri.parse('https://beta-luna.douyin.com/luna/x')),
        isNull,
      );
    });
  });

  group('Dio 拦截器', () {
    test('未登录不加头、登录后官方域加头、已有头不覆盖', () async {
      final adapter = RoutingAdapter({});
      final dio = Dio()..httpClientAdapter = adapter;
      final auth = AuthService(store: MemoryStore());
      auth.attachCookies(dio);

      await dio.get<dynamic>('https://beta-luna.douyin.com/luna/ping');
      expect(adapter.lastOptions!.headers.containsKey('Cookie'), isFalse);

      await auth.saveCookies([sessionCookie()]);
      await dio.get<dynamic>('https://beta-luna.douyin.com/luna/ping');
      expect(adapter.lastOptions!.headers['Cookie'], 'sessionid=sess-abc');

      await dio.get<dynamic>(
        'https://beta-luna.douyin.com/luna/ping',
        options: Options(headers: {'Cookie': 'manual=1'}),
      );
      expect(adapter.lastOptions!.headers['Cookie'], 'manual=1');

      await dio.get<dynamic>('https://v11-luna.douyinvod.com/media');
      expect(adapter.lastOptions!.headers.containsKey('Cookie'), isFalse);
    });
  });

  group('自检解释（纯函数）', () {
    test('live-tab 三态', () {
      expect(
        AuthService.interpretLiveTab({'status_code': 0}).outcome,
        SelfCheckOutcome.ok,
      );
      expect(
        AuthService.interpretLiveTab({'status_code': 1000016}).outcome,
        SelfCheckOutcome.rejected,
      );
      expect(
        AuthService.interpretLiveTab({'status_code': 1000062}).outcome,
        SelfCheckOutcome.riskControl,
      );
      expect(
        AuthService.interpretLiveTab({'status_code': 999}).outcome,
        SelfCheckOutcome.unknown,
      );
    });

    test('account/info 成功与失败', () {
      expect(
        AuthService.interpretAccountInfo({
          'message': 'success',
          'data': {'user_id': 1},
        }).outcome,
        SelfCheckOutcome.ok,
      );
      final rejected = AuthService.interpretAccountInfo({
        'message': 'error',
        'data': {'error_code': 1105},
      });
      expect(rejected.outcome, SelfCheckOutcome.rejected);
      expect(rejected.businessCode, 1105);
    });
  });

  group('runSelfCheck 全链路（mock 适配器）', () {
    Future<AuthService> authWith(Map<String, Map<String, dynamic>> routes) async {
      final dio = Dio()..httpClientAdapter = RoutingAdapter(routes);
      final auth = AuthService(store: MemoryStore(), selfCheckDio: dio);
      await auth.saveCookies([
        sessionCookie(),
        const StoredCookie(
          name: 'sessionid',
          value: 'sess-abc',
          domain: 'qishui.com',
        ),
      ]);
      return auth;
    }

    test('双探针通过 → passed', () async {
      final auth = await authWith({
        'account/info': {
          'message': 'success',
          'data': {'user_id': 1},
        },
        'live-tab': {'status_code': 0},
      });
      final result = await auth.runSelfCheck();
      expect(result.verdict, LoginVerdict.passed);
      expect(auth.lastSelfCheck, same(result));
    });

    test('live-tab 1000016 → sessionRejected', () async {
      final auth = await authWith({
        'account/info': {
          'message': 'success',
          'data': {'user_id': 1},
        },
        'live-tab': {'status_code': 1000016},
      });
      final result = await auth.runSelfCheck();
      expect(result.verdict, LoginVerdict.sessionRejected);
    });

    test('live-tab 1000062 → riskControl', () async {
      final auth = await authWith({
        'account/info': {'message': 'error', 'data': <String, dynamic>{}},
        'live-tab': {'status_code': 1000062},
      });
      final result = await auth.runSelfCheck();
      expect(result.verdict, LoginVerdict.riskControl);
    });
  });
}
