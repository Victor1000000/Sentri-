import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:http/http.dart' as http;

import '../storage/key_value_store.dart';
import 'models.dart';

export 'models.dart';

/// The server could not be reached (no data, timeout, DNS, TLS). The SOS logic treats this as
/// "data is down" and keeps the alert on the phone to retry; it is NOT the same as the server saying no.
class ApiUnreachable implements Exception {
  ApiUnreachable(this.cause);
  final Object cause;
  @override
  String toString() => 'ApiUnreachable($cause)';
}

/// The server answered with an error status.
class ApiHttpError implements Exception {
  ApiHttpError(this.status, this.code);
  final int status;
  final String code;
  @override
  String toString() => 'ApiHttpError($status, $code)';
}

class GeoFix {
  const GeoFix({required this.lat, required this.lon, this.accuracyM, required this.at});
  final double lat;
  final double lon;
  final double? accuracyM;
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'lat': lat,
        'lon': lon,
        if (accuracyM != null && accuracyM! > 0) 'accuracyM': accuracyM,
      };
}

class SosStartResult {
  const SosStartResult(this.sosId, this.state);
  final String sosId;
  final String state;
}

enum PinResult { cancelled, wrong, locked }

class SignInResult {
  const SignInResult({required this.userId, required this.isNew});
  final String userId;
  final bool isNew;
}

/// Everything the app needs from the backend. A fake implements this in tests.
/// A named place for a position. Every field may be missing.
class Place {
  const Place({this.street, this.area, this.lga, this.state, this.landmark, required this.label});
  final String? street;
  final String? area;
  final String? lga;
  final String? state;

  /// A named building or business close by, when the phone's place lookup knows one.
  final String? landmark;
  final String label;

  static Place? fromJson(Object? j) {
    if (j is! Map) return null;
    final label = j['label'];
    if (label is! String || label.isEmpty) return null;
    String? s(String k) => j[k] is String ? j[k] as String : null;
    return Place(street: s('street'), area: s('area'), lga: s('lga'), state: s('state'), label: label);
  }
}

/// One emergency contact as the owner sees it. [consent] is pending, accepted or declined.
class ContactStatus {
  const ContactStatus({this.id = '', required this.phone, required this.consent, this.reachable = false});
  final String id;
  final String phone;
  final String consent;

  /// This person has Sentri installed, so an alert can actually reach them.
  final bool reachable;

  static List<ContactStatus> listFromJson(Object? j) {
    if (j is! List) return const [];
    return [
      for (final c in j)
        if (c is Map && c['phone'] is String)
          ContactStatus(
            id: c['id'] is String ? c['id'] as String : '',
            reachable: c['reachable'] == true,
            phone: c['phone'] as String,
            consent: const {'pending', 'accepted', 'declined'}.contains(c['consent']) ? c['consent'] as String : 'pending',
          ),
    ];
  }
}

/// The server's answer to "send me a sign-up code".
class OtpRequest {
  const OtpRequest({this.devCode, this.telegramUrl});

  /// Only when the server runs in dev echo mode (mock SMS): the code itself, so sign-up can be tried without a text.
  final String? devCode;

  /// Telegram mode: the link that opens the login bot. The code then comes from the bot, not from a text message.
  final Uri? telegramUrl;
}

abstract class SentriApi {
  Future<OtpRequest> requestOtp(String phone);
  Future<SignInResult> verifyOtp({
    required String phone,
    required String code,
    required String platform,
    required String publicKey,
    required String boxPublicKey,
    required String locale,
  });
  Future<void> saveContacts(List<({String phone, String locale})> contacts);
  Future<void> savePins({required String cancelPin, required String duressPin});
  Future<void> saveProfile({String? locale, bool? dataSaver, String? name});
  Future<void> savePushToken(String token);

  /// The user's contacts and whether each accepted the invitation.
  Future<List<ContactStatus>> listContacts();

  Future<SosStartResult> startSos({required String trigger, GeoFix? geo});

