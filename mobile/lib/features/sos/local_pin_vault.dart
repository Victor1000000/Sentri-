import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import '../../core/storage/key_value_store.dart';

enum PinDecision { cancel, duress, wrong, locked }

/// Stores salted PBKDF2 verifiers for the cancel and duress PINs ON THE PHONE, so the 5-second
/// cancel window works with no data at all. The server keeps its own copy (peppered scrypt) and is
/// told the PIN too, so it can stop or flag the alert.
///
/// Both PINs are always checked, so timing does not reveal which one matched. Failed attempts are
/// counted in storage (not memory), so killing the app does not reset the lockout.
class LocalPinVault {
  LocalPinVault(
    this._store, {
    int iterations = 120000,
    this.maxAttempts = 5,
    this.lockout = const Duration(minutes: 5),
  }) : _pbkdf2 = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256);

  final KeyValueStore _store;
  final Pbkdf2 _pbkdf2;
  final int maxAttempts;
  final Duration lockout;

  static const _kPins = 'pin.v1';
  static const _kGuard = 'pin.guard.v1';
  static final _format = RegExp(r'^\d{4}$');

  static bool isValidFormat(String pin) => _format.hasMatch(pin);

  Future<bool> get isSet async => (await _store.read(_kPins)) != null;

  Future<List<int>> _derive(String pin, List<int> salt) async {
    final key = await _pbkdf2.deriveKeyFromPassword(password: pin, nonce: salt);
    return key.extractBytes();
  }

  Future<void> save(String cancelPin, String duressPin) async {
    if (!isValidFormat(cancelPin) || !isValidFormat(duressPin)) throw ArgumentError('PIN must be 4 digits');
    if (cancelPin == duressPin) throw ArgumentError('PINs must differ');
    final rnd = Random.secure();
    final saltC = List<int>.generate(16, (_) => rnd.nextInt(256));
    final saltD = List<int>.generate(16, (_) => rnd.nextInt(256));
    await _store.write(
      _kPins,
      jsonEncode({
        'cs': base64.encode(saltC),
        'ch': base64.encode(await _derive(cancelPin, saltC)),
        'ds': base64.encode(saltD),
        'dh': base64.encode(await _derive(duressPin, saltD)),
      }),
    );
    await _store.delete(_kGuard);
  }

  Future<PinDecision> evaluate(String pin, DateTime now) async {
    final guard = await _readGuard();
    if (guard.lockedUntil.isAfter(now)) return PinDecision.locked;

    final raw = await _store.read(_kPins);
    if (raw == null) return PinDecision.wrong;
    final j = jsonDecode(raw) as Map<String, dynamic>;

    // Derive against both salts even for malformed input, to keep timing uniform.
    final probe = isValidFormat(pin) ? pin : '00000000';
    final cancelHash = await _derive(probe, base64.decode(j['cs'] as String));
    final duressHash = await _derive(probe, base64.decode(j['ds'] as String));
    final isCancel = isValidFormat(pin) && _constEq(cancelHash, base64.decode(j['ch'] as String));
    final isDuress = isValidFormat(pin) && _constEq(duressHash, base64.decode(j['dh'] as String));

    if (isCancel || isDuress) {
      await _store.delete(_kGuard);
      return isCancel ? PinDecision.cancel : PinDecision.duress;
    }

    final fails = guard.fails + 1;
    if (fails >= maxAttempts) {
      await _writeGuard(0, now.add(lockout));
      return PinDecision.locked;
    }
    await _writeGuard(fails, DateTime.fromMillisecondsSinceEpoch(0));
    return PinDecision.wrong;
  }

  bool _constEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  Future<({int fails, DateTime lockedUntil})> _readGuard() async {
    final raw = await _store.read(_kGuard);
    if (raw == null) return (fails: 0, lockedUntil: DateTime.fromMillisecondsSinceEpoch(0));
    final j = jsonDecode(raw) as Map<String, dynamic>;
    return (fails: j['f'] as int, lockedUntil: DateTime.fromMillisecondsSinceEpoch(j['u'] as int));
  }

  Future<void> _writeGuard(int fails, DateTime lockedUntil) =>
      _store.write(_kGuard, jsonEncode({'f': fails, 'u': lockedUntil.millisecondsSinceEpoch}));
}
