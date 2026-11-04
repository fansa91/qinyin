import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qinyin/models/models.dart';
import 'package:qinyin/services/download_service.dart';
import 'package:qinyin/services/play_resolver.dart';
import 'package:qinyin/services/settings_service.dart';
import 'package:qinyin/widgets/download_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 数字全部取自 §17 实测样本：
// 《雨爱》VIP 试听段 higher：size=487145, bitrate=129901 → 推算 30.0s，
// 曲目时长 261.56s（ffprobe 实测下发音频恰 30.0s）。
PlayStream trialStream(String url) => PlayStream(
      quality: 'higher',
      codecType: 'aac',
      bitrate: 129901,
      size: 487145,
      mainUrl: url,
    );

// 整曲流：同码率下 size 与 261.56s 时长成比例（推算时长 ≈ 261.6s）
PlayStream fullStream(String url) => PlayStream(
      quality: 'higher',
      codecType: 'aac',
      bitrate: 129901,
      size: 4247000,
      mainUrl: url,
    );

SeoTrack seoOf(Track track, List<PlayStream> streams) => SeoTrack(
      track: track,
      streams: streams,
      expireAt: 9999999999,
    );

/// 测试专用：强制 HttpClient 直连（绕过环境出口代理，仅本地服务器用）
class _DirectHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..findProxy = (_) => 'DIRECT';
}