  /// Returns the SOS state the server reports ('active', 'acknowledged', ...). Throws
  /// [ApiHttpError] with status 404 when the SOS is unknown or already ended.
  Future<String> sendLocation(String sosId, GeoFix geo);
  /// [sosId] null means "my current alert": used when the phone never received the id because the
  /// start request timed out (the server may still have received it).
  /// Throws [ApiHttpError] 404 when there is no live alert to apply it to.
  Future<PinResult> submitPin(String? sosId, String pin);
  Future<void> lowBattery(GeoFix? geo);

  /// Street, area, LGA and state for a position, or null when the server cannot say. Never required for an alert.
  Future<Place?> reverseGeocode(double lat, double lon);

  // ---- in-app inbox (alerts from people who chose you) ----
  Future<InboxList> inbox();
  Future<InboxDetail?> inboxItem(String id);

  /// "I'm responding". Returns ok | already_responding | ended.
  Future<String> respondToAlert(String id);
  Future<void> decideInvite(String contactId, {required bool accept});

  /// Throws [ApiHttpError] 429 when asked again within ten minutes.
  Future<TestAlertResult> sendTestAlert();

  // ---- live location sharing ----
  Future<ShareStartResult> startShare(List<String> contactIds, {GeoFix? geo, double? hours});

  /// Throws [ApiHttpError] 404 when the share has ended or expired.
  Future<void> updateShare(String id, GeoFix geo);
  Future<void> stopShare(String id);
  Future<DateTime> extendShare(String id, double hours);
  Future<List<ShareInfo>> activeShares();
}

/// Tokens, persisted in secure storage.
class Session {
  Session(this._store);
  final KeyValueStore _store;
  static const _k = 'session.v1';

  String? accessToken;
  String? refreshToken;
  String? deviceId;
  String? userId;

  bool get signedIn => refreshToken != null && deviceId != null;

  Future<void> load() async {
    final raw = await _store.read(_k);
    if (raw == null) return;
    final j = jsonDecode(raw) as Map<String, dynamic>;
    accessToken = j['a'] as String?;
    refreshToken = j['r'] as String?;
    deviceId = j['d'] as String?;
    userId = j['u'] as String?;
  }

  Future<void> save() => _store.write(_k, jsonEncode({'a': accessToken, 'r': refreshToken, 'd': deviceId, 'u': userId}));

  Future<void> clear() async {
    accessToken = refreshToken = deviceId = userId = null;
    await _store.delete(_k);
  }
}

/// How a token refresh ended. "Rejected" means the server said it does not know this session; "unavailable" means
/// it could not be asked (offline, or the server was busy), which says nothing about the session itself.
enum _Refreshed { ok, rejected, unavailable }

class HttpSentriApi implements SentriApi {
  HttpSentriApi({
    required this.baseUrl,
    required this.session,
    http.Client? client,
    this.timeout = const Duration(seconds: 8),
    this.patientTimeout = const Duration(seconds: 20),
    this.wakeBudget = const Duration(seconds: 70),
    this.wakeProbe = const Duration(seconds: 10),
    this.wakePause = const Duration(seconds: 3),
    this.onSessionExpired,
  }) : _http = client ?? http.Client();

  final String baseUrl;
  final Session session;
  final http.Client _http;

  /// Time allowed for an emergency request (an alert, a location update). Short, so the phone keeps the alert and retries.
  final Duration timeout;

  /// Time allowed for an ordinary request. Longer, because a server that has been idle can be slow to answer.
  final Duration patientTimeout;

  /// How long an ordinary request waits for a sleeping server to wake up before it gives up.
  final Duration wakeBudget;

  /// How long each "are you awake?" check may take, and how long to pause between checks.
  final Duration wakeProbe;
  final Duration wakePause;

  /// Called once when the server has said it no longer knows this phone's session (for example after a server reset).
  void Function()? onSessionExpired;

  /// True while the app is waiting for a sleeping server to wake up, so the screen can say so.
  final ValueNotifier<bool> waking = ValueNotifier<bool>(false);

