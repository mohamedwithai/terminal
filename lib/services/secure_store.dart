/// Encrypted key-value store for secrets.
///
/// Production uses [FlutterSecureStore]. Tests pass an in-memory fake so
/// vault behavior can be checked without the platform keystore.
abstract interface class SecureStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);

  Future<bool> containsKey(String key);
}
