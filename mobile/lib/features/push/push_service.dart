import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../core/net/api.dart';

final _local = FlutterLocalNotificationsPlugin();

/// Every contact-facing notification vibrates in the same alarm rhythm, with the app
/// open or closed: SOS and duress, but also "Ada started sharing her location" - a
/// push Vic can miss silently while the phone is in a pocket. The channel plays at
/// the ALARM volume stream, so an emergency rings like an alarm clock would, even
/// when media volume is turned down.
final _alarmPattern = Int64List.fromList([0, 700, 300, 700, 300, 700, 300, 700]);

final _channel = AndroidNotificationChannel(
  'sentri_alerts',
  'Sentri alerts',
  description: 'Emergency alerts from people who chose you as a contact.',
  importance: Importance.max,
  enableVibration: true,
  vibrationPattern: _alarmPattern,
  playSound: true,
  audioAttributesUsage: AudioAttributesUsage.alarm,
);

/// Location-sharing updates are important but not an emergency, so they do not ring like one.
final _shareChannel = AndroidNotificationChannel(
  'sentri_shares',
  'Location sharing',
  description: 'When someone starts or stops sharing their location with you.',
  importance: Importance.high,
  enableVibration: true,
  vibrationPattern: _alarmPattern,
);

/// Health notes (heart-rate warnings, drink-water reminders): noticeable, but they never
/// ring like an emergency, because they are not one.
final _healthChannel = AndroidNotificationChannel(
  'sentri_health',
  'Health',
  description: 'Drink-water reminders and gentle heart-rate notes from your own Health tab.',
  importance: Importance.high,
  enableVibration: true,
);

/// One notification per alert: repeats of the same alert replace it (and ring again) instead of piling up.
int _idFor(Map<String, dynamic> data) => ((data['inboxId'] ?? data['sosId'] ?? data['text'] ?? '').toString().hashCode) & 0x7fffffff;

/// Fixed ids so each kind can cancel or replace exactly itself.
const _waterId = 7201;
const _healthNoteId = 7202;

/// The honest state of the drink-water reminder on this phone, as the app can verify it:
/// * [off] - the person has not chosen a pace (or chose "off").
/// * [ok] - the reminder really is scheduled and the phone allows notifications.
/// * [noPermission] - the phone blocks Sentri's notifications entirely.
/// * [notScheduled] - notifications are allowed but the recurring alarm could not
///   be placed on the phone's alarm system at all.
enum WaterStatus { off, ok, noPermission, notScheduled }

/// Checks what actually became of the reminder on this phone instead of assuming it
/// works: is the notification permission granted, and is at least one link of the
/// reminder's alarm CHAIN still among the phone's pending scheduled notifications.
/// The chain is a batch of independent one-shot alarms the app lays down itself (see
/// [scheduleWaterReminder]), so "still pending" means the phone really has the alarms.
Future<WaterStatus> waterReminderStatus(int minutes) async {
  if (minutes <= 0) return WaterStatus.off;
  try {
    final android = _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    var enabled = true;
    try {
      final a = await android?.areNotificationsEnabled();
      if (a == false) enabled = false;
    } catch (_) {}
    if (!enabled) return WaterStatus.noPermission;
    var scheduled = false;
    try {
      final pending = await _local.pendingNotificationRequests();
      scheduled = pending.any((p) => p.id >= _waterChainFirst && p.id <= _waterChainLast);
    } catch (_) {}
    if (!scheduled) return WaterStatus.notScheduled;
    return WaterStatus.ok;
  } catch (_) {
    // If even the check fails, say the reminder is not verified rather than pretend.
    return WaterStatus.notScheduled;
  }
}

/// The drink-water reminder, rebuilt as a CHAIN of independent one-shot alarms.
///
/// Why: the plugin's repeating schedule (`periodicallyShowWithDuration`) turned out to
/// be the one part of this feature that no code could make trustworthy - on several
/// phone brands it never fires at all, with every permission granted. So the app now
/// lays down its OWN chain: up to 48 separate one-shot alarms on the phone's alarm
/// system (alarm-clock mode, the one phone makers promise not to swallow), one per
/// interval. When one fires, the next one is already waiting. Every time the app
/// opens, the chain is topped back up - so a chain the phone partially purged is
/// refilled instead of dying. The pace and the reminder text (which carries the
/// language) live in every link's payload as a fingerprint; the pending list is read
/// back from the phone itself, so a chain with a different pace or language is torn
/// down and rebuilt, and a healthy chain is left strictly alone.
const _waterPayloadPrefix = 'water:';

/// The chain's fixed id range - 48 slots, far from the emergency and health-note ids.
const _waterChainFirst = 7300;
const _waterChainLast = 7347;
const _waterChainKeep = 24; // how many links are considered "enough" while topping up

bool _tzReady = false;

