import 'dart:async';
import 'dart:io' show Platform;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/services.dart' show rootBundle;

import 'core/config.dart';
import 'core/i18n/i18n.dart';
import 'core/net/api.dart';
import 'core/platform/native_bridge.dart';
import 'core/settings.dart';
import 'core/theme.dart';
import 'core/storage/key_value_store.dart';
import 'core/timers.dart';
import 'features/battery/battery.dart';
import 'features/battery/low_battery_alerter.dart';
import 'features/checkin/checkin_controller.dart';
import 'features/health/health_controller.dart';
import 'features/inbox/inbox_controller.dart';
import 'features/location/location.dart';
import 'features/police/police_directory.dart';
import 'features/share/share_controller.dart';
import 'features/onboarding/onboarding_controller.dart';
import 'features/push/push_service.dart';
import 'features/sos/contact_people.dart';
import 'features/sos/local_pin_vault.dart';
import 'features/sos/sos_controller.dart';

/// Builds and wires everything once at start-up.
class AppServices {
  AppServices._({
    required this.store,
    required this.session,
    required this.api,
    required this.i18n,
    required this.bridge,
    required this.vault,
    required this.contacts,
    required this.people,
    required this.settings,
    required this.sos,
    required this.lowBattery,
    required this.health,
    required this.onboarding,
    required this.location,
    required this.inbox,
    required this.share,
    required this.checkin,
    required this.waking,
  });

  final KeyValueStore store;
  final Session session;
  final SentriApi api;
  final I18n i18n;
  final NativeBridge bridge;
  final LocalPinVault vault;
  final ContactStore contacts;

  /// Names and drawn guardian characters for the contacts (saved on this phone only).
  final ContactPeople people;
  final AppSettings settings;
  final SosController sos;
  final LowBatteryAlerter lowBattery;

  /// The Health tab's watch: heart-rate readings, drink-water reminders, nearby hospitals.
  final HealthController health;

  final OnboardingController onboarding;
  final LocationSource location;
  final InboxController inbox;
  final ShareController share;

  /// The "Check on me" watch: a timed safety check that raises a full alert when missed.
  final CheckInController checkin;

  /// True while the app waits for a sleeping server to wake up.
  final ValueListenable<bool> waking;

  /// The police directory, loaded once; the SOS screen and alert screens use it to show who to call.
  final Future<PoliceDirectory> police = rootBundle.loadString('assets/directory/police_directory.json').then(PoliceDirectory.parse);
  StreamSubscription<List<ConnectivityResult>>? _net;
  late final PushService _push = PushService(api, onAlert: () => unawaited(inbox.refresh()));

  static Future<AppServices> create() async {
    final store = SecureKeyValueStore();
    final session = Session(store);
    await session.load();
    final settings = AppSettings(store);
    await settings.load();
    ThemeChoice.mode.value = ThemeChoice.parse(settings.theme);
    ThemeChoice.persist = (n) => settings.update(theme: n);

    final i18n = I18n();
    await i18n.init(settings.language);

    final httpApi = HttpSentriApi(baseUrl: AppConfig.safeApiBaseUrl, session: session);
    final SentriApi api = httpApi;
    final bridge = MethodChannelBridge();
    final vault = LocalPinVault(store);
    final contacts = ContactStore(store);
    final people = ContactPeople(store);
    const timers = RealTimers();
    final location = GeolocatorSource();
    final battery = BatteryPlusSource();

    final sos = SosController(
      api: api,
      vault: vault,
      location: location,
      battery: battery,
      timers: timers,
      pending: store,
      dataSaver: () => settings.dataSaver,
    );

    final inbox = InboxController(
      api,
      onOver: cancelAlertNotification,
      onUrgent: (e) => showAlertNotification({'kind': e.kind, 'text': e.text, 'inboxId': e.id}),
    );
    final share = ShareController(api: api, location: location, battery: battery, timers: timers, store: store, dataSaver: () => settings.dataSaver);

    final checkin = CheckInController(sos: sos, timers: timers, store: store);

    final lowBattery = LowBatteryAlerter(
      api: api,
      battery: battery,
      location: location,
      timers: timers,
    );

    final health = HealthController(
      api: api,
      settings: settings,
      location: location,
      i18n: i18n,
    );

    final onboarding = OnboardingController(
      api: api,
      i18n: i18n,
      session: session,
      keyStore: store,
      vault: vault,
      contacts: contacts,
      settings: settings,
      bridge: bridge,
      countryCode: AppConfig.defaultCountryCode,
      platform: Platform.isIOS ? 'ios' : 'android',
    );
    // If the server says it no longer knows this phone, start sign-in again instead of failing quietly.
    httpApi.onSessionExpired = () => unawaited(onboarding.sessionExpired());
    await onboarding.resume();

    final s = AppServices._(
      store: store,
      session: session,
      api: api,
      i18n: i18n,
      bridge: bridge,
      vault: vault,
      contacts: contacts,
      people: people,
      settings: settings,
      sos: sos,
      lowBattery: lowBattery,
      health: health,
      onboarding: onboarding,
      location: location,
      inbox: inbox,
      share: share,
      checkin: checkin,
      waking: httpApi.waking,
    );
    // Start waking a sleeping server now, so it is ready by the time the person taps anything.
    unawaited(httpApi.prewarm());
    await s._start();
    return s;
  }

  Future<void> _start() async {
    // OS-level triggers (Android: shake, volume, power, floating button, quick-settings tile;
    // iOS: App Intent / Shortcut) arrive here.
    // An alert that never reached the server (phone restarted, app killed) is sent first of all.
    if (settings.onboarded) unawaited(sos.resumePending());
    // The moment a connection returns, a waiting alert goes out instead of waiting for the next retry.
    _net = Connectivity().onConnectivityChanged.listen((r) {
      if (r.any((c) => c != ConnectivityResult.none)) {
        sos.networkRestored();
        final a = api;
        if (a is HttpSentriApi) unawaited(a.prewarm());
        unawaited(inbox.refresh());
      }
    });
    bridge.onTrigger((t) => unawaited(sos.trigger(t.name)));
    final pending = await bridge.takePendingTrigger();
    if (pending != null) unawaited(sos.trigger(pending.name));
    // A "check on me" window armed before the app last closed re-arms (or fires if it just ended).
    if (settings.onboarded) unawaited(checkin.resume());

    // Protection is the app's whole purpose: the triggers stay armed even when the session has
    // slipped (for example after the server restarted), so help always works.
    await bridge.startProtection(settings.triggers);
    if (settings.onboarded) {
      lowBattery.start();
      health.start();
      unawaited(_push.start());
      unawaited(inbox.refresh());
      unawaited(share.resume());
    }
    settings.addListener(() {
      if (settings.onboarded) {
        lowBattery.start();
        health.start();
        unawaited(_push.start());
      }
    });

  }

  Future<void> dispose() async {
    await _net?.cancel();
    lowBattery.stop();
    health.dispose();
    checkin.dispose();
    sos.dispose();
    share.dispose();
  }
}
