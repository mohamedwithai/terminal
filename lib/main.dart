import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:ssh_app/app.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/services/hive_metadata_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  final metadataStore = await HiveMetadataStore.open();
  runApp(
    ProviderScope(
      overrides: [
        metadataStoreProvider.overrideWithValue(metadataStore),
      ],
      child: const SessionKeeperScope(child: SshApp()),
    ),
  );
}
