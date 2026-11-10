import 'package:flutter/material.dart';

import '../../core/widgets/flat.dart';

/// Number pad for the cancel PIN — in the flat family: solid card squares with a
/// hairline edge, like every other card on this app, and the dots fill in the
/// alarm red as the digits go in. The PIN is exactly 4 digits: the fourth digit
/// submits at once, like a bank card machine, so there is no OK key and no way
/// to type more. Dots (not digits) are shown, and haptics/sounds are left off so
/// nothing draws attention.
class PinPad extends StatefulWidget {
  const PinPad({super.key, required this.onSubmit, this.enabled = true});
  final void Function(String pin) onSubmit;
  final bool enabled;

  @override
  State<PinPad> createState() => PinPadState();
}

class PinPadState extends State<PinPad> {
  static const int _length = 4;
  String _pin = '';

  /// Clears the entry (used after a wrong PIN).
  void clear() => setState(() => _pin = '');

  void _add(String d) {
    if (!widget.enabled || _pin.length >= _length) return;
    final next = _pin + d;
    setState(() => _pin = next);
    if (next.length == _length) widget.onSubmit(next);
  }

  void _back() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Widget _key(BuildContext context, String label, VoidCallback onTap, {IconData? icon}) {
    final radius = BorderRadius.circular(14);
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: Material(
          color: Flat.card(context),
          shape: RoundedRectangleBorder(borderRadius: radius, side: BorderSide(color: Flat.hairline(context))),
          child: InkWell(
            borderRadius: radius,
            onTap: widget.enabled ? onTap : null,
            child: SizedBox(
              height: 62,
              alignment: Alignment.center,
              child: icon != null
                  ? Icon(icon, size: 22, color: Flat.muted(context))
                  : Text(label, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w500)),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 28,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < _length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    margin: const EdgeInsets.symmetric(horizontal: 5),
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i < _pin.length ? Flat.danger : Colors.transparent,
                      border: Border.all(color: i < _pin.length ? Flat.danger : Flat.hairline(context), width: 1.5),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          for (final row in const [
            ['1', '2', '3'],
            ['4', '5', '6'],
            ['7', '8', '9'],
          ])
            Row(children: [for (final d in row) _key(context, d, () => _add(d))]),
          Row(children: [
            const Expanded(child: SizedBox(height: 62)),
            _key(context, '0', () => _add('0')),
            _key(context, '', _back, icon: Icons.backspace_outlined),
          ]),
        ],
      ),
    );
  }
}
