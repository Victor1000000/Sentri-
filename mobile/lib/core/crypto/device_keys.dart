import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../storage/key_value_store.dart';

/// Per-device identity keys, generated once on the phone. Private keys never leave it.
///
/// Ed25519 identifies the device; X25519 is what contacts' apps will encrypt-to / the phone will
/// seal alerts with when end-to-end encrypted payloads are switched on (next step). Registering the
/// public halves at sign-up now means that step needs no re-enrolment.
class DeviceKeys {
  DeviceKeys({required this.publicKeyB64, required this.boxPublicKeyB64});
  final String publicKeyB64;
  final String boxPublicKeyB64;

  static const _kSign = 'keys.sign.v1';
  static const _kBox = 'keys.box.v1';

  static Future<DeviceKeys> loadOrCreate(KeyValueStore store) async {
    final sign = await _publicKey(store, _kSign, () => Ed25519().newKeyPair());
    final box = await _publicKey(store, _kBox, () => X25519().newKeyPair());
    return DeviceKeys(publicKeyB64: sign, boxPublicKeyB64: box);
  }

  static Future<String> _publicKey(
    KeyValueStore store,
    String key,
    Future<SimpleKeyPair> Function() generate,
  ) async {
    final saved = await store.read(key);
    if (saved != null) {
      return (jsonDecode(saved) as Map<String, dynamic>)['pub'] as String;
    }
    final pair = await generate();
    final data = await pair.extract();
    final priv = base64.encode(await data.extractPrivateKeyBytes());
    final pub = base64.encode((await pair.extractPublicKey()).bytes);
    await store.write(key, jsonEncode({'priv': priv, 'pub': pub}));
    return pub;
  }
}