void _initTz() {
  if (_tzReady) return;
  tzdata.initializeTimeZones();
  _tzReady = true;
}

Future<void> scheduleWaterReminder(int minutes, String title, String body) async {
  const details = NotificationDetails(
    android: AndroidNotificationDetails(
      'sentri_health',
      'Health',
      channelDescription: 'Drink-water reminders and gentle heart-rate notes from your own Health tab.',
      importance: Importance.high,
      priority: Priority.high,
      channelShowBadge: true,
    ),
    iOS: DarwinNotificationDetails(interruptionLevel: InterruptionLevel.timeSensitive),
  );
  try {
    final fingerprint = minutes <= 0 ? null : '$_waterPayloadPrefix$minutes|$title|$body';
    // What is ACTUALLY pending on this phone right now - the durable truth, not
    // this session's memory of it.
    var pendingCount = 0;
    final pendingIds = <int>{};
    String? pendingPayload;
    try {
      final pending = await _local.pendingNotificationRequests();
      for (final p in pending) {
        final id = p.id;
        if (id >= _waterChainFirst && id <= _waterChainLast) {
          pendingCount++;
          pendingIds.add(id);
          pendingPayload ??= p.payload;
        }
      }
      if (pendingIds.isEmpty) {
        // A v36 install may still carry the old repeating schedule: find its payload too.
        for (final p in pending) {
          if (p.id == _waterId) {
            pendingPayload ??= p.payload;
            break;
          }
        }
      }
    } catch (_) {}
    if (minutes <= 0) {
      if (pendingCount > 0 || pendingPayload != null) {
        for (var id = _waterChainFirst; id <= _waterChainLast; id++) {
          await _local.cancel(id);
        }
        await _local.cancel(_waterId);
      }
      return;
    }
    final healthy = pendingPayload == fingerprint && pendingCount >= _waterChainKeep;
    if (healthy) {
      return; // the chain is stocked: leave its own clock running
    }
    final sameChain = pendingPayload == fingerprint && pendingCount > 0;
    if (!sameChain) {
      // Different pace or language (or a dead chain): tear the whole chain down first.
      for (var id = _waterChainFirst; id <= _waterChainLast; id++) {
        await _local.cancel(id);
      }
      await _local.cancel(_waterId);
    }
    final android = _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(_healthChannel);
    if (!sameChain) {
      await android?.requestNotificationsPermission();
      // Exact alarms are finer-grained than the alarm-clock schedule, but some phones
      // deny them by default; asking keeps the reminder exact where the phone allows
      // it. A refusal must never block the reminder, so this is best effort.
      try {
        await android?.requestExactAlarmsPermission();
      } catch (_) {}
      // Battery savers on common phone brands silently drop scheduled reminders - the
      // classic "it never rings at all" case. Ask to be always allowed to run in the
      // background.
      try {
        if (!await Permission.ignoreBatteryOptimizations.isGranted) {
          await Permission.ignoreBatteryOptimizations.request();
        }
      } catch (_) {
        // Only ask when the platform supports the question; a refusal must never block the reminder.
      }
    }
    _initTz();
    // How many links to lay down: a fresh chain lays the FULL batch (48 x the pace -
    // a full day at the 30-minute pace); a top-up refills back up to [keep].
    final want = sameChain ? _waterChainKeep : 48;
    var slots = [for (var id = _waterChainFirst; id <= _waterChainLast; id++) if (!pendingIds.contains(id)) id];
    final now = DateTime.now();
    var placed = 0;
    // Links walk forward in whole paces from now. A top-up starts at two paces out:
    // a link for the immediate next slot is almost certainly still pending, and two
    // reminders ten minutes apart is noise.
    var offset = sameChain ? 2 : 1;
    for (final id in slots) {
      if (placed >= want) break;
      final at = now.add(Duration(minutes: minutes * offset));
      offset++;
      placed++;
      try {
        await _local.zonedSchedule(
          id,
          title,
          body,
          tz.TZDateTime.from(at, tz.UTC),
          details,
          payload: fingerprint,
          androidScheduleMode: AndroidScheduleMode.alarmClock,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
        );
      } on PlatformException {
        // Some phones lock alarm-clock scheduling too: a gently inexact alarm still
        // keeps the habit - far better than a chain the phone refuses outright.
        try {
          await _local.zonedSchedule(
            id,
            title,
            body,
            tz.TZDateTime.from(at, tz.UTC),
            details,
            payload: fingerprint,
            androidScheduleMode: AndroidScheduleMode.inexact,
            uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
          );
        } catch (_) {}
      } catch (_) {}
    }
  } catch (_) {
    // A reminder that cannot be scheduled must never break the Health tab.
  }
}