  Future<http.Response> _once(String method, String path, Object? body, bool auth, [Duration? limit]) async {
    final t = limit ?? timeout;
    final req = http.Request(method, Uri.parse('$baseUrl$path'));
    req.headers['content-type'] = 'application/json';
    if (auth && session.accessToken != null) req.headers['authorization'] = 'Bearer ${session.accessToken}';
    if (body != null) req.body = jsonEncode(body);
    final streamed = await _http.send(req).timeout(t);
    return http.Response.fromStream(streamed).timeout(t);
  }

  /// [patient] false is for emergencies (an alert, a PIN, a location update): fail fast and let the phone keep the
  /// alert and retry. Everything else is patient: it waits longer, and if the server is asleep it waits for it to wake.
  Future<http.Response> _call(String method, String path, {Object? body, bool auth = true, bool patient = true}) async {
    try {
      return await _attempt(method, path, body, auth, patient);
    } on ApiUnreachable catch (e) {
      // No connection at all (offline, no DNS) is reported at once. Only a slow answer, or the hosting
      // platform's own "not ready" reply, means a sleeping server worth waiting for.
      final slow = e.cause is TimeoutException || e.cause is String;
      if (!patient || !slow) rethrow;
      if (!await _wake()) rethrow;
      return _attempt(method, path, body, auth, patient);
    }
  }

  Future<http.Response> _attempt(String method, String path, Object? body, bool auth, bool patient) async {
    final limit = patient ? patientTimeout : timeout;
    try {
      var res = await _once(method, path, body, auth, limit);
      if (res.statusCode == 401 && auth) {
        final r = await _refresh();
        if (r == _Refreshed.ok) {
          res = await _once(method, path, body, auth, limit);
        } else if (r == _Refreshed.rejected && patient) {
          unawaited(_expire());
        } else if (r == _Refreshed.unavailable && patient) {
          throw ApiUnreachable('could not check the session');
        }
      }
      if (patient && const {502, 503, 504}.contains(res.statusCode)) throw ApiUnreachable('server answered ${res.statusCode}');
      if (res.statusCode >= 400) throw ApiHttpError(res.statusCode, _errorCode(res));
      return res;
    } on TimeoutException catch (e) {
      throw ApiUnreachable(e);
    } on SocketException catch (e) {
      throw ApiUnreachable(e);
    } on http.ClientException catch (e) {
      throw ApiUnreachable(e);
    } on HandshakeException catch (e) {
      throw ApiUnreachable(e);
    }
  }

  /// The server said it does not know this session: forget it and let the app start sign-in again.
  Future<void> _expire() async {
    if (!session.signedIn) return;
    await session.clear();
    onSessionExpired?.call();
  }

  /// A server that has been idle can take up to a minute to start. Checks on it until it answers or [wakeBudget]
  /// runs out. One check at a time, however many requests are waiting.
  Future<bool>? _waking;
  Future<bool> _wake() => _waking ??= _doWake().whenComplete(() => _waking = null);

  Future<bool> _doWake() async {
    waking.value = true;
    try {
      final end = DateTime.now().add(wakeBudget);
      while (DateTime.now().isBefore(end)) {
        try {
          final streamed = await _http.send(http.Request('GET', Uri.parse('$baseUrl/healthz'))).timeout(wakeProbe);
          final res = await http.Response.fromStream(streamed).timeout(wakeProbe);
          if (res.statusCode == 200) return true;
        } on TimeoutException {
          // still starting up
        } on SocketException {
          return false; // the phone itself is offline
        } on HandshakeException {
          return false;
        } on http.ClientException {
          // the connection dropped while the server was starting: ask again
        }
        await Future<void>.delayed(wakePause);
      }
      return false;
    } finally {
      waking.value = false;
    }
  }

  /// Wakes the server in the background so the first real request does not have to wait. Never throws.
  Future<void> prewarm() async {
    try {
      await _wake();
    } catch (_) {
      // best effort
    }
  }

  String _errorCode(http.Response r) {
    try {
      return (jsonDecode(r.body) as Map<String, dynamic>)['error'] as String? ?? 'error';
    } catch (_) {
      return 'error';
    }
  }

  Map<String, dynamic> _json(http.Response r) => r.body.isEmpty ? {} : jsonDecode(r.body) as Map<String, dynamic>;

