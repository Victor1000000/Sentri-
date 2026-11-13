import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/i18n/i18n.dart';
import '../checkin/checkin_controller.dart';
import '../map/map_screen.dart' show sentriBaseLayers;
import 'awards.dart';
import 'exercise_controller.dart';
import 'route_builder.dart';

/// A live workout on the app's map: the session starts the moment this screen
/// opens and everything counts right away - the clock, real steps from the
/// phone's step sensor (walk and run) and kilometre distance from GPS, with the
/// route drawn as the person moves. "Check on me" is armed for the session's
/// chosen length, so if the person never comes back and never marks themselves
/// safe, their contacts hear the alert exactly like any other missed check.
/// Finishing saves the session to the history and hands out any awards.
///
/// A session can carry a plan the person built on the route-builder screen; the
/// plan is drawn as a dashed line and the stats show how much of it is left.
class WorkoutScreen extends StatefulWidget {
  const WorkoutScreen({
    super.key,
    required this.exercise,
    required this.checkin,
    required this.i18n,
    required this.mode,
    required this.checkMinutes,
    this.planned,
    this.mapType = 'hybrid',
  });
  final ExerciseController exercise;
  final CheckInController checkin;
  final I18n i18n;
  final ExerciseMode mode;
  final int checkMinutes; // 0 = no check-on-me for this session
  final PlannedRoute? planned;

  /// The base layer chosen on the map tab, so the live session wears the same look.
  final String mapType;

  @override
  State<WorkoutScreen> createState() => _WorkoutScreenState();
}

class _WorkoutScreenState extends State<WorkoutScreen> {
  final _map = MapController();
  int _lastPathLen = 0;
  bool _cameraOn = false;

  @override
  void initState() {
    super.initState();
    unawaited(_begin());
  }

