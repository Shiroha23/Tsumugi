import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// WebDAV 密码的存储。只用系统安全存储，不写数据库或应用自己的文件（architecture §4.6）。
abstract interface class CredentialStore {
  Future<String?> readPassword();

  /// [password] 为 null 时删除。
  Future<void> writePassword(String? password);
}

/// 系统安全存储：Android Keystore 加密、iOS Keychain、Windows DPAPI 加密文件。
class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'tsumugi.webdav.password';

  final FlutterSecureStorage _storage;

  @override
  Future<String?> readPassword() => _storage.read(key: _key);

  @override
  Future<void> writePassword(String? password) => password == null
      ? _storage.delete(key: _key)
      : _storage.write(key: _key, value: password);
}

/// 测试用：只在内存中。
class MemoryCredentialStore implements CredentialStore {
  MemoryCredentialStore([this.password]);

  String? password;

  @override
  Future<String?> readPassword() async => password;

  @override
  Future<void> writePassword(String? value) async => password = value;
}
