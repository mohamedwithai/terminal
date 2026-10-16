import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/services/preferences_store.dart';

/// Opened in `main` with [HivePreferencesStore]. Tests override this or pass
/// a [MemoryPreferencesStore] directly.
final preferencesStoreProvider = Provider<PreferencesStore>((ref) {
  throw StateError('preferencesStoreProvider must be overridden at startup.');
});
