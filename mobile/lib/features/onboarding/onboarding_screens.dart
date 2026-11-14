import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data' show Uint8List;
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/emergency.dart';
import '../../core/i18n/i18n.dart';
import '../../core/phone.dart';
import '../../core/widgets/brand.dart';
import '../../core/widgets/flat.dart';
import 'floating3d.dart';
import 'onboarding_controller.dart';
import 'permissions_panel.dart';
import '../../core/platform/native_bridge.dart';

/// Typing a phone number: only characters a number can contain, and no more than a number needs.
/// The number is normalised and checked again before anything is sent.
final _phoneFormatters = <TextInputFormatter>[
  FilteringTextInputFormatter.allow(RegExp(r'[0-9+\-\s().]')),
  LengthLimitingTextInputFormatter(24),
];

/// The code and the PINs are digits only. Their length is checked again before anything is sent.
final _digitFormatters = <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly];

/// The sign-up screens. One widget per step, switched by [OnboardingController.step].
class OnboardingFlow extends StatelessWidget {
  const OnboardingFlow({super.key, required this.c, required this.i18n, required this.bridge});
  final OnboardingController c;
  final I18n i18n;
  final NativeBridge bridge;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([c, i18n]),
      builder: (context, _) {
        final Widget body;
        switch (c.step) {
          case OnboardingStep.language:
            body = _PhoneStep(c: c, i18n: i18n); // language is chosen from the top-right button
          case OnboardingStep.phone:
            body = _PhoneStep(c: c, i18n: i18n);
          case OnboardingStep.otp:
            body = _OtpStep(c: c, i18n: i18n);
          case OnboardingStep.contacts:
            body = _ContactsStep(c: c, i18n: i18n);
          case OnboardingStep.pins:
            body = _PinsStep(c: c, i18n: i18n);
          case OnboardingStep.permissions:
            body = _PermissionsStep(c: c, i18n: i18n, bridge: bridge);
          case OnboardingStep.done:
            body = const SizedBox.shrink();
        }
        final dot = switch (c.step) {
          OnboardingStep.language || OnboardingStep.phone || OnboardingStep.otp => 0,
          OnboardingStep.contacts => 1,
          _ => 2,
        };
        return Scaffold(
          body: SentriBackground(
            child: SafeArea(
              child: Column(
                children: [
                  SentriTopBar(
                    i18n: i18n,
                    // v41: before the number is typed, the device's own region
                    // picks the language set; the sign-up number takes over later.
                    countryIso: countryForLocale(Platform.localeName)?.iso,
                    onLanguage: (code) async {
                      await i18n.setLanguage(code);
                      await c.settings.update(language: code);
                    },
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                      padding: const EdgeInsets.fromLTRB(26, 56, 26, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          body,
                          if (c.errorKey != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(i18n.t(c.errorKey!), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                            ),
                          if (c.busy) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
                        ],
                      ),
                    ),
                  ),
                  Padding(padding: const EdgeInsets.only(bottom: 28), child: PagerDots(index: dot)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

Widget _title(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(text, style: Theme.of(context).textTheme.headlineSmall),
    );

class _LanguageStep extends StatelessWidget {
  const _LanguageStep({required this.c});
  final OnboardingController c;
  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _title(context, c.i18n.t('lang.title')),
          for (final l in supportedLanguages)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: OutlinedButton(onPressed: () => unawaited(c.chooseLanguage(l.code)), child: Text(l.nativeName)),
            ),
        ],
      );
}

class _PhoneStep extends StatefulWidget {
  const _PhoneStep({required this.c, required this.i18n});
  final OnboardingController c;
  final I18n i18n;
  @override
  State<_PhoneStep> createState() => _PhoneStepState();
}

class _PhoneStepState extends State<_PhoneStep> {
  final _ctl = TextEditingController();

  /// The country whose dial code local-format numbers belong to, picked
  /// Life360-style (v43): a row of flag + code + name that opens a searchable
  /// sheet of every country Sentri knows. Picking one immediately moves the
  /// controller's dial code, so the number is normalised with THEIR country.
  late SentriCountry _country = countryByDial(widget.c.countryCode) ?? countryForLocale(Platform.localeName) ?? sentriCountries.first;

  @override
  void initState() {
    super.initState();
    // If the server forgot the session, start with the number they used last time filled in.
    _ctl.text = widget.c.settings.lastPhone;
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  /// The searchable country sheet, Life360-style: a search field, the
  /// recommended countries (the phone's own region first, then the world's
  /// biggest dial codes), and finally the complete alphabetical list. Pure
  /// filtering lives in [searchCountries] so it can be unit-tested.
  Future<void> _pickCountry() async {
    final t = widget.i18n.t;
    final localeCountry = countryForLocale(Platform.localeName);
    final recommended = <SentriCountry>[if (localeCountry != null) localeCountry];
    for (final iso in const ['us', 'it', 'in', 'br', 'gb', 'kr', 'mx', 'de']) {
      if (countryByIso(iso) case final c?) {
        if (!recommended.any((r) => r.iso == c.iso)) recommended.add(c);
      }
    }
    final picked = await showModalBottomSheet<SentriCountry>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        var query = '';
        return StatefulBuilder(
          builder: (sheetContext, setSheet) {
            final cs = Theme.of(sheetContext).colorScheme;
            final results = searchCountries(query);
            final showRecommended = query.trim().isEmpty;
            final list = showRecommended
                ? [
                    ...results.where((c) => recommended.any((r) => r.iso == c.iso)),
                    if (results.any((c) => !recommended.any((r) => r.iso == c.iso)))
                      ...results.where((c) => !recommended.any((r) => r.iso == c.iso)),
                  ]
                : results;
            return Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheetContext).bottom),
              child: Container(
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.82),
                decoration: BoxDecoration(
                  color: cs.surface,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                    child: TextField(
                      autofocus: true,
                      onChanged: (v) => setSheet(() => query = v),
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search_rounded),
                        hintText: t('country.search'),
                        isDense: true,
                        filled: true,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none),
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
                      children: [
                        if (showRecommended) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                            child: Text(t('country.recommended').toUpperCase(), style: Theme.of(sheetContext).textTheme.labelMedium?.copyWith(letterSpacing: 1.1, color: cs.outline)),
                          ),
                          for (final c in recommended.where((r) => list.any((l) => l.iso == r.iso))) _CountryRow(c, onPick: (c2) => Navigator.of(sheetContext).pop(c2)),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
                            child: Text(t('country.all').toUpperCase(), style: Theme.of(sheetContext).textTheme.labelMedium?.copyWith(letterSpacing: 1.1, color: cs.outline)),
                          ),
                          for (final c in list.where((c) => !recommended.any((r) => r.iso == c.iso))) _CountryRow(c, onPick: (c2) => Navigator.of(sheetContext).pop(c2)),
                        ] else
                          for (final c in list) _CountryRow(c, onPick: (c2) => Navigator.of(sheetContext).pop(c2)),
                        if (list.isEmpty && !showRecommended)
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Center(child: Icon(Icons.search_off_rounded, size: 40, color: cs.outline)),
                          ),
                      ],
                    ),
                  ),
                ]),
              ),
            );
          },
        );
      },
    );
    if (picked == null) return;
    setState(() {
      _country = picked;
      widget.c.countryCode = picked.dial;
    });
  }

  @override
  Widget build(BuildContext context) {
    // The welcome moment: the 3D floating field above, the form in one soft card below.
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _FloatingField(),
          _title(context, widget.i18n.t('phone.title')),
          Text(widget.i18n.t('phone.help'), style: TextStyle(fontSize: 14, height: 1.45, color: Flat.muted(context))),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Flat.card(context),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Flat.hairline(context)),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 14, offset: const Offset(0, 6))],
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // The country row, Life360-style: flag, dial code, name, chevron.
              // One tap opens the searchable country sheet below.
              InkWell(
                onTap: widget.c.busy ? null : _pickCountry,
                borderRadius: BorderRadius.circular(30),
                child: Container(
                  height: 54,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  decoration: BoxDecoration(
                    color: (Theme.of(context).brightness == Brightness.dark ? Colors.white.withValues(alpha: 0.08) : Colors.white.withValues(alpha: 0.5)),
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(color: Theme.of(context).colorScheme.onSurface, width: 2.5),
                  ),
                  child: Row(children: [
                    Text(_country.flag, style: const TextStyle(fontSize: 22)),
                    const SizedBox(width: 12),
                    Text('+${_country.dial}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, fontFeatures: [FontFeature.tabularFigures()])),
                    const SizedBox(width: 10),
                    Expanded(child: Text(_country.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis)),
                    Icon(Icons.keyboard_arrow_down_rounded, size: 26, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)),
                  ]),
                ),
              ),
              const SizedBox(height: 14),
              PillField(
                controller: _ctl,
                label: widget.i18n.t('phone.title'),
                keyboardType: TextInputType.phone,
                autofillHints: const [AutofillHints.telephoneNumber],
                inputFormatters: _phoneFormatters,
                hint: '0803 123 4567',
              ),
              const SizedBox(height: 14),
              PillButton(
                onPressed: widget.c.busy ? null : () => unawaited(widget.c.submitPhone(_ctl.text)),
                label: widget.i18n.t('phone.send_code'),
              ),
            ]),
          ),
        ],
      );
  }
}

