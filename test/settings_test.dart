import 'package:flutter_test/flutter_test.dart';
import 'package:qinyin/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('下载音质（与播放音质独立）', () {
    test('老用户无下载音质键 → 跟随播放音质', () async {
      SharedPreferences.setMockInitialValues({'default_quality': 'highest'});
      final s = SettingsService();
      await s.init();
      expect(s.defaultQuality, 'highest');
      expect(s.hasDownloadQuality, isFalse);
      expect(s.downloadQuality, 'highest'); // 跟随现状
    });

    test('单独设置后互不影响，且持久化可回读', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsService();
      await s.init();
      await s.setQuality('medium');
      await s.setDownloadQuality('lossless');
      expect(s.defaultQuality, 'medium');
      expect(s.downloadQuality, 'lossless');
      expect(s.hasDownloadQuality, isTrue);

      final s2 = SettingsService();
      await s2.init();
      expect(s2.defaultQuality, 'medium');
      expect(s2.downloadQuality, 'lossless');
    });

    test('改播放音质不带动已单独设置的下载音质', () async {
      SharedPreferences.setMockInitialValues({
        'default_quality': 'higher',
        'download_quality': 'medium',
      });
      final s = SettingsService();
      await s.init();
      await s.setQuality('highest');
      expect(s.downloadQuality, 'medium');
    });
  });
}
