import 'package:flutter/material.dart';

/// Number pad for the cancel PIN. The PIN is exactly 4 digits: the fourth digit submits at
/// once, like a bank card machine, so there is no OK key and no way to type more.
/// Dots (not digits) are shown, and haptics/sounds are left off so nothing draws attention.
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
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: SizedBox(
          height: 62,
          child: FilledButton(
            onPressed: widget.enabled ? onTap : null,
            style: FilledButton.styleFrom(
              minimumSize: Size.zero,
              backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
              foregroundColor: Theme.of(context).colorScheme.onSurface,
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