/// The playful welcome field: real 3D renders - the siren, the bell, the shield,
/// the pin and two faces - drift and tilt on their own sine phases above the
/// form, each grounded by a soft shadow that reacts to its height.
class _FloatingField extends StatefulWidget {
  const _FloatingField();
  @override
  State<_FloatingField> createState() => _FloatingFieldState();
}

class _FloatingFieldState extends State<_FloatingField> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 4200))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) return _field(t: 0.25, animate: false);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => _field(t: _c.value, animate: true),
    );
  }

  /// The welcome moment: real 3D renders (the siren, the bell, the shield, the
  /// pin, and two faces) drifting above the form, connected by a moving line
  /// that glides from one to the next and directs the eye across them.
  Widget _field({required double t, required bool animate}) {
    double wave(double phase) => math.sin(2 * math.pi * (t + phase));
    final items = <({Uint8List bytes, double size, double phase, double amp, double left, double top, double spin})>[
      (bytes: f3dsirenBytes, size: 78, phase: 0.00, amp: 9, left: 30, top: 12, spin: 0.07),
      (bytes: f3dgrinBytes, size: 50, phase: 0.20, amp: 7, left: 128, top: 4, spin: 0.05),
      (bytes: f3dshieldBytes, size: 46, phase: 0.55, amp: 6, left: 232, top: 56, spin: 0.05),
      (bytes: f3dpinBytes, size: 40, phase: 0.42, amp: 6, left: 208, top: 120, spin: 0.06),
      (bytes: f3dsmileBytes, size: 46, phase: 0.80, amp: 7, left: 6, top: 116, spin: 0.05),
      (bytes: f3dbellBytes, size: 42, phase: 0.68, amp: 8, left: 106, top: 100, spin: 0.06),
    ];
    return SizedBox(
      height: 170,
      child: Stack(children: [
        // The moving line: a smooth path through the elements, dashed, with the
        // dashes gliding along it - it reads as energy flowing element to
        // element, directing the eye exactly like the reference boards.
        Positioned.fill(
          child: CustomPaint(
            painter: ConnectLine([for (final it in items) Offset(it.left + it.size / 2, it.top + it.size / 2)], wave(0.30)),
          ),
        ),
        for (final it in items)
          FloatItem3d(bytes: it.bytes, size: it.size, phase: it.phase, amp: it.amp, left: it.left, top: it.top, spin: it.spin, t: t, animate: animate),
      ]),
    );
  }
}

