import 'package:hive/hive.dart';

/// Small app settings and one-time flags. Never holds secrets.
abstract interface class PreferencesStore {
  bool getBool(String key, {bool defaultValue = false});

  Future<void> setBool(String key, bool value);

  String? getString(String key);

  Future<void> setString(String key, String value);
}

/// [PreferencesStore] in the Hive box `app_preferences`.
///
/// Call `Hive.initFlutter` before [HivePreferencesStore.open].
class HivePreferencesStore implements PreferencesStore {
  HivePreferencesStore(this._box);

  static const boxName = 'app_preferences';

  final Box<Object?> _box;

  static Future<HivePreferencesStore> open() async {
    return HivePreferencesStore(await Hive.openBox<Object?>(boxName));
  }

  @override
  bool getBool(String key, {bool defaultValue = false}) {
    final value = _box.get(key);
    return value is bool ? value : defaultValue;
  }

  @override
  Future<void> setBool(String key, bool value) => _box.put(key, value);

  @override
  String? getString(String key) {
    final value = _box.get(key);
    return value is String ? value : null;
  }

  @override
  Future<void> setString(String key, String value) => _box.put(key, value);
}

/// [PreferencesStore] that forgets everything when the app closes.
class MemoryPreferencesStore implements PreferencesStore {
  final Map<String, Object> values = {};

  @override
  bool getBool(String key, {bool defaultValue = false}) {
    final value = values[key];
    return value is bool ? value : defaultValue;
  }

  @override
  Future<void> setBool(String key, bool value) async {
    values[key] = value;
  }

  @override
  String? getString(String key) {
    final value = values[key];
    return value is String ? value : null;
  }

  @override
  Future<void> setString(String key, String value) async {
    values[key] = value;
  }
}
