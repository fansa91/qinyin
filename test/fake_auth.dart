import 'package:qinyin/services/auth_service.dart';

/// 测试共用的未登录 AuthService（内存存储）：只需要让
/// AccountBar/AccountSection 等登录态 UI 在 provider 树里找得到它，
/// 状态恒为游客态，不触发任何平台通道。
class _MemoryStore implements SecureKeyValueStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

final AuthService testAuthService = AuthService(store: _MemoryStore());
