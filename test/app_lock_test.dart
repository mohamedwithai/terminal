import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/app.dart';
import 'package:ssh_app/models/app_settings.dart';
import 'package:ssh_app/providers/app_lock_providers.dart';
import 'package:ssh_app/providers/preferences_providers.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/screens/settings_screen.dart';
import 'package:ssh_app/services/app_lock/biometric_authenticator.dart';
import 'package:ssh_app/services/app_lock/pin_store.dart';
import 'package:ssh_app/services/app_lock/window_security.dart';
import 'package:ssh_app/services/preferences_store.dart';
import 'package:ssh_app/services/vault_service.dart';

import 'support/memory_stores.dart';

class FakeBiometrics implements BiometricAuthenticator {
  FakeBiometrics({this.available = true, this.accept = true});

  bool available;
  bool accept;
  var prompts = 0;
  Future<void> Function()? duringPrompt;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> authenticate(String reason) async {
    prompts++;
    await duringPrompt?.call();
    return accept;
  }

  @override
  Future<void> cancel() async {}
}

class FakeWindowSecurity implements WindowSecurity {
  final calls = <bool>[];

  @override
  Future<void> setSecure(bool secure) async => calls.add(secure);
}

PinStore fastPinStore(MemorySecureStore secure, {DateTime Function()? clock}) {
  return PinStore(secure, iterations: 4, hashInBackground: false, clock: clock);
}

