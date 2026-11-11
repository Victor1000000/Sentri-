import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'core/theme.dart';
import 'core/widgets/brand.dart'; // SplashView lives here
import 'core/widgets/flat.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'features/home/home_screen.dart';
import 'features/location/place_lookup.dart';
import 'features/map/map_screen.dart';
import 'features/police/police_directory.dart';
import 'features/police/police_screen.dart';
import 'features/health/health_screen.dart';
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


/// Home, Map, Health and Police. The pages stay built inside an IndexedStack, so directions, pins and
/// route voice plans survive a switch to Home and back.
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

  /// The live Map tab's state, so the Health tab can ask it to plan a route to a
  /// nearby hospital or gym with one tap - the map is already built and warm.
  final GlobalKey<MapScreenState> _mapKey = GlobalKey<MapScreenState>();

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
    // All tabs stay built inside an IndexedStack, so switching to Home and back no longer
    // tears down the Map tab: an active route, its pin and its voice plan survive the switch.
    final body = IndexedStack(
      index: _tab,
      children: [
        HomeScreen(sos: s.sos, settings: s.settings, i18n: s.i18n, bridge: s.bridge, api: s.api, inbox: s.inbox, share: s.share, checkin: s.checkin, police: s.police, people: s.people, profile: s.profile),
        MapScreen(key: _mapKey, location: s.location, api: s.api, i18n: s.i18n, placeLookup: const DevicePlaceLookup(), onPlace: (p) => _state = p?.state, police: _directoryFuture),
        HealthScreen(
          health: s.health,
          i18n: s.i18n,
          exercise: s.exercise,
          awards: s.awards,
          checkin: s.checkin,
          onRoute: (place) {
            // Tap a hospital or gym in the Health tab: the map plans the route to it
            // and the app switches to the Map tab, which is already warm.
            _mapKey.currentState?.routeTo(LatLng(place.lat, place.lon), place.name);
            setState(() => _tab = 1);
          },
        ),
        PoliceScreen(directory: _directory, i18n: s.i18n, currentState: _state),
      ],
    );
    return Scaffold(
      body: body,
      bottomNavigationBar: _PillNav(
        labels: [t('tabs.home'), t('tabs.map'), t('tabs.health'), t('tabs.police')],
        icons: const [Icons.home_outlined, Icons.map_outlined, Icons.monitor_heart_outlined, Icons.local_police_outlined],
        selected: const [Icons.home, Icons.map, Icons.monitor_heart, Icons.local_police],
        index: _tab,
        onTap: (i) => setState(() => _tab = i),
      ),
    );
  }
}

/// The floating flat pill tab bar: one solid rounded panel, the chosen tab filled with
/// the mode's ink chip (near-black on light, white on dark). No translucency, no blur,
/// no heavy NavigationBar block.
class _PillNav extends StatelessWidget {
  const _PillNav({required this.labels, required this.icons, required this.selected, required this.index, required this.onTap});
  final List<String> labels;
  final List<IconData> icons;
  final List<IconData> selected;
  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bar = dark ? const Color(0xFF17181D) : Colors.white;
    final chip = dark ? Colors.white : SentriColors.inkDark;
    final chipInk = dark ? SentriColors.inkDark : Colors.white;
    final idle = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.62);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 10),
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: bar,
            borderRadius: BorderRadius.circular(999),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.4 : 0.08), blurRadius: 16, offset: const Offset(0, 6))],
          ),
          child: Row(
            children: [
              for (var i = 0; i < labels.length; i++)
                Expanded(
                  // The excited tap from the reference reel: the chosen icon
                  // hops and wiggles happily, then settles into its chip.
                  child: TapBounce(
                    onTap: () => onTap(i),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: i == index ? chip : Colors.transparent,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(i == index ? selected[i] : icons[i], size: 21, color: i == index ? chipInk : idle),
                        const SizedBox(height: 2),
                        Text(labels[i], maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10.5, fontWeight: i == index ? FontWeight.w700 : FontWeight.w500, color: i == index ? chipInk : idle)),
                      ]),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
