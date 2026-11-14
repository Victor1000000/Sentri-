import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/i18n/i18n.dart';
import '../../core/widgets/flat.dart';
import '../location/location.dart';

/// Travel (v42): the home screen's fourth circle. The app has read how the
/// person is travelling since v41 - the map chip and the alert detail say
/// "on foot", "on a train", "in flight" - but that reading had no home of its
/// own. This screen opens on the live answer, straight from this phone's GPS:
/// the same hysteresis [TravelWatcher] the share flow uses (a mode only flips
/// once three speed readings in a row agree), fed by the phone's position
/// stream while the screen is open.
///
/// Honest note, shown on screen too: nothing is being shared here. Travel
/// mode only rides along with an alert or a location share the person starts
/// on purpose; this screen is just the person's own window onto it.
class TravelScreen extends StatefulWidget {
  const TravelScreen({super.key, required this.location, required this.i18n});
  final LocationSource location;
  final I18n i18n;

  @override
  State<TravelScreen> createState() => _TravelScreenState();
}

class _TravelScreenState extends State<TravelScreen> {
  final TravelWatcher _travel = TravelWatcher();
  StreamSubscription<GeoFix>? _sub;
  GeoFix? _last;
  double? _lastSpeedMps; // metres per second, for the km/h line
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  Future<void> _start() async {
    try {
      _sub = widget.location.positions(distanceFilterM: 8).listen(_onFix, onError: (_) {
        if (mounted) setState(() => _failed = true);
      });
    } catch (_) {
      // Sources that cannot stream: the screen says so instead of guessing.
      if (mounted) setState(() => _failed = true);
    }
  }

  void _onFix(GeoFix f) {
    final prev = _last;
    _last = f;
    final mps = prev == null ? null : speedBetween(prev, f);
    if (mps != null) {
      _travel.feed(mps);
      if (mounted) setState(() => _lastSpeedMps = mps);
    } else if (mounted) {
      setState(() {});
    }
  }

  IconData _icon(TravelMode m) => switch (m) {
        TravelMode.walk => Icons.directions_walk,
        TravelMode.run => Icons.directions_run,
        TravelMode.ride => Icons.pedal_bike,
        TravelMode.drive => Icons.directions_car,
        TravelMode.train => Icons.train,
        TravelMode.flight => Icons.flight,
        TravelMode.still => Icons.my_location,
      };

  @override
  Widget build(BuildContext context) {
    final t = widget.i18n.t;
    final cs = Theme.of(context).colorScheme;
    final mode = _travel.mode;
    final kmh = _lastSpeedMps == null ? null : (_lastSpeedMps! * 3.6).round();
    return FlatPage(
      title: t('travel.title'),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: cs.primary.withValues(alpha: 0.1),
                  border: Border.all(color: cs.primary.withValues(alpha: 0.35), width: 1.5),
                ),
                child: Icon(_icon(mode), size: 40, color: cs.primary),
              ),
              const SizedBox(height: 14),
              Text(
                t('map.travel_${mode.name}'),
                style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800, letterSpacing: -0.3),
              ),
              const SizedBox(height: 4),
              Text(
                kmh == null
                    ? (_failed ? t('travel.stream_failed') : t('travel.waiting'))
                    : t('travel.speed', {'n': '$kmh'}),
                style: TextStyle(fontSize: 13.5, height: 1.35, color: cs.onSurface.withValues(alpha: 0.6)),
              ),
              const SizedBox(height: 16),
              // Every band the phone can honestly tell apart, as its own chip:
              // the live one is filled in, so the person can see where they sit.
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final m in TravelMode.values)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(99),
                        color: m == mode ? cs.primary.withValues(alpha: 0.14) : Colors.transparent,
                        border: Border.all(color: m == mode ? cs.primary : cs.onSurface.withValues(alpha: 0.16)),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(_icon(m), size: 15, color: m == mode ? cs.primary : cs.onSurface.withValues(alpha: 0.55)),
                        const SizedBox(width: 5),
                        Text(
                          t('map.travel_${m.name}'),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: m == mode ? FontWeight.w700 : FontWeight.w500,
                            color: m == mode ? cs.primary : cs.onSurface.withValues(alpha: 0.65),
                          ),
                        ),
                      ]),
                    ),
                ],
              ),
            ]),
          ),
        ),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.airplanemode_active, size: 18, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(child: Text(t('travel.title'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
              ]),
              const SizedBox(height: 8),
              Text(t('travel.note'), style: TextStyle(fontSize: 13, height: 1.45, color: cs.onSurface.withValues(alpha: 0.7))),
            ]),
          ),
        ),
      ],
    );
  }
}
