import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ssh_app/services/secure_store.dart';

/// [SecureStore] backed by the Android Keystore and the iOS Keychain.
///
/// iOS items use `kSecAttrAccessibleAfterFirstUnlock` so a background
/// reconnect can read credentials after the first unlock since boot.
class FlutterSecureStore implements SecureStore {
  FlutterSecureStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(migrateWithBackup: true),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) {
    return _storage.write(key: key, value: value);
  }

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<bool> containsKey(String key) => _storage.containsKey(key: key);
}
