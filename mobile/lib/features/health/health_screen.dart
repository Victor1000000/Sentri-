import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:camera/camera.dart' show CameraController, CameraPreview;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config.dart';
import '../../core/i18n/i18n.dart';
import '../../core/settings.dart' show AppSettings, HeartTake;
import '../../core/widgets/flat.dart';
import '../checkin/checkin_controller.dart';
import '../push/push_service.dart';
import '../photos/photo_gym.dart';
import '../photos/photo_health.dart';
import '../photos/photo_bike.dart';
import '../photos/photo_run.dart';
import '../photos/photo_walk.dart';
import '../photos/photo_water.dart';
import 'awards.dart';
import 'exercise_controller.dart';
import 'health_controller.dart';
import 'route_builder.dart';
import 'workout_screen.dart';
import '../map/map_screen.dart' show sentriBaseLayers;

/// The Health tab: heart-rate readings taken by the app itself - fingertip over the
/// front camera, lit by the screen - drink-water reminders at the person's own pace
/// (with an honest status of what the phone actually allows), the exercise section -
/// walk/run/bike with live steps, distance, history and award badges - and hospitals
/// AND gyms/stadiums near them: nearest first, numbers where they exist, and a tap
/// plans the route on the app's map. The same calm card look as the rest of the app.
class HealthScreen extends StatefulWidget {
  const HealthScreen({
    super.key,
    required this.health,
    required this.i18n,
    required this.exercise,
    required this.awards,
    required this.checkin,
    this.onRoute,
  });
  final HealthController health;
  final I18n i18n;
  final ExerciseController exercise;
  final AwardStore awards;
  final CheckInController checkin;

  /// Plans a route to a place on the app's map and switches to the Map tab.
  final void Function(NearbyPlace place)? onRoute;

