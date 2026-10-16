import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/app_settings.dart';
import 'package:ssh_app/services/preferences_store.dart';

/// `main` overrides this with [HivePreferencesStore]. Without the override
/// (widget tests) settings live in memory.
final preferencesStoreProvider = Provider<PreferencesStore>((ref) {
  return MemoryPreferencesStore();
});

final appSettingsProvider = NotifierProvider<AppSettingsNotifier, AppSettings>(
  AppSettingsNotifier.new,
);

class AppSettingsNotifier extends Notifier<AppSettings> {
  static const storageKey = 'app_settings';

  @override
  AppSettings build() {
    final raw = ref.watch(preferencesStoreProvider).getString(storageKey);
    if (raw == null) {
      return const AppSettings();
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return AppSettings.fromJson(decoded);
      }
    } on FormatException catch (error) {
      debugPrint('Ignoring unreadable settings: $error');
    }
    return const AppSettings();
  }

  Future<void> update(AppSettings Function(AppSettings current) change) async {
    state = change(state);
    await ref
        .read(preferencesStoreProvider)
        .setString(storageKey, jsonEncode(state.toJson()));
  }

  /// Remembers [size] as the font size for [serverId].
  Future<void> setHostFontSize(String serverId, double size) {
    return update(
      (current) => current.copyWith(
        hostFontSizes: {...current.hostFontSizes, serverId: size},
      ),
    );
  }

  Future<void> addTag(String tag) {
    final trimmed = tag.trim();
    return update(
      (current) => trimmed.isEmpty || current.tags.contains(trimmed)
          ? current
          : current.copyWith(tags: [...current.tags, trimmed]),
    );
  }
}
