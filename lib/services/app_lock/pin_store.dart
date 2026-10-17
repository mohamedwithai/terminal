import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:ssh_app/services/secure_store.dart';

/// How a PIN check ended.
sealed class PinResult {
  const PinResult();
}

class PinCorrect extends PinResult {
  const PinCorrect();
}

class PinWrong extends PinResult {
  const PinWrong({required this.failures, this.lockedFor});

  /// Wrong attempts in a row.
  final int failures;

  /// How long to wait before the next try, once too many were wrong.
  final Duration? lockedFor;
}

/// Too many wrong tries: not checked at all until [remaining] has passed.
class PinLockedOut extends PinResult {
  const PinLockedOut(this.remaining);

  final Duration remaining;
}

/// Why a PIN was refused before saving.
String? pinProblem(String pin) {
  if (!RegExp(r'^\d+$').hasMatch(pin)) return 'Use digits only.';
  if (pin.length < 4) return 'Use at least 4 digits.';
  if (pin.length > 12) return 'Use at most 12 digits.';
  return null;
}

/// PBKDF2-HMAC-SHA256 of [pin]. Top level so [compute] can run it.
Uint8List derivePinHash((String, Uint8List, int) args) {
  final derivator = pc.PBKDF2KeyDerivator(pc.HMac(pc.SHA256Digest(), 64))
    ..init(pc.Pbkdf2Parameters(args.$2, args.$3, 32));
  return derivator.process(Uint8List.fromList(utf8.encode(args.$1)));
}

/// The app lock PIN, kept as a salted hash in secure storage, never as the
/// PIN itself. Wrong tries are counted there too, so restarting the app
/// does not reset the wait.
class PinStore {
  PinStore(
    this._secure, {
    Random? random,
    DateTime Function()? clock,
    this.iterations = 100000,
    this.freeTries = 5,
    this.baseLockout = const Duration(seconds: 30),
    this.maxLockout = const Duration(minutes: 15),
    this.hashInBackground = true,
  }) : _random = random ?? Random.secure(),
       _clock = clock ?? DateTime.now;

  static const storageKey = 'app_lock_pin';

  final SecureStore _secure;
  final Random _random;
  final DateTime Function() _clock;

  /// PBKDF2 rounds. Tests use few.
  final int iterations;

  /// Wrong tries allowed before the waiting starts.
  final int freeTries;

  /// The first wait; it doubles with each further wrong try.
  final Duration baseLockout;
  final Duration maxLockout;

  /// Run the hash in an isolate. Tests turn this off.
  final bool hashInBackground;

  Future<Uint8List> _hash(String pin, Uint8List salt, int rounds) {
    final args = (pin, salt, rounds);
    return hashInBackground
        ? compute(derivePinHash, args)
        : Future.value(derivePinHash(args));
  }

  Future<Map<String, dynamic>?> _read() async {
    final raw = await _secure.read(storageKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } on FormatException {
      return null;
    }
  }

  Future<bool> hasPin() async => (await _read())?['hash'] is String;

  /// How many digits the PIN has, so the lock screen can submit by itself.
  Future<int?> length() async {
    final value = (await _read())?['length'];
    return value is int ? value : null;
  }

  /// Saves [pin], replacing any other. Throws [ArgumentError] if it is not
  /// a valid PIN.
  Future<void> setPin(String pin) async {
    final problem = pinProblem(pin);
    if (problem != null) throw ArgumentError(problem);
    final salt = Uint8List.fromList(
      List.generate(16, (_) => _random.nextInt(256)),
    );
    final hash = await _hash(pin, salt, iterations);
    await _secure.write(
      storageKey,
      jsonEncode({
        'salt': base64.encode(salt),
        'hash': base64.encode(hash),
        'iterations': iterations,
        'length': pin.length,
        'failures': 0,
        'lockedUntil': 0,
      }),
    );
  }

  /// How much longer the PIN cannot be tried, if at all.
  Future<Duration?> lockoutRemaining() async {
    final until = (await _read())?['lockedUntil'];
    if (until is! int) return null;
    final left = DateTime.fromMillisecondsSinceEpoch(
      until,
      isUtc: true,
    ).difference(_clock().toUtc());
    return left > Duration.zero ? left : null;
  }

  Future<PinResult> verify(String pin) async {
    final record = await _read();
    if (record == null || record['hash'] is! String) {
      return const PinWrong(failures: 0);
    }
    final left = await lockoutRemaining();
    if (left != null) return PinLockedOut(left);

    final salt = base64.decode(record['salt'] as String);
    final rounds = record['iterations'] as int;
    final expected = base64.decode(record['hash'] as String);
    final actual = await _hash(pin, Uint8List.fromList(salt), rounds);
    if (_sameBytes(actual, expected)) {
      record
        ..['failures'] = 0
        ..['lockedUntil'] = 0;
      await _secure.write(storageKey, jsonEncode(record));
      return const PinCorrect();
    }

    final failures = ((record['failures'] as int?) ?? 0) + 1;
    Duration? wait;
    if (failures >= freeTries) {
      final doublings = failures - freeTries;
      final millis = baseLockout.inMilliseconds * pow(2, min(doublings, 20));
      wait = Duration(
        milliseconds: min(millis.toInt(), maxLockout.inMilliseconds),
      );
    }
    record['failures'] = failures;
    record['lockedUntil'] = wait == null
        ? 0
        : _clock().toUtc().add(wait).millisecondsSinceEpoch;
    await _secure.write(storageKey, jsonEncode(record));
    return PinWrong(failures: failures, lockedFor: wait);
  }

  Future<void> clear() => _secure.delete(storageKey);

  /// Compares without stopping at the first difference.
  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
