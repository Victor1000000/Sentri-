import 'dart:async';
import 'dart:typed_data';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../core/net/api.dart';

final _local = FlutterLocalNotificationsPlugin();

const _channel = AndroidNotificationChannel(
  'sentri_alerts',
  'Sentri alerts',
  description: 'Emergency alerts from people who chose you as a contact.',
  importance: Importance.max,
  enableVibration: true,
  playSound: true,
);

/// Location-sharing updates are important but not an emergency, so they do not ring like one.
const _shareChannel = AndroidNotificationChannel(
  'sentri_shares',
  'Location sharing',
  description: 'When someone starts or stops sharing their location with you.',
  importance: Importance.high,
);

/// Health notes (heart-rate warnings, drink-water reminders): noticeable, but they never
/// ring like an emergency, because they are not one.
const _healthChannel = AndroidNotificationChannel(
  'sentri_health',
  'Health',
  description: 'Drink-water reminders and gentle heart-rate notes from your own Health tab.',
  importance: Importance.high,
);

final _alarmPattern = Int64List.fromList([0, 700, 300, 700, 300, 700, 300, 700]);

/// One notification per alert: repeats of the same alert replace it (and ring again) instead of piling up.
int _idFor(Map<String, dynamic> data) => ((data['inboxId'] ?? data['sosId'] ?? data['text'] ?? '').toString().hashCode) & 0x7fffffff;

/// Fixed ids so each kind can cancel or replace exactly itself.
const _waterId = 7201;
const _healthNoteId = 7202;

/// Repeats the drink-water reminder at the person's own pace. Cancels the previous one first
/// (including "off"), then asks for the notification permission once, right when the person
/// turns reminders on.
///
/// The quiet problem this fights: phones purge scheduled alarms (reboot, battery saving,
/// "auto-start" managers), so a reminder set weeks ago can die without anyone noticing. So
/// this asks for exact-alarm permission when the system offers it, and callers re-run it
/// every time the app opens - each fresh schedule outlives what the system dropped.
Future<void> scheduleWaterReminder(int minutes, String title, String body) async {
  const details = NotificationDetails(
    android: AndroidNotificationDetails(
      'sentri_health',
      'Health',
      channelDescription: 'Drink-water reminders and gentle heart-rate notes from your own Health tab.',
      importance: Importance.high,
      priority: Priority.high,
    ),
    iOS: DarwinNotificationDetails(interruptionLevel: InterruptionLevel.timeSensitive),
  );
  try {
    await _local.cancel(_waterId);
    if (minutes <= 0) return;
    final android = _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(_healthChannel);
    await android?.requestNotificationsPermission();
    // When the system allows exact alarms, use them - precise chimes at the chosen pace even
    // when the phone has been asleep. On phones that deny them, ask once (the system shows its
    // own page) and keep the alarm-clock mode, which still rings on time in practice.
    var exactAllowed = false;
    try {
      exactAllowed = await android?.canScheduleExactNotifications() ?? false;
      if (!exactAllowed) await android?.requestExactAlarmsPermission();
    } catch (_) {
      exactAllowed = false;
    }
    try {
      await _local.periodicallyShowWithDuration(
        _waterId,
        title,
        body,
        Duration(minutes: minutes),
        details,
        androidScheduleMode: exactAllowed ? AndroidScheduleMode.exactAllowWhileIdle : AndroidScheduleMode.alarmClock,
      );
    } on PlatformException {
      // Some phones lock exact alarms: a gently inexact chime still keeps the habit.
      await _local.periodicallyShowWithDuration(
        _waterId,
        title,
        body,
        Duration(minutes: minutes),
        details,
        androidScheduleMode: AndroidScheduleMode.inexact,
      );
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
Future<void> cancelAlertNotification(String inboxId) => _local.cancel(inboxId.hashCode & 0x7fffffff);

/// Shows the alert. The server sends data-only pushes, so the app builds the notification.
///
/// An emergency alert (SOS, duress, phone offline) keeps ringing and vibrating until someone deals with it:
/// the notification is "insistent" (Android repeats its sound and vibration) and cannot be swiped away. It is
/// removed when a contact taps "I'm responding", when the person cancels, or when the server says it is over.
Future<void> showAlertNotification(Map<String, dynamic> data) async {
  final kind = data['kind'];
  if (kind == 'clear') {
    await _local.cancel(_idFor(data));
    return;
  }
  final text = data['text'];
  if (text is! String || text.isEmpty) return;
  if (kind == 'share_start' || kind == 'share_stop') {
    await _local.show(
      _idFor(data),
      'Sentri',
      text,
      NotificationDetails(
        android: AndroidNotificationDetails(_shareChannel.id, _shareChannel.name, channelDescription: _shareChannel.description, importance: Importance.high, priority: Priority.high),
        iOS: const DarwinNotificationDetails(interruptionLevel: InterruptionLevel.timeSensitive),
      ),
    );
    return;
  }
  final urgent = kind == 'sos' || kind == 'duress' || kind == 'offline';
  await _local.show(
    _idFor(data),
    'Sentri',
    text,
    NotificationDetails(
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
        ongoing: urgent,
        autoCancel: !urgent,
        // FLAG_INSISTENT (4): keep repeating the sound and vibration until the notification is removed.
        additionalFlags: urgent ? Int32List.fromList([4]) : null,
      ),
      iOS: const DarwinNotificationDetails(interruptionLevel: InterruptionLevel.timeSensitive),
    ),
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