  @override
  State<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends State<HealthScreen> {
  double _scrollY = 0;

  @override
  void initState() {
    super.initState();
    // Re-arms the water reminder on every open and refreshes nearby lists when stale.
    unawaited(widget.health.onHealthTabOpen());
    if (widget.exercise.history.isEmpty) unawaited(widget.exercise.load());
    if (widget.awards.awards.isEmpty) unawaited(widget.awards.load());
  }

  String t(String k, [Map<String, String> a = const {}]) => widget.i18n.t(k, a);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.health, widget.exercise, widget.awards, widget.checkin]),
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: Text(t('tabs.health'))),
        body: NotificationListener<ScrollNotification>(
          // The scroll offset drives the banner's parallax: the photo slides
          // slower than the list, like the police tab's cover.
          onNotification: (n) {
            if (n.metrics.axis == Axis.vertical && (n.metrics.pixels - _scrollY).abs() > 0.5) {
              setState(() => _scrollY = n.metrics.pixels);
            }
            return false;
          },
          child: ListView(
          // Bouncy pull: every tab scrolls with the same alive spring.
          physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            // The tab opens on a person, not on a form: a morning-stretch banner
            // straight from the reference boards, with the tab's promise on it.
            ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: SizedBox(
                height: 168,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      // The photo lags behind the list (parallax) but is drawn
                      // taller than the box, so no bounce can pull it past an
                      // edge and show a bare stripe underneath.
                      top: _scrollY * 0.35 - 60,
                      height: 288,
                      child: Image.memory(photoHealthBytes, fit: BoxFit.cover, gaplessPlayback: true),
                    ),
                    Align(
                      alignment: Alignment.bottomLeft,
                      child: Container(
                        // A whisper of shading, not a dark banner: just enough
                        // under the words to keep them readable, and the words
                        // also carry their own soft shadow.
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [Color(0x40000000), Color(0x00000000)],
                          ),
                        ),
                        padding: const EdgeInsets.fromLTRB(16, 30, 16, 14),
                        child: Text(
                          t('tabs.health'),
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            letterSpacing: -0.4,
                            shadows: [Shadow(color: Color(0x99000000), blurRadius: 10, offset: Offset(0, 1))],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            _section('HEART', t('health.heart'), Icons.favorite_border),
            _heartCard(context, cs),
            const SizedBox(height: 20),
            _section('WATER', t('health.water'), Icons.water_drop_outlined),
            _waterCard(context),
            const SizedBox(height: 20),
            _section('EXERCISE', t('exercise.title'), Icons.directions_run),
            _exerciseCard(context, cs),
            const SizedBox(height: 10),
            _awardsCard(context, cs),
            _historyCard(context, cs),
            const SizedBox(height: 20),
            _section('NEARBY', t('health.hospitals'), Icons.local_hospital_outlined),
            _placesCard(
              context,
              cs,
              loading: widget.health.hospitalsLoading,
              failed: widget.health.hospitalsFailed,
              noLocation: widget.health.hospitalsNoLocation,
              list: widget.health.hospitals,
              emptyKey: 'health.hosp_none',
              retry: () => unawaited(widget.health.loadHospitals(force: true)),
            ),
            const SizedBox(height: 20),
            // The gyms list opens on a person training, the way the tab should feel.
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 8),
              child: Row(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: Image.memory(photoGymBytes, fit: BoxFit.cover, gaplessPlayback: true),
                  ),
                ),
                const SizedBox(width: 8),
                Text(t('health.gyms'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.3)),
              ]),
            ),
            _placesCard(
              context,
              cs,
              loading: widget.health.gymsLoading,
              failed: widget.health.gymsFailed,
              noLocation: widget.health.gymsNoLocation,
              list: widget.health.gyms,
              emptyKey: 'health.gym_none',
              retry: () => unawaited(widget.health.loadGyms(force: true)),
            ),
          ],
          ),
        ),
      ),
    );
  }

  Widget _section(String note, String title, IconData icon) => Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 8),
        child: Row(children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.3)),
        ]),
      );

  // ---------------------------------------------------------------- heart

  Widget _heartCard(BuildContext context, ColorScheme cs) {
    final h = widget.health;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (h.measuring) ...[
            _measureArea(context, cs),
          ] else ...[
            // The measure flow is the primary path; no "connect a health app" homework.
            // A saved reading (from the camera or a band via Health Connect) still shows.
            if (h.bpm != null) ...[
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('${h.bpm}', style: const TextStyle(fontSize: 46, fontWeight: FontWeight.w800, height: 1)),
                const SizedBox(width: 8),
                Padding(padding: const EdgeInsets.only(bottom: 7), child: Text('bpm', style: TextStyle(fontSize: 14, color: Flat.muted(context), fontWeight: FontWeight.w600))),
                const Spacer(),
                Icon(Icons.monitor_heart_outlined, size: 22, color: cs.primary),
              ]),
              if (h.baseline != null) ...[
                const SizedBox(height: 6),
                Text(t('health.heart_base', {'n': '${h.baseline}'}), style: TextStyle(fontSize: 13.5, color: Flat.muted(context))),
              ],
              const SizedBox(height: 4),
              Text(t('health.heart_watch'), style: const TextStyle(fontSize: 13, height: 1.4)),
            ] else ...[
              Text(t('health.heart_cam'), style: const TextStyle(fontSize: 14, height: 1.45)),
            ],
            // Honest failure notes, each with its own advice.
            if (h.measureFailed && h.noCamera) ...[
              const SizedBox(height: 12),
              Text(t('health.measure_no_cam'), textAlign: TextAlign.center, style: TextStyle(fontSize: 13.5, height: 1.4, color: cs.error.withValues(alpha: 0.85))),
            ] else if (h.measureFailed && h.measureNofeed) ...[
              const SizedBox(height: 12),
              Text(t('health.measure_nofeed'), textAlign: TextAlign.center, style: TextStyle(fontSize: 13.5, height: 1.4, color: cs.error.withValues(alpha: 0.85))),
            ] else if (h.measureFailed) ...[
              const SizedBox(height: 12),
              Text(t('health.measure_fail'), textAlign: TextAlign.center, style: TextStyle(fontSize: 13.5, height: 1.4, color: Flat.muted(context))),
            ],
            const SizedBox(height: 14),
            Center(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 22)),
                onPressed: () => unawaited(h.measureWithCamera()),
                icon: const Icon(Icons.waving_hand_outlined, size: 20),
                label: Text(t(h.cameraBpm == null ? 'health.measure' : 'health.measure_again'), style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
              ),
            ),
            // The readings the app itself has taken before, newest first, plus one
            // honest line about where the rate is heading.
            _heartHistory(context, cs),
          ],
        ]),
      ),
    );
  }

  /// The recent self-taken readings as small chips, and a trend line: the average of
  /// the newest three takes against the three before them (or the last two takes
  /// while there are fewer than six). A lower resting rate reads as "better".
  Widget _heartHistory(BuildContext context, ColorScheme cs) {
    final takes = widget.health.settings.heartTakes;
    if (takes.isEmpty) return const SizedBox.shrink();
    String? trendKey;
    double avg(List<HeartTake> l) => l.map((e) => e.bpm).reduce((a, b) => a + b) / l.length;
    if (takes.length >= 6) {
      final cur = avg(takes.sublist(takes.length - 3));
      final prev = avg(takes.sublist(takes.length - 6, takes.length - 3));
      if (cur <= prev - 2.5) {
        trendKey = 'heart.trend_better';
      } else if (cur >= prev + 2.5) {
        trendKey = 'heart.trend_worse';
      } else {
        trendKey = 'heart.trend_steady';
      }
    } else if (takes.length >= 2) {
      final d = takes.last.bpm - takes[takes.length - 2].bpm;
      if (d <= -3) {
        trendKey = 'heart.trend_better';
      } else if (d >= 3) {
        trendKey = 'heart.trend_worse';
      } else {
        trendKey = 'heart.trend_steady';
      }
    }
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t('heart.recent'), style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, letterSpacing: 0.2)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final h in takes.reversed.take(4))
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: cs.primary.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(12)),
                child: Column(children: [
                  Text('${h.bpm}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, height: 1.05, fontFeatures: [FontFeature.tabularFigures()])),
                  Text(_dayLabel(DateTime.fromMillisecondsSinceEpoch(h.atMs)), style: TextStyle(fontSize: 10.5, color: Flat.muted(context))),
                ]),
              ),
          ],
        ),
        if (trendKey != null) ...[
          const SizedBox(height: 10),
          Row(children: [
            Icon(
              trendKey == 'heart.trend_better' ? Icons.trending_down : trendKey == 'heart.trend_worse' ? Icons.trending_up : Icons.trending_flat,
              size: 18,
              color: trendKey == 'heart.trend_better' ? const Color(0xFF2BB673) : trendKey == 'heart.trend_worse' ? cs.error : cs.primary,
            ),
            const SizedBox(width: 6),
            Expanded(child: Text(t(trendKey), style: TextStyle(fontSize: 13, height: 1.35, color: Flat.muted(context)))),
          ]),
        ],
      ]),
    );
  }

  /// A compact "13/11 09:42" stamp for a reading chip.
  String _dayLabel(DateTime d) =>
      '${d.day}/${d.month} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  Widget _measureArea(BuildContext context, ColorScheme cs) {
    final h = widget.health;
    final ctrl = h.cameraPreview;
    // A big warm, near-white panel: with the finger pressed over the front camera, this
    // bright surface IS the light source for the reading. The small round window shows
    // the live stream so frames keep flowing.
    return Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
      Text(t('health.measure_left', {'n': '${h.measureLeft}'}),
          style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, height: 1, fontFeatures: [FontFeature.tabularFigures()])),
      const SizedBox(height: 12),
      Center(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
          decoration: BoxDecoration(
            color: const Color(0xFFFDF1E0),
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFFFFFBF4), Color(0xFFFBEEDC)],
            ),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Column(children: [
            ClipOval(
              child: Container(
                width: 130,
                height: 130,
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0x338A6D3B), width: 3),
                ),
                child: ctrl == null
                    ? const ColoredBox(color: Color(0xFFFFF6EA))
                    : CameraPreview(ctrl),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              t('health.measure_tip'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, height: 1.45, color: Colors.black.withValues(alpha: 0.78)),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 12),
      const LinearProgressIndicator(minHeight: 2),
    ]);
  }

  // ---------------------------------------------------------------- water

  Widget _waterCard(BuildContext context) {
    final h = widget.health;
    final s = h.settings;
    final cs = Theme.of(context).colorScheme;
    const options = [0, 30, 60, 120, 180];
    String label(int m) => switch (m) {
          0 => t('health.water_off'),
          30 => t('health.water_30'),
          60 => t('health.water_1'),
          120 => t('health.water_2'),
          _ => t('health.water_3'),
        };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // The photo sits beside the intro and the pace picker gets the whole
          // card width - the time chips no longer squeeze into a side lane.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: Image.memory(photoWaterBytes, fit: BoxFit.cover, gaplessPlayback: true),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(t('health.water_sub'), style: const TextStyle(fontSize: 13.5, height: 1.4)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(color: Flat.hairline(context), borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              for (final m in options)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: s.waterMinutes == m,
                    child: GestureDetector(
                      onTap: () async {
                        await s.update(waterMinutes: m);
                        // After every pace change, the honest state is read back.
                        await h.refreshWaterStatus();
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        height: 40,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: s.waterMinutes == m ? Flat.card(context) : Colors.transparent, borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Text(label(m), textAlign: TextAlign.center, maxLines: 2, style: TextStyle(fontSize: 12, fontWeight: s.waterMinutes == m ? FontWeight.w600 : FontWeight.w500)),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
          // The honest line: what actually became of the reminder on THIS phone.
          if (s.waterMinutes > 0) ...[
            const SizedBox(height: 12),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(
                h.waterStatus == WaterStatus.ok ? Icons.verified_outlined : Icons.warning_amber_rounded,
                size: 17,
                color: h.waterStatus == WaterStatus.ok ? cs.tertiary : Colors.amber.shade700,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  h.waterStatus == WaterStatus.ok
                      ? t('health.water_ok', {'n': label(s.waterMinutes)})
                      : t('health.water_broken'),
                  style: TextStyle(fontSize: 12.5, height: 1.4, color: cs.onSurface.withValues(alpha: 0.75)),
                ),
              ),
            ]),
          ],
        ]),
      ),
    );
  }

  // ---------------------------------------------------------------- exercise

  ExerciseMode _mode = ExerciseMode.walk;
  int _checkMinutes = 0;
  PlannedRoute? _planned;

  Widget _exerciseCard(BuildContext context, ColorScheme cs) {
    final e = widget.exercise;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t('exercise.sub'), style: const TextStyle(fontSize: 14, height: 1.45)),
          const SizedBox(height: 14),
          // The three ways to move, one photo card each - pick like the reference
          // boards: tap the tile, the ring shows the choice.
          Row(
            children: [
              for (final m in ExerciseMode.values)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: _mode == m,
                    child: GestureDetector(
                      onTap: () => setState(() => _mode = m),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        margin: EdgeInsets.only(right: m != ExerciseMode.bike ? 10 : 0),
                        height: 92,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          borderRadius: _mode == m ? BorderRadius.circular(20) : BorderRadius.circular(16),
                          border: Border.all(
                            width: _mode == m ? 2.5 : 1.5,
                            color: _mode == m ? cs.primary : cs.onSurface.withValues(alpha: 0.12),
                          ),
                        ),
                        child: Stack(
                          fit: StackFit.expand,
                          alignment: Alignment.bottomLeft,
                          children: [
                            if (m == ExerciseMode.walk) Image.memory(photoWalkBytes, fit: BoxFit.cover, gaplessPlayback: true),
                            if (m == ExerciseMode.run) Image.memory(photoRunBytes, fit: BoxFit.cover, gaplessPlayback: true),
                            if (m == ExerciseMode.bike) Image.memory(photoBikeBytes, fit: BoxFit.cover, gaplessPlayback: true),
                            Align(
                              alignment: Alignment.bottomLeft,
                              child: Padding(
                                padding: const EdgeInsets.all(6),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xCC17181C),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    switch (m) {
                                      ExerciseMode.walk => t('exercise.walk'),
                                      ExerciseMode.run => t('exercise.run'),
                                      ExerciseMode.bike => t('exercise.bike'),
                                    },
                                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          // Build your own route, Strava-style: tap every street the session should
          // pass through, the plan is drawn and carried into the live session.
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(42), padding: const EdgeInsets.symmetric(horizontal: 14)),
                onPressed: () async {
                  final fix = widget.exercise.lastFix;
                  final plan = await Navigator.of(context).push<PlannedRoute>(MaterialPageRoute(
                    builder: (_) => RouteBuilderScreen(
                      i18n: widget.i18n,
                      mode: _mode,
                      start: fix == null ? null : LatLng(fix.lat, fix.lon),
                    ),
                  ));
                  if (plan != null) setState(() => _planned = plan);
                },
                icon: const Icon(Icons.route_outlined, size: 20),
                label: Text(t('route.build'), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              ),
            ),
            if (_planned != null) ...[
              const SizedBox(width: 8),
              InkWell(
                onTap: () => setState(() => _planned = null),
                customBorder: const CircleBorder(),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(Icons.cancel_rounded, size: 24, color: cs.primary),
                ),
              ),
            ],
          ]),
          if (_planned != null) ...[
            const SizedBox(height: 8),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.check_circle_outline_rounded, size: 17, color: cs.tertiary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${t('route.planned')} ${_planned!.km < 1 ? _planned!.km.toStringAsFixed(2) : _planned!.km.toStringAsFixed(1)} km · ~${_planned!.mins} min',
                  style: TextStyle(fontSize: 12.5, height: 1.4, color: cs.onSurface.withValues(alpha: 0.75)),
                ),
              ),
            ]),
          ],
          // The safety watch for the session, moved here from the home screen:
          // pick how long the session may take; if it goes past that without
          // "I'm safe", the contacts get a full alert, same as any other check.
          const SizedBox(height: 14),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.timer_outlined, size: 17, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(t('exercise.check_sub'), style: TextStyle(fontSize: 12.5, height: 1.4, color: cs.onSurface.withValues(alpha: 0.75))),
            ),
          ]),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(color: Flat.hairline(context), borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              for (final m in const [0, 30, 60, 120])
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: _checkMinutes == m,
                    child: GestureDetector(
                      onTap: () => setState(() => _checkMinutes = m),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        height: 36,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: _checkMinutes == m ? Flat.card(context) : Colors.transparent, borderRadius: BorderRadius.circular(9)),
                        child: Text(switch (m) {
                          0 => t('exercise.check_off'),
                          30 => t('health.water_30'),
                          60 => t('health.water_1'),
                          _ => t('health.water_2'),
                        }, style: TextStyle(fontSize: 12, fontWeight: _checkMinutes == m ? FontWeight.w600 : FontWeight.w500)),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 14),
          Center(
            child: FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 46), padding: const EdgeInsets.symmetric(horizontal: 26)),
              onPressed: () => unawaited(_startSession(context)),
              icon: const Icon(Icons.play_arrow_rounded, size: 24),
              label: Text(t('exercise.start'), style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> _startSession(BuildContext context) async {
    //   -1 means "inherit a running watch": the person already armed check-on-me.
    final mins = _checkMinutes;
    final routes = Navigator.of(context);
    final started = await routes.push(MaterialPageRoute<bool>(
      builder: (_) => WorkoutScreen(
        exercise: widget.exercise,
        checkin: widget.checkin,
        i18n: widget.i18n,
        mode: _mode,
        checkMinutes: mins,
        planned: _planned,
        mapType: widget.health.settings.mapType,
      ),
    ));
    if (started == null) return; // discarded inside: nothing to celebrate
  }

  // ---------------------------------------------------------------- awards

  Widget _awardsCard(BuildContext context, ColorScheme cs) {
    // The shelf is shared: the Health tab shows it, and so do the full history
    // screen and each session's own page.
    return _AwardShelfCard(awards: widget.awards, i18n: widget.i18n);
  }

  // ---------------------------------------------------------------- history

  Widget _historyCard(BuildContext context, ColorScheme cs) {
    final hist = widget.exercise.history;
    String _ageText(DateTime d) => t('exercise.hist_on', {'d': '${d.day}/${d.month}'});
    return Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // The whole header opens the full story: every session ever saved plus
        // the award shelf - the History section is one visible tap.
        TapBounce(
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => ExerciseHistoryScreen(exercise: widget.exercise, awards: widget.awards, i18n: widget.i18n, mapType: widget.health.settings.mapType),
          )),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 10, 0),
            child: Row(children: [
              Text(t('exercise.history'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              const Spacer(),
              Text(t('exercise.hist_total', {'n': widget.exercise.totalKm.toStringAsFixed(1)}), style: TextStyle(fontSize: 13, color: Flat.muted(context), fontFeatures: const [FontFeature.tabularFigures()])),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 20, color: cs.onSurface.withValues(alpha: 0.4)),
            ]),
          ),
        ),
        if (hist.isEmpty)
          Padding(
            padding: const EdgeInsets.all(18),
            child: Text(t('exercise.history_empty'), style: TextStyle(fontSize: 13.5, height: 1.4, color: Flat.muted(context))),
          )
        else ...[
          const SizedBox(height: 6),
          for (var i = 0; i < hist.length && i < 5; i++) ...[
            if (i > 0) Divider(height: 1, color: Flat.hairline(context)),
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: Icon(
                switch (hist[i].mode) {
                  'walk' => Icons.directions_walk_outlined,
                  'run' => Icons.directions_run_outlined,
                  _ => Icons.directions_bike_outlined,
                },
                size: 22,
                color: cs.primary,
              ),
              title: Text(
                '${switch (hist[i].mode) {
                  'walk' => t('exercise.walk'),
                  'run' => t('exercise.run'),
                  _ => t('exercise.bike'),
                }} · ${_ageText(hist[i].start)}',
                style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                [
                  if (hist[i].km > 0) '${hist[i].km < 1 ? hist[i].km.toStringAsFixed(2) : hist[i].km.round()} km',
                  '${hist[i].seconds ~/ 60} ${t('exercise.min_short')}',
                  if (hist[i].mode != 'bike') t('exercise.steps_n', {'n': '${hist[i].steps}'}),
                ].join(' · '),
                style: TextStyle(fontSize: 12.5, color: Flat.muted(context), fontFeatures: const [FontFeature.tabularFigures()]),
              ),
              onTap: () => unawaited(_openSession(context, hist[i])),
            ),
          ],
        ],
        const SizedBox(height: 10),
      ]),
    );
  }

  /// One past session on its own page: the exact route walked/ran/rode, drawn
  /// and fitted, Strava-style.
  Future<void> _openSession(BuildContext context, WorkoutRecord r) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _SessionDetailScreen(record: r, awards: widget.awards, i18n: widget.i18n, mapType: widget.health.settings.mapType),
    ));
  }

  // ------------------------------------------------- hospitals / gyms nearby

  Widget _placesCard(
    BuildContext context,
    ColorScheme cs, {
    required bool loading,
    required bool failed,
    required bool noLocation,
    required List<NearbyPlace> list,
    required String emptyKey,
    required VoidCallback retry,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(children: [
          if (loading) ...[
            Padding(padding: const EdgeInsets.all(28), child: LinearProgressIndicator(minHeight: 2, color: cs.primary)),
          ] else if (noLocation && list.isEmpty) ...[
            Padding(padding: const EdgeInsets.all(16), child: Text(t('health.hosp_location'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, height: 1.45))),
          ] else if (failed && list.isEmpty) ...[
            Padding(padding: const EdgeInsets.all(16), child: Text(t('health.hosp_error'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, height: 1.45))),
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: OutlinedButton(
                onPressed: retry,
                child: Text(t('contacts.retry')),
              ),
            ),
          ] else if (list.isEmpty) ...[
            Padding(padding: const EdgeInsets.all(16), child: Text(t(emptyKey), textAlign: TextAlign.center, style: TextStyle(fontSize: 14, height: 1.45, color: Flat.muted(context)))),
          ] else
            for (var i = 0; i < list.length; i++) ...[
              if (i > 0) Divider(height: 1, color: Flat.hairline(context)),
              _placeTile(context, list[i], cs),
            ],
        ]),
      ),
    );
  }

  Widget _placeTile(BuildContext context, NearbyPlace p, ColorScheme cs) {
    final phone = p.phone;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(p.name, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
        const SizedBox(height: 3),
        Text(
          phone == null ? t('health.hosp_no_phone') : '${t('health.hosp_km', {'n': p.km < 10 ? p.km.toStringAsFixed(1) : p.km.round().toString()})} · $phone',
          style: TextStyle(fontSize: 13, color: phone == null ? cs.error.withValues(alpha: 0.7) : Flat.muted(context), fontFeatures: const [FontFeature.tabularFigures()]),
        ),
        const SizedBox(height: 9),
        Row(children: [
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 40),
              padding: const EdgeInsets.symmetric(horizontal: 18),
              side: BorderSide(color: cs.primary),
              foregroundColor: cs.primary,
            ),
            onPressed: () => unawaited(_call(phone)),
            icon: const Icon(Icons.call_outlined, size: 18),
            label: Text(t('health.call'), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 40),
              padding: const EdgeInsets.symmetric(horizontal: 18),
            ),
            onPressed: () => widget.onRoute?.call(p),
            icon: const Icon(Icons.directions_outlined, size: 18),
            label: Text(t('health.route'), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
        ]),
      ]),
    );
  }

  Future<void> _call(String? phone) async {
    if (phone == null) return;
    final clean = phone.replaceAll(RegExp(r'[^0-9+*#]'), '');
    if (clean.isEmpty) return;
    try {
      await launchUrl(Uri(scheme: 'tel', path: clean), mode: LaunchMode.externalApplication);
    } catch (_) {
      // No dialler on this device: nothing to do; the number is still visible and copyable.
    }
  }
}

