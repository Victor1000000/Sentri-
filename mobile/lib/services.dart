import 'dart:async';
import 'dart:io' show Platform;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:sensors_plus/sensors_plus.dart';

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
import 'features/inbox/inbox_controller.dart';
import 'features/location/location.dart';
import 'features/police/police_directory.dart';
import 'features/share/share_controller.dart';
import 'features/onboarding/onboarding_controller.dart';
import 'features/push/push_service.dart';
import 'features/sos/local_pin_vault.dart';
import 'features/sos/sos_controller.dart';
import 'features/triggers/shake_detector.dart';

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
    required this.settings,
    required this.sos,
    required this.lowBattery,
    required this.onboarding,
    required this.location,
    required this.inbox,
    required this.share,
  });

  final KeyValueStore store;
  final Session session;
  final SentriApi api;
  final I18n i18n;
  final NativeBridge bridge;
  final LocalPinVault vault;
  final ContactStore contacts;
  final AppSettings settings;
  final SosController sos;
  final LowBatteryAlerter lowBattery;
  final OnboardingController onboarding;
  final LocationSource location;
  final InboxController inbox;
  final ShareController share;

  /// The police directory, loaded once; the SOS screen and alert screens use it to show who to call.
  final Future<PoliceDirectory> police = rootBundle.loadString('assets/directory/police_directory.json').then(PoliceDirectory.parse);
  StreamSubscription<AccelerometerEvent>? _accel;
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

    final api = HttpSentriApi(baseUrl: AppConfig.safeApiBaseUrl, session: session);
    final bridge = MethodChannelBridge();
    final vault = LocalPinVault(store);
    final contacts = ContactStore(store);
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

    final lowBattery = LowBatteryAlerter(
      api: api,
      battery: battery,
      location: location,
      timers: timers,
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
    await onboarding.resume();

    final s = AppServices._(
      store: store,
      session: session,
      api: api,
      i18n: i18n,
      bridge: bridge,
      vault: vault,
      contacts: contacts,
      settings: settings,
      sos: sos,
      lowBattery: lowBattery,
      onboarding: onboarding,
      location: location,
      inbox: inbox,
      share: share,
    );
    await s._start();
    return s;
  }

  Future<void> _start() async {
    // OS-level triggers (Android: shake, volume, power, floating button, quick-settings tile;
    // iOS: App Intent / Shortcut) arrive here.
    // An alert that never reached the server (phone restarted, app killed) is sent first of all.
    unawaited(sos.resumePending());
    // The moment a connection returns, a waiting alert goes out instead of waiting for the next retry.
    _net = Connectivity().onConnectivityChanged.listen((r) {
      if (r.any((c) => c != ConnectivityResult.none)) {
        sos.networkRestored();
        unawaited(inbox.refresh());
      }
    });
    bridge.onTrigger((t) => unawaited(sos.trigger(t.name)));
    final pending = await bridge.takePendingTrigger();
    if (pending != null) unawaited(sos.trigger(pending.name));

    if (settings.onboarded) {
      await bridge.startProtection(settings.triggers);
      lowBattery.start();
      unawaited(_push.start());
      unawaited(inbox.refresh());
      unawaited(share.resume());
    }
    settings.addListener(() {
      if (settings.onboarded) {
        lowBattery.start();
        unawaited(_push.start());
      }
    });

    // iOS cannot watch sensors in the background, so shake works only while the app is open.
    if (Platform.isIOS) {
      final detector = ShakeDetector();
      _accel = accelerometerEventStream().listen((e) {
        if (settings.triggers.shake && settings.onboarded && detector.addSample(e.x, e.y, e.z, DateTime.now())) {
          unawaited(sos.trigger('shake'));
        }
      });
    }
  }

  Future<void> dispose() async {
    await _accel?.cancel();
    await _net?.cancel();
    lowBattery.stop();
    sos.dispose();
    share.dispose();
  }
}
