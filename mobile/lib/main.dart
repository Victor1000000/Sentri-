import 'package:cryptography_flutter/cryptography_flutter.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Use the platform's native crypto (much faster PBKDF2 for the PIN check inside the cancel window).
  FlutterCryptography.enable();
  final services = await AppServices.create();
  runApp(SentriApp(services: services));
}