void main() {
  group('PinStore', () {
    late MemorySecureStore secure;
    var now = DateTime.utc(2026, 1, 1);

    setUp(() {
      secure = MemorySecureStore();
      now = DateTime.utc(2026, 1, 1);
    });

    PinStore store() => fastPinStore(secure, clock: () => now);

    test('only the salted hash is stored, never the PIN', () async {
      await store().setPin('482915');

      final raw = secure.values[PinStore.storageKey]!;
      expect(raw, isNot(contains('482915')));
      final record = jsonDecode(raw) as Map;
      expect(record['salt'], isNotEmpty);
      expect(record['hash'], isNotEmpty);
      expect(record['length'], 6);
      expect(await store().hasPin(), isTrue);
      expect(await store().length(), 6);
    });

    test('the same PIN gets a different salt and hash each time', () async {
      final a = fastPinStore(MemorySecureStore());
      await a.setPin('1234');
      await store().setPin('1234');
      await store().setPin('1234');
      final first = jsonDecode(secure.values[PinStore.storageKey]!) as Map;
      await store().setPin('1234');
      final second = jsonDecode(secure.values[PinStore.storageKey]!) as Map;
      expect(first['salt'], isNot(second['salt']));
      expect(first['hash'], isNot(second['hash']));
    });

    test('checks the PIN', () async {
      await store().setPin('1234');

      expect(await store().verify('1234'), isA<PinCorrect>());
      final wrong = await store().verify('1235') as PinWrong;
      expect(wrong.failures, 1);
      expect(wrong.lockedFor, isNull);
      expect(await store().verify('12345'), isA<PinWrong>());
      expect(await store().verify(''), isA<PinWrong>());
    });

    test('PIN rules', () {
      expect(pinProblem('123'), contains('4'));
      expect(pinProblem('1234567890123'), contains('12'));
      expect(pinProblem('12a4'), contains('digits'));
      expect(pinProblem('1234'), isNull);
      expect(() => store().setPin('12'), throwsA(isA<ArgumentError>()));
    });

    test('five wrong tries start a wait that doubles, and caps', () async {
      await store().setPin('1234');
      for (var i = 1; i <= 4; i++) {
        expect((await store().verify('0000') as PinWrong).lockedFor, isNull);
      }

      var result = await store().verify('0000') as PinWrong;
      expect(result.lockedFor, const Duration(seconds: 30));

      // Locked out: even the right PIN is not looked at.
      final locked = await store().verify('1234') as PinLockedOut;
      expect(locked.remaining, const Duration(seconds: 30));
      expect(await store().lockoutRemaining(), const Duration(seconds: 30));

      now = now.add(const Duration(seconds: 31));
      expect(await store().lockoutRemaining(), isNull);
      result = await store().verify('0000') as PinWrong;
      expect(result.failures, 6);
      expect(result.lockedFor, const Duration(seconds: 60));

      for (var i = 0; i < 12; i++) {
        now = now.add(const Duration(hours: 1));
        result = await store().verify('0000') as PinWrong;
      }
      expect(result.lockedFor, const Duration(minutes: 15));
    });

    test(
      'the wait survives restarting the app; a right PIN resets it',
      () async {
        await store().setPin('1234');
        for (var i = 0; i < 5; i++) {
          await store().verify('0000');
        }

        // A new PinStore, as after a restart, still refuses.
        expect(await store().verify('1234'), isA<PinLockedOut>());

        now = now.add(const Duration(seconds: 31));
        expect(await store().verify('1234'), isA<PinCorrect>());
        // The count started over.
        expect((await store().verify('0000') as PinWrong).failures, 1);
      },
    );

    test('clear removes it', () async {
      await store().setPin('1234');
      await store().clear();
      expect(await store().hasPin(), isFalse);
      expect(await store().verify('1234'), isA<PinWrong>());
    });

    test('the real hash settings are strong', () {
      expect(
        PinStore(MemorySecureStore()).iterations,
        greaterThanOrEqualTo(100000),
      );
    });
  });

  group('AppLockController', () {
    late MemorySecureStore secure;
    late MemoryPreferencesStore prefs;
    late FakeBiometrics biometrics;
    late FakeWindowSecurity window;
    var now = DateTime.utc(2026, 1, 1);

    setUp(() {
      secure = MemorySecureStore();
      prefs = MemoryPreferencesStore();
      biometrics = FakeBiometrics();
      window = FakeWindowSecurity();
      now = DateTime.utc(2026, 1, 1);
    });

    Future<ProviderContainer> start({
      bool enabled = true,
      LockTimeout timeout = LockTimeout.immediately,
      bool biometricsOn = false,
      bool withPin = true,
    }) async {
      if (withPin) await fastPinStore(secure).setPin('1234');
      prefs.values[AppSettingsNotifier.storageKey] = jsonEncode(
        const AppSettings()
            .copyWith(
              appLock: enabled,
              lockTimeout: timeout,
              lockBiometrics: biometricsOn,
            )
            .toJson(),
      );
      final container = ProviderContainer(
        overrides: <Override>[
          preferencesStoreProvider.overrideWithValue(prefs),
          secureStoreProvider.overrideWithValue(secure),
          pinStoreProvider.overrideWithValue(
            fastPinStore(secure, clock: () => now),
          ),
          biometricAuthenticatorProvider.overrideWithValue(biometrics),
          windowSecurityProvider.overrideWithValue(window),
          vaultServiceProvider.overrideWithValue(
            VaultService(
              secureStore: secure,
              metadataStore: MemoryMetadataStore(),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(appLockProvider.notifier).clock = () => now;
      return container;
    }

    AppLockController lock(ProviderContainer c) =>
        c.read(appLockProvider.notifier);
    bool locked(ProviderContainer c) => c.read(appLockProvider).locked;

    test('starts locked when on, open when off', () async {
      expect(locked(await start()), isTrue);
      expect(locked(await start(enabled: false)), isFalse);
    });

    test('"immediately" locks as the app leaves the foreground', () async {
      final c = await start();
      await lock(c).unlockWithPin('1234');
      expect(locked(c), isFalse);

      lock(c).onLifecycle(AppLifecycleState.inactive);
      expect(
        locked(c),
        isFalse,
        reason: 'a dialog or the shade is not leaving',
      );
      lock(c).onLifecycle(AppLifecycleState.hidden);
      expect(locked(c), isTrue);
    });

    test('a timeout locks only after that long away', () async {
      final c = await start(timeout: LockTimeout.oneMinute);
      await lock(c).unlockWithPin('1234');

      lock(c).onLifecycle(AppLifecycleState.paused);
      expect(locked(c), isFalse);
      now = now.add(const Duration(seconds: 59));
      lock(c).onLifecycle(AppLifecycleState.resumed);
      expect(locked(c), isFalse);

      lock(c).onLifecycle(AppLifecycleState.paused);
      now = now.add(const Duration(seconds: 61));
      lock(c).onLifecycle(AppLifecycleState.resumed);
      expect(locked(c), isTrue);
    });

    test('five minutes', () async {
      final c = await start(timeout: LockTimeout.fiveMinutes);
      await lock(c).unlockWithPin('1234');
      lock(c).onLifecycle(AppLifecycleState.paused);
      now = now.add(const Duration(minutes: 4));
      lock(c).onLifecycle(AppLifecycleState.resumed);
      expect(locked(c), isFalse);
      lock(c).onLifecycle(AppLifecycleState.paused);
      now = now.add(const Duration(minutes: 6));
      lock(c).onLifecycle(AppLifecycleState.resumed);
      expect(locked(c), isTrue);
    });

    test('an external screen (file picker, share) does not lock', () async {
      final c = await start();
      await lock(c).unlockWithPin('1234');

      await lock(c).runExternal(() async {
        lock(c).onLifecycle(AppLifecycleState.hidden);
        lock(c).onLifecycle(AppLifecycleState.resumed);
      });
      expect(locked(c), isFalse);

      // Afterwards leaving the app locks as usual.
      lock(c).onLifecycle(AppLifecycleState.hidden);
      expect(locked(c), isTrue);
    });

    test('the fingerprint prompt itself does not lock the app', () async {
      final c = await start(biometricsOn: true);
      biometrics.duringPrompt = () async {
        // The prompt pauses the app on some phones.
        lock(c).onLifecycle(AppLifecycleState.paused);
        lock(c).onLifecycle(AppLifecycleState.resumed);
      };

      expect(await lock(c).unlockWithBiometrics(), isTrue);
      expect(locked(c), isFalse);
      expect(biometrics.prompts, 1);
    });

    test('biometrics: only when on, and a refusal leaves it locked', () async {
      var c = await start(biometricsOn: false);
      expect(await lock(c).unlockWithBiometrics(), isFalse);
      expect(biometrics.prompts, 0);

      c = await start(biometricsOn: true);
      biometrics.accept = false;
      expect(await lock(c).unlockWithBiometrics(), isFalse);
      expect(locked(c), isTrue);
    });

    test('a wrong PIN stays locked and reports the wait', () async {
      final c = await start();
      for (var i = 0; i < 4; i++) {
        await lock(c).unlockWithPin('0000');
      }
      expect(c.read(appLockProvider).lockedOutFor, isNull);

      await lock(c).unlockWithPin('0000');
      expect(locked(c), isTrue);
      expect(c.read(appLockProvider).lockedOutFor, const Duration(seconds: 30));

      final result = await lock(c).unlockWithPin('1234');
      expect(result, isA<PinLockedOut>());
      expect(locked(c), isTrue);
    });

    test('turning the lock off opens the app', () async {
      final c = await start();
      expect(locked(c), isTrue);
      await c
          .read(appSettingsProvider.notifier)
          .update((s) => s.copyWith(appLock: false));
      expect(locked(c), isFalse);
    });

    test(
      'a lock without a PIN is dropped rather than trapping the user',
      () async {
        final c = await start(withPin: false);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(locked(c), isFalse);
        expect(c.read(appSettingsProvider).appLock, isFalse);
      },
    );

    test('nothing happens when the lock is off', () async {
      final c = await start(enabled: false);
      lock(c).onLifecycle(AppLifecycleState.hidden);
      lock(c).lockNow();
      expect(locked(c), isFalse);
    });
  });

  group('lock screen', () {
    late MemorySecureStore secure;
    late MemoryPreferencesStore prefs;
    late FakeBiometrics biometrics;
    late FakeWindowSecurity window;

    Future<void> pumpApp(
      WidgetTester tester, {
      bool enabled = true,
      bool biometricsOn = false,
      String pin = '1234',
      DateTime Function()? clock,
    }) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      secure = MemorySecureStore();
      prefs = MemoryPreferencesStore();
      biometrics = FakeBiometrics();
      window = FakeWindowSecurity();
      final store = fastPinStore(secure, clock: clock);
      await store.setPin(pin);
      prefs.values[AppSettingsNotifier.storageKey] = jsonEncode(
        const AppSettings()
            .copyWith(appLock: enabled, lockBiometrics: biometricsOn)
            .toJson(),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            preferencesStoreProvider.overrideWithValue(prefs),
            secureStoreProvider.overrideWithValue(secure),
            pinStoreProvider.overrideWithValue(store),
            biometricAuthenticatorProvider.overrideWithValue(biometrics),
            windowSecurityProvider.overrideWithValue(window),
            vaultServiceProvider.overrideWithValue(
              VaultService(
                secureStore: secure,
                metadataStore: MemoryMetadataStore(),
              ),
            ),
          ],
          child: const SshApp(),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    Future<void> enter(WidgetTester tester, String digits) async {
      for (final digit in digits.split('')) {
        await tester.tap(find.byKey(ValueKey('pin-$digit')));
        await tester.pump();
      }
      await tester.pump();
      await tester.pump();
    }

    testWidgets('the app is covered and cannot be touched until unlocked', (
      tester,
    ) async {
      await pumpApp(tester);

      expect(find.byKey(const ValueKey('lock-screen')), findsOneWidget);
      expect(find.text('SSH is locked'), findsOneWidget);
      // Nothing underneath answers touches.
      final blocking = tester.widget<IgnorePointer>(
        find
            .ancestor(
              of: find.byType(Navigator),
              matching: find.byType(IgnorePointer),
            )
            .first,
      );
      expect(blocking.ignoring, isTrue);

      await enter(tester, '1234');
      expect(find.byKey(const ValueKey('lock-screen')), findsNothing);
      expect(find.text('No hosts yet'), findsOneWidget);
    });

    testWidgets('a wrong PIN clears the dots and says so', (tester) async {
      await pumpApp(tester);

      await enter(tester, '9999');
      expect(find.byKey(const ValueKey('lock-screen')), findsOneWidget);
      expect(find.text('Wrong PIN'), findsOneWidget);

      await enter(tester, '1234');
      expect(find.byKey(const ValueKey('lock-screen')), findsNothing);
    });

    testWidgets('after too many wrong tries the keys wait', (tester) async {
      await pumpApp(tester);
      for (var i = 0; i < 5; i++) {
        await enter(tester, '9999');
      }
      expect(find.textContaining('Too many tries. Wait'), findsOneWidget);

      // The right PIN is not accepted during the wait.
      await enter(tester, '1234');
      expect(find.byKey(const ValueKey('lock-screen')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('delete removes the last digit', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.byKey(const ValueKey('pin-1')));
      await tester.tap(find.byKey(const ValueKey('pin-2')));
      await tester.tap(find.byKey(const ValueKey('pin-back')));
      await tester.pump();
      await enter(tester, '234');
      // 1, 2, delete, then 2 3 4 spells 1234: delete took the 2 away.
      expect(find.byKey(const ValueKey('lock-screen')), findsNothing);
    });

    testWidgets(
      'with fingerprint on, the prompt shows by itself and has a button',
      (tester) async {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 2.625;
        addTearDown(tester.view.reset);
        secure = MemorySecureStore();
        prefs = MemoryPreferencesStore();
        biometrics = FakeBiometrics(accept: false);
        window = FakeWindowSecurity();
        final store = fastPinStore(secure);
        await store.setPin('1234');
        prefs.values[AppSettingsNotifier.storageKey] = jsonEncode(
          const AppSettings()
              .copyWith(appLock: true, lockBiometrics: true)
              .toJson(),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: <Override>[
              preferencesStoreProvider.overrideWithValue(prefs),
              secureStoreProvider.overrideWithValue(secure),
              pinStoreProvider.overrideWithValue(store),
              biometricAuthenticatorProvider.overrideWithValue(biometrics),
              windowSecurityProvider.overrideWithValue(window),
              vaultServiceProvider.overrideWithValue(
                VaultService(
                  secureStore: secure,
                  metadataStore: MemoryMetadataStore(),
                ),
              ),
            ],
            child: const SshApp(),
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(
          biometrics.prompts,
          1,
          reason: 'asked once when the lock appeared',
        );
        expect(find.byKey(const ValueKey('pin-biometric')), findsOneWidget);

        // Refused: still locked, the PIN works, and the button asks again.
        expect(find.byKey(const ValueKey('lock-screen')), findsOneWidget);
        biometrics.accept = true;
        await tester.tap(find.byKey(const ValueKey('pin-biometric')));
        await tester.pump();
        await tester.pump();
        expect(biometrics.prompts, 2);
        expect(find.byKey(const ValueKey('lock-screen')), findsNothing);
      },
    );

    testWidgets('no fingerprint key when it is off', (tester) async {
      await pumpApp(tester);
      expect(find.byKey(const ValueKey('pin-biometric')), findsNothing);
      expect(biometrics.prompts, 0);
    });

    testWidgets('lock off: no lock screen, window not secured', (tester) async {
      await pumpApp(tester, enabled: false);
      expect(find.byKey(const ValueKey('lock-screen')), findsNothing);
      expect(window.calls, [false]);
    });

    testWidgets('the window is secured while the lock is on', (tester) async {
      await pumpApp(tester);
      expect(window.calls.first, isTrue);
    });
  });

  group('settings', () {
    late MemorySecureStore secure;
    late MemoryPreferencesStore prefs;
    late FakeBiometrics biometrics;
    late FakeWindowSecurity window;

    Future<ProviderContainer> pumpSettings(
      WidgetTester tester, {
      bool enabled = false,
      bool biometricsAvailable = true,
    }) async {
      tester.view.physicalSize = const Size(1080, 3200);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      secure = MemorySecureStore();
      prefs = MemoryPreferencesStore();
      biometrics = FakeBiometrics(available: biometricsAvailable);
      window = FakeWindowSecurity();
      final store = fastPinStore(secure);
      if (enabled) {
        await store.setPin('1234');
        prefs.values[AppSettingsNotifier.storageKey] = jsonEncode(
          const AppSettings().copyWith(appLock: true).toJson(),
        );
      }
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            preferencesStoreProvider.overrideWithValue(prefs),
            secureStoreProvider.overrideWithValue(secure),
            pinStoreProvider.overrideWithValue(store),
            biometricAuthenticatorProvider.overrideWithValue(biometrics),
            windowSecurityProvider.overrideWithValue(window),
            vaultServiceProvider.overrideWithValue(
              VaultService(
                secureStore: secure,
                metadataStore: MemoryMetadataStore(),
              ),
            ),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SettingsScreen)),
      );
      // The app creates the lock at startup, before anything is turned on.
      container.read(appLockProvider);
      // Unlock if it started locked (the gate is not in this tree).
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('app-lock-switch')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets(
      'turning it on: PINs must match, then it is on with a hashed PIN',
      (tester) async {
        final container = await pumpSettings(tester);

        await tester.tap(find.byKey(const ValueKey('app-lock-switch')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('pin-new')), '2468');
        await tester.enterText(
          find.byKey(const ValueKey('pin-confirm')),
          '2469',
        );
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(find.text('The two PINs do not match.'), findsOneWidget);
        expect(container.read(appSettingsProvider).appLock, isFalse);

        await tester.enterText(find.byKey(const ValueKey('pin-new')), '12');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(find.text('Use at least 4 digits.'), findsOneWidget);

        await tester.enterText(find.byKey(const ValueKey('pin-new')), '2468');
        await tester.enterText(
          find.byKey(const ValueKey('pin-confirm')),
          '2468',
        );
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        // Biometrics are offered because the device has them.
        expect(find.text('Use fingerprint or face?'), findsOneWidget);
        await tester.tap(find.text('Not now'));
        await tester.pumpAndSettle();

        expect(container.read(appSettingsProvider).appLock, isTrue);
        expect(container.read(appSettingsProvider).lockBiometrics, isFalse);
        expect(secure.values[PinStore.storageKey], isNot(contains('2468')));
        expect(await fastPinStore(secure).verify('2468'), isA<PinCorrect>());
        // Turning it on does not lock the person who just did it.
        expect(container.read(appLockProvider).locked, isFalse);
      },
    );

    testWidgets('fingerprint is confirmed once before it is relied on', (
      tester,
    ) async {
      final container = await pumpSettings(tester);
      await tester.tap(find.byKey(const ValueKey('app-lock-switch')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('pin-new')), '2468');
      await tester.enterText(find.byKey(const ValueKey('pin-confirm')), '2468');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      biometrics.accept = false;
      await tester.tap(find.text('Use it'));
      await tester.pumpAndSettle();
      expect(biometrics.prompts, 1);
      expect(container.read(appSettingsProvider).lockBiometrics, isFalse);
      expect(
        find.text('Fingerprint or face was not confirmed.'),
        findsOneWidget,
      );

      biometrics.accept = true;
      await tester.tap(find.byKey(const ValueKey('app-lock-biometrics')));
      await tester.pumpAndSettle();
      expect(container.read(appSettingsProvider).lockBiometrics, isTrue);
    });

    testWidgets('no fingerprint option on a device without it', (tester) async {
      await pumpSettings(tester, enabled: true, biometricsAvailable: false);
      await tester.ensureVisible(
        find.byKey(const ValueKey('app-lock-biometrics')),
      );
      expect(find.text('Not set up on this device'), findsOneWidget);
    });

    testWidgets('turning it off needs the current PIN', (tester) async {
      final container = await pumpSettings(tester, enabled: true);
      container.read(appLockProvider.notifier);

      await tester.tap(find.byKey(const ValueKey('app-lock-switch')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('pin-current')), '0000');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(find.text('Wrong PIN'), findsOneWidget);
      expect(container.read(appSettingsProvider).appLock, isTrue);

      await tester.enterText(find.byKey(const ValueKey('pin-current')), '1234');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(container.read(appSettingsProvider).appLock, isFalse);
      expect(secure.values.containsKey(PinStore.storageKey), isFalse);
    });

    testWidgets('changing the PIN needs the old one', (tester) async {
      await pumpSettings(tester, enabled: true);
      await tester.ensureVisible(
        find.byKey(const ValueKey('app-lock-change-pin')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('app-lock-change-pin')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('pin-current')), '1234');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('pin-new')), '777777');
      await tester.enterText(
        find.byKey(const ValueKey('pin-confirm')),
        '777777',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('PIN changed.'), findsOneWidget);
      expect(await fastPinStore(secure).verify('1234'), isA<PinWrong>());
      expect(await fastPinStore(secure).verify('777777'), isA<PinCorrect>());
      expect(await fastPinStore(secure).length(), 6);
    });

    testWidgets('the lock time is chosen from three options', (tester) async {
      final container = await pumpSettings(tester, enabled: true);
      await tester.ensureVisible(
        find.byKey(const ValueKey('app-lock-timeout')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Immediately'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('app-lock-timeout')));
      await tester.pumpAndSettle();
      expect(find.text('After 1 minute'), findsOneWidget);
      expect(find.text('After 5 minutes'), findsOneWidget);
      await tester.tap(find.text('After 5 minutes'));
      await tester.pumpAndSettle();

      expect(
        container.read(appSettingsProvider).lockTimeout,
        LockTimeout.fiveMinutes,
      );
      expect(find.text('After 5 minutes'), findsOneWidget);
    });
  });

  test('the lock settings survive JSON and ignore junk', () {
    final settings = const AppSettings().copyWith(
      appLock: true,
      lockTimeout: LockTimeout.oneMinute,
      lockBiometrics: true,
    );
    final copy = AppSettings.fromJson(settings.toJson());
    expect(copy.appLock, isTrue);
    expect(copy.lockTimeout, LockTimeout.oneMinute);
    expect(copy.lockBiometrics, isTrue);

    final junk = AppSettings.fromJson({
      'lockTimeout': 'whenever',
      'appLock': 'yes',
    });
    expect(junk.appLock, isFalse);
    expect(junk.lockTimeout, LockTimeout.immediately);
    expect(const AppSettings().appLock, isFalse);
  });
}