/// Three-item bands for the sign-up steps, mirroring the welcome field's cast.

class _OtpStep extends StatefulWidget {
  const _OtpStep({required this.c, required this.i18n});
  final OnboardingController c;
  final I18n i18n;
  @override
  State<_OtpStep> createState() => _OtpStepState();
}

class _OtpStepState extends State<_OtpStep> {
  final _ctl = TextEditingController();
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _tick?.cancel();
    _ctl.dispose();
    super.dispose();
  }

  int get _wait {
    final s = widget.c.resendAt.difference(DateTime.now()).inSeconds + 1;
    return s > 0 ? s : 0;
  }

  @override
  Widget build(BuildContext context) {
    // Telegram mode: the code comes from the login bot, so there is no text message and no resend timer.
    final telegram = widget.c.telegramUrl != null;
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FloatBand([
            (bytes: f3dbellBytes, size: 50, left: 26, top: 10, phase: 0.00),
            (bytes: f3dstarBytes, size: 44, left: 150, top: 34, phase: 0.40),
            (bytes: f3dshieldBytes, size: 48, left: 258, top: 6, phase: 0.72),
          ]),
          _title(context, widget.i18n.t('otp.title')),
          Text(widget.i18n.t(telegram ? 'otp.telegram_sent' : 'otp.sent_to', {'phone': widget.c.phone})),
          if (telegram) ...[
            const SizedBox(height: 6),
            Text(widget.i18n.t('otp.telegram_hint'), style: const TextStyle(fontSize: 13)),
          ],
          const SizedBox(height: 16),
          PillField(
            controller: _ctl,
            label: widget.i18n.t('otp.title'),
            keyboardType: TextInputType.number,
            maxLength: 6,
            obscure: true,
            inputFormatters: _digitFormatters,
            autofillHints: const [AutofillHints.oneTimeCode],
          ),
          if (widget.c.devCode != null) ...[
            const SizedBox(height: 10),
            // Test mode only: the server sent no real text and handed the code back.
            GestureDetector(
              onTap: () => _ctl.text = widget.c.devCode!,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(color: Brand.mint.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(14)),
                child: Text(widget.i18n.t('otp.test_code', {'code': widget.c.devCode!}), style: const TextStyle(fontSize: 13)),
              ),
            ),
          ],
          const SizedBox(height: 16),
          PillButton(
            onPressed: widget.c.busy ? null : () => unawaited(widget.c.submitCode(_ctl.text)),
            label: widget.i18n.t('otp.verify'),
          ),
          const SizedBox(height: 6),
          if (telegram)
            TextButton(
              onPressed: widget.c.busy ? null : () => unawaited(widget.c.openTelegram()),
              child: Text(widget.i18n.t('otp.open_telegram')),
            )
          else
            TextButton(
              onPressed: widget.c.busy || _wait > 0 ? null : () => unawaited(widget.c.resendCode()),
              child: Text(_wait > 0 ? widget.i18n.t('otp.resend_in', {'s': '$_wait'}) : widget.i18n.t('otp.resend')),
            ),
        ],
      );
  }
}

