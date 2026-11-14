import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/emergency.dart';
import '../../core/i18n/i18n.dart';
import '../photos/photo_police.dart';
import '../photos24/photo_police_world.dart';
import 'police_directory.dart';

/// Digits only (plus a leading +), so a copied line with spaces dials correctly.
String _dialable(String l) => '+${l.replaceAll(RegExp(r'[^0-9]'), '')}'.replaceFirst('++', '+');

/// Lists every state command with its public lines. Numbers are selectable so they can be copied
/// — and now they can be dialled right there: one tap on the green call button beside a line,
/// no copy-paste needed. Shows the command for the user's current state first, when known.
///
/// v41, global: the person's own country decides the tab. Nigeria keeps the full NPF
/// command directory; every other country shows only the emergency lines that actually
/// answer there - never Nigerian police numbers.
class PoliceScreen extends StatelessWidget {
  const PoliceScreen({super.key, required this.directory, required this.i18n, this.currentState, this.country});
  final PoliceDirectory? directory;
  final I18n i18n;
  final String? currentState;

  /// The person's own country, resolved by the app shell from the phone number they
  /// signed up with (v41). Null falls back to the device's region on the phone.
  final SentriCountry? country;

  @override
  Widget build(BuildContext context) {
    final t = i18n.t;
    final dir = directory;
    return Scaffold(
      appBar: AppBar(title: Text(t('tabs.police'))),
      body: dir == null
          ? const Center(child: CircularProgressIndicator())
          : _ParallaxList(dir: dir, i18n: i18n, state: currentState, country: country),
    );
  }
}

/// Holds the scroll offset so the banner above can slide while the list moves.
/// A plain StatefulWidget rebuilds the list with the latest offset; cheap and honest.
/// The directory (non-null by the time it gets here), the language and the user's
/// state are handed over as widget fields, so nothing nullable is ever captured
/// inside this object's closures.
class _ParallaxList extends StatefulWidget {
  const _ParallaxList({required this.dir, required this.i18n, this.state, this.country});
  final PoliceDirectory dir;
  final I18n i18n;
  final String? state;

  /// The person's own country (v41) - overrides the device's region.
  final SentriCountry? country;
  @override
  State<_ParallaxList> createState() => _ParallaxListState();
}

class _ParallaxListState extends State<_ParallaxList> {
  double _offset = 0;