/// A one-off health note (for example a heart-rate warning): same channel as the water
/// reminder, noticeable but calm, and it replaces the previous note instead of piling up.
Future<void> showHealthNote(String title, String body) async {
  try {
    final android = _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(_healthChannel);
    final android2 = await android?.areNotificationsEnabled() ?? true;
    if (android2 == false) return;
    await _local.show(
      _healthNoteId,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'sentri_health',
          'Health',
          channelDescription: 'Drink-water reminders and gentle heart-rate notes from your own Health tab.',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(interruptionLevel: InterruptionLevel.timeSensitive),
      ),
    );
  } catch (_) {
    // Nothing about health notes may break the app.
  }
}

/// Removes the ringing notification of an alert that has been answered or has ended.
Future<void> cancelAlertNotification(String inboxId) {
  _stopAlertRepeat();
  return _local.cancel(inboxId.hashCode & 0x7fffffff);
}

// ---- watches (v41) ----
// A paired Wear OS watch mirrors the phone's notifications automatically - that
// is Android, not an app feature. So the Watches screen has no pairing code of
// its own to get wrong: it explains this, and rings one harmless test ping so
// the person can watch it arrive on their wrist and know the pipe works.

/// A harmless test notification, sent from the Watches screen. Seeing it
/// mirror onto the paired watch proves the alert path reaches the wrist.
const _watchNoteId = 424242;

Future<void> showWatchTestNote(String title, String body) async {
  try {
    final android = _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(
      const AndroidNotificationDetails(
        'sentri_watch',
        'Watches',
        channelDescription: 'The test ping from the Watches screen, so you can see it arrive on your paired watch.',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      ),
    );
    final enabled = await android?.areNotificationsEnabled() ?? true;
    if (enabled == false) return;
    await _local.show(
      _watchNoteId,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'sentri_watch',
          'Watches',
          channelDescription: 'The test ping from the Watches screen, so you can see it arrive on your paired watch.',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
        iOS: DarwinNotificationDetails(interruptionLevel: InterruptionLevel.active),
      ),
    );
  } catch (_) {
    // A test ping must never break anything.
  }
}

// ---- an alert does not ring once and die: it nags until someone deals with it ----
// Some phone makers strip the system "insistent" flag, so the sound and vibration stop
// after one round. This app does not trust that: while an emergency alert is live and
// unanswered, the notification is re-issued on a timer, and every re-issue plays the
// alarm sound and the vibration again. Nothing here is dismissible in between.
//
// The nagging never gives up while the alert is live: the first hour it re-rings every
// 30 seconds; after that it keeps re-ringing every 3 minutes, indefinitely, until the
// alert is attended to (answered, or a "clear"/end arrives). The notification itself
// stays on the phone the whole time.

Timer? _alertRepeat;
int? _alertRepeatId;
int _alertRepeatCount = 0;
const _alertRepeatEvery = Duration(seconds: 30);
const _alertRepeatFast = 120; // the first hour: a ring every 30 seconds
const _alertRepeatSlow = Duration(minutes: 3); // after that: a ring every 3 minutes, forever

void _stopAlertRepeat() {
  _alertRepeat?.cancel();
  _alertRepeat = null;
  _alertRepeatId = null;
  _alertRepeatCount = 0;
}

void _beginAlertRepeat(int id, Map<String, dynamic> data, NotificationDetails details, {bool persistent = true}) {
  _stopAlertRepeat();
  _alertRepeatId = id;
  _alertRepeatCount = 0;
  _alertRepeat = Timer.periodic(_alertRepeatEvery, (_) async {
    if (_alertRepeatId != id) return; // a newer alert or an end took over
    _alertRepeatCount++;
    // Emergencies never give up: past the fast hour, one ring every 3 minutes,
    // forever, until somebody deals with the alert. A share start keeps the
    // old bound - it insisted for the first hour, then let the person be.
    if (_alertRepeatCount > _alertRepeatFast) {
      if (!persistent) return _stopAlertRepeat();
      if (_alertRepeatCount % 6 != 0) return; // 3-minute cadence on the same timer
    }
    try {
      await _local.show(id, 'Sentri', data['text'] as String?, details);
    } catch (_) {
      // A failed ring again must never crash the app; the next tick tries once more.
    }
  });
}

NotificationDetails _urgentDetails() {
  return NotificationDetails(
    android: AndroidNotificationDetails(
      _channel.id,
      _channel.name,
      channelDescription: _channel.description,
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.alarm,
      fullScreenIntent: true,
      enableVibration: true,
      vibrationPattern: _alarmPattern,
      visibility: NotificationVisibility.public,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      ongoing: true,
      autoCancel: false,
      // FLAG_INSISTENT (4): the system itself repeats sound and vibration between re-issues.
      additionalFlags: Int32List.fromList([4]),
    ),
    iOS: const DarwinNotificationDetails(interruptionLevel: InterruptionLevel.timeSensitive),
  );
}

