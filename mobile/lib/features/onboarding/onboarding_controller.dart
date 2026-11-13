import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/emergency.dart';
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
    Future<bool> Function(Uri url)? openLink,
  }) : openLink = openLink ?? _launchExternal;

  /// Opens a link in another app (Telegram, or the browser if Telegram is not installed).
  static Future<bool> _launchExternal(Uri url) => launchUrl(url, mode: LaunchMode.externalApplication);

  final SentriApi api;
  final I18n i18n;
  final Session session;
  final KeyValueStore keyStore;
  final LocalPinVault vault;
  final ContactStore contacts;
  final AppSettings settings;
  final NativeBridge bridge;

  /// The dial code local-format numbers belong to ('234' for 0803…). v40: not
  /// final - the first phone the person types tells us their country, and from
  /// then on their contacts normalize with THEIR dial code, not a hardcoded one.
  String countryCode;
  final String platform;

  /// How links are opened. Replaced in tests.
  final Future<bool> Function(Uri url) openLink;

  OnboardingStep step = OnboardingStep.language;
  bool busy = false;

  /// i18n key of the error to show, or null.
  String? errorKey;
  String phone = '';

  /// Set only when the server is in dev echo mode: the code to type, so sign-up can be tried with no SMS.
  String? devCode;

  /// Telegram mode: the link to the login bot. When set, the code comes from the bot, not from a text message.
  Uri? telegramUrl;

  /// Earliest moment another code may be requested (30 s after the last one).
  DateTime resendAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// True when the server refused the contacts save because an alert started earlier
  /// is still running on this account. The list is safe on this phone and a quiet
  /// retry keeps trying to sync it, so onboarding is never held hostage by the 409.
  bool contactsPendingServer = false;
  List<({String phone, String locale})>? _pendingContacts;
  Timer? _contactRetry;

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

  /// The server no longer knows this phone (for example after the server was reset). Protection cannot work until
  /// the person signs in again, so say so plainly and start sign-in at the phone number.
  Future<void> sessionExpired() async {
    await settings.update(onboarded: false);
    devCode = null;
    telegramUrl = null;
    _go(OnboardingStep.phone);
    errorKey = 'auth.session_ended';
    notifyListeners();
  }

  void back() {
    switch (step) {
      case OnboardingStep.phone:
        _go(OnboardingStep.language);
      case OnboardingStep.otp:
        devCode = null;
        telegramUrl = null;
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
      errorKey = 'phone.invalid';
      notifyListeners();
      return;
    }
    await _run(() async {
      final r = await api.requestOtp(p);
      devCode = r.devCode;
      telegramUrl = r.telegramUrl;
      phone = p;
      // v40, global: remember the dial code the person's own number starts with
      // ('+44…' → '44'), so contacts typed later in local format (0803…, 020…)
      // belong to THEIR country instead of a hardcoded Nigerian one.
      final dc = dialCodeFromE164(p);
      if (dc != null) countryCode = dc;
      // Remember it: if the server later forgets the session, the phone step starts filled in.
      await settings.update(lastPhone: p);
      resendAt = DateTime.now().add(const Duration(seconds: 30));
      _go(OnboardingStep.otp);
      // Show the code screen first, then hand over to Telegram. If Telegram cannot be opened the person is
      // still on the code screen, where the "Open Telegram" button tries again.
      await openTelegram();
    }, failKey: 'otp.send_failed');
  }

  /// Opens the login bot in Telegram. Does nothing outside Telegram mode and never throws.
  Future<void> openTelegram() async {
    final url = telegramUrl;
    if (url == null) return;
    try {
      await openLink(url);
    } catch (_) {
      // Telegram missing or the link blocked: the Open Telegram button lets the person try again.
    }
  }

  /// Asks for a fresh code for the same number. Allowed 30 seconds after the last one.
  Future<void> resendCode() async {
    if (DateTime.now().isBefore(resendAt)) return;
    await _run(() async {
      final r = await api.requestOtp(phone);
      devCode = r.devCode;
      telegramUrl = r.telegramUrl;
      resendAt = DateTime.now().add(const Duration(seconds: 30));
      await openTelegram();
    }, failKey: 'otp.send_failed');
  }

  Future<void> submitCode(String code) async {
    final c = code.trim();
    // The server checks this too. Stopping an obvious mistake here saves a round trip and says what is wrong.
    if (!RegExp(r'^\d{6}$').hasMatch(c)) {
      errorKey = 'otp.format';
      notifyListeners();
      return;
    }
    await _run(() async {
      final keys = await DeviceKeys.loadOrCreate(keyStore);
      try {
        await api.verifyOtp(
          phone: phone,
          code: c,
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
      try {
        await api.saveContacts(list);
      } on ApiHttpError catch (e) {
        if (e.status == 409) {
          // The server has an alert for this account that is still running (one started
          // before this install and never ended). It ends by itself, so: keep the list
          // safe on this phone, quietly retry the sync until the alert is over, tell the
          // person plainly, and let them continue - sign-up must not be bricked by it.
          await contacts.save([for (final c in list) LocalContact(phone: c.phone, locale: c.locale)]);
          _pendingContacts = list;
          contactsPendingServer = true;
          _startContactRetry();
          errorKey = 'sos.contacts_busy';
          return;
        }
        rethrow;
      }
      _pendingContacts = null;
      contactsPendingServer = false;
      _stopContactRetry();
      await contacts.save([for (final c in list) LocalContact(phone: c.phone, locale: c.locale)]);
      _go(OnboardingStep.pins);
    });
  }

  /// Continues past the blocked contacts step. The list is already saved on this
  /// phone and [_startContactRetry] keeps syncing it; the alert ends by itself.
  void continuePastBlockedContacts() {
    if (step != OnboardingStep.contacts) return;
    _go(OnboardingStep.pins);
  }

  /// Quietly re-tries the contacts sync once a minute while the app is open. The
  /// server only refuses while an alert is running, and alerts end on their own
  /// (they are capped by the repeat loop and swept if the backend restarted).
  /// Capped at 120 tries (~2 h), the longest a stuck alert can live server-side.
  void _startContactRetry() {
    _stopContactRetry();
    _contactTries = 0;
    _contactRetry = Timer.periodic(const Duration(seconds: 60), (_) => unawaited(_retryPendingContacts()));
    unawaited(_retryPendingContacts());
  }

  int _contactTries = 0;

  void _stopContactRetry() {
    _contactRetry?.cancel();
    _contactRetry = null;
  }

  Future<void> _retryPendingContacts() async {
    final list = _pendingContacts;
    if (list == null) {
      _stopContactRetry();
      return;
    }
    if (++_contactTries > 120) {
      _stopContactRetry();
      return;
    }
    try {
      await api.saveContacts(list);
      _pendingContacts = null;
      contactsPendingServer = false;
      _stopContactRetry();
      notifyListeners();
    } catch (_) {
      // The alert is still running, or the network is down. Try again next minute.
    }
  }

  @override
  void dispose() {
    _stopContactRetry();
    super.dispose();
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
      unused = List.generate(4, (_) => rnd.nextInt(10)).join();
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
