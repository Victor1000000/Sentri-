import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/i18n/i18n.dart';
import '../../core/widgets/brand.dart';
import 'onboarding_controller.dart';
import 'permissions_panel.dart';
import '../../core/platform/native_bridge.dart';

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
                    onLanguage: (code) async {
                      await i18n.setLanguage(code);
                      await c.settings.update(language: code);
                    },
                  ),
                  Expanded(
                    child: SingleChildScrollView(
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
  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _title(context, widget.i18n.t('phone.title')),
          Text(widget.i18n.t('phone.help')),
          const SizedBox(height: 16),
          PillField(
            controller: _ctl,
            label: widget.i18n.t('phone.title'),
            keyboardType: TextInputType.phone,
            autofillHints: const [AutofillHints.telephoneNumber],
            hint: '0803 123 4567',
          ),
          const SizedBox(height: 16),
          PillButton(
            onPressed: widget.c.busy ? null : () => unawaited(widget.c.submitPhone(_ctl.text)),
            label: widget.i18n.t('phone.send_code'),
          ),
        ],
      );
}

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
    for (var i = 0; i < 3; i++) {
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
          _title(context, widget.i18n.t('contacts.title')),
          Text(widget.i18n.t('contacts.help')),
          const SizedBox(height: 16),
          for (var i = 0; i < _ctls.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: PillField(key: ObjectKey(_ctls[i]), controller: _ctls[i], focusNode: _focus[i], noAutofill: true, keyboardType: TextInputType.phone, hint: widget.i18n.t('contacts.phone_hint')),
            ),
          if (_ctls.length < 5)
            OutlinePill(
              onPressed: () => setState(_addBox),
              label: '+ ${widget.i18n.t('contacts.add')}',
            ),
          const SizedBox(height: 14),
          PillButton(
            onPressed: widget.c.busy
                ? null
                : () => unawaited(widget.c.submitContacts(
                      [for (final c in _ctls) c.text],
                      // Each contact is texted in the language chosen for this app, until per-contact choice is added.
                      locales: [for (final _ in _ctls) widget.i18n.code],
                    )),
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
          PillField(controller: c, label: label, keyboardType: TextInputType.number, obscure: true, maxLength: 8),
          if (help != null) Padding(padding: const EdgeInsets.only(left: 8, top: 4), child: Text(help, style: Theme.of(context).textTheme.bodySmall)),
        ]),
      );

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
