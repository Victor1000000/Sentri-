import 'dart:async';

import 'package:flutter/material.dart';

import 'core/theme.dart';
import 'core/widgets/brand.dart';
import 'core/widgets/glass.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'features/home/home_screen.dart';
import 'features/location/place_lookup.dart';
import 'features/map/map_screen.dart';
import 'features/police/police_directory.dart';
import 'features/police/police_screen.dart';
import 'features/onboarding/onboarding_controller.dart';
import 'features/onboarding/onboarding_screens.dart';
import 'features/sos/sos_controller.dart';
import 'features/sos/sos_screen.dart';
import 'services.dart';

class SentriApp extends StatelessWidget {
  const SentriApp({super.key, required this.services});
  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeChoice.mode,
      builder: (context, mode, _) => MaterialApp(
      title: 'Sentri',
      debugShowCheckedModeBanner: false,
      // Flutter's own widgets only need a locale they support; app text comes from I18n,
      // which also covers Pidgin (not a Flutter-supported locale).
      locale: const Locale('en'),
      theme: sentriTheme(Brightness.light),
      darkTheme: sentriTheme(Brightness.dark),
      themeMode: mode,
      // Text a little smaller than the platform default. The person's own system font-size setting still applies.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear((MediaQuery.of(context).textScaler.scale(1) * 0.92).clamp(0.8, 1.6))),
        child: child!,
      ),
      home: _Root(services: services),
    ));
  }
}

class _Root extends StatefulWidget {
  const _Root({required this.services});
  final AppServices services;
  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  SosPhase _last = SosPhase.idle;
  bool _splash = true;

  @override
  void initState() {
    super.initState();
    widget.services.sos.addListener(_onSos);
    Future<void>.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _splash = false);
    });
  }

  @override
  void dispose() {
    widget.services.sos.removeListener(_onSos);
    super.dispose();
  }

  /// When an alert ends by PIN, say "Alert cancelled". A duress PIN lands here too, because the
  /// controller reports idle for it: the two are indistinguishable on screen by design.
  void _onSos() {
    final now = widget.services.sos.phase;
    final endedByPin = (_last == SosPhase.countdown || _last == SosPhase.active) && now == SosPhase.idle;
    _last = now;
    if (endedByPin && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(widget.services.i18n.t('sos.cancelled'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    if (_splash) return const SplashView();
    return Stack(
      children: [
        Positioned.fill(
          child: ListenableBuilder(
            listenable: Listenable.merge([s.sos, s.onboarding, s.settings, s.i18n]),
            builder: (context, _) {
              final onboarded = s.settings.onboarded && s.onboarding.step == OnboardingStep.done;
              if (!onboarded) {
                return OnboardingFlow(c: s.onboarding, i18n: s.i18n, bridge: s.bridge);
              }
              return Stack(
                children: [
                  _Tabs(services: s),
                  if (s.sos.phase != SosPhase.idle) Positioned.fill(child: SosScreen(sos: s.sos, i18n: s.i18n, police: s.police)),
                ],
              );
            },
          ),
        ),

      ],
    );
  }
}


/// Home, Map and Police. The map is built only while its tab is open, so it does not use GPS or
/// battery in the background.
class _Tabs extends StatefulWidget {
  const _Tabs({required this.services});
  final AppServices services;
  @override
  State<_Tabs> createState() => _TabsState();
}

class _TabsState extends State<_Tabs> {
  int _tab = 0;
  PoliceDirectory? _directory;
  Future<PoliceDirectory>? _directoryFuture;
  String? _state;

  @override
  void initState() {
    super.initState();
    // The same parsed directory backs the Police tab and aims the map's directions at the closest
    // command's post. Loading it once here keeps both users on one parse.
    _directoryFuture = rootBundle.loadString('assets/directory/police_directory.json').then((raw) => PoliceDirectory.parse(raw));
    unawaited(_directoryFuture!.then((d) {
      if (mounted) setState(() => _directory = d);
    }));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    final t = s.i18n.t;
    final body = switch (_tab) {
      1 => MapScreen(location: s.location, api: s.api, i18n: s.i18n, placeLookup: const DevicePlaceLookup(), onPlace: (p) => _state = p?.state, police: _directoryFuture),
      2 => PoliceScreen(directory: _directory, i18n: s.i18n, currentState: _state),
      _ => HomeScreen(sos: s.sos, settings: s.settings, i18n: s.i18n, bridge: s.bridge, api: s.api, inbox: s.inbox, share: s.share, police: s.police),
    };
    return Scaffold(
      body: body,
      bottomNavigationBar: Glass(
       radius: 0,
       blur: 24,
       child: NavigationBar(
        height: 68,
        indicatorColor: Brand.indigo,
        backgroundColor: Colors.transparent,
        elevation: 0,
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          NavigationDestination(icon: const Icon(Icons.home_outlined), selectedIcon: const Icon(Icons.home, color: Colors.white), label: t('tabs.home')),
          NavigationDestination(icon: const Icon(Icons.map_outlined), selectedIcon: const Icon(Icons.map, color: Colors.white), label: t('tabs.map')),
          NavigationDestination(icon: const Icon(Icons.local_police_outlined), selectedIcon: const Icon(Icons.local_police, color: Colors.white), label: t('tabs.police')),
        ],
      )),
    );
  }
}
