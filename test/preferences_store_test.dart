import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ssh_app/services/preferences_store.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ssh_prefs_');
    Hive.init(directory.path);
  });

  tearDown(() async {
    await Hive.close();
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  test('a flag survives closing and reopening the box', () async {
    final first = await HivePreferencesStore.open();
    expect(first.getBool('hint_shown'), isFalse);
    expect(first.getBool('hint_shown', defaultValue: true), isTrue);

    await first.setBool('hint_shown', true);
    await Hive.close();
    Hive.init(directory.path);

    final second = await HivePreferencesStore.open();
    expect(second.getBool('hint_shown'), isTrue);
  });
}