/// A session's route drawn on a mini map and fitted so the whole walk/run/ride
/// line is visible at once. With [ends] it also drops a start pin and an end
/// pin on the line, Strava-style. No live tracking - just the story.
class FlutterMapSheetMap extends StatelessWidget {
  const FlutterMapSheetMap({super.key, required this.path, this.ends = false, this.mapType = 'standard'});
  final List<LatLng> path;
  final bool ends;

  /// The base layer the person chose on the map tab, so every map in the app wears
  /// the same look (satellite, hybrid, night...).
  final String mapType;

  @override
  Widget build(BuildContext context) {
    if (path.length < 2) {
      return const Center(child: Icon(Icons.route_outlined, size: 40));
    }
    return FlutterMap(
      options: MapOptions(
        initialCameraFit: CameraFit.coordinates(
          coordinates: path,
          padding: const EdgeInsets.fromLTRB(46, 46, 46, 46),
        ),
      ),
      children: [
        for (final url in sentriBaseLayers(mapType).urls) TileLayer(urlTemplate: url, userAgentPackageName: 'ng.sentri.sentri'),
        PolylineLayer(polylines: [
          // A pale casing under the line, same look as the map's live routes.
          Polyline(points: path, strokeWidth: 7, color: const Color(0x336A5FF0)),
          Polyline(points: path, strokeWidth: 4, color: const Color(0xFF6A5FF0)),
        ]),
        if (ends)
          MarkerLayer(markers: [
            // Where the session began, and where it ended: two small round
            // pins with a white edge so they read on any tile.
            Marker(
              point: path.first,
              width: 18,
              height: 18,
              child: Container(
                decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFF1E9E56), border: Border.all(color: Colors.white, width: 2.5)),
              ),
            ),
            Marker(
              point: path.last,
              width: 18,
              height: 18,
              child: Container(
                decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFF6A5FF0), border: Border.all(color: Colors.white, width: 2.5)),
              ),
            ),
          ]),
        RichAttributionWidget(attributions: [for (final a in sentriBaseLayers(mapType).attributions) TextSourceAttribution(a)]),
      ],
    );
  }
}