class _ContactsStep extends StatefulWidget {
  const _ContactsStep({required this.c, required this.i18n});
  final OnboardingController c;
  final I18n i18n;
  @override
  State<_ContactsStep> createState() => _ContactsStepState();
}

class _ContactsStepState extends State<_ContactsStep> {
  final List<TextEditingController> _ctls = [];
  final List<FocusNode> _focus = [];
  Timer? _guard;

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < 2; i++) {
      _addBox();
    }
    // Autofill can set the boxes at different moments with no event we can rely on, so check on a short timer too.
    _guard = Timer.periodic(const Duration(milliseconds: 250), (_) => _dedupe());
  }

  void _addBox() {
    final c = TextEditingController();
    _ctls.add(c);
    _focus.add(FocusNode());
    c.addListener(_dedupe);
  }

  /// Each box is its own number. Phone autofill can drop one saved number into every phone box, and a number can
  /// never be a contact twice, so a box that is not being typed in and repeats an earlier box is emptied.
  void _dedupe() {
    for (var i = 1; i < _ctls.length; i++) {
      final t = _ctls[i].text;
      if (t.isEmpty || _focus[i].hasFocus) continue;
      for (var k = 0; k < i; k++) {
        if (_ctls[k].text == t) {
          _ctls[i].text = '';
          break;
        }
      }
    }
  }

  @override
  void dispose() {
    _guard?.cancel();
    for (final c in _ctls) {
      c.dispose();
    }
    for (final f in _focus) {
      f.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FloatBand([
            (bytes: f3dgrinBytes, size: 50, left: 26, top: 10, phase: 0.00),
            (bytes: f3dsmileBytes, size: 44, left: 150, top: 34, phase: 0.40),
            (bytes: f3dpinBytes, size: 48, left: 258, top: 6, phase: 0.72),
          ]),
          _title(context, widget.i18n.t('contacts.title')),
          Text(widget.i18n.t('contacts.help')),
          const SizedBox(height: 16),
          for (var i = 0; i < _ctls.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: PillField(key: ObjectKey(_ctls[i]), controller: _ctls[i], focusNode: _focus[i], noAutofill: true, keyboardType: TextInputType.phone, inputFormatters: _phoneFormatters, hint: widget.i18n.t('contacts.phone_hint')),
            ),
          // Only two numbers are needed at sign-up; the remaining slots (up to ten in
          // total) can stay empty now and be added later in the contacts tab.
          if (_ctls.length < 10)
            OutlinePill(
              onPressed: () => setState(_addBox),
              label: '+ ${widget.i18n.t('contacts.add')}',
            ),
          const SizedBox(height: 14),
          PillButton(
            onPressed: widget.c.busy
                ? null
                : () {
                    // The server refused the save because an alert started earlier is
                    // still running on this account. The list is safe on this phone and
                    // a quiet retry syncs it, so Continue moves on instead of trapping
                    // the person on this step.
                    if (widget.c.contactsPendingServer) {
                      widget.c.continuePastBlockedContacts();
                      return;
                    }
                    unawaited(widget.c.submitContacts(
                      [for (final c in _ctls) c.text],
                      // Each contact is texted in the language chosen for this app, until per-contact choice is added.
                      locales: [for (final _ in _ctls) widget.i18n.code],
                    ));
                  },
            label: widget.i18n.t('common.continue'),
          ),
        ],
      );
}

