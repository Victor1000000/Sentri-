import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/crypto/device_keys.dart';
import '../../core/i18n/i18n.dart';
import '../../core/net/api.dart';
import '../../core/phone.dart';
import '../../core/platform/native_bridge.dart';
import '../../core/settings.dart';
import '../../core/storage/key_value_store.dart';
import '../sos/local_pin_vault.dart';
import '../sos/sos_controller.dart';

enum OnboardingStep { language, phone, otp, contacts, pins, permissions, done }

/// Drives sign-up: language -> phone -> code -> contacts -> PINs -> permissions.
/// Each step saves to the server AND to the phone (contacts and PINs are needed offline).
class OnboardingController extends ChangeNotifier {
  OnboardingController({
    required this.api,
    required this.i18n,
    required this.session,
    required this.keyStore,
    required this.vault,
    required this.contacts,
    required this.settings,
    required this.bridge,
    this.countryCode = '234',
    this.platform = 'android',
  });

  final SentriApi api;
  final I18n i18n;
  final Session session;
  final KeyValueStore keyStore;
  final LocalPinVault vault;
  final ContactStore contacts;
  final AppSettings settings;
  final NativeBridge bridge;
  final String countryCode;
  final String platform;

  OnboardingStep step = OnboardingStep.language;
  bool busy = false;

  /// i18n key of the error to show, or null.
  String? errorKey;
  String phone = '';

  /// Set only when the server is in dev echo mode: the code to type, so sign-up can be tried with no SMS.
  String? devCode;

  /// Earliest moment another code may be requested (30 s after the last one).
  DateTime resendAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Picks up where the user left off if they quit part-way.
  Future<void> resume() async {
    if (settings.onboarded) {
      step = OnboardingStep.done;
    } else if (session.signedIn) {
      if ((await contacts.load()).isEmpty) {
        step = OnboardingStep.contacts;
      } else if (!await vault.isSet) {
        step = OnboardingStep.pins;
      } else {
        step = OnboardingStep.permissions;
      }
    }
    notifyListeners();
  }

  void _go(OnboardingStep s) {
    step = s;
    errorKey = null;
    notifyListeners();
  }

  void back() {
    switch (step) {
      case OnboardingStep.phone:
        _go(OnboardingStep.language);
      case OnboardingStep.otp:
        _go(OnboardingStep.phone);
      default:
        break;
    }
  }

  Future<void> _run(Future<void> Function() body, {String failKey = 'common.error'}) async {
    busy = true;
    errorKey = null;
    notifyListeners();
    try {
      await body();
    } on ApiHttpError catch (e) {
      errorKey = e.status == 409 ? 'sos.contacts_busy' : (e.status == 429 ? 'otp.too_many' : failKey);
    } catch (_) {
      errorKey = 'common.error';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> chooseLanguage(String code) async {
    await i18n.setLanguage(code);
    await settings.update(language: code);
    _go(OnboardingStep.phone);
  }

  Future<void> submitPhone(String raw) async {
    final p = normalizePhone(raw, countryCode: countryCode);
    if (p == null) {
      errorKey = 'common.error';
      notifyListeners();
      return;
    }
    await _run(() async {
      devCode = await api.requestOtp(p);
      phone = p;
      resendAt = DateTime.now().add(const Duration(seconds: 30));
      _go(OnboardingStep.otp);
    }, failKey: 'otp.send_failed');
  }

  /// Asks for a fresh code for the same number. Allowed 30 seconds after the last one.
  Future<void> resendCode() async {
    if (DateTime.now().isBefore(resendAt)) return;
    await _run(() async {
      devCode = await api.requestOtp(phone);
      resendAt = DateTime.now().add(const Duration(seconds: 30));
    }, failKey: 'otp.send_failed');
  }

  Future<void> submitCode(String code) async {
    await _run(() async {
      final keys = await DeviceKeys.loadOrCreate(keyStore);
      try {
        await api.verifyOtp(
          phone: phone,
          code: code.trim(),
          platform: platform,
          publicKey: keys.publicKeyB64,
          boxPublicKey: keys.boxPublicKeyB64,
          locale: i18n.code,
        );
      } on ApiHttpError catch (e) {
        if (e.status == 401) {
          errorKey = 'otp.invalid';
          return;
        }
        rethrow;
      }
      await resumeAfterSignIn();
    });
  }

  /// A returning user who already finished setup on this account goes straight to the contacts step
  /// only if they have no contacts saved on this phone.
  Future<void> resumeAfterSignIn() async {
    _go(OnboardingStep.contacts);
  }

  /// Returns a problem key if the list is not acceptable.
  Future<void> submitContacts(List<String> raw, {List<String> locales = const []}) async {
    final r = validateContactNumbers(raw, ownPhone: phone, countryCode: countryCode);
    if (r.phones == null) {
      errorKey = r.problem == ContactsProblem.tooFewOrMany ? 'contacts.need_more' : 'contacts.invalid';
      notifyListeners();
      return;
    }
    await _run(() async {
      final list = [for (var i = 0; i < r.phones!.length; i++) (phone: r.phones![i], locale: i < locales.length ? locales[i] : 'en')];
      await api.saveContacts(list);
      await contacts.save([for (final c in list) LocalContact(phone: c.phone, locale: c.locale)]);
      _go(OnboardingStep.pins);
    });
  }

  /// One cancel PIN, typed twice. The server and the phone still expect a second "silent alert" PIN, so
  /// the app generates a random one nobody sees or knows. It can never be typed by accident, which
  /// leaves the duress path switched off in practice.
  Future<void> submitPins(String cancelPin, String confirmPin) async {
    if (!LocalPinVault.isValidFormat(cancelPin)) {
      errorKey = 'pins.format';
      notifyListeners();
      return;
    }
    if (cancelPin != confirmPin) {
      errorKey = 'pins.mismatch';
      notifyListeners();
      return;
    }
    final rnd = Random.secure();
    var unused = '';
    do {
      unused = List.generate(8, (_) => rnd.nextInt(10)).join();
    } while (unused == cancelPin);
    await _run(() async {
      await api.savePins(cancelPin: cancelPin, duressPin: unused);
      await vault.save(cancelPin, unused);
      _go(OnboardingStep.permissions);
    });
  }

  Future<void> finish() async {
    await settings.update(onboarded: true);
    await bridge.startProtection(settings.triggers);
    _go(OnboardingStep.done);
  }
}
