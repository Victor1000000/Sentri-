import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/net/api.dart';

final _local = FlutterLocalNotificationsPlugin();

/// Every contact-facing notification vibrates in the same alarm rhythm, with the app
/// open or closed: SOS and duress, but also "Ada started sharing her location" - a
/// push Vic can miss silently while the phone is in a pocket.
final _alarmPattern = Int64List.fromList([0, 700, 300, 700, 300, 700, 300, 700]);

final _channel = AndroidNotificationChannel(
  'sentri_alerts',
  'Sentri alerts',
  description: 'Emergency alerts from people who chose you as a contact.',
  importance: Importance.max,
  enableVibration: true,
  vibrationPattern: _alarmPattern,
  playSound: true,
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
/// works: is the notification permission granted, and is the recurring alarm still
/// among the phone's pending scheduled notifications. The battery-exemption question
/// is asked when the pace is picked, but it does not report the reminder as broken:
/// the alarm-clock schedule the app uses is one phone makers promise not to swallow,
/// and re-arming on every open keeps a purged schedule alive anyway.
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
      // pendingNotificationRequests returns int ids; comparing with a string never matched.
      scheduled = pending.any((p) => p.id == _waterId);
    } catch (_) {}
    if (!scheduled) return WaterStatus.notScheduled;
    return WaterStatus.ok;
  } catch (_) {
    // If even the check fails, say the reminder is not verified rather than pretend.
    return WaterStatus.notScheduled;
  }
}

/// Repeats the drink-water reminder at the person's own pace. Cancels the previous one first
/// (including "off"), then asks for the notification permission once, right when the person
/// turns reminders on.
///
/// The quiet problem this fights: phones purge scheduled alarms (reboot, battery saving,
/// "auto-start" managers), so a reminder set weeks ago can die without anyone noticing. So
/// this asks the person to excuse Sentri from battery saving (the screen most phones hide
/// behind), and callers re-run it every time the app opens - but only when it must: if the
/// same pace is already on the phone's alarm system, re-arming would RESET its countdown,
/// so the reminder would go off shortly after every app open instead of on its own clock.
/// The schedule itself uses the alarm-clock mode, the one phone makers promise not to
/// swallow, instead of exact alarms many phones deny by default.
int? _waterScheduledMinutes;

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
    if (minutes > 0 && _waterScheduledMinutes == minutes) {
      var stillThere = false;
      try {
        final pending = await _local.pendingNotificationRequests();
        stillThere = pending.any((p) => p.id == _waterId);
      } catch (_) {}
      if (stillThere) return; // same pace, still scheduled: let its own clock run
    }
    await _local.cancel(_waterId);
    _waterScheduledMinutes = null;
    if (minutes <= 0) return;
    final android = _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(_healthChannel);
    await android?.requestNotificationsPermission();
    // Exact alarms are finer-grained than the alarm-clock schedule, but some phones deny
    // them by default; asking keeps the reminder exact where the phone allows it. A refusal
    // must never block the reminder, so this is best effort.
    try {
      await android?.requestExactAlarmsPermission();
    } catch (_) {}
    // Battery savers on common phone brands silently drop scheduled reminders - the classic
    // "it never rings at all" case. Ask to be always allowed to run in the background.
    try {
      if (!await Permission.ignoreBatteryOptimizations.isGranted) {
        await Permission.ignoreBatteryOptimizations.request();
      }
    } catch (_) {
      // Only ask when the platform supports the question; a refusal must never block the reminder.
    }
    try {
      await _local.periodicallyShowWithDuration(
        _waterId,
        title,
        body,
        Duration(minutes: minutes),
        details,
        androidScheduleMode: AndroidScheduleMode.alarmClock,
      );
      _waterScheduledMinutes = minutes;
    } on PlatformException {
      // Some phones lock alarm-clock scheduling too: a gently inexact chime still keeps the habit.
      await _local.periodicallyShowWithDuration(
        _waterId,
        title,
        body,
        Duration(minutes: minutes),
        details,
        androidScheduleMode: AndroidScheduleMode.inexact,
      );
      _waterScheduledMinutes = minutes;
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

// ---- an alert does not ring once and die: it nags until someone deals with it ----
// Some phone makers strip the system "insistent" flag, so the sound and vibration stop
// after one round. This app does not trust that: while an emergency alert is live and
// unanswered, the notification is re-issued on a timer, and every re-issue plays the
// alarm sound and the vibration again. Nothing here is dismissible in between.

Timer? _alertRepeat;
int? _alertRepeatId;
int _alertRepeatCount = 0;
const _alertRepeatEvery = Duration(seconds: 30);
const _alertRepeatMax = 120; // one hour of insisting, then the phone gets a break

void _stopAlertRepeat() {
  _alertRepeat?.cancel();
  _alertRepeat = null;
  _alertRepeatId = null;
  _alertRepeatCount = 0;
}

void _beginAlertRepeat(int id, Map<String, dynamic> data, NotificationDetails details) {
  _stopAlertRepeat();
  _alertRepeatId = id;
  _alertRepeatCount = 0;
  _alertRepeat = Timer.periodic(_alertRepeatEvery, (_) async {
    if (_alertRepeatId != id) return; // a newer alert or an end took over
    _alertRepeatCount++;
    if (_alertRepeatCount > _alertRepeatMax) return _stopAlertRepeat();
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
  final details = _shareStartDetails();
  final id = _idFor(data);
  try {
    await _local.show(id, 'Sentri', text, details);
  } catch (_) {
    // A failed notification must never crash the app.
    return;
  }
  if (kind == 'sos' || kind == 'duress' || kind == 'offline') {
    _beginAlertRepeat(id, data, _urgentDetails());
  } else if (kind == 'share_start') {
    // keep insisting until the person opens it or the share ends
    _beginAlertRepeat(id, data, details);
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
