import 'package:flutter/foundation.dart';

/// Build-time configuration. Nothing secret lives in the app.
///
///   flutter run --dart-define=API_BASE_URL=http://10.0.0.2:8080
///
/// 10.0.2.2 is the host machine as seen from the Android emulator.
class AppConfig {
  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: 'http://10.0.2.2:8080');
  /// The server address to use. A release build refuses anything that is not HTTPS, so a mistake in the build
  /// settings can never send phone numbers or locations over an open connection.
  static String get safeApiBaseUrl {
    if (kReleaseMode && !apiBaseUrl.startsWith('https://')) {
      throw StateError('API_BASE_URL must start with https:// in a release build');
    }
    return apiBaseUrl;
  }

  static const defaultCountryCode = String.fromEnvironment('DEFAULT_COUNTRY_CODE', defaultValue: '234');

  /// Map tiles. The public OSM server is for development only (its usage policy forbids heavy use);
  /// point this at your own tile server or a paid provider for release.
  static const tileUrl = String.fromEnvironment('TILE_URL', defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png');

  /// Cancel window shown to the user. Must match the server's CANCEL_WINDOW_MS.
  static const cancelWindow = Duration(seconds: 5);
}