  @override
  Widget build(BuildContext context) {
    final t = widget.i18n.t;
    final cs = Theme.of(context).colorScheme;
    final dir = widget.dir;
    final mine = dir.forState(widget.state);
    // v41, global: the person's own country first - the number they signed up
    // with decides, not the phone's SIM - falling back to the device's region.
    // Nigeria is the one country with its own full command directory; for every
    // other country the emergency-lines card is the whole tab.
    final country = widget.country ?? countryForLocale(Platform.localeName);
    final ngLayout = country == null || country.iso == 'ng';
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.axis == Axis.vertical && n.metrics.pixels != _offset) {
          setState(() => _offset = n.metrics.pixels);
        }
        return false;
      },
      child: ListView(
        // Bouncy pull like the rest of the refreshed screens.
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          // The NPF banner and directory are Nigeria's own: shown for Nigeria
          // (and when the country is simply unknown). Everywhere else the tab
          // is the world card only (v41).
          if (ngLayout) ...[
            // The tab opens on a real officer's face, not on a form: a Nigerian
            // police banner that slides gently as the page scrolls (parallax).
            ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: SizedBox(
                height: 150,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Transform.translate(
                      offset: Offset(0, (-_offset * 0.35).clamp(-60.0, 60.0)),
                      child: Image.memory(photoPoliceBytes, fit: BoxFit.cover, gaplessPlayback: true),
                    ),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [Color(0x66000000), Color(0x00000000)],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
          ],
          if (mine != null) ...[
            Text(t('police.your_state').toUpperCase(), style: Theme.of(context).textTheme.labelMedium?.copyWith(letterSpacing: 1.1, color: cs.outline)),
            const SizedBox(height: 8),
            Card(child: _CommandTile(mine, widget.i18n)),
            const SizedBox(height: 20),
          ],
          // The world's lines for this phone's country: police, fire and ambulance,
          // each one tappable, no copy-paste. Only shown when a country is known.
          // v42: the country also gets its region's police and firefighter
          // photos, so the tab opens on real faces from the person's part of the
          // world, not only Nigerian ones. Photos decode once and are cached.
          if (country != null) ...[
            if (policePhotoForCountry(country.iso) case final policePhoto?) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: SizedBox(
                  height: 150,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Transform.translate(
                        offset: Offset(0, (-_offset * 0.35).clamp(-60.0, 60.0)),
                        child: Image.memory(policePhoto, fit: BoxFit.cover, gaplessPlayback: true),
                      ),
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: [Color(0x66000000), Color(0x00000000)],
                            ),
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.bottomLeft,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          child: Text(
                            '${country.flag}  ${country.name}',
                            style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700, shadows: [Shadow(color: Color(0x99000000), blurRadius: 8, offset: Offset(0, 1))]),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
            ],
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(country.flag, style: const TextStyle(fontSize: 20)),
                    const SizedBox(width: 8),
                    Expanded(child: Text(t('emergency.title', {'name': country.name}), style: Theme.of(context).textTheme.titleMedium)),
                  ]),
                  const SizedBox(height: 6),
                  for (final s in const [('emergency.police', 'police'), ('emergency.fire', 'fire'), ('emergency.ambulance', 'ambulance')])
                    Row(children: [
                      Expanded(child: Text(t(s.$1), style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600))),
                      const SizedBox(width: 8),
                      Text(switch (s.$2) { 'police' => country.police, 'fire' => country.fire, _ => country.ambulance },
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
                      IconButton(
                        tooltip: t('health.call'),
                        visualDensity: VisualDensity.compact,
                        icon: Icon(Icons.call, color: cs.primary),
                        onPressed: () {
                          final n = switch (s.$2) { 'police' => country.police, 'fire' => country.fire, _ => country.ambulance };
                          unawaited(launchUrl(Uri(scheme: 'tel', path: n), mode: LaunchMode.externalApplication).catchError((_) => false));
                        },
                      ),
                    ]),
                  const SizedBox(height: 2),
                  Text(t('emergency.note'), style: TextStyle(fontSize: 12.5, height: 1.35, color: cs.outline)),
                ]),
              ),
            ),
            // v42: the region's firefighters, right under the lines. Labelled
            // with the same words the card uses, so nothing new has to be read.
            if (firePhotoForCountry(country.iso) case final firePhoto?) ...[
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: SizedBox(
                  height: 120,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.memory(firePhoto, fit: BoxFit.cover, gaplessPlayback: true),
                      Align(
                        alignment: Alignment.bottomLeft,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                          child: Text(
                            '${country.flag}  ${t('emergency.fire')}',
                            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700, shadows: [Shadow(color: Color(0x99000000), blurRadius: 8, offset: Offset(0, 1))]),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
          ],
          // v43: the world reel - every police and firefighter photo in the
          // library, from eight regions and four fire services, sliding past
          // on its own like a screensaver. A gentle timer advances the reel
          // every few seconds; a drag by the person pauses it for a moment.
          // Shown for every country: the photos are a tour of the world's
          // forces, not this country's own.
          Text(t('police.gallery_note').toUpperCase(), style: Theme.of(context).textTheme.labelMedium?.copyWith(letterSpacing: 1.1, color: cs.outline)),
          const SizedBox(height: 10),
          _WorldGallery(widget.i18n),
          const SizedBox(height: 20),
          if (ngLayout) ...[
            Text(t('police.note'), style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 16),
            Text(t('police.all').toUpperCase(), style: Theme.of(context).textTheme.labelMedium?.copyWith(letterSpacing: 1.1, color: cs.outline)),
            const SizedBox(height: 8),
            Card(
              child: Column(
                children: [
                  for (var i = 0; i < dir.commands.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    _CommandTile(dir.commands[i], widget.i18n),
                  ],
                ],
              ),
            ),
          ] else ...[
            const SizedBox(height: 16),
            Text(t('police.global_note'), style: TextStyle(fontSize: 13, height: 1.45, color: cs.outline)),
          ],
        ],
      ),
    );
  }
}