void main() {
  group('完整性判定 streamComplete（§17 口径）', () {
    const dur = 261560; // 《雨爱》曲目时长 ms
    test('试听段流（推算 30s / 全曲 261.6s）→ 不完整', () {
      expect(
        PlayResolver.streamComplete(
            stream: trialStream('https://x'), trackDurationMs: dur, seoIsVip: true),
        isFalse,
      );
    });
    test('VIP 曲目但流推算时长达标 → 完整（不凭 isVip 一刀切）', () {
      expect(
        PlayResolver.streamComplete(
            stream: fullStream('https://x'), trackDurationMs: dur, seoIsVip: true),
        isTrue,
      );
    });
    test('非 VIP 全曲流 → 完整', () {
      expect(
        PlayResolver.streamComplete(
            stream: fullStream('https://x'), trackDurationMs: dur, seoIsVip: false),
        isTrue,
      );
    });
    test('边界：推算时长为全曲 95% → 完整；85% → 不完整', () {
      PlayStream sized(int size) => PlayStream(
          quality: 'higher', bitrate: 100000, size: size, mainUrl: 'https://x');
      // 全曲 100s @100kbps → size=1250000；95% → 1187500，85% → 1062500
      expect(
          PlayResolver.streamComplete(
              stream: sized(1187500), trackDurationMs: 100000, seoIsVip: false),
          isTrue);
      expect(
          PlayResolver.streamComplete(
              stream: sized(1062500), trackDurationMs: 100000, seoIsVip: false),
          isFalse);
    });
    test('流元数据缺失 → 退回 seo 标记：VIP 判不完整、非 VIP 判完整', () {
      const bare = PlayStream(quality: 'higher', mainUrl: 'https://x');
      expect(
          PlayResolver.streamComplete(
              stream: bare, trackDurationMs: dur, seoIsVip: true),
          isFalse);
      expect(
          PlayResolver.streamComplete(
              stream: bare, trackDurationMs: dur, seoIsVip: false),
          isTrue);
    });
    test('曲目时长未知 → 退回 seo 标记（不拿推算时长瞎猜）', () {
      expect(
          PlayResolver.streamComplete(
              stream: trialStream('https://x'), trackDurationMs: 0, seoIsVip: true),
          isFalse);
      expect(
          PlayResolver.streamComplete(
              stream: trialStream('https://x'), trackDurationMs: 0, seoIsVip: false),
          isTrue);
    });
  });

  group('resolveForDownload', () {
    test('VIP + 试听信号 → complete=false', () async {
      final track = Track(id: 'v1', name: '雨爱', durationMs: 261560, isVip: true);
      final resolver =
          PlayResolver((id) async => seoOf(track, [trialStream('https://x')]));
      final r = await resolver.resolveForDownload(track, quality: 'higher');
      expect(r.complete, isFalse);
      expect(r.resolved.stream.quality, 'higher');
    });
    test('VIP + 全曲信号 → complete=true', () async {
      final track = Track(id: 'v2', name: 'VIP全曲', durationMs: 261560, isVip: true);
      final resolver =
          PlayResolver((id) async => seoOf(track, [fullStream('https://x')]));
      final r = await resolver.resolveForDownload(track, quality: 'higher');
      expect(r.complete, isTrue);
    });
    test('无流 → PlayUnavailable（与播放同口径）', () async {
      final track = Track(id: 'v3', name: '无流', durationMs: 1000, isVip: true);
      final resolver = PlayResolver((id) async => seoOf(track, const []));
      expect(() => resolver.resolveForDownload(track, quality: 'higher'),
          throwsA(isA<PlayUnavailable>()));
    });
  });

  group('DownloadService VIP 闸门', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    late HttpServer server;
    late Directory tmp;
    late String baseUrl;

    setUpAll(() async {
      // 本机 HttpServer 必须直连：测试机环境变量里的出口代理会把
      // 127.0.0.1 请求也劫走（实测回 400），故本组内强制 DIRECT。
      HttpOverrides.global = _DirectHttpOverrides();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUrl = 'http://${server.address.host}:${server.port}';
      server.listen((req) {
        req.response
          ..statusCode = 200
          ..add(List.filled(8192, 7))
          ..close();
      });
      tmp = await Directory.systemTemp.createTemp('qinyin_vip_dl_test');
    });
    tearDownAll(() async {
      HttpOverrides.global = null;
      await server.close(force: true);
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<DownloadService> makeService(SeoTrack seo) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService();
      await settings.init();
      await settings.setDownloadDirectory(tmp.path);
      final resolver = PlayResolver((id) async => seo);
      return DownloadService(resolver, settings);
    }

    test('VIP + 试听段 → 拒绝并提示需 VIP，不落文件不建记录', () async {
      final track =
          Track(id: 'vip-trial', name: '雨爱', durationMs: 261560, isVip: true);
      final svc = await makeService(seoOf(track, [trialStream('$baseUrl/a.m4a')]));
      await expectLater(
        svc.download(track),
        throwsA(isA<VipDownloadException>().having((e) => e.message,
            'message', allOf(contains('VIP'), contains('只能试听')))),
      );
      expect(svc.records, isEmpty);
      expect(svc.tasks, isEmpty);
      expect(
        tmp.listSync().where((f) => f.path.endsWith('.m4a')),
        isEmpty,
      );
    });

    test('VIP + 全曲信号 → 正常下载落盘', () async {
      final track =
          Track(id: 'vip-full', name: 'VIP全曲', durationMs: 261560, isVip: true);
      final svc = await makeService(seoOf(track, [fullStream('$baseUrl/b.m4a')]));
      final record = await svc.download(track);
      expect(File(record.path).existsSync(), isTrue);
      expect(svc.isDownloaded('vip-full'), isTrue);
    });

    test('非 VIP → 不受闸门影响，正常下载', () async {
      final track = Track(id: 'free-full', name: '免费全曲', durationMs: 261560);
      final svc = await makeService(seoOf(track, [fullStream('$baseUrl/c.m4a')]));
      final record = await svc.download(track);
      expect(File(record.path).existsSync(), isTrue);
      expect(svc.isDownloaded('free-full'), isTrue);
    });
  });

  group('下载按钮状态映射', () {
    test('未下载/未进行 → ready', () {
      expect(
          downloadButtonState(isDownloaded: false, isDownloading: false),
          DownloadButtonState.ready);
    });
    test('下载中 → downloading', () {
      expect(
          downloadButtonState(isDownloaded: false, isDownloading: true),
          DownloadButtonState.downloading);
    });
    test('已下载 → downloaded（优先于残留任务态）', () {
      expect(
          downloadButtonState(isDownloaded: true, isDownloading: false),
          DownloadButtonState.downloaded);
      expect(
          downloadButtonState(isDownloaded: true, isDownloading: true),
          DownloadButtonState.downloaded);
    });
  });

  testWidgets('播放页下载按钮：VIP 试听曲点按 → 弹出需 VIP 提示', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    await settings.init();
    final track =
        Track(id: 'vip-btn', name: '雨爱', durationMs: 261560, isVip: true);
    final resolver =
        PlayResolver((id) async => seoOf(track, [trialStream('https://x/a.m4a')]));
    final downloads = DownloadService(resolver, settings);
    await tester.pumpWidget(
      ChangeNotifierProvider<DownloadService>.value(
        value: downloads,
        child: MaterialApp(
          home: Scaffold(body: TrackDownloadButton(track: track)),
        ),
      ),
    );
    expect(find.text('下载'), findsOneWidget);
    await tester.tap(find.text('下载'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('游客只能试听'), findsOneWidget);
    expect(downloads.records, isEmpty);
  });
}
