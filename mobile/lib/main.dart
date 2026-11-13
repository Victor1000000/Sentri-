import 'package:cryptography_flutter/cryptography_flutter.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'core/fonts.dart';
import 'core/poppins.dart';
import 'services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Use the platform's native crypto (much faster PBKDF2 for the PIN check inside the cancel window).
  FlutterCryptography.enable();
  // Register the bundled Inter faces before the first frame, so even the splash paints with
  // the brand font, offline, on the very first launch.
  await BrandFonts.ensure();
  // v40: Poppins is the app's typeface everywhere now. Registered the same way - bundled
  // base64 faces loaded into the engine before the first frame, so nothing is fetched.
  await BrandPoppins.ensure();
  final services = await AppServices.create();
  runApp(SentriApp(services: services));
}
