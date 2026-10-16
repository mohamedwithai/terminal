import 'package:hive/hive.dart';

/// Small app settings and one-time flags. Never holds secrets.
abstract interface class PreferencesStore {
  bool getBool(String key, {bool defaultValue = false});

  Future<void> setBool(String key, bool value);
}

/// [PreferencesStore] in the Hive box `app_preferences`.
///
/// Call `Hive.initFlutter` before [HivePreferencesStore.open].
class HivePreferencesStore implements PreferencesStore {
  HivePreferencesStore(this._box);

  static const boxName = 'app_preferences';

  final Box<bool> _box;

  static Future<HivePreferencesStore> open() async {
    return HivePreferencesStore(await Hive.openBox<bool>(boxName));
  }

  @override
  bool getBool(String key, {bool defaultValue = false}) {
    return _box.get(key, defaultValue: defaultValue) ?? defaultValue;
  }

  @override
  Future<void> setBool(String key, bool value) => _box.put(key, value);
}

/// [PreferencesStore] that forgets everything when the app closes.
class MemoryPreferencesStore implements PreferencesStore {
  final Map<String, bool> values = {};

  @override
  bool getBool(String key, {bool defaultValue = false}) {
    return values[key] ?? defaultValue;
  }

  @override
  Future<void> setBool(String key, bool value) async {
    values[key] = value;
  }
}