  /// Swaps the refresh token for a new pair. One refresh at a time.
  Future<_Refreshed>? _refreshing;
  Future<_Refreshed> _refresh() => _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);

  Future<_Refreshed> _doRefresh() async {
    if (!session.signedIn) return _Refreshed.rejected;
    try {
      final res = await _once('POST', '/v1/auth/refresh', {'deviceId': session.deviceId, 'refreshToken': session.refreshToken}, false);
      if (res.statusCode == 200) {
        final j = _json(res);
        session.accessToken = j['accessToken'] as String;
        session.refreshToken = j['refreshToken'] as String;
        await session.save();
        return _Refreshed.ok;
      }
      return const {400, 401, 403, 404}.contains(res.statusCode) ? _Refreshed.rejected : _Refreshed.unavailable;
    } on TimeoutException {
      return _Refreshed.unavailable;
    } on SocketException {
      return _Refreshed.unavailable;
    } on HandshakeException {
      return _Refreshed.unavailable;
    } on http.ClientException {
      return _Refreshed.unavailable;
    } catch (_) {
      return _Refreshed.unavailable; // an answer the app cannot read
    }
  }

  @override
  Future<Place?> reverseGeocode(double lat, double lon) async {
    try {
      final res = await _call('GET', '/v1/geo/reverse?lat=$lat&lon=$lon', patient: false);
      return Place.fromJson(_json(res)['place']);
    } on ApiHttpError {
      return null; // 404 when the server has no geocoder, 429 when asked too often
    }
  }

  @override
  Future<OtpRequest> requestOtp(String phone) async {
    final r = await _call('POST', '/v1/auth/otp/request', body: {'phone': phone}, auth: false);
    try {
      final j = jsonDecode(r.body);
      if (j is! Map) return const OtpRequest();
      return OtpRequest(devCode: j['devCode'] as String?, telegramUrl: _telegramLink(j['telegramUrl']));
    } catch (_) {
      return const OtpRequest();
    }
  }

  /// Accepts only a plain https link to t.me. Anything else the server sends is ignored, so a wrong or tampered
  /// answer can never make the app open some other address.
  static Uri? _telegramLink(Object? v) {
    if (v is! String) return null;
    final u = Uri.tryParse(v);
    if (u == null || u.scheme != 'https' || u.host != 't.me' || u.userInfo.isNotEmpty) return null;
    if (u.hasPort && u.port != 443) return null;
    return u;
  }

  @override
  Future<SignInResult> verifyOtp({
    required String phone,
    required String code,
    required String platform,
    required String publicKey,
    required String boxPublicKey,
    required String locale,
  }) async {
    final j = _json(await _call('POST', '/v1/auth/otp/verify', auth: false, body: {
      'phone': phone,
      'code': code,
      'platform': platform,
      'publicKey': publicKey,
      'boxPublicKey': boxPublicKey,
      'locale': locale,
    }));
    session
      ..accessToken = j['accessToken'] as String
      ..refreshToken = j['refreshToken'] as String
      ..deviceId = j['deviceId'] as String
      ..userId = j['userId'] as String;
    await session.save();
    return SignInResult(userId: session.userId!, isNew: j['isNew'] as bool? ?? false);
  }

  @override
  Future<void> saveContacts(List<({String phone, String locale})> contacts) async {
    await _call('PUT', '/v1/me/contacts', body: {
      'contacts': [for (final c in contacts) {'phone': c.phone, 'locale': c.locale}],
    });
  }

  @override
  Future<void> savePins({required String cancelPin, required String duressPin}) async {
    await _call('PUT', '/v1/me/pins', body: {'cancelPin': cancelPin, 'duressPin': duressPin});
  }

  @override
  Future<void> saveProfile({String? locale, bool? dataSaver, String? name}) async {
    await _call('PUT', '/v1/me/profile', body: {
      if (locale != null) 'locale': locale,
      if (dataSaver != null) 'dataSaver': dataSaver,
      if (name != null) 'name': name,
    });
  }

  @override
  Future<List<ContactStatus>> listContacts() async {
    final res = await _call('GET', '/v1/me/contacts');
    return ContactStatus.listFromJson(_json(res)['contacts']);
  }

  @override
  Future<void> savePushToken(String token) async {
    await _call('PUT', '/v1/me/push-token', body: {'token': token});
  }

  @override
  Future<SosStartResult> startSos({required String trigger, GeoFix? geo}) async {
    final j = _json(await _call('POST', '/v1/sos', body: {'trigger': trigger, ...?geo?.toJson()}, patient: false));
    return SosStartResult(j['sosId'] as String, j['state'] as String);
  }

  @override
  Future<String> sendLocation(String sosId, GeoFix geo) async {
    final j = _json(await _call('POST', '/v1/sos/$sosId/location', body: geo.toJson(), patient: false));
    return j['state'] as String? ?? 'active';
  }

  @override
  Future<PinResult> submitPin(String? sosId, String pin) async {
    final j = _json(await _call('POST', '/v1/sos/${sosId ?? 'current'}/pin', body: {'pin': pin}, patient: false));
    switch (j['result']) {
      case 'cancelled':
        return PinResult.cancelled;
      case 'locked':
        return PinResult.locked;
      default:
        return PinResult.wrong;
    }
  }

  @override
  Future<void> lowBattery(GeoFix? geo) async {
    await _call('POST', '/v1/alerts/low-battery', body: {...?geo?.toJson()}, patient: false);
  }

  // ---- inbox ----

  @override
  Future<InboxList> inbox() async => InboxList.fromJson(_json(await _call('GET', '/v1/inbox')));

  @override
  Future<InboxDetail?> inboxItem(String id) async {
    try {
      return InboxDetail.fromJson(_json(await _call('GET', '/v1/inbox/${Uri.encodeComponent(id)}', patient: false)));
    } on ApiHttpError catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  @override
  Future<String> respondToAlert(String id) async {
    final j = _json(await _call('POST', '/v1/inbox/${Uri.encodeComponent(id)}/respond', patient: false));
    return j['result'] as String? ?? 'ok';
  }

  @override
  Future<void> decideInvite(String contactId, {required bool accept}) async {
    await _call('POST', '/v1/invites/${Uri.encodeComponent(contactId)}', body: {'decision': accept ? 'accept' : 'decline'});
  }

  @override
  Future<TestAlertResult> sendTestAlert() async {
    final j = _json(await _call('POST', '/v1/test-alert'));
    int n(String k) => j[k] is num ? (j[k] as num).toInt() : 0;
    return TestAlertResult(sent: n('sent'), reachable: n('reachable'), total: n('total'));
  }

  // ---- location sharing ----

  @override
  Future<ShareStartResult> startShare(List<String> contactIds, {GeoFix? geo, double? hours}) async {
    final j = _json(await _call('POST', '/v1/shares', body: {
      'contactIds': contactIds,
      if (geo != null) 'geo': geo.toJson(),
      if (hours != null) 'hours': hours,
    }));
    return ShareStartResult(
      id: j['id'] as String,
      expiresAt: DateTime.fromMillisecondsSinceEpoch((j['expiresAt'] as num).toInt()),
      reached: (j['reached'] as num?)?.toInt() ?? 0,
      unreachable: [for (final c in (j['unreachable'] as List? ?? const [])) if (c is String) c],
    );
  }

  @override
  Future<void> updateShare(String id, GeoFix geo) async {
    await _call('PUT', '/v1/shares/${Uri.encodeComponent(id)}/location', body: geo.toJson(), patient: false);
  }

  @override
  Future<void> stopShare(String id) async {
    await _call('DELETE', '/v1/shares/${Uri.encodeComponent(id)}');
  }

  @override
  Future<DateTime> extendShare(String id, double hours) async {
    final j = _json(await _call('POST', '/v1/shares/${Uri.encodeComponent(id)}/extend', body: {'hours': hours}));
    return DateTime.fromMillisecondsSinceEpoch((j['expiresAt'] as num).toInt());
  }

  @override
  Future<List<ShareInfo>> activeShares() async {
    final j = _json(await _call('GET', '/v1/shares'));
    return [for (final s in (j['shares'] as List? ?? const [])) if (s is Map<String, dynamic>) ShareInfo.fromJson(s)];
  }
}