/// Shows the alert. The server sends data-only pushes, so the app builds the notification.
///
/// Every contact notice vibrates in the alarm rhythm, whether the app is open or closed:
/// SOS, duress, "phone went quiet" - and also a location share starting. Live alerts keep
/// re-issueing themselves until someone deals with them (emergencies cannot be swiped
/// away; a starting share stays dismissible but keeps re-ringing); a share stopping or a
/// "clear" removes the ringing quietly.
Future<void> showAlertNotification(Map<String, dynamic> data) async {
  final kind = data['kind'];
  final text = data['text'];
  if (kind == 'clear' || kind == 'share_stop') {
    _stopAlertRepeat();
    await _local.cancel(_idFor(data));
    return;
  }
  if (text is! String || text.isEmpty) return;
  // A live emergency is urgent from the VERY FIRST ring: alarm category, full-screen
  // intent, alarm-volume sound and the insistent flag. (An earlier version showed the
  // first ring with the milder share details and only escalated 30 seconds later -
  // the most important seconds of the alert were also the quietest.)
  final urgent = kind == 'sos' || kind == 'duress' || kind == 'offline';
  final details = urgent ? _urgentDetails() : _shareStartDetails();
  final id = _idFor(data);
  try {
    await _local.show(id, 'Sentri', text, details);
  } catch (_) {
    // A failed notification must never crash the app.
    return;
  }
  if (urgent) {
    _beginAlertRepeat(id, data, _urgentDetails());
  } else if (kind == 'share_start') {
    // keep insisting until the person opens it or the share ends - one hour of
    // fast ringing, then the person is left in peace (it is not an emergency).
    _beginAlertRepeat(id, data, details, persistent: false);
  }
}

/// A share starting is the moment a push must interrupt: the person may need to open the
/// map, not just glance at a badge. It vibrates in the alarm rhythm and re-rings like a
/// live alert, but it stays on the location-sharing channel.
NotificationDetails _shareStartDetails() {
  return NotificationDetails(
    android: AndroidNotificationDetails(
      _shareChannel.id,
      _shareChannel.name,
      channelDescription: _shareChannel.description,
      importance: Importance.high,
      priority: Priority.high,
      enableVibration: true,
      vibrationPattern: _alarmPattern,
    ),
    iOS: const DarwinNotificationDetails(interruptionLevel: InterruptionLevel.timeSensitive),
  );
}

/// Runs when a push arrives while the app is closed. Must be a top-level function.
@pragma('vm:entry-point')
Future<void> sentriBackgroundPush(RemoteMessage m) async {
  await Firebase.initializeApp();
  await _local.initialize(const InitializationSettings(android: AndroidInitializationSettings('@drawable/ic_stat_sentri')));
  final android = _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  await android?.createNotificationChannel(_channel);
  await android?.createNotificationChannel(_shareChannel);
  await showAlertNotification(m.data);
}

/// Registers for push and keeps the server's copy of this phone's token current.
///
/// Push is optional. If the Firebase config files are missing, or the user says no, this logs and
/// does nothing. Contacts then see alerts only when they open the app.
class PushService {
  PushService(this._api, {this.onAlert});
  final SentriApi _api;

  /// Called when a push arrives while the app is open, so the message bar updates at once.
  final void Function()? onAlert;
  StreamSubscription<String>? _refresh;
  StreamSubscription<RemoteMessage>? _foreground;

  Future<void> start() async {
    try {
      await Firebase.initializeApp();
    } catch (e) {
      debugPrint('Push disabled: Firebase is not configured ($e)');
      return;
    }
    try {
      final fm = FirebaseMessaging.instance;
      await _local.initialize(const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_stat_sentri'),
        iOS: DarwinInitializationSettings(),
      ));
      await _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(_channel);
      await _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(_shareChannel);
      final perm = await fm.requestPermission(alert: true, badge: false, sound: true, criticalAlert: false);
      if (perm.authorizationStatus == AuthorizationStatus.denied) return;

      FirebaseMessaging.onBackgroundMessage(sentriBackgroundPush);
      _foreground = FirebaseMessaging.onMessage.listen((m) {
        unawaited(showAlertNotification(m.data));
        onAlert?.call();
      });
      FirebaseMessaging.onMessageOpenedApp.listen((_) => onAlert?.call());

      final token = await fm.getToken();
      if (token != null) await _send(token);
      _refresh = fm.onTokenRefresh.listen((t) => unawaited(_send(t)));
    } catch (e) {
      debugPrint('Push setup failed: $e');
    }
  }

  Future<void> _send(String token) async {
    try {
      await _api.savePushToken(token);
    } catch (_) {
      // Offline or signed out: the next start or token refresh tries again.
    }
  }

  void dispose() {
    _refresh?.cancel();
    _foreground?.cancel();
  }
}
