import 'package:flutter/material.dart';

/// Number pad for entering a PIN. PINs are 4-8 digits, so there is an explicit OK key.
/// Dots (not digits) are shown, and haptics/sounds are left off so nothing draws attention.
class PinPad extends StatefulWidget {
  const PinPad({super.key, required this.onSubmit, this.maxLength = 8, this.enabled = true});
  final void Function(String pin) onSubmit;
  final int maxLength;
  final bool enabled;

  @override
  State<PinPad> createState() => PinPadState();
}

class PinPadState extends State<PinPad> {
  String _pin = '';

  /// Clears the entry (used after a wrong PIN).
  void clear() => setState(() => _pin = '');

  void _add(String d) {
    if (!widget.enabled || _pin.length >= widget.maxLength) return;
    setState(() => _pin += d);
  }

  void _back() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  void _ok() {
    if (!widget.enabled || _pin.length < 4) return;
    final p = _pin;
    setState(() => _pin = '');
    widget.onSubmit(p);
  }

  Widget _key(BuildContext context, String label, VoidCallback onTap, {IconData? icon, bool primary = false}) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: SizedBox(
          height: 60,
          child: FilledButton(
            onPressed: widget.enabled ? onTap : null,
            style: FilledButton.styleFrom(
              minimumSize: Size.zero,
              backgroundColor: primary ? cs.primary : cs.surfaceContainerHighest,
              foregroundColor: primary ? cs.onPrimary : cs.onSurface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            child: icon != null ? Icon(icon) : Text(label, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w500)),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Eight slots so the layout never jumps as digits are added.
          SizedBox(
            height: 28,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < widget.maxLength; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    margin: const EdgeInsets.symmetric(horizontal: 5),
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i < _pin.length ? cs.onSurface : Colors.transparent,
                      border: Border.all(color: i < _pin.length ? cs.onSurface : cs.outline, width: 1.5),
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
          Row(
            children: [
              _key(context, '', _back, icon: Icons.backspace_outlined),
              _key(context, '0', () => _add('0')),
              _key(context, '', _ok, icon: Icons.check, primary: true),
            ],
          ),
        ],
      ),
    );
  }
}