/// The award shelf, shared: the Health tab, the full history screen and every
/// session page all show the same badges.
class _AwardShelfCard extends StatelessWidget {
  const _AwardShelfCard({required this.awards, required this.i18n});
  final AwardStore awards;
  final I18n i18n;

  @override
  Widget build(BuildContext context) {
    final t = i18n.t;
    final all = awards.awards;
    final kinds = AwardKind.values;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(t('award.shelf'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            const Spacer(),
            Text('${all.length}/${kinds.length}', style: TextStyle(fontSize: 13, color: Flat.muted(context), fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
          const SizedBox(height: 12),
          // The shelf scrolls left and right: each badge keeps a roomy, fixed
          // width instead of eight of them shrinking into the edge.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: Row(
              children: [
                for (final k in kinds)
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: SizedBox(
                      width: 58,
                      child: Column(children: [
                        AwardBadge(kind: k, size: 40, dim: !awards.has(k)),
                        const SizedBox(height: 4),
                        Text(
                          t('award.${awardId(k)}_title'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 9.5, height: 1.15, color: awards.has(k) ? null : Flat.muted(context)),
                        ),
                      ]),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(t('award.shelf_hint'), style: TextStyle(fontSize: 12, height: 1.35, color: Flat.muted(context))),
        ]),
      ),
    );
  }
}

/// The full exercise story, opened from the History card's header: every saved
/// session (walk, run or ride), each with its own page, plus the award shelf.
class ExerciseHistoryScreen extends StatelessWidget {
  const ExerciseHistoryScreen({super.key, required this.exercise, required this.awards, required this.i18n, this.mapType = 'standard'});
  final ExerciseController exercise;
  final AwardStore awards;
  final I18n i18n;

  /// The base layer chosen on the map tab, so every session map wears the same look.
  final String mapType;

  @override
  Widget build(BuildContext context) {
    final t = i18n.t;
    final cs = Theme.of(context).colorScheme;
    final hist = exercise.history;
    return FlatPage(
      title: t('exercise.history'),
      subtitle: t('exercise.hist_total', {'n': exercise.totalKm.toStringAsFixed(1)}),
      children: [
        _AwardShelfCard(awards: awards, i18n: i18n),
        const SizedBox(height: 16),
        Card(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (hist.isEmpty)
              Padding(
                padding: const EdgeInsets.all(18),
                child: Text(t('exercise.history_empty'), style: TextStyle(fontSize: 13.5, height: 1.4, color: Flat.muted(context))),
              )
            else
              for (var i = 0; i < hist.length; i++) ...[
                if (i > 0) Divider(height: 1, color: Flat.hairline(context)),
                ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  leading: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: cs.primary.withValues(alpha: 0.12)),
                    child: Icon(
                      switch (hist[i].mode) {
                        'walk' => Icons.directions_walk_outlined,
                        'run' => Icons.directions_run_outlined,
                        _ => Icons.directions_bike_outlined,
                      },
                      size: 21,
                      color: cs.primary,
                    ),
                  ),
                  title: Text(
                    '${switch (hist[i].mode) {
                      'walk' => t('exercise.walk'),
                      'run' => t('exercise.run'),
                      _ => t('exercise.bike'),
                    }} · ${t('exercise.hist_on', {'d': '${hist[i].start.day}/${hist[i].start.month}'})}',
                    style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    [
                      if (hist[i].km > 0) '${hist[i].km < 1 ? hist[i].km.toStringAsFixed(2) : hist[i].km.round()} km',
                      '${hist[i].seconds ~/ 60} ${t('exercise.min_short')}',
                      if (hist[i].mode != 'bike') t('exercise.steps_n', {'n': '${hist[i].steps}'}),
                    ].join(' · '),
                    style: TextStyle(fontSize: 12.5, color: Flat.muted(context), fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                  trailing: Icon(Icons.chevron_right, size: 20, color: cs.onSurface.withValues(alpha: 0.4)),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => _SessionDetailScreen(record: hist[i], awards: awards, i18n: i18n, mapType: mapType),
                  )),
                ),
              ],
          ]),
        ),
      ],
    );
  }
}