class _PinsStep extends StatefulWidget {
  const _PinsStep({required this.c, required this.i18n});
  final OnboardingController c;
  final I18n i18n;
  @override
  State<_PinsStep> createState() => _PinsStepState();
}

class _PinsStepState extends State<_PinsStep> {
  final _cancel = TextEditingController();
  final _confirm = TextEditingController();
  @override
  void dispose() {
    _cancel.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Widget _field(BuildContext context, TextEditingController c, String label, String? help) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          PillField(controller: c, label: label, keyboardType: TextInputType.number, obscure: true, maxLength: 4, inputFormatters: _digitFormatters),
          if (help != null) Padding(padding: const EdgeInsets.only(left: 8, top: 4), child: Text(help, style: Theme.of(context).textTheme.bodySmall)),
        ]),
      );

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FloatBand([
            (bytes: f3dshieldBytes, size: 50, left: 26, top: 10, phase: 0.00),
            (bytes: f3dstarBytes, size: 44, left: 150, top: 34, phase: 0.40),
            (bytes: f3dsmileBytes, size: 48, left: 258, top: 6, phase: 0.72),
          ]),
          _title(context, widget.i18n.t('pins.title')),
          Text(widget.i18n.t('pins.cancel_help')),
          const SizedBox(height: 16),
          _field(context, _cancel, widget.i18n.t('pins.cancel_label'), null),
          _field(context, _confirm, widget.i18n.t('pins.confirm_label'), null),
          PillButton(
            onPressed: widget.c.busy ? null : () => unawaited(widget.c.submitPins(_cancel.text, _confirm.text)),
            label: widget.i18n.t('common.continue'),
          ),
        ],
      );
}

class _PermissionsStep extends StatelessWidget {
  const _PermissionsStep({required this.c, required this.i18n, required this.bridge});
  final OnboardingController c;
  final I18n i18n;
  final NativeBridge bridge;
  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _title(context, i18n.t('perm.title')),
          PermissionsPanel(bridge: bridge, i18n: i18n),
          const SizedBox(height: 16),
          PillButton(onPressed: () => unawaited(c.finish()), label: i18n.t('perm.finish')),
        ],
      );
}

/// One line of the country sheet: flag, name, dial code (v43). Tapping picks it.
class _CountryRow extends StatelessWidget {
  const _CountryRow(this.c, {required this.onPick});
  final SentriCountry c;
  final ValueChanged<SentriCountry> onPick;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => onPick(c),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          Text(c.flag, style: const TextStyle(fontSize: 24)),
          const SizedBox(width: 14),
          Expanded(child: Text(c.name, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600))),
          Text('+${c.dial}', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: cs.onSurface.withValues(alpha: 0.65), fontFeatures: const [FontFeature.tabularFigures()])),
        ]),
      ),
    );
  }
}
