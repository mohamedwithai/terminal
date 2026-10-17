import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:ssh_app/app.dart';
import 'package:ssh_app/providers/preferences_providers.dart';
import 'package:ssh_app/providers/snippet_providers.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/services/hive_metadata_store.dart';
import 'package:ssh_app/services/preferences_store.dart';
import 'package:ssh_app/services/snippet_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(_fontLicenses);
  await Hive.initFlutter();
  final metadataStore = await HiveMetadataStore.open();
  final preferences = await HivePreferencesStore.open();
  final snippets = await HiveSnippetStore.open();
  runApp(
    ProviderScope(
      overrides: [
        metadataStoreProvider.overrideWithValue(metadataStore),
        preferencesStoreProvider.overrideWithValue(preferences),
        snippetStoreProvider.overrideWithValue(snippets),
      ],
      child: const SessionKeeperScope(child: SshApp()),
    ),
  );
}

/// The bundled fonts' SIL Open Font Licenses, for the licenses page.
Stream<LicenseEntry> _fontLicenses() async* {
  const fonts = {
    'IBM Plex Sans': 'assets/fonts/IBMPlexSans-LICENSE.txt',
    'JetBrains Mono': 'assets/fonts/JetBrainsMono-LICENSE.txt',
    'Noto Sans Tamil': 'assets/fonts/NotoSansTamil-LICENSE.txt',
  };
  for (final MapEntry(key: name, value: path) in fonts.entries) {
    yield LicenseEntryWithLineBreaks([name], await rootBundle.loadString(path));
  }
}