  Future<void> _begin() async {
    final ok = await widget.exercise.start(widget.mode);
    if (!ok) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(widget.i18n.t('exercise.perm_denied'))));
        Navigator.of(context).pop();
      }
      return;
    }
    if (widget.checkMinutes > 0) {
      await widget.checkin.start(Duration(minutes: widget.checkMinutes));
    }
    // The camera jumps to the person the moment the first fix lands (handled in
    // build); the map never opens zoomed out over the whole country.
  }

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  String _clock(int s) => '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  /// Finishes and saves the session, then celebrates each NEW award; the
  /// check-on-me watch is marked safe (the person is back).
  Future<void> _finish() async {
    final earned = await widget.exercise.stop(keepRecord: true);
    await widget.checkin.cancel();
    if (mounted) Navigator.of(context).pop();
    for (final k in earned) {
      if (!mounted) return;
      await showAwardCelebration(context, widget.i18n, k);
    }
  }

  /// Stops without saving. The check-on-me watch stays armed on purpose: the
  /// person said they are not done yet, they only did not want this one saved.
  Future<void> _discard() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(widget.i18n.t('exercise.discard_title')),
        content: Text(widget.i18n.t('exercise.discard_body')),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(widget.i18n.t('exercise.discard_keep'))),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(widget.i18n.t('exercise.discard_go'))),
        ],
      ),
    );
    if (confirm != true) return;
    await widget.exercise.stop(keepRecord: false);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.i18n.t;
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final e = widget.exercise;
    final icon = switch (widget.mode) {
      ExerciseMode.walk => Icons.directions_walk,
      ExerciseMode.run => Icons.directions_run,
      ExerciseMode.bike => Icons.directions_bike,
    };
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        // Saving happens through the Finish button; the system back button asks plainly.
        if (!didPop) unawaited(_askBeforePop(context));
      },
      child: ListenableBuilder(
        listenable: e,
        builder: (context, _) {
          final path = e.path;
          if (!_cameraOn && e.lastFix != null) {
            // The session just started: jump to the first fix at once, before the
            // route line exists, so the map never opens over the whole country.
            _cameraOn = true;
            try {
              _map.move(LatLng(e.lastFix!.lat, e.lastFix!.lon), 17);
            } catch (_) {}
          }
          // The camera follows the newest point of the line while the session runs.
          if (path.length != _lastPathLen && path.isNotEmpty) {
            _lastPathLen = path.length;
            try {
              _map.move(path.last, 17);
            } catch (_) {}
          }
          final here = path.isNotEmpty ? path.last : null;
          return Scaffold(
            appBar: AppBar(
              leading: BackButton(onPressed: () => unawaited(_askBeforePop(context))),
              title: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 20, color: cs.primary),
                const SizedBox(width: 8),
                Text(switch (widget.mode) {
                  ExerciseMode.walk => t('exercise.walk'),
                  ExerciseMode.run => t('exercise.run'),
                  ExerciseMode.bike => t('exercise.bike'),
                }),
              ]),
            ),
            body: Stack(children: [
              Positioned.fill(
                child: FlutterMap(
                  mapController: _map,
                  options: MapOptions(initialCenter: here ?? const LatLng(9.0820, 7.4730), initialZoom: here == null ? 5.5 : 17),
                  children: [
                    for (final url in sentriBaseLayers(widget.mapType).urls) TileLayer(urlTemplate: url, userAgentPackageName: 'ng.sentri.sentri'),
                    // The plan the person built: a dashed line the walked line grows along.
                    if (widget.planned != null)
                      PolylineLayer(polylines: [
                        Polyline(
                          points: widget.planned!.points,
                          strokeWidth: 4,
                          color: dark ? const Color(0xFFB9C4D4) : const Color(0xFF44546A),
                          pattern: StrokePattern.dashed(segments: [10.0, 10.0]),
                        ),
                      ]),
                    if (path.length >= 2)
                      PolylineLayer(polylines: [Polyline(points: path, strokeWidth: 5, color: const Color(0xFF6A5FF0))]),
                    if (here != null)
                      MarkerLayer(markers: [
                        Marker(
                          point: here,
                          width: 26,
                          height: 26,
                          child: Container(
                            decoration: BoxDecoration(color: const Color(0xFF6A5FF0), shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 4)),
                          ),
                        ),
                      ]),
                    RichAttributionWidget(attributions: [for (final a in sentriBaseLayers(widget.mapType).attributions) TextSourceAttribution(a)]),
                  ],
                ),
              ),
              // The live stats strip on top of the map bottom, Google-Fit style.
              Positioned(
                left: 14,
                right: 14,
                bottom: MediaQuery.paddingOf(context).bottom + 14,
                child: Column(children: [
                  if (widget.planned != null) ...[
                    Builder(builder: (context) {
                      final left = _kmLeftOnPlan(e);
                      final plan = widget.planned!;
                      final km = plan.km < 1 ? plan.km.toStringAsFixed(2) : plan.km.toStringAsFixed(1);
                      final sub = left == null ? '' : ' · ${t('route.left', {'km': left < 1 ? left.toStringAsFixed(2) : left.toStringAsFixed(1)})}';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Material(
                          color: dark ? const Color(0xFF17181D) : Colors.white,
                          borderRadius: BorderRadius.circular(30),
                          elevation: 4,
                          shadowColor: Colors.black38,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(switch (widget.mode) {
                                ExerciseMode.walk => Icons.directions_walk,
                                ExerciseMode.run => Icons.directions_run,
                                ExerciseMode.bike => Icons.directions_bike,
                              }, size: 18, color: cs.primary),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  '${t('route.planned')} $km km · ~${plan.mins} min$sub',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                                ),
                              ),
                            ]),
                          ),
                        ),
                      );
                    }),
                  ],
                  if (widget.checkin.running)
                    ListenableBuilder(
                      listenable: widget.checkin,
                      builder: (context, _) {
                        final ends = widget.checkin.endsAt;
                        if (ends == null) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Material(
                            color: Colors.amber.shade700,
                            borderRadius: BorderRadius.circular(30),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                const Icon(Icons.timer_outlined, size: 18, color: Colors.white),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    t('home.check_until', {'time': TimeOfDay.fromDateTime(ends).format(context)}),
                                    style: const TextStyle(fontSize: 13.5, color: Colors.white, fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ]),
                            ),
                          ),
                        );
                      },
                    ),
                  Material(
                    color: dark ? const Color(0xFF17181D) : Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    elevation: 6,
                    shadowColor: Colors.black38,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
                      child: Column(children: [
                        Row(children: [
                          // The clock is the star: big, tabular so every single tick-
                          // tock holds its one second without any characters jumping.
                          Expanded(
                            child: Column(children: [
                              Text(
                                _clock(e.seconds),
                                style: TextStyle(
                                  fontSize: 34,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.5,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                  color: dark ? const Color(0xFFC6F16E) : cs.primary,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(t('exercise.time'), style: TextStyle(fontSize: 12.5, color: cs.onSurface.withValues(alpha: 0.55))),
                            ]),
                          ),
                          Expanded(child: _stat(t('exercise.distance'), '${e.km < 1 ? e.km.toStringAsFixed(2) : e.km.toStringAsFixed(1)} km')),
                          if (widget.mode != ExerciseMode.bike) Expanded(child: _stat(t('exercise.steps'), '${e.steps}')),
                        ]),
                        const SizedBox(height: 12),
                        Row(children: [
                          Expanded(
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                              onPressed: () => unawaited(_finish()),
                              icon: const Icon(Icons.check_rounded, size: 22),
                              label: Text(t('exercise.finish'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                            ),
                          ),
                          const SizedBox(width: 10),
                          OutlinedButton(
                            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 46), padding: const EdgeInsets.symmetric(horizontal: 16)),
                            onPressed: () => unawaited(_discard()),
                            child: Text(t('exercise.discard'), style: const TextStyle(fontSize: 14)),
                          ),
                        ]),
                      ]),
                    ),
                  ),
                ]),
              ),
            ]),
          );
        },
      ),
    );
  }

  Widget _stat(String label, String value) => Column(children: [
        Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55))),
      ]);

  /// How much of the built plan is still ahead: the plan point closest to the
  /// person right now, then every plan metre from there to the route's end.
  /// Null while the session has no position yet.
  double? _kmLeftOnPlan(ExerciseController e) {
    final plan = widget.planned;
    if (plan == null || plan.points.length < 2) return null;
    final here = e.path.isEmpty ? null : e.path.last;
    if (here == null) return null;
    const d = Distance();
    var bestI = 0;
    var bestM = double.infinity;
    for (var i = 0; i < plan.points.length; i++) {
      final m = d.distance(plan.points[i], here);
      if (m < bestM) {
        bestM = m;
        bestI = i;
      }
    }
    var left = 0.0;
    for (var i = bestI; i < plan.points.length - 1; i++) {
      left += d.distance(plan.points[i], plan.points[i + 1]);
    }
    return left / 1000.0;
  }

  Future<void> _askBeforePop(BuildContext context) async {
    // Same plain question as the discard button; nothing is lost silently.
    await _discard();
  }
}