class _CommandTile extends StatelessWidget {
  const _CommandTile(this.c, this.i18n);
  final PoliceCommand c;
  final I18n i18n;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final official = c.verified || c.npfListed;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(c.state, style: Theme.of(context).textTheme.titleMedium)),
              if (official)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(color: cs.tertiary),
                  ),
                  child: Text(
                    i18n.t(c.verified ? 'police.verified' : 'police.listed'),
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: cs.tertiary),
                  ),
                ),
            ],
          ),
          if (c.commissioner != null) ...[
            const SizedBox(height: 4),
            Text(
              '${i18n.t('police.commissioner')}: ${c.commissioner}',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.onSurface),
            ),
          ],
          const SizedBox(height: 6),
          for (final l in c.lines)
            Row(children: [
              Expanded(
                child: SelectableText(l, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()])),
              ),
              // Only a real number line gets the call button: text lines like
              // "767 or 112 (toll-free)" would dial stripped nonsense digits.
              if (RegExp(r'^\+?[0-9][0-9 ()\-]{5,}$').hasMatch(l))
                IconButton(
                  tooltip: 'Call',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.call, color: cs.primary),
                  onPressed: () {
                    final n = _dialable(l);
                    unawaited(launchUrl(Uri(scheme: 'tel', path: n), mode: LaunchMode.externalApplication).catchError((_) => false));
                  },
                ),
            ]),
        ],
      ),
    );
  }
}

/// The world gallery (v43): an auto-scrolling reel of the police and
/// firefighter photos from around the world, the way a photo wall glides past.
///
/// How it stays pleasant instead of annoying:
/// * the timer advances one slide every 3.2 seconds and stops the moment the
///   person's own finger starts a drag, resuming a few seconds after the drag
///   settles, so it never fights the hand that feeds it;
/// * the reel walks forward slide by slide and, at the end, glides back to the
///   first - a tour that starts over, not a slide deck that stops;
/// * the photos decode once (the photo file caches) and the captions reuse the
///   words the emergency card already teaches: "Police" / "Fire service".
class _WorldGallery extends StatefulWidget {
  const _WorldGallery(this.i18n);
  final I18n i18n;

  @override
  State<_WorldGallery> createState() => _WorldGalleryState();
}

class _WorldGalleryState extends State<_WorldGallery> {
  late final PageController _pc = PageController(viewportFraction: 0.86);
  Timer? _auto;
  Timer? _resume;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _auto = Timer.periodic(const Duration(milliseconds: 3200), (_) => _advance());
  }

  @override
  void dispose() {
    _auto?.cancel();
    _resume?.cancel();
    _pc.dispose();
    super.dispose();
  }

  void _advance() {
    if (!mounted || _dragging || !_pc.hasClients) return;
    final page = (_pc.page ?? 0).round();
    if (page >= worldGalleryItems.length - 1) {
      // End of the reel: glide back to the start and begin the tour again.
      _pc.animateToPage(0, duration: const Duration(milliseconds: 900), curve: Curves.easeInOutCubic);
    } else {
      _pc.animateToPage(page + 1, duration: const Duration(milliseconds: 560), curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = widget.i18n.t;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      NotificationListener<ScrollNotification>(
        onNotification: (n) {
          // A hand on the reel pauses the timer; a settled hand hands
          // control back after a short grace period.
          if (n is ScrollStartNotification && n.dragDetails != null) {
            _dragging = true;
            _resume?.cancel();
          } else if (n is ScrollEndNotification) {
            _resume?.cancel();
            _resume = Timer(const Duration(seconds: 4), () {
              if (mounted) setState(() => _dragging = false);
            });
          }
          return false;
        },
        child: SizedBox(
          height: 186,
          child: PageView.builder(
            controller: _pc,
            itemCount: worldGalleryItems.length,
            itemBuilder: (context, i) {
              final item = worldGalleryItems[i];
              final bytes = worldGalleryPhoto(item.key);
              final kindLabel = t(item.kind == 'police' ? 'emergency.police' : 'emergency.fire');
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (bytes != null) Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: [Color(0x8C000000), Color(0x00000000)],
                            ),
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.bottomLeft,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${item.flag} ${item.place} · $kindLabel',
                                style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w700, shadows: [Shadow(color: Color(0x99000000), blurRadius: 8, offset: Offset(0, 1))]),
                              ),
                              Text(
                                item.credit,
                                style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 9.5, shadows: [Shadow(color: Color(0x99000000), blurRadius: 6, offset: Offset(0, 1))]),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
      const SizedBox(height: 10),
      // The dots: rebuilt from the controller's own scroll animation.
      AnimatedBuilder(
        animation: _pc,
        builder: (context, _) {
          final page = (_pc.page ?? 0).round().clamp(0, worldGalleryItems.length - 1);
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < worldGalleryItems.length; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  height: 7,
                  width: i == page ? 18 : 7,
                  decoration: BoxDecoration(
                    color: i == page ? cs.primary : cs.outline.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
            ],
          );
        },
      ),
    ]);
  }
}