/// One saved session, Strava-style: the big numbers up top, then the exact
/// route on the map with its start and end pins, then the award shelf it feeds.
class _SessionDetailScreen extends StatelessWidget {
  const _SessionDetailScreen({required this.record, required this.awards, required this.i18n, this.mapType = 'standard'});
  final WorkoutRecord record;
  final AwardStore awards;
  final I18n i18n;

  /// The base layer chosen on the map tab, so the route map wears the same look.
  final String mapType;

  @override
  Widget build(BuildContext context) {
    final t = i18n.t;
    final r = record;
    final modeName = switch (r.mode) {
      'walk' => t('exercise.walk'),
      'run' => t('exercise.run'),
      _ => t('exercise.bike'),
    };
    // The clock reads minutes:seconds, tabular so it doesn't jitter.
    final clock = '${(r.seconds ~/ 60).toString().padLeft(2, '0')}:${(r.seconds % 60).toString().padLeft(2, '0')}';
    return FlatPage(
      title: '$modeName · ${t('exercise.hist_on', {'d': '${r.start.day}/${r.start.month}'})}',
      children: [
        // The stat strip: distance, time and steps, the numbers that tell it.
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            child: Row(children: [
              Expanded(child: _bigStat(
                r.km < 1 ? r.km.toStringAsFixed(2) : r.km.toStringAsFixed(1),
                t('exercise.distance'),
              )),
              Expanded(child: _bigStat(clock, t('exercise.time'))),
              Expanded(child: _bigStat(
                r.mode == 'bike' ? '—' : '${r.steps}',
                t('exercise.steps'),
              )),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        // The route, nearly full-bleed like the reference: the line the person
        // actually passed, fitted to the view, start and end pinned.
        ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: SizedBox(
            height: 280,
            child: FlutterMapSheetMap(path: r.path, ends: true, mapType: mapType),
          ),
        ),
        const SizedBox(height: 16),
        _AwardShelfCard(awards: awards, i18n: i18n),
      ],
    );
  }

  Widget _bigStat(String value, String label) => Column(children: [
        Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, height: 1.05, fontFeatures: [FontFeature.tabularFigures()])),
        const SizedBox(height: 3),
        Text(label, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, letterSpacing: 0.2)),
      ]);
}
